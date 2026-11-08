import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_app/util/native/file_availability.dart';
import 'package:localchat_isolates/model/file_type.dart';
import 'package:localchat_isolates/util/file_size_helper.dart';

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
///
/// [FORK] 卡片会自己确认一次「本机还有没有这个文件」，因为 [ChatMessage] 里只记了
/// 一个路径，文件随时可能被移动 / 更名 / 删除：
/// - 磁盘上已经不在了 → 悬浮给一句提示，右键菜单里的「打开文件所在位置」置灰；
/// - `filePath` 为空（接收时没留下绝对路径，例如只存进了相册）→ 同样算不可用，
///   提示语换成「这个文件不在本机」。
class FileMessageCard extends StatefulWidget {
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
  State<FileMessageCard> createState() => _FileMessageCardState();
}

class _FileMessageCardState extends State<FileMessageCard> {
  /// 本机是否已经没有这个文件了。
  ///
  /// `null` = 还没查出来，按「可用」处理，避免在真相出来之前先把卡片画成不可用。
  bool? _missing;

  /// 鼠标当前是否停在卡片上。用来决定「状态刚变过来时要不要补一次提示」。
  bool _hovered = false;

  /// 由 [Tooltip] 承载：文件在鼠标已经悬停之后才被删时，enter 事件已经错过了，
  /// 只能靠这个手动补一次显示。
  final _tooltipKey = GlobalKey<TooltipState>();

  /// 路径为空是确定的不存在，不必等 IO；有路径才去 stat。
  @override
  void initState() {
    super.initState();
    final path = widget.message.filePath;
    if (path == null || path.isEmpty) {
      _missing = true;
    } else {
      unawaited(_refreshMissing());
    }
  }

  @override
  void didUpdateWidget(FileMessageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id || oldWidget.message.filePath != widget.message.filePath) {
      _missing = null;
      final path = widget.message.filePath;
      if (path == null || path.isEmpty) {
        _missing = true;
      } else {
        unawaited(_refreshMissing());
      }
    }
  }

  /// 查一次文件是否还在磁盘上，结果有变化才重建。
  ///
  /// 「怎么算不在」的统一规则在 [localFileExists]（桌面端 + 绝对路径才真的 stat），
  /// 右键菜单里的「打开文件所在位置」用的是同一个函数，两处不会说两套话。
  Future<void> _refreshMissing() async {
    final exists = await localFileExists(widget.message.filePath);
    if (!mounted || _missing == !exists) {
      return;
    }
    setState(() => _missing = !exists);
    if (!exists && _hovered) {
      // 判断结果是「刚变过来的」且鼠标正停在卡片上：Tooltip 的 enter 事件早就过去了，
      // 不补这一下的话，用户得把鼠标挪开再挪回来才看得到提示。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tooltipKey.currentState?.ensureTooltipVisible();
      });
    }
  }

  /// 还能不能打开：有本地副本、且磁盘上确实还在。
  bool get _isOpenable {
    if (_missing == true) {
      return false;
    }
    return widget.message.filePath?.isNotEmpty ?? false;
  }

  /// 不可用时悬浮显示的说明。
  ///
  /// 两种原因的措辞分开：路径为空是「本来就没存在本机」，文件不在是
  /// 「原来有、现在没了」，混成一句会误导。
  String get _unavailableHint {
    final path = widget.message.filePath;
    if (path == null || path.isEmpty) {
      return t.conversation.fileUnavailable;
    }
    return t.conversation.fileMovedOrDeleted;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    // [FORK] 发出的气泡是固定蓝底（见 message_bubble.dart 的 kOutgoingBubbleColor），
    // 所以这一侧的文字/图标固定用白色系，不跟主题的 onPrimary 走。
    final titleColor = widget.isOutgoing ? Colors.white : theme.colorScheme.onSurface;
    final subColor = widget.isOutgoing ? Colors.white.withValues(alpha: 0.75) : theme.colorScheme.outline;
    final iconBg = widget.isOutgoing
        ? Colors.white.withValues(alpha: 0.22)
        : theme.colorScheme.surfaceContainerHighest;
    final iconColor = widget.isOutgoing ? Colors.white : theme.colorScheme.primary;

    Widget card = InkWell(
      onTap: widget.onTap,
      // [FORK] InkWell 默认用 WidgetStateMouseCursor.adaptiveClickable，而它在非 Web 平台
      // 返回 SystemMouseCursors.basic（桌面原生 App 的惯例是按钮不给手型），所以 Windows /
      // macOS 上悬浮文件卡片是普通箭头。这里显式要手型，但只给真能打开的卡片：
      // 路径为空或文件已经不在时保持箭头，避免暗示一个点不动的东西可以打开。
      mouseCursor: _isOpenable ? SystemMouseCursors.click : SystemMouseCursors.basic,
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

    // 不可用才挂提示；能打开的卡片不弹任何东西，免得划过列表一路冒气泡。
    if (_missing == true) {
      card = Tooltip(
        key: _tooltipKey,
        message: _unavailableHint,
        // 桌面端悬浮 0.4s 再出，划过列表时不会一路弹。
        waitDuration: const Duration(milliseconds: 400),
        child: card,
      );
    }

    // 悬停时再确认一次：文件可能是卡片渲染之后才被移动/删除的，
    // 靠 initState 那一次判断会一直显示过期的状态。
    return MouseRegion(
      onEnter: (_) {
        _hovered = true;
        unawaited(_refreshMissing());
      },
      onExit: (_) => _hovered = false,
      child: card,
    );
  }
}
