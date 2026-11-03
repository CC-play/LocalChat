import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/conversation/conversation.dart';
import 'package:localsend_app/provider/conversation_provider.dart';
import 'package:localsend_app/util/conversation/conversation_sender.dart';
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/widget/chat/message_bubble.dart';
import 'package:localsend_app/widget/chat/top_toast.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';

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
                : ListView.builder(
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
    if (text.isEmpty || _busy) {
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

    setState(() => _busy = true);
    _controller.clear();

    SendFailure? failure;
    try {
      failure = await sendTextMessage(
        ref: context.ref,
        target: target,
        text: text,
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }

    if (failure == null) {
      // 保持焦点，方便接着发下一条。
      if (mounted) {
        _focusNode.requestFocus();
      }
      return;
    }

    // 发送失败把内容还回输入框，别让用户重打一遍。
    if (mounted && _controller.text.isEmpty) {
      _controller.text = text;
      _controller.selection = TextSelection.collapsed(offset: text.length);
    }
    if (mounted) {
      _focusNode.requestFocus();
    }
    _showMessage(_describeFailure(failure));
  }

  Future<void> _pickAndSendFiles() async {
    if (_busy) {
      return;
    }

    final target = resolveConversationTarget(context.ref, widget.conversation);
    if (target == null) {
      _showMessage(t.conversation.peerUnreachable);
      return;
    }

    setState(() => _busy = true);
    SendFailure? failure;
    try {
      failure = await sendFilesToConversation(ref: context.ref, target: target);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }

    if (failure != null) {
      _showMessage(_describeFailure(failure));
    }
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
