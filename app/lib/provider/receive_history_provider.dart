import 'dart:async';

import 'package:localchat_app/model/persistence/receive_history_entry.dart';
import 'package:localchat_app/provider/persistence_provider.dart';
import 'package:localchat_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';

const _maxHistoryEntries = 30;

/// This provider stores the history of received files.
/// It automatically saves the history to the device's storage.
final receiveHistoryProvider = ReduxProvider<ReceiveHistoryService, List<ReceiveHistoryEntry>>((ref) {
  return ReceiveHistoryService(ref.read(persistenceProvider));
});

class ReceiveHistoryService extends ReduxNotifier<List<ReceiveHistoryEntry>> {
  final PersistenceService _persistence;

  ReceiveHistoryService(this._persistence);

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
    return updated;
  }
}

/// Removes all history entries.
class RemoveAllHistoryEntriesAction extends AsyncReduxAction<ReceiveHistoryService, List<ReceiveHistoryEntry>> {
  @override
  Future<List<ReceiveHistoryEntry>> reduce() async {
    await notifier._persistence.setReceiveHistory([]);
    return [];
  }
}
