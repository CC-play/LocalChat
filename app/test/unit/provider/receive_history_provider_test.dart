import 'package:intl/date_symbol_data_local.dart';
import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_app/model/persistence/receive_history_entry.dart';
import 'package:localchat_app/provider/conversation_provider.dart';
import 'package:localchat_app/provider/persistence_provider.dart';
import 'package:localchat_app/provider/receive_history_provider.dart';
import 'package:localchat_isolates/model/file_type.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import '../../mocks.mocks.dart';

void main() {
  late MockPersistenceService persistenceService;

  setUpAll(() async {
    await initializeDateFormatting();
  });

  setUp(() {
    persistenceService = MockPersistenceService();
    when(persistenceService.isSaveToHistory()).thenReturn(true);
  });

  test('Should add an entry', () async {
    final service = ReduxNotifier.test(
      redux: ReceiveHistoryService(persistenceService),
    );

    final entry = _createEntry('1');

    await service.dispatchAsync(
      AddHistoryEntryAction(
        entryId: entry.id,
        fileName: entry.fileName,
        fileType: entry.fileType,
        path: entry.path,
        savedToGallery: entry.savedToGallery,
        isMessage: entry.isMessage,
        fileSize: entry.fileSize,
        senderAlias: entry.senderAlias,
        timestamp: entry.timestamp,
      ),
    );

    expect(service.state, [entry]);
    verify(persistenceService.setReceiveHistory([entry]));
  });

  test('Should not add an entry if disabled', () async {
    when(persistenceService.isSaveToHistory()).thenReturn(false);

    final service = ReduxNotifier.test(
      redux: ReceiveHistoryService(persistenceService),
    );

    final entry = _createEntry('1');

    await service.dispatchAsync(
      AddHistoryEntryAction(
        entryId: entry.id,
        fileName: entry.fileName,
        fileType: entry.fileType,
        path: entry.path,
        savedToGallery: entry.savedToGallery,
        isMessage: entry.isMessage,
        fileSize: entry.fileSize,
        senderAlias: entry.senderAlias,
        timestamp: entry.timestamp,
      ),
    );

    expect(service.state, []);
    verifyNever(persistenceService.setReceiveHistory(any));
  });

  test('Should remove the 30th entry when adding another', () async {
    final service = ReduxNotifier.test(
      redux: ReceiveHistoryService(persistenceService),
      initialState: List.generate(30, (index) => _createEntry(index.toString())),
    );

    expect(service.state.length, 30);
    expect(service.state.first, _createEntry('0'));
    expect(service.state.last, _createEntry('29'));

    final entry = _createEntry('AAA');

    await service.dispatchAsync(
      AddHistoryEntryAction(
        entryId: entry.id,
        fileName: entry.fileName,
        fileType: entry.fileType,
        path: entry.path,
        savedToGallery: entry.savedToGallery,
        isMessage: entry.isMessage,
        fileSize: entry.fileSize,
        senderAlias: entry.senderAlias,
        timestamp: entry.timestamp,
      ),
    );

    expect(service.state.length, 30);
    expect(service.state.first, entry);
    expect(service.state.first, _createEntry('AAA'));
    expect(service.state[1], _createEntry('0'));
    expect(service.state.last, _createEntry('28'));
  });

  test('Should remove an entry', () async {
    final service = ReduxNotifier.test(
      redux: ReceiveHistoryService(persistenceService),
      initialState: [
        _createEntry('1'),
        _createEntry('2'),
        _createEntry('3'),
      ],
    );

    expect(service.state.length, 3);

    await service.dispatchAsync(RemoveHistoryEntryAction('2'));

    expect(service.state.length, 2);
    expect(service.state, [
      _createEntry('1'),
      _createEntry('3'),
    ]);
    verify(
      persistenceService.setReceiveHistory([
        _createEntry('1'),
        _createEntry('3'),
      ]),
    );
  });

  test('Should not remove an entry if not found', () async {
    final service = ReduxNotifier.test(
      redux: ReceiveHistoryService(persistenceService),
      initialState: [
        _createEntry('1'),
        _createEntry('2'),
        _createEntry('3'),
      ],
    );

    expect(service.state.length, 3);

    await service.dispatchAsync(RemoveHistoryEntryAction('4'));

    expect(service.state.length, 3);
    expect(service.state, [
      _createEntry('1'),
      _createEntry('2'),
      _createEntry('3'),
    ]);
    verifyNever(persistenceService.setReceiveHistory(any));
  });

  test('Should remove all entries', () async {
    final service = ReduxNotifier.test(
      redux: ReceiveHistoryService(persistenceService),
      initialState: [
        _createEntry('1'),
        _createEntry('2'),
        _createEntry('3'),
      ],
    );

    expect(service.state.length, 3);

    await service.dispatchAsync(RemoveAllHistoryEntriesAction());

    expect(service.state.length, 0);
    verify(persistenceService.setReceiveHistory([]));
  });

  // [FORK] 聊天页多选删除走批量 action：一次写盘删多条。
  test('Should remove many entries with one write', () async {
    final service = ReduxNotifier.test(
      redux: ReceiveHistoryService(persistenceService),
      initialState: [
        _createEntry('1'),
        _createEntry('2'),
        _createEntry('3'),
        _createEntry('4'),
      ],
    );

    await service.dispatchAsync(RemoveHistoryEntriesAction({'1', '3'}));

    expect(service.state, [_createEntry('2'), _createEntry('4')]);
    verify(persistenceService.setReceiveHistory([_createEntry('2'), _createEntry('4')])).called(1);
  });

  test('Should not write when no entry matches the batch', () async {
    final service = ReduxNotifier.test(
      redux: ReceiveHistoryService(persistenceService),
      initialState: [
        _createEntry('1'),
        _createEntry('2'),
      ],
    );

    await service.dispatchAsync(RemoveHistoryEntriesAction({'9', '10'}));

    expect(service.state, [_createEntry('1'), _createEntry('2')]);
    verifyNever(persistenceService.setReceiveHistory(any));
  });

  // [FORK] 文本消息只归会话，历史里的遗留文本条目在 init 时清掉。
  test('Should drop legacy text entries on init', () {
    when(persistenceService.getReceiveHistory()).thenReturn([
      _createEntry('1'),
      _createMessageEntry('m1'),
      _createEntry('2'),
    ]);

    final state = ReceiveHistoryService(persistenceService).init();

    expect(state, [_createEntry('1'), _createEntry('2')]);
    verify(persistenceService.setReceiveHistory([_createEntry('1'), _createEntry('2')]));
  });

  test('Should keep history untouched on init when there is nothing to drop', () {
    when(persistenceService.getReceiveHistory()).thenReturn([_createEntry('1')]);

    final state = ReceiveHistoryService(persistenceService).init();

    expect(state, [_createEntry('1')]);
    verifyNever(persistenceService.setReceiveHistory(any));
  });

  // [FORK] 历史条目与会话里的文件卡片共用协议里的 fileId，删除要联动。
  test('Should delete the linked chat message when removing a history entry', () async {
    when(persistenceService.getReceiveHistory()).thenReturn([
      _createEntry('f1'),
      _createEntry('f2'),
    ]);
    when(persistenceService.getConversations()).thenReturn([
      Conversation(
        peerFingerprint: 'fp',
        peerAlias: 'Peer',
        lastActivity: DateTime(2026, 1, 1),
        unreadCount: 2,
        messages: [_fileMessage('f1'), _fileMessage('f2')],
      ),
    ]);

    final container = RefenaContainer(
      overrides: [persistenceProvider.overrideWithValue(persistenceService)],
    );
    addTearDown(container.disposeContainer);

    expect(container.read(receiveHistoryProvider).length, 2);
    expect(container.read(conversationProvider).single.messages.length, 2);

    await container.redux(receiveHistoryProvider).dispatchAsync(RemoveHistoryEntryAction('f1'));

    expect(container.read(receiveHistoryProvider).map((e) => e.id), ['f2']);
    expect(
      container.read(conversationProvider).single.messages.map((m) => m.id),
      ['f2'],
      reason: '聊天里的同一张卡片应该一起消失',
    );
  });

  test('Should delete every linked chat message when clearing the history', () async {
    when(persistenceService.getReceiveHistory()).thenReturn([
      _createEntry('f1'),
      _createEntry('f2'),
    ]);
    when(persistenceService.getConversations()).thenReturn([
      Conversation(
        peerFingerprint: 'fp',
        peerAlias: 'Peer',
        lastActivity: DateTime(2026, 1, 1),
        unreadCount: 2,
        messages: [_fileMessage('f1'), _fileMessage('f2')],
      ),
    ]);

    final container = RefenaContainer(
      overrides: [persistenceProvider.overrideWithValue(persistenceService)],
    );
    addTearDown(container.disposeContainer);

    await container.redux(receiveHistoryProvider).dispatchAsync(RemoveAllHistoryEntriesAction());

    expect(container.read(receiveHistoryProvider), isEmpty);
    expect(container.read(conversationProvider), isEmpty, reason: '两个文件都被删空，会话也不该留壳');
  });

  // [FORK] 多选删除同样要联动会话里的卡片，且只动被选中的那几条。
  test('Should delete linked chat messages in one batch', () async {
    when(persistenceService.getReceiveHistory()).thenReturn([
      _createEntry('f1'),
      _createEntry('f2'),
      _createEntry('f3'),
    ]);
    when(persistenceService.getConversations()).thenReturn([
      Conversation(
        peerFingerprint: 'fp',
        peerAlias: 'Peer',
        lastActivity: DateTime(2026, 1, 1),
        unreadCount: 3,
        messages: [_fileMessage('f1'), _fileMessage('f2'), _fileMessage('f3')],
      ),
    ]);

    final container = RefenaContainer(
      overrides: [persistenceProvider.overrideWithValue(persistenceService)],
    );
    addTearDown(container.disposeContainer);

    await container.redux(receiveHistoryProvider).dispatchAsync(RemoveHistoryEntriesAction({'f1', 'f3'}));

    expect(container.read(receiveHistoryProvider).map((e) => e.id), ['f2']);
    expect(
      container.read(conversationProvider).single.messages.map((m) => m.id),
      ['f2'],
      reason: '只删被选中的两条，剩下那条的卡片要留着',
    );
  });
}

ChatMessage _fileMessage(String id) {
  return ChatMessage(
    id: id,
    direction: ChatMessageDirection.received,
    kind: ChatMessageKind.file,
    timestamp: DateTime(2021, 1, 1),
    status: ChatMessageStatus.received,
    fileName: '$id.png',
    filePath: '/tmp/$id.png',
    fileSize: 123,
    fileType: FileType.image,
  );
}

ReceiveHistoryEntry _createMessageEntry(String id) {
  return ReceiveHistoryEntry(
    id: id,
    fileName: 'text message',
    fileType: FileType.text,
    path: null,
    savedToGallery: false,
    isMessage: true,
    fileSize: 12,
    senderAlias: 'senderAlias',
    timestamp: DateTime(2021, 1, 1),
  );
}

ReceiveHistoryEntry _createEntry(String id) {
  return ReceiveHistoryEntry(
    id: id,
    fileName: 'fileName',
    fileType: FileType.image,
    path: 'path',
    savedToGallery: true,
    isMessage: false,
    fileSize: 123,
    senderAlias: 'senderAlias',
    timestamp: DateTime(2021, 1, 1),
  );
}
