import 'package:flutter/material.dart';
import 'package:localsend_app/model/conversation/conversation.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';

IconData iconForFileType(FileType? type) {
  return switch (type) {
    FileType.image => Icons.image,
    FileType.video => Icons.movie,
    FileType.pdf => Icons.picture_as_pdf,
    FileType.text => Icons.description,
    FileType.apk => Icons.android,
    _ => Icons.insert_drive_file,
  };
}

/// 气泡内的文件卡片（图标 + 文件名 + 大小），可点击打开。
class FileMessageCard extends StatelessWidget {
  final ChatMessage message;
  final bool isOutgoing;
  final VoidCallback? onTap;

  const FileMessageCard({
    super.key,
    required this.message,
    required this.isOutgoing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleColor = isOutgoing ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    final subColor = isOutgoing ? theme.colorScheme.onPrimary.withValues(alpha: 0.7) : theme.colorScheme.outline;
    final iconBg = isOutgoing ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest;
    final iconColor = isOutgoing ? theme.colorScheme.onPrimary : theme.colorScheme.primary;

    return InkWell(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(iconForFileType(message.fileType), color: iconColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.fileName ?? '',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: titleColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  message.fileSize.asReadableFileSize,
                  style: TextStyle(fontSize: 11, color: subColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
