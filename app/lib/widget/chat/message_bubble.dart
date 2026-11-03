import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/conversation/conversation.dart';
import 'package:localsend_app/provider/conversation/chat_transfer_provider.dart';
import 'package:localsend_app/widget/chat/file_message_card.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// [FORK] 自己发出的气泡固定用这个蓝色；文字因此固定走白色系（不跟主题走，
/// 否则深色主题的 onPrimary 是深蓝，压在浅蓝底上会看不清）。
const kOutgoingBubbleColor = Color(0xFF4C98FF);
const kOnOutgoingBubbleColor = Colors.white;

/// 单条消息气泡：接收靠左、发送靠右，与主流即时通讯软件一致。
class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  /// 对方（接收方消息）的头像占位字符。
  final String peerInitial;

  final VoidCallback? onFileTap;

  /// [FORK] 右键（桌面）点击气泡时回调，参数是全局坐标，用于在该点弹出菜单。
  final ValueChanged<Offset>? onSecondaryTap;

  /// [FORK] 点击「发送失败」的红色感叹号时重发。
  final VoidCallback? onRetry;

  /// [FORK] 点击「发送中」的转圈时取消这次发送。
  final VoidCallback? onCancel;

  /// [FORK] 「发送中」已经挂得太久时回调，由页面直接把它标成失败。
  ///
  /// 这是纯 UI 侧的兜底：不依赖任何后台任务，只要气泡还在屏幕上就生效。
  final VoidCallback? onStalePending;

  /// 超过这个时长仍是「发送中」就触发 [onStalePending]。
  final Duration staleAfter;

  const MessageBubble({
    super.key,
    required this.message,
    required this.peerInitial,
    this.onFileTap,
    this.onSecondaryTap,
    this.onRetry,
    this.onCancel,
    this.onStalePending,
    this.staleAfter = const Duration(minutes: 3),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOutgoing = message.isOutgoing;
    final bubbleColor = isOutgoing ? kOutgoingBubbleColor : theme.colorScheme.surfaceContainer;
    final onBubbleColor = isOutgoing ? kOnOutgoingBubbleColor : theme.colorScheme.onSurface;
    final failed = message.status == ChatMessageStatus.failed;

    final Widget bubbleChild;
    if (message.kind == ChatMessageKind.text) {
      bubbleChild = Text(
        message.text ?? '',
        style: TextStyle(
          fontSize: 14,
          color: onBubbleColor,
        ),
      );
    } else {
      bubbleChild = FileMessageCard(
        message: message,
        isOutgoing: isOutgoing,
        onTap: onFileTap,
      );
    }

    final avatar = Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        // [FORK] 头像跟随设置里的主题色（与固定蓝色气泡不同色，是有意为之）
        color: isOutgoing ? theme.colorScheme.primary : theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: Text(
          isOutgoing ? t.conversation.you : (peerInitial.isEmpty ? '?' : peerInitial),
          style: TextStyle(
            color: isOutgoing ? theme.colorScheme.onPrimary : theme.colorScheme.onSecondaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );

    final statusHint = switch (message.status) {
      ChatMessageStatus.pending => t.conversation.sending,
      ChatMessageStatus.failed => message.errorMessage ?? t.conversation.sendFailed,
      _ => null,
    };

    // [FORK] 气泡左侧的状态圆圈：发送中转圈，失败红色感叹号，成功不占位。
    final Widget? statusIndicator;
    if (!isOutgoing) {
      statusIndicator = null;
    } else {
      statusIndicator = switch (message.status) {
        ChatMessageStatus.pending => Tooltip(
          // [FORK] 转圈不再是只读的：点一下就把这次发送停掉，
          // 不必等满两分钟的重试窗口。
          message: onCancel == null ? t.conversation.sending : t.conversation.cancelSend,
          child: InkResponse(
            onTap: onCancel,
            radius: 16,
            containedInkWell: false,
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        ChatMessageStatus.failed => Tooltip(
          message: onRetry == null ? statusHint ?? '' : t.conversation.retryHint,
          child: InkResponse(
            onTap: onRetry,
            radius: 16,
            containedInkWell: false,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.error,
                size: 18,
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ),
        _ => null,
      };
    }

    return GestureDetector(
      // 整行可右键（含气泡外侧留白），菜单由页面统一弹。
      // 用 translucent：子节点（文件卡片）自己的点击照旧生效。
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: onSecondaryTap == null ? null : (details) => onSecondaryTap!(details.globalPosition),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        child: Row(
          mainAxisAlignment: isOutgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isOutgoing) avatar,
            if (!isOutgoing) const SizedBox(width: 8),
            // [FORK] 发送状态圆圈（转圈 / 红色感叹号），只在发出方向显示。
            if (statusIndicator != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 6),
                child: statusIndicator,
              ),
            Flexible(
              child: Column(
                crossAxisAlignment: isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Container(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    decoration: BoxDecoration(
                      color: bubbleColor,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: bubbleChild,
                  ),
                  // [FORK] 发出方向「发送中」时显示上传进度条；没有进度可报
                  // （还没进入上传，例如正在算校验和）就退回原来那行文字。
                  if (isOutgoing && message.status == ChatMessageStatus.pending)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: _SendProgressFooter(
                        messageId: message.id,
                        color: theme.colorScheme.primary,
                        staleAfter: staleAfter,
                        onStale: onStalePending,
                      ),
                    )
                  else if (statusHint != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        statusHint,
                        style: TextStyle(
                          fontSize: 10,
                          color: failed ? theme.colorScheme.error : theme.colorScheme.outline,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (isOutgoing) const SizedBox(width: 8),
            if (isOutgoing) avatar,
          ],
        ),
      ),
    );
  }
}

/// [FORK] 气泡下方的上传进度。
///
/// 只订阅**这一条消息**的进度：[ChatTransferNotifier] 给每条消息一个独立的
/// [ValueNotifier]，所以并发传几个文件时，进度事件不会让整个消息列表重绘。
///
/// 进度为 null 表示还没开始上传（例如仍在计算校验和，或者正在等对方接受），
/// 此时显示「发送中 12s…」——**带上已等待的秒数**。
/// 原先只写「发送中…」，用户等上几十秒就无法判断是在正常工作还是已经卡死。
class _SendProgressFooter extends StatefulWidget {
  final String messageId;
  final Color color;
  final Duration staleAfter;
  final VoidCallback? onStale;

  const _SendProgressFooter({
    required this.messageId,
    required this.color,
    required this.staleAfter,
    this.onStale,
  });

  @override
  State<_SendProgressFooter> createState() => _SendProgressFooterState();
}

class _SendProgressFooterState extends State<_SendProgressFooter> {
  Timer? _ticker;
  int _seconds = 0;

  /// 兜底只触发一次：调用方会把它标失败，气泡随即被替换成红叹号。
  bool _reportedStale = false;

  @override
  void initState() {
    super.initState();
    // 每秒一次，只重建这行小字，不触碰消息列表。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() => _seconds++);
      if (!_reportedStale && _seconds >= widget.staleAfter.inSeconds) {
        _reportedStale = true;
        widget.onStale?.call();
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.ref.read(chatTransferProvider).progressOf(widget.messageId);

    return ValueListenableBuilder<double?>(
      valueListenable: notifier,
      builder: (context, progress, _) {
        if (progress == null) {
          return Text(
            t.conversation.sendingCountdown(seconds: _seconds),
            style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.outline),
          );
        }

        // 用 floor 而不是 round：99.6% 还没传完，显示 100% 会让人以为卡住了。
        final percent = (progress * 100).floor().clamp(0, 100);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 96,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: widget.color.withValues(alpha: 0.2),
                  valueColor: AlwaysStoppedAnimation<Color>(widget.color),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              t.conversation.sendingProgress(percent: percent),
              style: TextStyle(fontSize: 10, color: widget.color),
            ),
          ],
        );
      },
    );
  }
}
