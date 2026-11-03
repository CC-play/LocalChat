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

  const MessageBubble({
    super.key,
    required this.message,
    required this.peerInitial,
    this.onFileTap,
    this.onSecondaryTap,
    this.onRetry,
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
        ChatMessageStatus.pending => SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.colorScheme.primary,
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
                        idleHint: t.conversation.sending,
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
/// 此时显示原来的「发送中…」，不占用额外高度。
class _SendProgressFooter extends StatelessWidget {
  final String messageId;
  final Color color;
  final String idleHint;

  const _SendProgressFooter({
    required this.messageId,
    required this.color,
    required this.idleHint,
  });

  @override
  Widget build(BuildContext context) {
    final notifier = context.ref.read(chatTransferProvider).progressOf(messageId);

    return ValueListenableBuilder<double?>(
      valueListenable: notifier,
      builder: (context, progress, _) {
        if (progress == null) {
          return Text(
            idleHint,
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
                  backgroundColor: color.withValues(alpha: 0.2),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              t.conversation.sendingProgress(percent: percent),
              style: TextStyle(fontSize: 10, color: color),
            ),
          ],
        );
      },
    );
  }
}
