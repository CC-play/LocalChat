import 'dart:async';

import 'package:localchat_app/model/persistence/receive_history_entry.dart';
import 'package:localchat_app/provider/conversation_provider.dart';
import 'package:localchat_app/provider/persistence_provider.dart';
import 'package:localchat_isolates/model/file_type.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

const _maxHistoryEntries = 30;

final _logger = Logger('ReceiveHistory');

/// This provider stores the history of received files.
/// It automatically saves the history to the device's storage.
final receiveHistoryProvider = ReduxProvider<ReceiveHistoryService, List<ReceiveHistoryEntry>>((ref) {
  return ReceiveHistoryService(ref.read(persistenceProvider), ref);
});

class ReceiveHistoryService extends ReduxNotifier<List<ReceiveHistoryEntry>> {
  final PersistenceService _persistence;

  /// [FORK] 联动删除会话消息需要向另一个 provider 派发动作。
  ///
  /// 单测里直接构造 service 时没有容器，传 null 即跳过联动。
  final Ref? _ref;

  ReceiveHistoryService(this._persistence, [this._ref]);

  @override
  List<ReceiveHistoryEntry> init() {
    final stored = _persistence.getReceiveHistory();

    // [FORK] 清掉历史上遗留的文本消息条目。
    //
    // 早期版本把收到的文本同时写进接收历史和会话，两边的副本各有独立 id、
    // 各有独立的删除入口，删掉一处另一处纹丝不动。现在文本只归会话，
    // 历史回归上游语义（只记文件），老数据在这里顺手清一次。
    final migrated = stored.where((entry) => !entry.isMessage).toList();
    if (migrated.length != stored.length) {
      unawaited(_persistence.setReceiveHistory(migrated));
    }
    return migrated;
  }

  /// [FORK] 删除历史条目时，把会话里 id 相同的消息一起删掉。
  ///
  /// 接收文件的 `entryId` 与 `ChatMessage.id` 同取协议里的 `fileId`，精确匹配。
  /// 失败只记日志：清历史是主操作，联动是附带效果，不能因为联动失败而回滚。
  Future<void> deleteLinkedChatMessages(Iterable<String> entryIds) async {
    final ref = _ref;
    final ids = entryIds.toSet();
    if (ref == null || ids.isEmpty) {
      return;
    }
    try {
      await ref.redux(conversationProvider).dispatchAsync(DeleteChatMessagesAction(ids));
    } catch (e, st) {
      _logger.warning('Failed to delete linked chat messages', e, st);
    }
  }
}

/// Adds a history entry.
class AddHistoryEntryAction extends AsyncReduxAction<ReceiveHistoryService, List<ReceiveHistoryEntry>> {
  final String entryId;
  final String fileName;
  final FileType fileType;
  final String? path;
  final bool savedToGallery;
  final bool isMessage;
  final int fileSize;
  final String senderAlias;
  final DateTime timestamp;

  AddHistoryEntryAction({
    required this.entryId,
    required this.fileName,
    required this.fileType,
    required this.path,
    required this.savedToGallery,
    required this.isMessage,
    required this.fileSize,
    required this.senderAlias,
    required this.timestamp,
  });

  @override
  Future<List<ReceiveHistoryEntry>> reduce() async {
    if (!notifier._persistence.isSaveToHistory()) {
      return state;
    }

    final updated = [
      ReceiveHistoryEntry(
        id: entryId,
        fileName: fileName,
        fileType: fileType,
        path: path,
        savedToGallery: savedToGallery,
        isMessage: isMessage,
        fileSize: fileSize,
        senderAlias: senderAlias,
        timestamp: timestamp,
      ),
      ...state,
    ].take(_maxHistoryEntries).toList();
    await notifier._persistence.setReceiveHistory(updated);
    return updated;
  }
}

/// Removes a history entry.
class RemoveHistoryEntryAction extends AsyncReduxAction<ReceiveHistoryService, List<ReceiveHistoryEntry>> {
  final String entryId;

  RemoveHistoryEntryAction(this.entryId);

  @override
  Future<List<ReceiveHistoryEntry>> reduce() async {
    final index = state.indexWhere((e) => e.id == entryId);
    if (index == -1) {
      return state;
    }
    final updated = [...state]..removeAt(index);
    await notifier._persistence.setReceiveHistory(updated);
    // [FORK] 聊天里的文件卡片是同一份数据的另一个视图，删历史就别让它留在会话里。
    await notifier.deleteLinkedChatMessages([entryId]);
    return updated;
  }
}

/// [FORK] 批量删除历史条目（聊天页多选删除用）。
///
/// 为什么不循环派发 [RemoveHistoryEntryAction]：每个 action 都会
/// `setReceiveHistory(全量 JSON)` 一次、再联动派发一次会话删除，
/// N 条就是 2N 次全量写盘。这里合并成一次写盘 + 一次联动。
/// 没有命中任何条目时直接返回原 state，不写盘。
class RemoveHistoryEntriesAction extends AsyncReduxAction<ReceiveHistoryService, List<ReceiveHistoryEntry>> {
  final Set<String> entryIds;

  RemoveHistoryEntriesAction(this.entryIds);

  @override
  Future<List<ReceiveHistoryEntry>> reduce() async {
    if (entryIds.isEmpty || state.isEmpty) {
      return state;
    }

    final updated = state.where((e) => !entryIds.contains(e.id)).toList();
    if (updated.length == state.length) {
      return state;
    }

    await notifier._persistence.setReceiveHistory(updated);
    // [FORK] 与单条删除同语义：聊天里的文件卡片是同一份数据的另一个视图。
    await notifier.deleteLinkedChatMessages(entryIds);
    return updated;
  }
}

/// Removes all history entries.
class RemoveAllHistoryEntriesAction extends AsyncReduxAction<ReceiveHistoryService, List<ReceiveHistoryEntry>> {
  @override
  Future<List<ReceiveHistoryEntry>> reduce() async {
    final removedIds = state.map((entry) => entry.id).toList();
    await notifier._persistence.setReceiveHistory([]);
    // [FORK] 只联动「本来就在历史里」的那些，历史之外的更早消息不动。
    await notifier.deleteLinkedChatMessages(removedIds);
    return [];
  }
}
