import 'package:flutter/material.dart';
import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_app/util/conversation/peer_label.dart';

/// [FORK] 会话标题：显示名 + （仅重名时）指纹短码。
///
/// 会话列表和聊天页标题栏共用这一个组件，避免两处的样式各写一遍跑偏。
/// 不重名时短码根本不渲染，日常观感与原来完全一致。
class PeerTitleText extends StatelessWidget {
  final Conversation conversation;

  /// 是否与同一列表里的其它会话同名（由 `peerNameCollides` 判定）。
  final bool ambiguous;

  /// 名字部分的样式。不传则继承外层 `DefaultTextStyle`（AppBar 标题那种场景）。
  final TextStyle? style;

  /// 最多几行，默认 1 行（标题栏与列表都只有一行）。
  final int maxLines;

  const PeerTitleText({
    super.key,
    required this.conversation,
    required this.ambiguous,
    this.style,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 短码要比名字小一号、并且用弱色，读起来像注释而不是名字的一部分。
    // 字号从「实际生效的样式」里算：列表传了 w600 但没传字号，字号来自
    // ListTile 的 titleTextStyle，只能先 merge 到继承样式上再取。
    final resolved = DefaultTextStyle.of(context).style.merge(style);
    final codeStyle = TextStyle(
      fontWeight: FontWeight.w400,
      fontSize: (resolved.fontSize ?? 14) * 0.78,
      color: theme.colorScheme.outline,
    );

    return Text.rich(
      TextSpan(
        text: conversation.displayName,
        children: [
          if (ambiguous)
            TextSpan(
              text: ' · ${peerShortCode(conversation.peerFingerprint)}',
              style: codeStyle,
            ),
        ],
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}
