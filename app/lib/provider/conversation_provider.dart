import 'package:collection/collection.dart';
import 'package:localsend_app/model/conversation/conversation.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// 会话状态：全部会话，按最近活动时间倒序。
///
/// 与 `receiveHistoryProvider` 的关系：两者互相独立。接收历史继续按上游逻辑
/// 记录（全局 30 条、仅接收方向），会话则是本 fork 新增的双向聊天存储。
/// 这样上游代码不需要为了聊天功能做任何让步，合并冲突面最小。
final conversationProvider = ReduxProvider<ConversationService, List<Conversation>>((ref) {
  return ConversationService(ref.read(persistenceProvider));
});

class ConversationService extends ReduxNotifier<List<Conversation>> {
  final PersistenceService _persistence;

  ConversationService(this._persistence);

  @override
  List<Conversation> init() => sortConversations(_persistence.getConversations());

  Conversation? byFingerprint(String fingerprint) {
    return state.firstWhereOrNull((e) => e.peerFingerprint == fingerprint);
  }
}

/// 追加一条消息。
///
/// 幂等：若同一 [ChatMessage.id] 已存在则直接忽略，因此重复回调、重试、
/// 断线重连都不会产生重复气泡。
class AppendChatMessageAction extends AsyncReduxAction<ConversationService, List<Conversation>> {
  final String peerFingerprint;
  final String peerAlias;
  final String? peerIp;
  final int? peerPort;
  final ChatMessage message;

  AppendChatMessageAction({
    required this.peerFingerprint,
    required this.peerAlias,
    required this.message,
    this.peerIp,
    this.peerPort,
  });

  @override
  Future<List<Conversation>> reduce() async {
    if (peerFingerprint.isEmpty) {
      return state;
    }

    final existingIndex = state.indexWhere((e) => e.peerFingerprint == peerFingerprint);
    final existing = existingIndex == -1 ? null : state[existingIndex];

    if (existing != null && existing.messages.any((m) => m.id == message.id)) {
      return state;
    }

    final messages = [...?existing?.messages, message]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final trimmed = messages.length > maxMessagesPerConversation
        ? messages.sublist(messages.length - maxMessagesPerConversation)
        : messages;

    final updated = Conversation(
      peerFingerprint: peerFingerprint,
      // 对端可能改名，以最新一次收到的别名为准。
      peerAlias: peerAlias.isEmpty ? (existing?.peerAlias ?? '') : peerAlias,
      peerIp: peerIp ?? existing?.peerIp,
      peerPort: peerPort ?? existing?.peerPort,
      lastActivity: trimmed.last.timestamp,
      unreadCount: (existing?.unreadCount ?? 0) + (message.direction == ChatMessageDirection.received ? 1 : 0),
      messages: trimmed,
    );

    final next = [...state];
    if (existingIndex == -1) {
      next.add(updated);
    } else {
      next[existingIndex] = updated;
    }

    final sorted = sortConversations(next);
    final capped = sorted.length > maxConversations ? sorted.sublist(0, maxConversations) : sorted;

    await notifier._persistence.setConversations(capped);
    return capped;
  }
}

/// 更新某条消息的状态（用于发送中 -> 已发送 / 失败，或接收后补上落盘路径）。
class UpdateChatMessageAction extends AsyncReduxAction<ConversationService, List<Conversation>> {
  final String peerFingerprint;
  final String messageId;
  final ChatMessageStatus? status;
  final String? filePath;
  final String? errorMessage;

  UpdateChatMessageAction({
    required this.peerFingerprint,
    required this.messageId,
    this.status,
    this.filePath,
    this.errorMessage,
  });

  @override
  Future<List<Conversation>> reduce() async {
    final index = state.indexWhere((e) => e.peerFingerprint == peerFingerprint);
    if (index == -1) {
      return state;
    }

    final conversation = state[index];
    final messageIndex = conversation.messages.indexWhere((m) => m.id == messageId);
    if (messageIndex == -1) {
      return state;
    }

    final messages = [...conversation.messages];
    messages[messageIndex] = messages[messageIndex].copyWith(
      status: status,
      filePath: filePath,
      errorMessage: errorMessage,
    );

    final next = [...state];
    next[index] = conversation.copyWith(messages: messages);
    await notifier._persistence.setConversations(next);
    return next;
  }
}

/// 重发：把失败的气泡恢复成「发送中」。
///
/// 只对**发送方向且已失败**的消息生效——否则会把正在传的消息打回 pending，
/// 或者把一条接收到的消息改成「发送中」这种荒谬状态。
class MarkChatMessagePendingAction extends AsyncReduxAction<ConversationService, List<Conversation>> {
  final String peerFingerprint;
  final String messageId;

  MarkChatMessagePendingAction({
    required this.peerFingerprint,
    required this.messageId,
  });

  @override
  Future<List<Conversation>> reduce() async {
    final index = state.indexWhere((e) => e.peerFingerprint == peerFingerprint);
    if (index == -1) {
      return state;
    }

    final conversation = state[index];
    final messageIndex = conversation.messages.indexWhere((m) => m.id == messageId);
    if (messageIndex == -1) {
      return state;
    }
    final message = conversation.messages[messageIndex];
    if (!message.isOutgoing || message.status != ChatMessageStatus.failed) {
      return state;
    }

    final messages = [...conversation.messages];
    messages[messageIndex] = message.copyWith(
      status: ChatMessageStatus.pending,
      clearError: true,
    );

    final next = [...state];
    next[index] = conversation.copyWith(messages: messages);
    await notifier._persistence.setConversations(next);
    return next;
  }
}

/// 清除未读数（进入会话页时调用）。
class MarkConversationReadAction extends AsyncReduxAction<ConversationService, List<Conversation>> {
  final String peerFingerprint;

  MarkConversationReadAction(this.peerFingerprint);

  @override
  Future<List<Conversation>> reduce() async {
    final index = state.indexWhere((e) => e.peerFingerprint == peerFingerprint);
    if (index == -1 || state[index].unreadCount == 0) {
      return state;
    }

    final next = [...state];
    next[index] = state[index].copyWith(unreadCount: 0);
    await notifier._persistence.setConversations(next);
    return next;
  }
}

/// 删除单个会话。
class DeleteConversationAction extends AsyncReduxAction<ConversationService, List<Conversation>> {
  final String peerFingerprint;

  DeleteConversationAction(this.peerFingerprint);

  @override
  Future<List<Conversation>> reduce() async {
    final next = state.where((e) => e.peerFingerprint != peerFingerprint).toList();
    if (next.length == state.length) {
      return state;
    }
    await notifier._persistence.setConversations(next);
    return next;
  }
}

/// 删除全部会话。
class ClearConversationsAction extends AsyncReduxAction<ConversationService, List<Conversation>> {
  @override
  Future<List<Conversation>> reduce() async {
    await notifier._persistence.setConversations([]);
    return [];
  }
}

/// 只要总数和未读数变化就通知 UI 的轻量视图。
///
/// 会话列表页用它来显示角标，避免因为单条消息更新而整页重建。
final unreadConversationCountProvider = ViewProvider<int>((ref) {
  final conversations = ref.watch(conversationProvider);
  return conversations.where((e) => e.unreadCount > 0).length;
});
