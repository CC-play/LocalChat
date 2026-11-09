import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/model/conversation/conversation.dart';

/// [FORK] 删除单条记录（文本气泡 / 文件卡片）前的确认卡片。
///
/// 删除不可撤销，且文件卡片会连带删掉接收历史里的条目，代价比「点错一个按钮」
/// 高得多，所以先摆出要删的是哪一条，再让用户确认。返回 `true` 表示确认删除。
Future<bool> showDeleteRecordDialog(BuildContext context, ChatMessage message) async {
  final isFile = message.kind == ChatMessageKind.file;
  // 收到的文件在接收历史里有同 id 的条目，发出去的文件没有 —— 文案要如实反映，
  // 否则用户会以为「历史里也留了一份」而去翻。
  final hasHistoryEntry = isFile && message.direction == ChatMessageDirection.received;

  final content = switch ((isFile, hasHistoryEntry)) {
    (false, _) => t.conversation.deleteRecordTextContent,
    (true, true) => t.conversation.deleteRecordFileContent,
    (true, false) => t.conversation.deleteRecordSentFileContent,
  };

  final preview = message.preview ?? (isFile ? t.conversation.filePlaceholder : t.conversation.messagePlaceholder);

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);

      // 窗口被拖得很窄时不要硬撑 380，否则 AlertDialog 的 inset 会挤爆布局。
      final contentWidth = math.max(220.0, math.min(380.0, MediaQuery.sizeOf(dialogContext).width - 120));

      return AlertDialog(
        backgroundColor: theme.colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
        contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        title: Row(
          children: [
            Icon(Icons.delete_outline, size: 20, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Text(
              t.conversation.deleteRecordTitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        content: SizedBox(
          width: contentWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 先把「删的是哪一条」摆出来，避免删错后又没有撤销入口。
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      isFile ? Icons.insert_drive_file_outlined : Icons.chat_bubble_outline,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        preview,
                        // 文件名单行：文件名没有可以换行的位置，允许折成两行会把扩展名
                        // 从中间劈开（"…852.j" / "pg"），比截断更难看。
                        maxLines: isFile ? 1 : 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                content,
                style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
              ),
              // 还在传输的这条：删除会先取消传输，这个副作用必须提前讲清楚。
              if (message.status == ChatMessageStatus.pending) ...[
                const SizedBox(height: 8),
                Text(
                  t.conversation.deleteRecordPendingHint,
                  style: TextStyle(fontSize: 13, color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
              side: BorderSide(color: theme.colorScheme.outlineVariant),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            ),
            child: Text(t.general.cancel),
          ),
          // 破坏性动作：实心红，和菜单里的红字项呼应。
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: Text(t.general.delete),
          ),
        ],
      );
    },
  );

  return result ?? false;
}

/// [FORK] 多选删除的确认卡片。
///
/// 与单条删除同样的代价（不可撤销、接收历史联动），但**不能沿用单条的文案**：
/// 用户一次勾了二十条，确认框里只摆一条预览等于没告诉他删的是什么。
///
/// 这里按组成分别提示，避免把「含接收文件」「含传输中」这两个副作用埋掉。
/// 预览最多列 [maxPreview] 条，剩下的折成一行计数 —— 逐条列全会把对话框撑爆。
Future<bool> showDeleteSelectedDialog(BuildContext context, List<ChatMessage> messages) async {
  if (messages.isEmpty) {
    return false;
  }

  const maxPreview = 3;

  final receivedFileCount = messages.where((m) => m.kind == ChatMessageKind.file && m.direction == ChatMessageDirection.received).length;
  final pendingCount = messages.where((m) => m.status == ChatMessageStatus.pending).length;
  final head = messages.take(maxPreview).toList();
  final rest = messages.length - head.length;

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final contentWidth = math.max(220.0, math.min(380.0, MediaQuery.sizeOf(dialogContext).width - 120));

      return AlertDialog(
        backgroundColor: theme.colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
        contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        title: Row(
          children: [
            Icon(Icons.delete_outline, size: 20, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t.conversation.deleteSelectedTitle(count: messages.length),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: contentWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final message in head) _SelectedPreviewRow(message: message),
                    if (rest > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            t.conversation.deleteSelectedMore(count: rest),
                            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                t.conversation.deleteSelectedContent,
                style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
              ),
              // 收到的文件在接收历史里有同 id 的条目，删除会一并清掉。
              if (receivedFileCount > 0) ...[
                const SizedBox(height: 8),
                Text(
                  t.conversation.deleteSelectedFileHint(count: receivedFileCount),
                  style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              // 传输中的消息：删除会先取消传输，这个副作用必须提前讲清楚。
              if (pendingCount > 0) ...[
                const SizedBox(height: 8),
                Text(
                  t.conversation.deleteSelectedPendingHint(count: pendingCount),
                  style: TextStyle(fontSize: 13, color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
              side: BorderSide(color: theme.colorScheme.outlineVariant),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            ),
            child: Text(t.general.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: Text(t.general.delete),
          ),
        ],
      );
    },
  );

  return result ?? false;
}

/// 多选确认框里的一行摘要：图标 + 单行文本。
class _SelectedPreviewRow extends StatelessWidget {
  final ChatMessage message;

  const _SelectedPreviewRow({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFile = message.kind == ChatMessageKind.file;
    final text = message.preview ?? (isFile ? t.conversation.filePlaceholder : t.conversation.messagePlaceholder);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isFile ? Icons.insert_drive_file_outlined : Icons.chat_bubble_outline,
            size: 16,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              // 与单条删除一致：文件名不折行，正文最多两行。
              maxLines: isFile ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
