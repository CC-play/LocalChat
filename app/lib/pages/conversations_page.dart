import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_app/pages/conversation_page.dart';
import 'package:localchat_app/provider/conversation_provider.dart';
import 'package:localchat_app/util/conversation/peer_label.dart';
import 'package:localchat_app/util/native/chat_notification.dart';
import 'package:localchat_app/widget/chat/peer_title.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// 会话列表：按对端设备聚合的往来记录，微信式的首页。
class ConversationsPage extends StatelessWidget {
  const ConversationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final conversations = context.watch(conversationProvider);

    return Scaffold(
      // 这里不用 basicLocalChatAppbar：列表页需要 actions，而该 helper 目前只接受标题。
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
      body: Column(
        children: [
          // [FORK] 通知被关时用户根本察觉不到 —— 对方发了消息，他这边一片安静。
          // vivo / 小米这类 ROM 默认就把第三方通知关掉了，所以值得占一条横幅。
          const _NotificationsOffBanner(),
          Expanded(child: _buildList(context, conversations)),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, List<Conversation> conversations) {
    if (conversations.isEmpty) {
      return Center(
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
      );
    }

    // [FORK] 名字分布只算一次，itemBuilder 里按需查表（避免每条都重算一遍）。
    final nameCounts = peerNameCounts(conversations);

    return ListView.separated(
      itemCount: conversations.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, index) {
        final conversation = conversations[index];
        return _ConversationTile(
          conversation: conversation,
          // 同名才加指纹短码，否则标题保持原样。
          ambiguous: peerNameCollides(conversation, nameCounts),
        );
      },
    );
  }
}

/// [FORK] 通知不可用时的提示条。
///
/// 只在真的收不到提醒时出现：没权限、整个 App 的通知被关、或「消息」渠道被关。
/// 点「去开启」会先尝试系统权限框，已被永久拒绝则直接跳到通知设置页。
class _NotificationsOffBanner extends StatefulWidget {
  const _NotificationsOffBanner();

  @override
  State<_NotificationsOffBanner> createState() => _NotificationsOffBannerState();
}

class _NotificationsOffBannerState extends State<_NotificationsOffBanner> {
  ChatNotificationBlocker _blocker = ChatNotificationBlocker.unsupported;
  bool _dismissed = false;
  AppLifecycleListener? _lifecycleListener;

  @override
  void initState() {
    super.initState();
    // 从系统设置里改完通知再回来，横幅必须自己消失，不能等重启。
    _lifecycleListener = AppLifecycleListener(onResume: () => unawaited(_refresh()));
    // initState 里不能读 provider / 建上下文相关的东西，第一帧之后再查。
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final blocker = await ChatNotification.blocker();
    if (!mounted) {
      return;
    }
    setState(() => _blocker = blocker);
  }

  Future<void> _enable() async {
    await ChatNotification.requestAccess();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final blocking = _blocker != ChatNotificationBlocker.none && _blocker != ChatNotificationBlocker.unsupported;
    if (_dismissed || !blocking) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final foreground = theme.colorScheme.onSurfaceVariant;

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      child: Row(
        children: [
          Icon(Icons.notifications_off_outlined, size: 20, color: foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.conversation.notificationsOff,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: foreground),
                ),
                Text(
                  t.conversation.notificationsOffHint,
                  style: TextStyle(fontSize: 11, color: foreground.withValues(alpha: 0.75)),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => unawaited(_enable()),
            child: Text(t.conversation.notificationsEnable),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: t.general.hide,
            onPressed: () => setState(() => _dismissed = true),
          ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;

  /// [FORK] 是否与列表里其它会话同名 —— 同名时标题后追加指纹短码。
  final bool ambiguous;

  const _ConversationTile({
    required this.conversation,
    this.ambiguous = false,
  });

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
            // [FORK] 重名时标题变成「名字 · 3F7A」，否则与原来一模一样。
            child: PeerTitleText(
              conversation: conversation,
              ambiguous: ambiguous,
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
        content: Text(t.conversation.deleteMessage(name: peerLabel(conversation, ambiguous: ambiguous))),
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
