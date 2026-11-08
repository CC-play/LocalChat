import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';
import 'package:localchat_app/config/chat_palette.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_app/model/cross_file.dart';
import 'package:localchat_app/provider/conversation_provider.dart';
import 'package:localchat_app/provider/receive_history_provider.dart';
import 'package:localchat_app/util/conversation/clipboard_image.dart';
import 'package:localchat_app/util/conversation/conversation_media_picker.dart';
import 'package:localchat_app/util/conversation/conversation_sender.dart';
import 'package:localchat_app/util/conversation/peer_label.dart';
import 'package:localchat_app/util/native/chat_notification.dart';
import 'package:localchat_app/util/native/cross_file_converters.dart';
import 'package:localchat_app/util/native/file_availability.dart';
import 'package:localchat_app/util/native/open_file.dart';
import 'package:localchat_app/util/native/open_folder.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/widget/chat/delete_record_dialog.dart';
import 'package:localchat_app/widget/chat/drop_confirm_dialog.dart';
import 'package:localchat_app/widget/chat/message_bubble.dart';
import 'package:localchat_app/widget/chat/peer_title.dart';
import 'package:localchat_app/widget/chat/top_toast.dart';
import 'package:localchat_isolates/model/device.dart';
import 'package:localchat_isolates/model/file_type.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';

/// 气泡右键 / 长按 / 选中后弹出的菜单项。
///
/// [FORK] 「删除该条记录」「打开文件所在位置」是本 fork 加的；
/// 「复制」沿用上游的选区带出逻辑。
///
/// 声明顺序即菜单里的显示顺序：复制 → 打开文件所在位置 → 删除该条记录。
/// 破坏性动作放最后，和菜单里那行红字的位置一致。
enum _ChatMenuAction { copy, revealInFolder, delete }

/// 单个对端设备的会话窗口。
class ConversationPage extends StatefulWidget {
  final String peerFingerprint;

  /// [FORK] 新会话的起始设备。
  ///
  /// 从发送页的「发起会话」进来时，本地还没有这台设备的会话记录，靠它渲染一个
  /// **未落库的草稿会话**：标题、头像、发送目标全都能用，但不会在会话列表里留下
  /// 一条空记录。第一条消息发出时 `AppendChatMessageAction` 会顺手把会话建出来。
  ///
  /// 从会话列表进来时保持为 null，行为与之前完全一致。
  final Device? device;

  const ConversationPage({
    super.key,
    required this.peerFingerprint,
    this.device,
  });

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  /// [FORK] 文字可选中：靠它拿到当前选区锚点，用于定位「复制」菜单。
  final _selectionKey = GlobalKey<SelectionAreaState>();

  /// [FORK] 页面级 Ctrl+V 需要把活交给输入条（剪贴板读取与确认卡片都在那里）。
  final _composerKey = GlobalKey<_ComposerState>();

  /// 当前选中文本；由 [SelectionArea.onSelectionChanged] 维护，仅作字段用（不 setState）。
  String? _selectedText;

  /// 本次按下之后选区是否真的变化过。
  ///
  /// 用来区分「拖选 / 双击选词」（要弹菜单）和「点空白处取消选区」
  /// （此时 pointer up 前选区还是旧的，不该弹）。
  bool _selectionTouched = false;

  /// 菜单是否已经弹出。避免 pointer up 与后续事件重复弹两次。
  bool _menuOpen = false;

  /// [FORK] 是否有文件正被拖到窗口上方（用于显示「松开即可发送」遮罩）。
  bool _dragging = false;

  /// 拖拽确认卡片是否已经打开，避免连拖两次叠两层弹窗。
  bool _dropDialogOpen = false;

  /// [FORK] 正在重发的消息 id。重发期间点同一颗感叹号不再响应。
  final _retrying = <String>{};

  /// 消息列表的滚动控制器。列表是正向的（第 0 条在最上面），
  /// 「停在最新一条」由 [_handleScrollAnchors] 维护。
  final _scrollController = ScrollController();

  /// 上一次构建看到的消息条数；`null` 表示还没构建过（首帧）。
  int? _messageCount;

  /// 上一次构建时的软键盘高度，用来发现「键盘刚弹出」。
  double _keyboardInset = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// [FORK] 正向列表的「停在最新一条」维护。
  ///
  /// 列表原来是 `reverse: true`：它天然贴着底部，代价是消息不满一屏时整块
  /// 内容会沉到输入框上方（新建会话的头几条就浮在屏幕底部，上面一大片空白）。
  /// 改成正向列表后，不满一屏自然从顶部排起，代价是要自己维护位置：
  ///
  /// - 首帧：历史多时直接跳到底，否则用户会从最早一条开始看；
  /// - 来了新消息：只有原本就在底部才跟随，正在翻历史时被打断很讨厌；
  /// - 键盘弹出：视口变矮、`maxScrollExtent` 变大，得再贴一次底，
  ///   不然最新一条会被输入条挡住。
  void _handleScrollAnchors(int count, double keyboardInset) {
    final first = _messageCount == null;
    final grew = !first && count > _messageCount!;
    final keyboardOpened = keyboardInset > _keyboardInset;
    _messageCount = count;
    _keyboardInset = keyboardInset;

    if (first || keyboardOpened || (grew && _isNearBottom)) {
      _stickToBottomSoon();
    }
  }

  /// 是否还停在最后一条附近。没挂上列表（首帧、空会话）时按「在底部」算。
  bool get _isNearBottom {
    if (!_scrollController.hasClients) {
      return true;
    }
    final position = _scrollController.position;
    // 48 的宽容度：气泡有高度，差几个像素不该算作「离开底部」。
    return position.pixels >= position.maxScrollExtent - 48;
  }

  void _stickToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _stickToBottom());
  }

  void _stickToBottom() {
    if (!mounted || !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.maxScrollExtent <= 0) {
      return;
    }
    position.jumpTo(position.maxScrollExtent);
  }

  @override
  void initState() {
    super.initState();
    // 进入会话即视为已读。用 post frame 回调避免在首帧构建期间触发状态更新。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(context.ref.redux(conversationProvider).dispatchAsync(MarkConversationReadAction(widget.peerFingerprint)));
      // [FORK] 用户已经看到这个会话了，通知栏里那条提醒就该消失，
      // 否则点进来看完还留着一条，会让人以为有新消息没读。
      unawaited(ChatNotification.clear(widget.peerFingerprint));
    });
  }

  /// [FORK] 点击红色感叹号重发。
  ///
  /// 复用原消息 id：气泡原地从「失败」变回「发送中」，不会再插一条。
  Future<void> _retryMessage(ChatMessage message) async {
    if (!_retrying.add(message.id)) {
      return;
    }
    try {
      final conversation = context.ref
          .read(conversationProvider)
          .firstWhereOrNull((c) => c.peerFingerprint == widget.peerFingerprint);
      if (conversation == null) {
        return;
      }
      final target = resolveConversationTarget(context.ref, conversation);
      if (target == null) {
        if (mounted) {
          TopToast.show(context, t.conversation.peerUnreachable);
        }
        return;
      }

      final failure = await retryChatMessage(ref: context.ref, target: target, message: message);
      if (!mounted || failure == null) {
        return;
      }
      TopToast.show(context, _describeSendFailure(failure));
    } finally {
      _retrying.remove(message.id);
    }
  }

  /// [FORK] 点击「发送中」的转圈，立刻停下这次发送。
  ///
  /// 之所以需要它：发送最多要等满两分钟的重试窗口（给对方时间打开 App），
  /// 这期间界面上只有「发送中」，用户无法判断它是在工作还是卡死，
  /// 也无法中止。把转圈做成按钮，主动权就交回用户手里。
  Future<void> _cancelMessage(ChatMessage message) async {
    final target = _currentTarget();
    if (target == null) {
      return;
    }

    final cancelled = await cancelChatMessage(
      ref: context.ref,
      target: target,
      messageId: message.id,
      errorMessage: t.conversation.sendCancelled,
    );
    if (!mounted || !cancelled) {
      // 没停成说明它刚好已经结束了，气泡上会显示真实结局，不用再提示。
      return;
    }
    TopToast.show(context, t.conversation.sendCancelled);
  }

  /// [FORK] 兜底：气泡挂在「发送中」太久，直接判失败。
  ///
  /// 走到这里说明发送流程本身已经不正常了（异常逃逸，或页面销毁让上传看门狗
  /// 静默退出），不能继续让它转圈。[cancelChatMessage] 在没有活跃发送时
  /// 同样会把气泡写成终态。
  Future<void> _expireStaleMessage(ChatMessage message) async {
    final target = _currentTarget();
    if (target == null) {
      return;
    }
    await cancelChatMessage(
      ref: context.ref,
      target: target,
      messageId: message.id,
      errorMessage: t.conversation.peerUnreachable,
    );
  }

  /// 当前会话对应的可发送设备；找不到返回 null。
  Device? _currentTarget() {
    final conversation = _effectiveConversation();
    if (conversation == null) {
      return null;
    }
    return resolveConversationTarget(context.ref, conversation);
  }

  /// 当前生效的会话：库里已有就用它，还没有就用草稿。
  ///
  /// 草稿只在「从发送页发起会话」这条路径上存在，见 [_draftConversation]。
  Conversation? _effectiveConversation() {
    return context.ref
            .read(conversationProvider)
            .firstWhereOrNull((c) => c.peerFingerprint == widget.peerFingerprint) ??
        _draftConversation();
  }

  /// [FORK] 用 [ConversationPage.device] 拼一个不落库的草稿会话。
  ///
  /// 只有「发起会话」这条路径会走到：用户从发送页点进一台还没聊过的设备。
  /// 这里刻意不往 [conversationProvider] 里塞空会话——否则点一下「发起会话」
  /// 又退出来，会话列表里就会多一条空记录（预览为空、时间还是刚刚）。
  /// 真正建会话发生在第一条消息落地时。
  Conversation? _draftConversation() {
    final device = widget.device;
    if (device == null || device.fingerprint.isEmpty) {
      return null;
    }
    return Conversation(
      peerFingerprint: device.fingerprint,
      peerAlias: device.alias,
      peerIp: device.ip,
      peerPort: device.port > 0 ? device.port : null,
      lastActivity: DateTime.now(),
      unreadCount: 0,
      messages: const [],
    );
  }

  void _handleSelectionChanged(SelectedContent? content) {    final text = content?.plainText;
    _selectedText = text;
    if (text != null && text.isNotEmpty) {
      _selectionTouched = true;
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    // 新一轮按下，先认为选区没被碰过；真正的选中会在此后回调里置位。
    _selectionTouched = false;
  }

  /// 松手后如果存在选区，就在选区旁自动弹出「复制」。
  void _handlePointerUp(PointerUpEvent event) {
    unawaited(_autoShowMenu(event.position));
  }

  Future<void> _autoShowMenu(Offset fallbackPosition) async {
    // 必须等一帧再读：选区在 pointer up 之后才最终化，而双击选词更晚——
    // 选词发生在手势竞技场裁决阶段，比 Listener.onPointerUp 还迟，
    // 所以判断不能提前返回。
    //
    // 用 endOfFrame 而不是 addPostFrameCallback —— 后者只登记回调、**不会主动
    // 调度帧**（见 SchedulerBinding.addPostFrameCallback 源码）。松手之后如果没有
    // 任何重绘（桌面端拖选完成后框架不再画选区手柄），回调就会一直挂着，
    // 菜单永远不会出现。endOfFrame 在 idle 时会自己 scheduleFrame，行为确定。
    await WidgetsBinding.instance.endOfFrame;

    // 偶发情况下选区比一帧更晚才就绪（例如 SelectionResult 是 pending 的），
    // 这里再补几次短重试，避免「明明选中了却不弹菜单」。
    for (var attempt = 0; attempt < 4; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      if (!mounted || _menuOpen) {
        return;
      }
      final selected = _selectedText;
      // 点空白处取消选区时，本次按下从没产生过新选区，不该弹菜单。
      if (!_selectionTouched || selected == null || selected.isEmpty) {
        continue;
      }
      await _showMessageMenu(position: fallbackPosition, text: selected);
      return;
    }
  }

  /// 右键气泡：有选区就用选区，否则复制这一条气泡的正文。
  ///
  /// [FORK] 菜单里除「复制」外还有「打开文件所在位置」（桌面端、文件消息）
  /// 和「删除该条记录」，所以这里把整条 message 传下去。
  void _handleBubbleMenu(Offset position, ChatMessage message) {
    final body = message.kind == ChatMessageKind.text ? (message.text ?? '') : (message.fileName ?? '');
    final selected = _selectedText;
    // 选区必须确实落在这一条气泡里，才按「复制选中部分」处理，否则容易复制到别处的内容。
    final text = (selected != null && selected.isNotEmpty && body.contains(selected)) ? selected : body;
    unawaited(
      _showMessageMenu(
        position: position,
        message: message,
        text: text.isEmpty ? null : text,
      ),
    );
  }

  /// [FORK] 删除单条消息（文本气泡与文件卡片共用）。
  ///
  /// 三件事按顺序做，顺序不能换：
  /// 1. 还在「发送中」的先取消 —— 否则气泡从列表里消失后，后台仍会把文件传完；
  /// 2. 删接收历史里同 id 的条目（只有**收到的文件**才有，`entryId == fileId == message.id`），
  ///    两个视图是同一份数据的两种呈现，用户删的是「这条记录」，不该只删一半；
  /// 3. 删会话里的这条消息。`DeleteChatMessagesAction` 在删空时会一并移除会话。
  Future<void> _deleteMessage(ChatMessage message) async {
    final ref = context.ref;

    if (message.status == ChatMessageStatus.pending) {
      final target = _currentTarget();
      if (target != null) {
        await cancelChatMessage(
          ref: ref,
          target: target,
          messageId: message.id,
          errorMessage: t.conversation.sendCancelled,
        );
      }
    }

    await ref.redux(receiveHistoryProvider).dispatchAsync(RemoveHistoryEntryAction(message.id));
    await ref.redux(conversationProvider).dispatchAsync(DeleteChatMessagesAction({message.id}));

    if (!mounted) {
      return;
    }
    // 会话被删空时整条会话都没了，留在页面上只会看到「该会话已被删除」，直接退回列表。
    final stillExists = ref.read(conversationProvider).any((c) => c.peerFingerprint == widget.peerFingerprint);
    if (!stillExists) {
      unawaited(Navigator.of(context).maybePop());
    }
  }

  /// [FORK] 点会话里的文件卡片。
  ///
  /// `filePath` 为空表示这条消息在本机没有可用的副本（例如接收时只存进了相册，
  /// 没留下绝对路径）。这种情况不能静默吞掉点击，否则就是「点了没反应」，
  /// 所以在顶部提示一句。
  void _openFileMessage(ChatMessage message) {
    final path = message.filePath;
    if (path == null || path.isEmpty) {
      TopToast.show(context, t.conversation.fileUnavailable);
      return;
    }
    unawaited(openFile(context, message.fileType ?? FileType.other, path));
  }

  /// [FORK] 在系统文件管理器里定位这条文件消息对应的文件（Windows
  /// 资源管理器里是「打开文件所在的位置」）。
  ///
  /// 只给桌面端用，移动端的入口本来就不会出现（见 `canRevealInFolder`）。
  Future<void> _revealInFolder(ChatMessage message) async {
    final path = message.filePath;
    if (path == null || path.isEmpty) {
      return;
    }

    final file = File(path);
    final parent = file.parent;
    // 目录整个没了就定位不到：资源管理器对不存在的路径既不报错也不开窗口，
    // 用户只会觉得「点了没反应」，所以这里主动说明一句。
    if (!await parent.exists()) {
      if (mounted) {
        TopToast.show(context, t.conversation.revealInFolderFailed);
      }
      return;
    }

    // 用磁盘上的真实文件名，而不是 message.fileName —— 落盘时同名文件会被
    // 改名成 `xxx (1).txt`，用消息里记的名字会选不中那个文件。
    await openFolder(folderPath: parent.path, fileName: p.basename(path));
  }

  Future<void> _showMessageMenu({
    required Offset position,
    ChatMessage? message,
    String? text,
  }) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox || _menuOpen) {
      return;
    }

    _menuOpen = true;
    final theme = Theme.of(context);
    // [FORK] 「打开文件所在位置」的出现条件集中在菜单打开时算一次。
    //
    // 桌面端才给：手机上既没有文件夹可浏览，收到的文件路径还可能是
    // `content://`（相册 / 下载管理器给的 URI），`openFolder` 在 Android 上
    // 走的是完全不同的分支，语义不是「定位到文件」。
    final canRevealInFolder = message != null &&
        message.kind == ChatMessageKind.file &&
        (message.filePath?.isNotEmpty ?? false) &&
        checkPlatformIsDesktop();
    // [FORK] 文件已经不在磁盘上时，这一项仍然显示、但置灰。
    //
    // 直接不显示会让人以为功能丢了；能点却发现没反应更糟。置灰用
    // PopupMenuItem 自带的 disabled 样式（M3 取 onSurface 的 38%，M2 取
    // theme.disabledColor），深浅主题都跟着主题走，所以这里不写死颜色。
    final revealPath = canRevealInFolder ? message.filePath : null;
    final revealEnabled = await localFileExists(revealPath);
    if (!mounted) {
      _menuOpen = false;
      return;
    }
    _ChatMenuAction? action;
    try {
      action = await showMenu<_ChatMenuAction>(
        context: context,
        position: RelativeRect.fromLTRB(
          position.dx,
          position.dy,
          overlay.size.width - position.dx,
          overlay.size.height - position.dy,
        ),
        // [FORK] 菜单框描一圈浅色边框，和气泡一样有明确的边界感
        // （默认只有阴影，在浅色背景上几乎看不出边缘）。
        color: theme.colorScheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        items: [
          // 选中文字拖出来的菜单没有具体消息可删，只有复制。
          if (text != null && text.isNotEmpty)
            PopupMenuItem(
              value: _ChatMenuAction.copy,
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.copy, size: 16),
                  const SizedBox(width: 10),
                  Text(t.general.copy),
                ],
              ),
            ),
          // [FORK] 只在桌面端、且这条消息确实有本地路径时出现。
          // 位置按用户要求放在「复制」下面、「删除该条记录」上面。
          // 文件已经不在了就置灰（enabled: false）—— 那一项没有任何可做的事：
          // 资源管理器对不存在的路径既不报错也不开窗口，点下去等于没反应。
          if (canRevealInFolder)
            PopupMenuItem(
              value: _ChatMenuAction.revealInFolder,
              height: 40,
              enabled: revealEnabled,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.folder_open, size: 16),
                  const SizedBox(width: 10),
                  Text(t.conversation.revealInFolder),
                ],
              ),
            ),
          if (message != null)
            PopupMenuItem(
              value: _ChatMenuAction.delete,
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline, size: 16, color: theme.colorScheme.error),
                  const SizedBox(width: 10),
                  Text(
                    t.conversation.deleteBubble,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ),
            ),
        ],
      );
    } finally {
      _menuOpen = false;
    }

    if (!mounted) {
      return;
    }
    // 关掉菜单就取消高亮，避免残留一片蓝色选区。
    _selectionKey.currentState?.selectableRegion.clearSelection();
    _selectedText = null;
    _selectionTouched = false;

    switch (action) {
      case _ChatMenuAction.copy:
        if (text != null) {
          await Clipboard.setData(ClipboardData(text: text));
        }
      case _ChatMenuAction.revealInFolder:
        if (message != null) {
          await _revealInFolder(message);
        }
      case _ChatMenuAction.delete:
        if (message != null) {
          final confirmed = await showDeleteRecordDialog(context, message);
          if (!mounted) {
            return;
          }
          if (confirmed) {
            await _deleteMessage(message);
          }
        }
      case null:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // 拖拽文件
  // ---------------------------------------------------------------------------

  void _handleDragEntered(DropEventDetails details) {
    if (_dragging) {
      return;
    }
    setState(() => _dragging = true);
  }

  void _handleDragExited(DropEventDetails details) {
    if (!_dragging) {
      return;
    }
    setState(() => _dragging = false);
  }

  /// 拖拽落下：先统计，再确认，最后交给和回形针同一套投递流程。
  ///
  /// 拖拽是一次动作就把东西发出去，比点回形针更容易误操作，
  /// 所以中间加一张确认卡片，把数量和大小摆出来。
  Future<void> _handleDrop(DropDoneDetails details) async {
    if (mounted && _dragging) {
      setState(() => _dragging = false);
    }
    if (_dropDialogOpen) {
      return;
    }

    // 目录不展开（可能是整个 D 盘），只提示跳过。
    final files = <CrossFile>[];
    var skippedFolders = 0;
    try {
      for (final item in details.files) {
        if (Directory(item.path).existsSync()) {
          skippedFolders++;
          continue;
        }
        files.add(await CrossFileConverters.convertXFile(XFile(item.path)));
      }
    } catch (e) {
      debugPrint('Failed to read dropped files: $e');
      if (mounted) {
        TopToast.show(context, t.conversation.sendFailed);
      }
      return;
    }

    if (!mounted) {
      return;
    }
    if (skippedFolders > 0) {
      TopToast.show(context, t.conversation.dropFoldersIgnored);
    }
    if (files.isEmpty) {
      return;
    }

    // 拖拽同样支持「刚发起会话」：库里还没有记录时用草稿会话解析目标。
    final conversation = _effectiveConversation();
    if (conversation == null) {
      return;
    }
    final target = resolveConversationTarget(context.ref, conversation);
    if (target == null) {
      TopToast.show(context, t.conversation.peerUnreachable);
      return;
    }

    _dropDialogOpen = true;
    final bool confirmed;
    try {
      confirmed = await showDropConfirmDialog(context, files);
    } finally {
      _dropDialogOpen = false;
    }
    if (!confirmed || !mounted) {
      return;
    }

    // 拖进来的文件同样是「我刚发的」，投递前先把视角拉回最新一条。
    _stickToBottomSoon();
    unawaited(
      deliverFilesInBackground(
        ref: context.ref,
        target: target,
        files: files,
        onFailure: (message) {
          if (mounted) {
            TopToast.show(context, message);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conversations = context.watch(conversationProvider);
    final stored = conversations.firstWhereOrNull((e) => e.peerFingerprint == widget.peerFingerprint);
    final conversation = stored ?? _draftConversation();

    if (conversation == null) {
      return Scaffold(
        appBar: AppBar(title: Text(t.conversation.title)),
        body: Center(child: Text(t.conversation.deleted)),
      );
    }

    final messages = conversation.messages;
    final initial = conversation.initial;
    // [FORK] 草稿会话还不在列表里，判重名时要把它自己算进去，
    // 否则「和已有会话同名的设备」开新会话时标题分不清是谁。
    final nameCounts = peerNameCounts(stored == null ? [...conversations, conversation] : conversations);
    // [FORK] 消息不满一屏时从顶部排起，多于一屏时停在最新一条。见 [_handleScrollAnchors]。
    _handleScrollAnchors(messages.length, MediaQuery.viewInsetsOf(context).bottom);
    // [FORK] 聊天页配色（Local Chat + 浅色为中性灰底 + 纯白对方气泡）
    final palette = ChatPalette.of(context);

    final content = DropTarget(
      // [FORK] 会话窗口自己接住拖拽。主页那层 DropTarget 会同时收到事件
      // （desktop_drop 不做冒泡判定，只按各自 bounds 命中），
      // 所以在 home_page 里按「当前路由是否最上层」把它关掉。
      onDragEntered: _handleDragEntered,
      onDragExited: _handleDragExited,
      onDragDone: _handleDrop,
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: palette.background,
            appBar: AppBar(
              backgroundColor: palette.appBarBackground,
              // 关掉 M3 的滚动染色，否则内容滚到标题栏下方时头部会浮出主题色。
              surfaceTintColor: Colors.transparent,
              title: PeerTitleText(
                conversation: conversation,
                // [FORK] 与列表页同一套判定：只有重名时才补指纹短码，
                // 进门之后也能确认自己进的是哪一台。
                ambiguous: peerNameCollides(conversation, nameCounts),
              ),
            ),
            body: Column(
              children: [
                Expanded(
                  child: messages.isEmpty
                      ? Center(child: Text(t.conversation.noMessages))
                      : _wrapWithSelection(
                          ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            itemCount: messages.length,
                            itemBuilder: (context, index) {
                              // 正向列表：index 0 是最旧一条，最新一条在底部。
                              final msg = messages[index];
                              final showDate =
                                  index == 0 || _needsDateSeparator(messages[index - 1].timestamp, msg.timestamp);

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (showDate) _DateLabel(timestamp: msg.timestamp),
                                  MessageBubble(
                                    message: msg,
                                    peerInitial: initial,
                                    peerFingerprint: conversation.peerFingerprint,
                                    // 桌面：右键；移动端：长按。两者走同一个菜单。
                                    onSecondaryTap: (position) => _handleBubbleMenu(position, msg),
                                    onLongPress: _selectableTextSupported ? null : (position) => _handleBubbleMenu(position, msg),
                                    onRetry: msg.status == ChatMessageStatus.failed ? () => unawaited(_retryMessage(msg)) : null,
                                    onCancel: msg.status == ChatMessageStatus.pending ? () => unawaited(_cancelMessage(msg)) : null,
                                    onStalePending: msg.status == ChatMessageStatus.pending ? () => unawaited(_expireStaleMessage(msg)) : null,
                                    staleAfter: chatSendWatchdogTimeout,
                                    // 恒传非 null：filePath 为空时由 _openFileMessage 弹提示，
                                    // 让「点了没反应」变成「明确告诉你为什么打不开」。
                                    onFileTap: () => _openFileMessage(msg),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                ),
                _Composer(
                  key: _composerKey,
                  conversation: conversation,
                  onSent: _stickToBottomSoon,
                ),
              ],
            ),
          ),
          if (_dragging) const Positioned.fill(child: _DropOverlay()),
        ],
      ),
    );

    return _PasteShortcuts(
      onPaste: () => _composerKey.currentState?.handlePaste(),
      child: content,
    );
  }

  /// [FORK] 文字选区只在桌面端开启。
  ///
  /// 移动端的长按要留给气泡菜单：[SelectionArea] 的选词手势会在手势竞技场里赢走
  /// 长按（它比气泡更靠近子节点），而它自带的工具条又被我们置空了
  /// （`contextMenuBuilder` 返回 shrink），于是手机上选中文字**没有任何复制入口**——
  /// 留一个只能看不能用的选区没有意义。把长按让给菜单后，「复制」变成菜单项，
  /// 反而比之前可用。
  ///
  /// 桌面端完全维持原行为：拖选 / 双击选词即弹菜单，右键气泡也弹。
  static bool get _selectableTextSupported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 桌面端给消息列表套上选区能力，移动端原样返回。
  Widget _wrapWithSelection(Widget child) {
    if (!_selectableTextSupported) {
      return child;
    }
    return SelectionArea(
      key: _selectionKey,
      // 框架自带的工具栏在桌面端只在右键时出现，且无法定制成「只有复制」；
      // 这里清空它，改由 _handlePointerUp / 右键回调自己弹菜单。
      contextMenuBuilder: (context, state) => const SizedBox.shrink(),
      onSelectionChanged: _handleSelectionChanged,
      child: Listener(
        onPointerDown: _handlePointerDown,
        onPointerUp: _handlePointerUp,
        child: child,
      ),
    );
  }

  static bool _needsDateSeparator(DateTime previous, DateTime current) {
    return current.difference(previous) > const Duration(minutes: 10);
  }
}

/// 拖拽悬停时的提示遮罩：整页盖一层淡色蒙版 + 蓝色虚框，明确「松手就发」。
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 这层遮罩是 Scaffold 的同级而不是它的子节点，拿不到 Material 的
    // DefaultTextStyle；缺了它 Flutter 会退回 DefaultTextStyle.fallback
    // （黄色 + 双下划线），文字看着就像被划了两道线。包一层透明 Material 即可。
    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          color: theme.colorScheme.scrim.withValues(alpha: 0.06),
          padding: const EdgeInsets.all(16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kOutgoingBubbleColor, width: 2),
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.file_download_outlined, size: 64, color: kOutgoingBubbleColor),
                    const SizedBox(height: 12),
                    Text(
                      t.conversation.dropHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.normal,
                        color: theme.colorScheme.onSurface,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 把发送失败的原因翻译成用户能看懂的文案。
String _describeSendFailure(SendFailure failure) {
  switch (failure) {
    case SendFailure.peerDeclined:
      return t.conversation.peerDeclined;
    case SendFailure.peerBusy:
      return t.conversation.peerBusy;
    case SendFailure.unreachable:
      return t.conversation.peerUnreachable;
    case SendFailure.fileMissing:
      return t.conversation.fileMissing;
    case SendFailure.cancelled:
      return t.conversation.sendCancelled;
    case SendFailure.unknown:
      return t.conversation.sendFailed;
  }
}

/// 后台投递文件，只在最终失败时回调 [onFailure]。
///
/// 投递可能要重试到 [textSendRetryWindow]（默认 2 分钟），页面不能 await：
/// 「发送中」气泡由 deliverFiles 立刻落下，用户随时看得到进度。
/// 回形针和拖拽两条入口共用它，避免行为分叉。
Future<void> deliverFilesInBackground({
  required Ref ref,
  required Device target,
  required List<CrossFile> files,
  required void Function(String message) onFailure,
}) async {
  final SendFailure? failure;
  try {
    failure = await deliverFiles(ref: ref, target: target, files: files);
  } catch (e) {
    // 页面在重试窗口内被销毁时 ref 可能已失效，别让它变成未捕获异常。
    debugPrint('Failed to deliver files: $e');
    return;
  }

  if (failure == null) {
    return;
  }
  onFailure(_describeSendFailure(failure));
}

class _DateLabel extends StatelessWidget {
  final DateTime timestamp;

  const _DateLabel({required this.timestamp});

  @override
  Widget build(BuildContext context) {
    final local = timestamp.toLocal();
    final text =
        '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(
          text,
          style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline),
        ),
      ),
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// [FORK] Ctrl+V 的自定义意图。
///
/// 输入框默认的粘贴只认纯文本。这里先拦下来看剪贴板里有没有文件或图片：
/// 有就走「发文件」，都没有才插 text/plain。
class _PasteClipboardIntent extends Intent {
  const _PasteClipboardIntent();
}

/// [FORK] 页面级 Ctrl/Cmd+V。
///
/// 挂在会话页而不是输入框上：**不点输入框也能粘贴**。
/// 输入框获得焦点时，焦点链会先命中这里，再往上是 WidgetsApp 的
/// `DefaultTextEditingShortcuts`（纯文本粘贴），所以文本分支也由这里接管。
///
/// [autofocus] 的 [Focus] 是必需的：刚打开会话、什么都没点的时候，
/// 之前的焦点是 route 自己的 `FocusScopeNode`，它在整个页面的**外层**，
/// 沿 context 向上找 Shortcuts 根本不会经过这里（表现为「什么都没聚焦时按 Ctrl+V 无效」）。
class _PasteShortcuts extends StatelessWidget {
  final VoidCallback onPaste;
  final Widget child;

  const _PasteShortcuts({
    required this.onPaste,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyV, control: true): _PasteClipboardIntent(),
        // macOS 用 Command，顺手支持一下；原生侧没接也不影响文本粘贴。
        SingleActivator(LogicalKeyboardKey.keyV, meta: true): _PasteClipboardIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _PasteClipboardIntent: CallbackAction<_PasteClipboardIntent>(
            onInvoke: (intent) {
              onPaste();
              return null;
            },
          ),
        },
        // 只负责把焦点留在本页：真正要粘贴的是 [onPaste]。
        child: Focus(
          autofocus: true,
          child: child,
        ),
      ),
    );
  }
}

/// 底部输入条：文本输入框 + 发送文件 + 发送。
class _Composer extends StatefulWidget {
  final Conversation conversation;

  /// [FORK] 发送动作已经发起：页面借此把消息列表拉回最新一条。
  ///
  /// 光靠「消息数变多」不够：用户翻着历史发消息时，那一路是有条件的跟随。
  final VoidCallback? onSent;

  const _Composer({
    super.key,
    required this.conversation,
    this.onSent,
  });

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;
  bool _busy = false;

  /// [FORK] 移动端附件面板是否展开（相册 / 文件）。
  ///
  /// 桌面端不加这一层：空输入时右侧按钮就是「选择文件」，直接弹系统选择器。
  bool _panelOpen = false;

  /// 粘贴流程是否正在进行（读剪贴板 → 写临时文件 → 等确认卡片）。
  bool _pasting = false;

  /// 移动端判定：只有移动端才用「加号 + 面板」，桌面端用「文件夹 + 直接选文件」。
  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleTextChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// [FORK] Android 上回车键为什么不能靠这里接管（实测结论，别再加回来了）。
  ///
  /// 桌面端引擎把 Enter 翻成 `TextInputAction.send`，`onSubmitted` 能收到；
  /// Android 没有这一步：软键盘的回车本身就是「发送」键（`action = send`），
  /// 而外接键盘的回车会被 IME 直接当成 `\n` 提交进文本 ——
  /// **框架层连一个 KeyEvent 都收不到**（`FocusNode.onKeyEvent` 实测为空）。
  ///
  /// 因此「监听插入了一个换行就撤回并发送」这条看起来可行的路走不通：
  /// 换行落地时 Shift 早已松开，无法把 Shift+Enter 与裸回车区分开，
  /// 结果是 Shift+Enter 也会把内容直接发出去。误发到对端比多一个空行有害，
  /// 所以 Android 上保持引擎默认语义：
  /// - 软键盘回车 / 输入框右侧按钮 → 发送
  /// - 外接键盘的回车 → 换行
  /// - 软键盘上根本没有换行键 → 长按右侧发送按钮补一个，见 [_handleSendButtonLongPress]
  void _handleTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() {
        _hasText = hasText;
        // 一开始打字就把附件面板收起来：键盘会盖住它，且此时按钮已经是「发送」。
        if (hasText) {
          _panelOpen = false;
        }
      });
    }
  }

  /// [FORK] 输入条右侧按钮：有文字 = 发送，没文字 = 附件入口。
  ///
  /// 桌面端直接弹文件选择器；移动端先展开 [ _AttachmentPanel ]（相册 / 文件），
  /// 因为移动端「相册」和「文件」是两个不同的系统入口，需要一个中间步骤。
  void _handleTrailingPressed() {
    if (_busy) {
      return;
    }
    if (_hasText) {
      unawaited(_sendText());
      return;
    }
    if (_isMobile) {
      _togglePanel();
      return;
    }
    unawaited(_pickAndSendFiles());
  }

  /// 展开 / 收起移动端附件面板。
  ///
  /// 展开前先收起键盘：面板要占用屏幕底部这块空间，键盘留着它会没地方显示。
  void _togglePanel() {
    final open = !_panelOpen;
    setState(() => _panelOpen = open);
    if (open) {
      _focusNode.unfocus();
    }
  }

  void _closePanel() {
    if (_panelOpen) {
      setState(() => _panelOpen = false);
    }
  }

  /// [FORK] 回车键的语义：裸 Enter 发送，Shift+Enter 换行，其他组合键忽略。
  ///
  /// 桌面端引擎只在 `inputAction == newline` 时才自己往文本里插换行
  /// （`TextInputPlugin::EnterPressed`），我们的 action 是 `send`，
  /// 所以 Shift+Enter 的换行必须在这里补一个。
  void _handleEnter() {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed) {
      _insertText('\n');
      return;
    }
    if (keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed) {
      return;
    }
    unawaited(_sendText());
  }

  /// [FORK] 长按发送按钮 = 插入换行（Android 上唯一可行的换行入口）。
  ///
  /// 软键盘的键是输入法自己画的：`textInputAction: send` 时回车被渲染成 ➤，
  /// 输入法里就再没有「换行」这个键了。输入法的按键事件又不经过框架
  /// （见 [_handleTextChanged] 上方的实测），所以「长按软键盘回车」这件事
  /// 在框架层无从监听 —— 能挂手势的只有我们自己画的这个按钮。
  void _handleSendButtonLongPress() {
    if (_busy || _controller.text.isEmpty) {
      return;
    }
    // 同样的手指动作平时是「发送」，给一点触觉反馈，免得以为按漏了。
    unawaited(HapticFeedback.selectionClick());
    _insertText('\n');
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    // [FORK] 从顶部弹出，避免挡住底部输入条。
    TopToast.show(context, message);
  }

  /// 把发送失败的原因翻译成用户能看懂的文案。
  String _describeFailure(SendFailure failure) => _describeSendFailure(failure);

  Future<void> _sendText() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      return;
    }

    if (text.length > maxTextMessageLength) {
      _showMessage(t.conversation.messageTooLong(max: maxTextMessageLength));
      return;
    }

    final target = resolveConversationTarget(context.ref, widget.conversation);
    if (target == null) {
      _showMessage(t.conversation.peerUnreachable);
      return;
    }

    // 先清空并留住焦点，避免用户以为没发出去又点一次。
    _controller.clear();
    _focusNode.requestFocus();

    // 发送可能一直重试到上限（默认 2 分钟）才有结论，不能阻塞输入框：
    // 气泡的「发送中 / 失败」状态由 conversation_recorder 负责更新。
    widget.onSent?.call();
    unawaited(_deliver(context.ref, text, target));
  }

  /// 真正等待发送结果，只用来弹失败提示。
  Future<void> _deliver(Ref ref, String text, Device target) async {
    final SendFailure? failure;
    try {
      failure = await sendTextMessage(
        ref: ref,
        target: target,
        text: text,
      );
    } catch (e) {
      // 页面在两分钟的重试窗口内被销毁时 ref 可能已失效，别让它变成未捕获异常。
      debugPrint('Failed to deliver a text message: $e');
      return;
    }

    if (failure == null || !mounted) {
      return;
    }
    // 消息气泡里已经写了原文，失败时不再回填输入框（那样会变成两条）。
    _showMessage(_describeFailure(failure));
  }

  /// [FORK] Ctrl+V：剪贴板里是文件/图片就发出去，否则按普通文本粘贴。
  ///
  /// 由页面级的 [_PasteShortcuts] 调用（不要求输入框有焦点）。
  ///
  /// 顺序很重要：**先问文件列表**。在资源管理器里复制一张 .jpg 时，剪贴板里
  /// 放的是 CF_HDROP（一组路径）而不是位图，先去问图片通道永远拿不到东西。
  ///
  /// 先读剪贴板再做决定是有代价的（键事件必须同步给出「已处理」），
  /// 所以文本粘贴也接管了——见 [_insertText] 里为什么不复用 `PasteTextIntent`。
  Future<void> handlePaste() async {
    if (_pasting) {
      return;
    }
    _pasting = true;
    try {
      final files = await _readClipboardFiles();
      if (!mounted) {
        return;
      }
      if (files.isNotEmpty) {
        await _confirmAndSend(files);
        return;
      }

      final image = await ClipboardImage.read();
      if (!mounted) {
        return;
      }
      if (image == null) {
        // 既没有文件也没有位图：当作普通文本粘贴。
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (!mounted) {
          return;
        }
        final text = data?.text;
        if (text != null && text.isNotEmpty) {
          _insertText(text);
        }
        return;
      }

      final file = await ClipboardImage.writeToCache(image);
      final crossFile = await CrossFileConverters.convertFile(file);
      if (!mounted) {
        return;
      }
      await _confirmAndSend([crossFile]);
    } catch (e) {
      debugPrint('Failed to paste from the clipboard: $e');
      _showMessage(t.conversation.sendFailed);
    } finally {
      _pasting = false;
    }
  }

  /// 把剪贴板里的文件条目变成可发送的 [CrossFile]。
  Future<List<CrossFile>> _readClipboardFiles() async {
    final entries = await ClipboardFiles.read();
    if (entries.isEmpty) {
      return const [];
    }

    final files = <CrossFile>[];
    var skipped = 0;
    for (final entry in entries) {
      final path = entry.path;
      if (path != null && Directory(path).existsSync()) {
        // 文件夹不展开（可能是整个盘），和拖拽保持一致：只提示。
        skipped++;
        continue;
      }
      try {
        final file = await ClipboardFiles.materialize(entry);
        files.add(await CrossFileConverters.convertFile(file));
      } catch (e) {
        debugPrint('Failed to materialize a clipboard file: $e');
        skipped++;
      }
    }

    if (skipped > 0) {
      _showMessage(t.conversation.pasteSkipped);
    }
    return files;
  }

  /// 粘贴和拖拽同属「一步就把东西发出去」，共用同一张确认卡片。
  Future<void> _confirmAndSend(List<CrossFile> files) async {
    final target = resolveConversationTarget(context.ref, widget.conversation);
    if (target == null) {
      _showMessage(t.conversation.peerUnreachable);
      return;
    }

    final confirmed = await showDropConfirmDialog(context, files);
    if (!mounted) {
      return;
    }
    // 确认卡片抢走了焦点，关掉之后要把光标还给输入框。
    _focusNode.requestFocus();
    if (!confirmed) {
      return;
    }

    unawaited(_deliverFiles(context.ref, target, files));
  }

  /// 把文本插到当前光标处（粘贴的兜底路径）。
  ///
  /// 这里不用 `Actions.invoke(context, PasteTextIntent(...))`：那个 action 由
  /// `EditableTextState` 注册在**它自己的子树里**，而 `Actions.invoke` 只沿
  /// context 向上找，从输入条的 context 根本找不到它，会静默落到 no-op 上
  /// （表现为「文本粘不进来」）。
  void _insertText(String text) {
    final value = _controller.value;
    final length = value.text.length;
    final selection = value.selection;
    final start = selection.isValid ? selection.start.clamp(0, length) : length;
    final end = selection.isValid ? selection.end.clamp(0, length) : length;

    _controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _focusNode.requestFocus();
  }

  Future<void> _pickAndSendFiles() async {
    if (_busy) {
      return;
    }
    // 从移动端面板进来时先把面板收掉，否则选完文件回来它还摊在输入框下面。
    _closePanel();

    final ref = context.ref;
    final target = resolveConversationTarget(ref, widget.conversation);
    if (target == null) {
      _showMessage(t.conversation.peerUnreachable);
      return;
    }

    // 选择器是模态的，这期间锁住回形针，避免连点弹出两个窗口。
    setState(() => _busy = true);
    final List<CrossFile>? files;
    try {
      files = await pickConversationFiles();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (files == null || files.isEmpty) {
      return;
    }

    // 投递可能要重试到 2 分钟，同样不能阻塞输入框：
    // 「发送中」气泡已经由 deliverFiles 落下，用户随时能看到进度。
    widget.onSent?.call();
    unawaited(_deliverFiles(ref, target, files));
  }

  /// 移动端附件面板的「相册」：多选图片/视频后直接投递到当前会话。
  Future<void> _pickAndSendMedia() async {
    if (_busy) {
      return;
    }
    _closePanel();

    final ref = context.ref;
    final target = resolveConversationTarget(ref, widget.conversation);
    if (target == null) {
      _showMessage(t.conversation.peerUnreachable);
      return;
    }

    setState(() => _busy = true);
    final List<CrossFile>? files;
    try {
      files = await pickConversationMedia(context);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (files == null || files.isEmpty) {
      return;
    }

    widget.onSent?.call();
    unawaited(_deliverFiles(ref, target, files));
  }

  /// 真正等待文件投递结果，只用来弹失败提示。
  Future<void> _deliverFiles(Ref ref, Device target, List<CrossFile> files) {
    return deliverFilesInBackground(
      ref: ref,
      target: target,
      files: files,
      onFailure: (message) {
        if (mounted) {
          _showMessage(message);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // [FORK] 输入框无边框：主题里给 enabled/focusedBorder 都设了 secondaryContainer
    // 描边，只覆盖 border 还不够（那两个字段会继续生效），三处一起置空。
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: BorderSide.none,
    );

    return PopScope(
      // 面板展开时返回键先收起面板，而不是直接退出会话（手机上很容易误按）。
      canPop: !_panelOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _panelOpen) {
          _closePanel();
        }
      },
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          decoration: BoxDecoration(
            // [FORK] 跟随聊天页配色：Local Chat 浅色下与消息区同为中性灰，
            // 靠顶部那条 outlineVariant 细线和消息列表分开。
            color: ChatPalette.of(context).composerBackground,
            border: Border(
              top: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    // Ctrl+V 的拦截放在页面级（见 [ConversationPage.build]），
                    // 这样不用先把光标点进输入框也能粘贴。
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      minLines: 1,
                      // [FORK] 多行：Shift+Enter 要能换行并让输入框长高。
                      // action 保持 send（不是 newline），否则桌面端引擎会抢在框架前把
                      // 每个 Enter 都插成换行，连「发送」都轮不到我们。
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.send,
                      // [FORK] 只认「裸回车」发送，Shift+Enter 换行。
                      // 桌面端引擎把 Enter 统一翻成 action，修饰键信息不在 action 里，
                      // 只能在提交回调里查一次键盘状态。
                      onSubmitted: (_) => _handleEnter(),
                      // 默认实现会在回车后收起键盘 / 丢失焦点，聊天输入框必须留住焦点。
                      onEditingComplete: () {},
                      // 点回输入框就收起附件面板：用户显然是要打字了。
                      onTap: _closePanel,
                      onTapOutside: (_) => _closePanel(),
                      decoration: InputDecoration(
                        hintText: t.conversation.messageHint,
                        isDense: true,
                        filled: true,
                        fillColor: theme.colorScheme.surface,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: inputBorder,
                        enabledBorder: inputBorder,
                        focusedBorder: inputBorder,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _buildSendButton(),
                ],
              ),
              // [FORK] 移动端附件面板：输入框没有文字时点右侧加号展开。
              if (_isMobile && _panelOpen)
                _AttachmentPanel(
                  onAlbum: () => unawaited(_pickAndSendMedia()),
                  onFile: () => unawaited(_pickAndSendFiles()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 输入条右侧按钮。空输入 = 附件入口，有文字 = 发送。
  ///
  /// 桌面端空态是文件夹图标（直接弹系统文件选择器），移动端空态是加号
  /// （展开 [_AttachmentPanel]，因为「相册」和「文件」在移动端是两个入口）。
  /// Android 上长按 = 换行，见 [_handleSendButtonLongPress]。
  Widget _buildSendButton() {
    final label = _hasText ? t.conversation.send : t.conversation.attachFile;

    final Widget icon;
    if (_busy) {
      icon = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (_hasText) {
      // [FORK] 逆时针 90°：Icons.send 原本箭头朝右，转完朝正上（常见 IM 的发送键朝向）。
      icon = Transform.rotate(angle: -math.pi / 2, child: const Icon(Icons.send));
    } else {
      icon = Icon(_isMobile ? Icons.add : Icons.folder_outlined);
    }

    final button = IconButton(
      // Android 上长按已经被换行占用：tooltip 默认也是「长按弹出」，
      // 两个长按识别器会抢同一个手势，所以这里不给它 tooltip（下面用
      // 手动触发的 Tooltip 补回无障碍标签）。
      tooltip: Platform.isAndroid ? null : label,
      icon: icon,
      onPressed: _busy ? null : _handleTrailingPressed,
    );

    if (!Platform.isAndroid) {
      return button;
    }

    // `triggerMode: manual`：只保留语义标签，绝不自己弹，把长按让给换行。
    return Tooltip(
      message: label,
      triggerMode: TooltipTriggerMode.manual,
      child: GestureDetector(
        onLongPress: _handleSendButtonLongPress,
        child: button,
      ),
    );
  }
}

/// [FORK] 移动端附件面板：贴在输入条下方，两项「相册」「文件」。
///
/// 用「面板」而不是弹窗 / 底部弹层：它属于输入条的一部分，展开时不动页面，
/// 收起只需再点一次加号或点回输入框。
class _AttachmentPanel extends StatelessWidget {
  final VoidCallback onAlbum;
  final VoidCallback onFile;

  const _AttachmentPanel({
    required this.onAlbum,
    required this.onFile,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        // 与输入框同一底色：浅色下是纯白，深色下是深灰，两者都不会抢视线。
        // 不描边：输入栏底色（surfaceContainerLow）比 surface 深一档，
        // 圆角块本身就分得出来，多一条细线反而显脏。
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          _AttachmentAction(
            icon: Icons.photo_library_outlined,
            label: t.conversation.album,
            onTap: onAlbum,
          ),
          _AttachmentAction(
            icon: Icons.insert_drive_file_outlined,
            label: t.conversation.files,
            onTap: onFile,
          ),
        ],
      ),
    );
  }
}

/// 附件面板里的单项：图标 + 文字。
///
/// 固定 88 宽、左对齐排布：只有两项时也不会被拉开到屏幕两端，
/// 以后加「文件夹」「剪贴板」直接往后排即可。
class _AttachmentAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _AttachmentAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      width: 88,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 26, color: scheme.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
