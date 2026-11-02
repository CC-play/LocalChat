import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/conversation/conversation.dart';
import 'package:localsend_app/pages/conversation_page.dart';
import 'package:localsend_app/provider/conversation_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// 会话列表：按对端设备聚合的往来记录，微信式的首页。
class ConversationsPage extends StatelessWidget {
  const ConversationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final conversations = context.watch(conversationProvider);

    return Scaffold(
      // 这里不用 basicLocalSendAppbar：列表页需要 actions，而该 helper 目前只接受标题。
      appBar: AppBar(
        title: Text(t.conversation.title),
        actions: [
          if (conversations.isNotEmpty)
            IconButton(
              tooltip: t.conversation.clearAll,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(t.conversation.clearAllTitle),
                    content: Text(t.conversation.clearAllMessage),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.general.cancel)),
                      TextButton(onPressed: () => Navigator.pop(context, true), child: Text(t.conversation.clear)),
                    ],
                  ),
                );
                if (confirmed == true && context.mounted) {
                  await context.ref.redux(conversationProvider).dispatchAsync(ClearConversationsAction());
                }
              },
            ),
        ],
      ),
      body: conversations.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 48, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  Text(t.conversation.empty, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    t.conversation.emptyHint,
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
                  ),
                ],
              ),
            )
          : ListView.separated(
              itemCount: conversations.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
              itemBuilder: (context, index) => _ConversationTile(conversation: conversations[index]),
            ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;

  const _ConversationTile({required this.conversation});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = conversation.lastMessage;
    final unread = conversation.unreadCount;

    return ListTile(
      onTap: () => context.push(() => ConversationPage(peerFingerprint: conversation.peerFingerprint)),
      onLongPress: () => _confirmDelete(context),
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.secondaryContainer,
        foregroundColor: theme.colorScheme.onSecondaryContainer,
        child: Text(conversation.initial),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              conversation.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            _formatTime(conversation.lastActivity),
            style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
          ),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              last == null ? '' : _previewOf(last),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
            ),
          ),
          if (unread > 0)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.error,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                unread > 99 ? '99+' : '$unread',
                style: TextStyle(fontSize: 10, color: theme.colorScheme.onError),
              ),
            ),
        ],
      ),
      trailing: last != null && last.status == ChatMessageStatus.failed
          ? Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error)
          : null,
    );
  }

  String _previewOf(ChatMessage message) {
    final body = message.preview ??
        (message.kind == ChatMessageKind.text ? t.conversation.messagePlaceholder : t.conversation.filePlaceholder);
    final prefix = message.isOutgoing ? t.conversation.youPrefix : '';
    return '$prefix$body';
  }

  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    final sameDay = local.year == now.year && local.month == now.month && local.day == now.day;
    if (sameDay) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (local.year == yesterday.year && local.month == yesterday.month && local.day == yesterday.day) {
      return t.conversation.yesterday;
    }
    return '${local.month}/${local.day}';
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.conversation.deleteTitle),
        content: Text(t.conversation.deleteMessage(name: conversation.displayName)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.general.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(t.general.delete)),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await context.ref.redux(conversationProvider).dispatchAsync(DeleteConversationAction(conversation.peerFingerprint));
    }
  }
}
