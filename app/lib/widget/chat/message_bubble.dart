import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/conversation/conversation.dart';
import 'package:localsend_app/widget/chat/file_message_card.dart';

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

  const MessageBubble({
    super.key,
    required this.message,
    required this.peerInitial,
    this.onFileTap,
    this.onSecondaryTap,
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
        ChatMessageStatus.failed => Icon(
          Icons.error,
          size: 18,
          color: theme.colorScheme.error,
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
                  if (statusHint != null)
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
