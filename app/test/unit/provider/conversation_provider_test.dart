import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_app/provider/conversation_provider.dart';
import 'package:localchat_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import '../../mocks.mocks.dart';

void main() {
  late MockPersistenceService persistenceService;

  setUp(() {
    persistenceService = MockPersistenceService();
  });

  ConversationService createService() {
    return ConversationService(persistenceService);
  }

  ChatMessage textMessage({
    required String id,
    ChatMessageDirection direction = ChatMessageDirection.received,
    DateTime? timestamp,
  }) {
    return ChatMessage(
      id: id,
      direction: direction,
      kind: ChatMessageKind.text,
      timestamp: timestamp ?? DateTime(2026, 1, 1, 10),
      status: direction == ChatMessageDirection.sent ? ChatMessageStatus.sent : ChatMessageStatus.received,
      text: 'hello $id',
      fileSize: 5,
      fileType: FileType.text,
    );
  }

  test('新增消息会创建会话', () async {
    final service = ReduxNotifier.test(redux: createService());

    await service.dispatchAsync(
      AppendChatMessageAction(
        peerFingerprint: 'fp-a',
        peerAlias: 'Alice',
        message: textMessage(id: 'm1'),
      ),
    );

    expect(service.state.length, 1);
    expect(service.state.first.peerFingerprint, 'fp-a');
    expect(service.state.first.peerAlias, 'Alice');
    expect(service.state.first.messages.length, 1);
    expect(service.state.first.unreadCount, 1, reason: '接收方向应累加未读');
  });

  test('相同消息 ID 重复写入是幂等的', () async {
    final service = ReduxNotifier.test(redux: createService());

    for (var i = 0; i < 3; i++) {
      await service.dispatchAsync(
        AppendChatMessageAction(
          peerFingerprint: 'fp-a',
          peerAlias: 'Alice',
          message: textMessage(id: 'm1'),
        ),
      );
    }

    expect(service.state.length, 1);
    expect(service.state.first.messages.length, 1);
    expect(service.state.first.unreadCount, 1);
  });

  test('发送方向不累加未读', () async {
    final service = ReduxNotifier.test(redux: createService());

    await service.dispatchAsync(
      AppendChatMessageAction(
        peerFingerprint: 'fp-a',
        peerAlias: 'Alice',
        message: textMessage(id: 'm1', direction: ChatMessageDirection.sent),
      ),
    );

    expect(service.state.first.unreadCount, 0);
  });

  test('不同指纹互不干扰，且按最近活动倒序排列', () async {
    final service = ReduxNotifier.test(redux: createService());

    await service.dispatchAsync(
      AppendChatMessageAction(
        peerFingerprint: 'fp-a',
        peerAlias: 'Alice',
        message: textMessage(id: 'a1', timestamp: DateTime(2026, 1, 1, 10)),
      ),
    );
    await service.dispatchAsync(
      AppendChatMessageAction(
        peerFingerprint: 'fp-b',
        peerAlias: 'Bob',
        message: textMessage(id: 'b1', timestamp: DateTime(2026, 1, 1, 12)),
      ),
    );

    expect(service.state.length, 2);
    expect(service.state.first.peerFingerprint, 'fp-b', reason: '最近活动的会话排在前面');
  });

  test('对端改名后会话合并到同一指纹下', () async {
    final service = ReduxNotifier.test(redux: createService());

    await service.dispatchAsync(
      AppendChatMessageAction(
        peerFingerprint: 'fp-a',
        peerAlias: 'Alice',
        message: textMessage(id: 'm1'),
      ),
    );
    await service.dispatchAsync(
      AppendChatMessageAction(
        peerFingerprint: 'fp-a',
        peerAlias: 'Alice-New',
        message: textMessage(id: 'm2'),
      ),
    );

    expect(service.state.length, 1, reason: '同一指纹只应有一个会话');
    expect(service.state.first.peerAlias, 'Alice-New', reason: '别名应更新为最新值');
    expect(service.state.first.messages.length, 2);
  });

  test('消息按时间正序排列', () async {
    final service = ReduxNotifier.test(redux: createService());

    await service.dispatchAsync(
      AppendChatMessageAction(
        peerFingerprint: 'fp-a',
        peerAlias: 'Alice',
        message: textMessage(id: 'late', timestamp: DateTime(2026, 1, 1, 12)),
      ),
    );
    await service.dispatchAsync(
      AppendChatMessageAction(
        peerFingerprint: 'fp-a',
        peerAlias: 'Alice',
        message: textMessage(id: 'early', timestamp: DateTime(2026, 1, 1, 9)),
      ),
    );

    expect(service.state.first.messages.map((e) => e.id).toList(), ['early', 'late']);
  });

  test('单会话消息数超过上限时丢弃最旧的', () async {
    final service = ReduxNotifier.test(redux: createService());

    for (var i = 0; i <= maxMessagesPerConversation; i++) {
      await service.dispatchAsync(
        AppendChatMessageAction(
          peerFingerprint: 'fp-a',
          peerAlias: 'Alice',
          message: textMessage(id: 'm$i', timestamp: DateTime(2026, 1, 1).add(Duration(seconds: i))),
        ),
      );
    }

    final messages = service.state.first.messages;
    expect(messages.length, maxMessagesPerConversation);
    expect(messages.first.id, 'm1', reason: '最旧的 m0 应被丢弃');
    expect(messages.last.id, 'm$maxMessagesPerConversation');
  });

  test('标记已读会清零未读', () async {
    final service = ReduxNotifier.test(redux: createService());

    await service.dispatchAsync(
      AppendChatMessageAction(
        peerFingerprint: 'fp-a',
        peerAlias: 'Alice',
        message: textMessage(id: 'm1'),
      ),
    );
    expect(service.state.first.unreadCount, 1);

    await service.dispatchAsync(MarkConversationReadAction('fp-a'));
    expect(service.state.first.unreadCount, 0);
  });

  test('更新消息状态会落到目标消息上', () async {
    final service = ReduxNotifier.test(redux: createService());

    await service.dispatchAsync(
      AppendChatMessageAction(
        peerFingerprint: 'fp-a',
        peerAlias: 'Alice',
        message: textMessage(id: 'm1', direction: ChatMessageDirection.sent),
      ),
    );

    await service.dispatchAsync(
      UpdateChatMessageAction(
        peerFingerprint: 'fp-a',
        messageId: 'm1',
        status: ChatMessageStatus.failed,
        errorMessage: 'boom',
      ),
    );

    expect(service.state.first.messages.first.status, ChatMessageStatus.failed);
    expect(service.state.first.messages.first.errorMessage, 'boom');
  });

  test('删除会话与清空全部', () async {
    final service = ReduxNotifier.test(redux: createService());

    for (final fp in ['fp-a', 'fp-b']) {
      await service.dispatchAsync(
        AppendChatMessageAction(
          peerFingerprint: fp,
          peerAlias: fp,
          message: textMessage(id: 'm-$fp'),
        ),
      );
    }
    expect(service.state.length, 2);

    await service.dispatchAsync(DeleteConversationAction('fp-a'));
    expect(service.state.length, 1);
    expect(service.state.first.peerFingerprint, 'fp-b');

    await service.dispatchAsync(ClearConversationsAction());
    expect(service.state, isEmpty);
  });

  test('JSON 往返不丢字段', () {
    final conversation = Conversation(
      peerFingerprint: 'fp-a',
      peerAlias: 'Alice',
      peerIp: '192.168.1.5',
      peerPort: 53317,
      lastActivity: DateTime(2026, 1, 1, 12),
      unreadCount: 2,
      messages: [
        textMessage(id: 'm1'),
        ChatMessage(
          id: 'm2',
          direction: ChatMessageDirection.sent,
          kind: ChatMessageKind.file,
          timestamp: DateTime(2026, 1, 1, 12),
          status: ChatMessageStatus.sent,
          fileName: 'a.png',
          filePath: 'C:/tmp/a.png',
          fileSize: 1024,
          fileType: FileType.image,
        ),
      ],
    );

    final restored = Conversation.fromJson(conversation.toJson());

    expect(restored.peerFingerprint, conversation.peerFingerprint);
    expect(restored.peerAlias, conversation.peerAlias);
    expect(restored.peerIp, conversation.peerIp);
    expect(restored.peerPort, conversation.peerPort);
    expect(restored.unreadCount, conversation.unreadCount);
    expect(restored.messages.length, 2);
    expect(restored.messages.last.fileName, 'a.png');
    expect(restored.messages.last.fileType, FileType.image);
  });

  test('损坏的 JSON 降级而不是抛异常', () {
    final restored = Conversation.fromJson({
      'peerFingerprint': 'fp-x',
      'messages': [
        {'id': 'ok', 'kind': 'text', 'direction': 'received', 'timestamp': '2026-01-01T00:00:00Z'},
        {'id': ''}, // 空 id 应被过滤
      ],
    });

    expect(restored.messages.length, 1);
    expect(restored.messages.first.id, 'ok');
  });

  group('MarkChatMessagePendingAction（点感叹号重发）', () {
    Future<ReduxNotifierTester<List<Conversation>>> seed() async {
      final service = ReduxNotifier.test(redux: createService());
      await service.dispatchAsync(
        AppendChatMessageAction(
          peerFingerprint: 'fp-a',
          peerAlias: 'Alice',
          message: ChatMessage(
            id: 'failed',
            direction: ChatMessageDirection.sent,
            kind: ChatMessageKind.text,
            timestamp: DateTime(2026, 1, 1, 10),
            status: ChatMessageStatus.failed,
            text: 'hi',
            fileSize: 2,
            fileType: FileType.text,
            errorMessage: '对方拒绝',
          ),
        ),
      );
      return service;
    }

    test('失败的气泡恢复成发送中，并清掉上一次的错误文案', () async {
      final service = await seed();

      await service.dispatchAsync(
        MarkChatMessagePendingAction(peerFingerprint: 'fp-a', messageId: 'failed'),
      );

      final message = service.state.first.messages.single;
      expect(message.status, ChatMessageStatus.pending);
      expect(message.errorMessage, isNull, reason: '重发后不该继续显示上一轮的原因');
      expect(message.text, 'hi', reason: '正文必须保留');
      expect(service.state.first.messages.length, 1, reason: '不能新增气泡');
    });

    test('已发出的消息不会被改回发送中', () async {
      final service = ReduxNotifier.test(redux: createService());
      await service.dispatchAsync(
        AppendChatMessageAction(
          peerFingerprint: 'fp-a',
          peerAlias: 'Alice',
          message: textMessage(id: 'sent', direction: ChatMessageDirection.sent),
        ),
      );

      await service.dispatchAsync(
        MarkChatMessagePendingAction(peerFingerprint: 'fp-a', messageId: 'sent'),
      );

      expect(service.state.first.messages.single.status, ChatMessageStatus.sent);
    });

    test('接收到的消息不会被改成发送中', () async {
      final service = ReduxNotifier.test(redux: createService());
      await service.dispatchAsync(
        AppendChatMessageAction(
          peerFingerprint: 'fp-a',
          peerAlias: 'Alice',
          message: textMessage(id: 'in'),
        ),
      );

      await service.dispatchAsync(
        MarkChatMessagePendingAction(peerFingerprint: 'fp-a', messageId: 'in'),
      );

      expect(service.state.first.messages.single.status, ChatMessageStatus.received);
    });

    test('消息或会话不存在时静默退出', () async {
      final service = await seed();

      await service.dispatchAsync(
        MarkChatMessagePendingAction(peerFingerprint: 'fp-missing', messageId: 'failed'),
      );
      expect(service.state.first.messages.single.status, ChatMessageStatus.failed);

      await service.dispatchAsync(
        MarkChatMessagePendingAction(peerFingerprint: 'fp-a', messageId: 'missing'),
      );
      expect(service.state.first.messages.single.status, ChatMessageStatus.failed);
    });
  });
}
