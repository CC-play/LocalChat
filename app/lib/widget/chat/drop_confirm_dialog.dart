import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/widget/chat/message_bubble.dart' show kOnOutgoingBubbleColor, kOutgoingBubbleColor;
import 'package:localsend_isolates/util/file_size_helper.dart';

/// [FORK] 拖拽文件进会话窗口后的确认卡片。
///
/// 拖拽是「一次动作就把东西发出去」，比点回形针更容易误操作，
/// 所以先把文件数量、合计大小和清单摆出来，确认后才真正投递。
///
/// 返回 `true` 表示用户点了确认。
Future<bool> showDropConfirmDialog(BuildContext context, List<CrossFile> files) async {
  final totalSize = files.fold<int>(0, (sum, file) => sum + file.size);

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
            Icon(Icons.upload_file, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(t.conversation.dropTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ],
        ),
        content: SizedBox(
          width: contentWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.conversation.dropSummary(
                  count: files.length,
                  size: totalSize.asReadableFileSize,
                ),
                style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
                  itemCount: files.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    thickness: 0.5,
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                  ),
                  itemBuilder: (context, index) {
                    final file = files[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Row(
                        children: [
                          Icon(Icons.insert_drive_file_outlined, size: 16, color: theme.colorScheme.outline),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              file.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            file.size.asReadableFileSize,
                            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          // 取消：红字 + 红边框（破坏性动作要显眼，但不能是实心红，避免抢走焦点）。
          OutlinedButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
              side: BorderSide(color: theme.colorScheme.error),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            ),
            child: Text(t.general.cancel),
          ),
          // 确认：蓝底白字，沿用聊天气泡那个蓝，保证整个会话界面色调一致。
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: kOutgoingBubbleColor,
              foregroundColor: kOnOutgoingBubbleColor,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: Text(t.general.confirm),
          ),
        ],
      );
    },
  );

  return result ?? false;
}
