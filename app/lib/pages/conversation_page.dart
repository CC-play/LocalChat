import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/conversation/conversation.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/conversation_provider.dart';
import 'package:localsend_app/util/conversation/conversation_sender.dart';
import 'package:localsend_app/util/native/open_file.dart';
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

  /// 当前选中文本；由 [SelectionArea.onSelectionChanged] 维护，仅作字段用（不 setState）。
  String? _selectedText;

  /// 本次按下之后选区是否真的变化过。
  ///
  /// 用来区分「拖选 / 双击选词」（要弹菜单）和「点空白处取消选区」
  /// （此时 pointer up 前选区还是旧的，不该弹）。
  bool _selectionTouched = false;

  /// 菜单是否已经弹出。避免 pointer up 与后续事件重复弹两次。
  bool _menuOpen = false;

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

    return Scaffold(
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
            key: ValueKey(conversation.peerFingerprint),
            conversation: conversation,
          ),
        ],
      ),
    );
  }

  static bool _needsDateSeparator(DateTime previous, DateTime current) {
    return current.difference(previous) > const Duration(minutes: 10);
  }
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
  String _describeFailure(SendFailure failure) {
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
  Future<void> _deliverFiles(Ref ref, Device target, List<CrossFile> files) async {
    final SendFailure? failure;
    try {
      failure = await deliverFiles(ref: ref, target: target, files: files);
    } catch (e) {
      // 页面在重试窗口内被销毁时 ref 可能已失效，别让它变成未捕获异常。
      debugPrint('Failed to deliver files: $e');
      return;
    }

    if (failure == null || !mounted) {
      return;
    }
    _showMessage(_describeFailure(failure));
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
