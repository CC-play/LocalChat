import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_app/model/cross_file.dart';
import 'package:localchat_app/pages/conversation_page.dart';
import 'package:localchat_app/provider/conversation_provider.dart';
import 'package:localchat_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localchat_app/util/conversation/conversation_sender.dart';
import 'package:localchat_app/util/conversation/peer_label.dart';
import 'package:localchat_app/util/native/chat_notification.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/util/ui/avatar_color.dart';
import 'package:localchat_app/widget/chat/peer_avatar.dart';
import 'package:localchat_app/widget/chat/peer_title.dart';
import 'package:localchat_isolates/util/file_size_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// [FORK] 破坏性操作（删除会话 / 清空全部）的实心底色。
///
/// 不能直接拿 `colorScheme.error` 当背景：M3 在深色主题下把它定义成 #FFB4AB
/// 浅粉、配套的 onError 是暗红，成品是一块淡粉配深字——读起来像「选中高亮」，
/// 不像危险动作。危险红是语义色而非主题色，固定成同一个正红，深浅两套主题
/// 下都是红底白字。对比度 4.6:1，达到 AA 正文标准。
const _dangerRed = Color(0xFFD32F2F);

/// [FORK] 右键菜单里「删除此会话」的文字色。
///
/// 比 [_dangerRed] 亮两档：菜单项只是一行小字，夹在灰字菜单里要靠色相跳出来，
/// 用深红会发闷；而确认框的主按钮是整块实心红，用亮红反而刺眼。两种场景
/// 各取所需，不是同一块色。
const _dangerRedText = Color(0xFFFF5252);

/// [FORK] 会话项右侧「消息发送失败」警示图标的前景色。
///
/// 不用 `colorScheme.error`：浅色主题下它是 #BA1A1A，压在深色标题旁边像一块发暗的
/// 砖红；深色主题下是 #FFB4AB 浅粉，更不显眼。改用饱和正红，并按亮度分档——同一个
/// 色在两套背景上没法都够鲜艳：亮红在浅底上会糊，深红在深底上发闷。
/// 深色沿用菜单里那个 #FF5252；浅色用 Red 600，对浅底对比度约 3.9:1，
/// 20px 的描边图标仍能看清轮廓。
Color _failedIconColor(Brightness brightness) =>
    brightness == Brightness.dark ? _dangerRedText : const Color(0xFFE53935);

/// 会话列表：按对端设备聚合的往来记录，微信式的首页。
class ConversationsPage extends StatelessWidget {
  const ConversationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final conversations = context.watch(conversationProvider);
    // [FORK] 分享进来的待发文件：非空时列表顶部出现横幅，点会话改为「确认后发送」。
    // 数据源与「发送」Tab 共用——用户切到发送页时原有选设备流程照常可用。
    final pendingFiles = context.watch(selectedSendingFilesProvider);

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
                  // [FORK] 清空是不可撤销的批量删除，按钮做成红色并带 3 秒倒计时，
                  // 避免「连点两下」就把整页记录抹掉。倒计时由对话框自己管。
                  builder: (_) => const _ClearAllDialog(),
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
          if (pendingFiles.isNotEmpty) _ShareFilesBanner(files: pendingFiles),
          Expanded(child: _buildList(context, conversations, pendingFiles)),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, List<Conversation> conversations, List<CrossFile> pendingFiles) {
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
          // [FORK] 有待分享文件时，点会话先弹「发送给 X？」确认框，不再直接进入。
          pendingFiles: pendingFiles,
        );
      },
    );
  }
}

/// [FORK] 「清空全部会话」的确认框。
///
/// 比普通确认框多一道防误触：主按钮是红色的危险操作，且前 3 秒保持禁用并显示
/// 剩余秒数。清空会删掉所有会话记录且不可撤销，手一抖连点两下就没了——倒计时
/// 的成本远低于事后找不回来。
class _ClearAllDialog extends StatefulWidget {
  const _ClearAllDialog();

  @override
  State<_ClearAllDialog> createState() => _ClearAllDialogState();
}

class _ClearAllDialogState extends State<_ClearAllDialog> {
  /// 禁用时长。3 秒足够让「我要清空」和「手滑」区分开，又不至于让人等得不耐烦。
  static const _countdownFrom = 3;

  int _remaining = _countdownFrom;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _remaining--);
      if (_remaining <= 0) {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    // 用户提前取消 / 点遮罩关闭时，计时器必须跟着走，否则会给已卸载的 State setState。
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _remaining <= 0;
    return AlertDialog(
      title: Text(t.conversation.clearAllTitle),
      content: Text(t.conversation.clearAllMessage),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(t.general.cancel),
        ),
        FilledButton(
          // 禁用态下 onPressed 为 null，改用 disabledBackground/disabledForeground
          // 把红底压成淡红、文字转灰——仍看得出这里是主操作，但一眼知道还不能点。
          onPressed: ready ? () => Navigator.pop(context, true) : null,
          style: FilledButton.styleFrom(
            backgroundColor: _dangerRed,
            foregroundColor: Colors.white,
            disabledBackgroundColor: _dangerRed.withValues(alpha: 0.15),
            disabledForegroundColor: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.38),
          ),
          child: Text(ready ? t.conversation.clear : t.conversation.clearCountdown(seconds: _remaining)),
        ),
      ],
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

/// [FORK] 「待分享」横幅：其它 App 分享进来的文件落在会话页顶部。
///
/// 显示文件数量与总大小；点右侧关闭 = 放弃这次分享（清待发列表，
/// 不清缓存目录）。发送动作由点按列表里的会话触发（见 _ConversationTile._open）。
class _ShareFilesBanner extends StatelessWidget {
  final List<CrossFile> files;

  const _ShareFilesBanner({required this.files});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = theme.colorScheme.onSurfaceVariant;

    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      child: Row(
        children: [
          Icon(Icons.share_outlined, size: 20, color: foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.conversation.sharePending(count: files.length, size: _totalSizeOf(files)),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: foreground),
                ),
                Text(
                  t.conversation.sharePendingHint,
                  style: TextStyle(fontSize: 11, color: foreground.withValues(alpha: 0.75)),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: t.general.cancel,
            // 放弃分享：只清待发列表，不动缓存（文件可能正被别的流程引用）。
            onPressed: () => context.ref.redux(selectedSendingFilesProvider).dispatch(ConsumeSelectionAction()),
          ),
        ],
      ),
    );
  }
}

String _totalSizeOf(List<CrossFile> files) {
  var total = 0;
  for (final f in files) {
    total += f.size;
  }
  return total.asReadableFileSize;
}

/// [FORK] 会话项右键菜单里的动作。
///
/// 只有一个成员也单独立枚举：将来加「标为已读」「置顶」时，`showMenu` 的返回值和
/// `switch` 都能直接扩展，不必把 if/else 改成别的形式。
enum _TileMenuAction { delete }

/// [FORK] 会话列表里的一行。
///
/// 桌面端右击整行会弹出操作菜单（目前只有「删除此会话」），它和长按一样
/// 落到 [_confirmDelete]：两条入口共用同一个确认框与同一份删除逻辑，不会
/// 出现「菜单直接删、长按还要确认」这种不一致。
class _ConversationTile extends StatefulWidget {
  final Conversation conversation;

  /// [FORK] 是否与列表里其它会话同名 —— 同名时标题后追加指纹短码。
  final bool ambiguous;

  /// [FORK] 待分享的文件。非空时点按本会话会先弹「发送给 X？」确认框。
  final List<CrossFile> pendingFiles;

  const _ConversationTile({
    required this.conversation,
    this.ambiguous = false,
    this.pendingFiles = const [],
  });

  @override
  State<_ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<_ConversationTile> {
  /// 右键菜单是否已经打开。
  ///
  /// 连点右键时，`PopupRoute` 的遮罩只能吃掉第二次点击本身，挡不住再 push
  /// 一层菜单，会叠出两个一模一样的菜单；这里加一道闸门。
  bool _menuOpen = false;

  // 与 Widget 同名字段转发：下面的布局和交互沿用手感更熟的 `conversation.xxx`
  // 写法，不必逐处改成 `widget.conversation.xxx`。
  Conversation get conversation => widget.conversation;
  bool get ambiguous => widget.ambiguous;
  List<CrossFile> get pendingFiles => widget.pendingFiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = conversation.lastMessage;
    final unread = conversation.unreadCount;
    final failed = last?.status == ChatMessageStatus.failed;

    return GestureDetector(
      // [FORK] 桌面端右击整行弹出会话菜单。用 translucent：行内留白也能右键，
      // 且不抢 ListTile 自己的点击与长按（右键是次要键，不参与 tap 竞技）。
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: checkPlatformIsDesktop() ? (details) => unawaited(_showTileMenu(details.globalPosition)) : null,
      child: ListTile(
        onTap: () => unawaited(_open(context)),
        onLongPress: () => _confirmDelete(context),
        // [FORK] 未读数挂在头像右上角：44 的方框比头像大一圈，徽标锚 right/top，
        // 正好压在圆角方块的右上角外侧，不与标题行抢位置。
        leading: SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            // 徽标要探出头像方框一点，默认的 hardEdge 会把它切掉。
            clipBehavior: Clip.none,
            children: [
              Center(
                // [FORK] 与聊天气泡共用同一个头像部件：圆角方块 + 按指纹取色。
                child: PeerAvatar(
                  initial: conversation.initial,
                  colors: avatarColorsFor(conversation.peerFingerprint, theme.brightness),
                  size: 40,
                ),
              ),
              if (unread > 0)
                Positioned(
                  // 方块有实实在在的直角区域，徽标比圆形头像时再往外挪 1px，
                  // 避免压在头像本体上（徽标自带 1.5px 底色描边）。
                  top: -4,
                  right: -4,
                  child: _UnreadBadge(count: unread),
                ),
            ],
          ),
        ),
        // [FORK] 重名时标题变成「名字 · 3F7A」，否则与原来一模一样。
        title: PeerTitleText(
          conversation: conversation,
          ambiguous: ambiguous,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        // [FORK] 右侧竖排一列：时间在上，发送失败的警示图标在它正下方，两者都贴右边缘。
        //
        // 之前是「标题行里塞 [!] 11/14，再用 Transform 把图标下移到预览行底部」——
        // 图标和时间的 x 对不齐，偏移量还是照着实测间距硬编码的，改字体就会失准。
        // 合成一列后位置关系由布局保证，不需要任何魔法数字。
        //
        // 图标槽恒定 20dp 高（不失败时留空）：trailing 高度一致，各行的时间才会落在
        // 同一水平线上；否则 ListTile 的垂直居中会把有无图标的行错开半个图标高。
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _formatTime(conversation.lastActivity),
              style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 2),
            SizedBox(
              width: 20,
              height: 20,
              child: failed ? Icon(Icons.error_outline, size: 20, color: _failedIconColor(theme.brightness)) : null,
            ),
          ],
        ),
        subtitle: Text(
          last == null ? '' : _previewOf(last),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
        ),
      ),
    );
  }

  /// [FORK] 在右击位置弹出会话菜单。
  ///
  /// 样式与聊天页气泡的右键菜单保持一致（surfaceContainer 底 + 一圈 outlineVariant
  /// 描边），两个右键菜单在同一套界面里不该长得像两个 App。
  Future<void> _showTileMenu(Offset position) async {
    if (_menuOpen) {
      return;
    }
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) {
      return;
    }

    _menuOpen = true;
    final theme = Theme.of(context);
    _TileMenuAction? action;
    try {
      action = await showMenu<_TileMenuAction>(
        context: context,
        position: RelativeRect.fromLTRB(
          position.dx,
          position.dy,
          overlay.size.width - position.dx,
          overlay.size.height - position.dy,
        ),
        color: theme.colorScheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        items: [
          PopupMenuItem(
            value: _TileMenuAction.delete,
            height: 40,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.delete_outline, size: 16, color: _dangerRedText),
                const SizedBox(width: 10),
                // [FORK] 破坏性操作走鲜红文字：菜单里只有这一项，颜色就是唯一的提示。
                // 不用 colorScheme.error —— 深色下它是 #FFB4AB 浅粉，作为一行小字
                // 完全跳不出来。
                Text(t.conversation.deleteAction, style: const TextStyle(color: _dangerRedText)),
              ],
            ),
          ),
        ],
      );
    } finally {
      _menuOpen = false;
    }

    // 菜单关闭后会话可能已经被别处删掉，State 也就卸载了，确认框不能再弹。
    if (action == _TileMenuAction.delete && mounted) {
      await _confirmDelete(context);
    }
  }

  String _previewOf(ChatMessage message) {
    final body = message.preview ?? (message.kind == ChatMessageKind.text ? t.conversation.messagePlaceholder : t.conversation.filePlaceholder);
    final prefix = message.isOutgoing ? t.conversation.youPrefix : '';
    return '$prefix$body';
  }

  /// 点按会话：有待分享文件时先确认再发送，否则照常进入会话页。
  Future<void> _open(BuildContext context) async {
    if (pendingFiles.isEmpty) {
      await context.push(() => ConversationPage(peerFingerprint: conversation.peerFingerprint));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.conversation.sendToTitle(name: peerLabel(conversation, ambiguous: ambiguous))),
        content: Text(t.conversation.sendToContent(count: pendingFiles.length, size: _totalSizeOf(pendingFiles))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(t.general.cancel)),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(t.sendTab.title)),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }

    // 地址解析失败（会话既不在当前局域网、也没记录过 IP）只能放弃，
    // 待分享列表原样保留，用户还能换别的会话或去「发送」页。
    final target = resolveConversationTarget(context.ref, conversation);
    if (target == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.conversation.sendToNoAddress)));
      }
      return;
    }

    // 先消费掉待分享列表（见 ConsumeSelectionAction 的注释：不能走
    // ClearSelectionAction，那会把缓存目录里正在上传的源文件删掉），
    // 然后立刻进会话页看「发送中」气泡，投递全程在后台跑。
    context.ref.redux(selectedSendingFilesProvider).dispatch(ConsumeSelectionAction());
    final ref = context.ref;
    unawaited(
      deliverFilesInBackground(
        ref: ref,
        target: target,
        files: pendingFiles,
        onFailure: (message) {
          // 失败原因已写进气泡；这里只负责用户退回列表时补一条可见的提示。
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
          }
        },
      ),
    );
    await context.push(() => ConversationPage(peerFingerprint: conversation.peerFingerprint));
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
          // [FORK] 删除不可撤销，用实心红把它和「取消」区分开。
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: _dangerRed,
              foregroundColor: Colors.white,
            ),
            child: Text(t.general.delete),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await context.ref.redux(conversationProvider).dispatchAsync(DeleteConversationAction(conversation.peerFingerprint));
    }
  }
}

/// [FORK] 会话列表头像右上角的未读数徽标。
///
/// 描边用 `surface` 而不是透明：徽标压在头像上，没有这一圈边会和头像
/// 糊成一片。`minWidth` 让个位数也是圆的，`99+` 才自然向右长出来。
class _UnreadBadge extends StatelessWidget {
  /// 比主题的 `error` 更鲜艳、更偏橙：主题红在浅色背景上发闷，
  /// 而徽标要在头像旁一眼跳出。字色固定纯白，不跟随主题。
  static const _badgeColor = Color(0xFFFF3100);

  final int count;

  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 17),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: _badgeColor,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: theme.colorScheme.surface, width: 1.5),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 10,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}
