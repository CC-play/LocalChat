import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/conversation_provider.dart';
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/widget/chat/message_bubble.dart';
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
      body: messages.isEmpty
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
