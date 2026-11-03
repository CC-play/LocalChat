import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/conversation/conversation.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/conversation_provider.dart';
import 'package:localsend_app/util/conversation/clipboard_image.dart';
import 'package:localsend_app/util/conversation/conversation_sender.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/widget/chat/drop_confirm_dialog.dart';
import 'package:localsend_app/widget/chat/message_bubble.dart';
import 'package:localsend_app/widget/chat/top_toast.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// 气泡右键 / 选中后弹出的菜单项。目前只有复制，留枚举方便后续加「转发」「删除」。
enum _ChatMenuAction { copy }

/// 单个对端设备的会话窗口。
class ConversationPage extends StatefulWidget {
  final String peerFingerprint;

  const ConversationPage({
    super.key,
    required this.peerFingerprint,
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

  @override
  void initState() {
    super.initState();
    // 进入会话即视为已读。用 post frame 回调避免在首帧构建期间触发状态更新。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(context.ref.redux(conversationProvider).dispatchAsync(MarkConversationReadAction(widget.peerFingerprint)));
    });
  }

  void _handleSelectionChanged(SelectedContent? content) {
    final text = content?.plainText;
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
      await _showCopyMenu(fallbackPosition, selected);
      return;
    }
  }

  /// 右键气泡：有选区就用选区，否则复制这一条气泡的正文。
  void _handleBubbleSecondaryTap(Offset position, ChatMessage message) {
    final body = message.kind == ChatMessageKind.text ? (message.text ?? '') : (message.fileName ?? '');
    if (body.isEmpty) {
      return;
    }
    final selected = _selectedText;
    // 选区必须确实落在这一条气泡里，才按「复制选中部分」处理，否则容易复制到别处的内容。
    final text = (selected != null && selected.isNotEmpty && body.contains(selected)) ? selected : body;
    unawaited(_showCopyMenu(position, text));
  }

  Future<void> _showCopyMenu(Offset position, String text) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox || _menuOpen) {
      return;
    }

    _menuOpen = true;
    final theme = Theme.of(context);
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
        ],
      );
    } finally {
      _menuOpen = false;
    }

    if (!mounted) {
      return;
    }
    // 复制完顺手取消高亮，避免残留一片蓝色选区。
    _selectionKey.currentState?.selectableRegion.clearSelection();
    _selectedText = null;
    _selectionTouched = false;

    if (action == _ChatMenuAction.copy) {
      await Clipboard.setData(ClipboardData(text: text));
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

    final conversation = context.ref
        .read(conversationProvider)
        .firstWhereOrNull((c) => c.peerFingerprint == widget.peerFingerprint);
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
    final conversation = conversations.firstWhereOrNull((e) => e.peerFingerprint == widget.peerFingerprint);

    if (conversation == null) {
      return Scaffold(
        appBar: AppBar(title: Text(t.conversation.title)),
        body: Center(child: Text(t.conversation.deleted)),
      );
    }

    final messages = conversation.messages;
    final initial = conversation.initial;

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
            appBar: AppBar(title: Text(conversation.displayName)),
            body: Column(
              children: [
                Expanded(
                  child: messages.isEmpty
                      ? Center(child: Text(t.conversation.noMessages))
                      : SelectionArea(
                          key: _selectionKey,
                          // 框架自带的工具栏在桌面端只在右键时出现，且无法定制成「只有复制」；
                          // 这里清空它，改由 _handlePointerUp / 右键回调自己弹菜单。
                          contextMenuBuilder: (context, state) => const SizedBox.shrink(),
                          onSelectionChanged: _handleSelectionChanged,
                          child: Listener(
                            onPointerDown: _handlePointerDown,
                            onPointerUp: _handlePointerUp,
                            child: ListView.builder(
                              reverse: true,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              itemCount: messages.length,
                              itemBuilder: (context, index) {
                                // reverse: true 时 index 0 是最新一条。
                                final i = messages.length - 1 - index;
                                final msg = messages[i];
                                final showDate = i == 0 || _needsDateSeparator(messages[i - 1].timestamp, msg.timestamp);

                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    if (showDate) _DateLabel(timestamp: msg.timestamp),
                                    MessageBubble(
                                      message: msg,
                                      peerInitial: initial,
                                      onSecondaryTap: (position) => _handleBubbleSecondaryTap(position, msg),
                                      onFileTap: msg.filePath == null
                                          ? null
                                          : () async {
                                              await openFile(
                                                context,
                                                msg.fileType ?? FileType.other,
                                                msg.filePath!,
                                              );
                                            },
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                ),
                _Composer(
                  key: _composerKey,
                  conversation: conversation,
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
    final text = '${local.year}-${_two(local.month)}-${_two(local.day)} '
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

  const _Composer({
    super.key,
    required this.conversation,
  });

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;
  bool _busy = false;

  /// 粘贴流程是否正在进行（读剪贴板 → 写临时文件 → 等确认卡片）。
  bool _pasting = false;

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

  void _handleTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
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

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: t.conversation.attachFile,
              icon: const Icon(Icons.attach_file),
              onPressed: _busy ? null : _pickAndSendFiles,
            ),
            Expanded(
              // Ctrl+V 的拦截放在页面级（见 [ConversationPage.build]），
              // 这样不用先把光标点进输入框也能粘贴。
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                minLines: 1,
                maxLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendText(),
                // 默认实现会在回车后收起键盘 / 丢失焦点，聊天输入框必须留住焦点。
                onEditingComplete: () {},
                decoration: InputDecoration(
                  hintText: t.conversation.messageHint,
                  isDense: true,
                  filled: true,
                  fillColor: theme.colorScheme.surface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: t.conversation.send,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              onPressed: _hasText && !_busy ? _sendText : null,
            ),
          ],
        ),
      ),
    );
  }
}
