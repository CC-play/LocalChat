import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/conversation/conversation.dart';
import 'package:localsend_app/widget/chat/file_message_card.dart';

/// 单条消息气泡：接收靠左、发送靠右，与主流即时通讯软件一致。
class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  /// 对方（接收方消息）的头像占位字符。
  final String peerInitial;

  final VoidCallback? onFileTap;

  const MessageBubble({
    super.key,
    required this.message,
    required this.peerInitial,
    this.onFileTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOutgoing = message.isOutgoing;
    final bubbleColor = isOutgoing ? theme.colorScheme.primary : theme.colorScheme.surfaceContainer;
    final failed = message.status == ChatMessageStatus.failed;

    final Widget bubbleChild;
    if (message.kind == ChatMessageKind.text) {
      bubbleChild = Text(
        message.text ?? '',
        style: TextStyle(
          fontSize: 14,
          color: isOutgoing ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: Row(
        mainAxisAlignment: isOutgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isOutgoing) avatar,
          if (!isOutgoing) const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  decoration: BoxDecoration(
                    color: failed ? theme.colorScheme.errorContainer : bubbleColor,
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
    );
  }
}
