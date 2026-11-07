import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localchat_app/config/chat_palette.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_app/provider/conversation/chat_transfer_provider.dart';
import 'package:localchat_app/util/ui/avatar_color.dart';
import 'package:localchat_app/widget/chat/file_message_card.dart';
import 'package:localchat_app/widget/chat/peer_avatar.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// [FORK] 自己发出的气泡固定用这个蓝色；文字因此固定走白色系（不跟主题走，
/// 否则深色主题的 onPrimary 是深蓝，压在浅蓝底上会看不清）。
const kOutgoingBubbleColor = Color(0xFF4C98FF);
const kOnOutgoingBubbleColor = Colors.white;

/// 单条消息气泡：接收靠左、发送靠右，与主流即时通讯软件一致。
class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  /// 对方（接收方消息）的头像占位字符。
  final String peerInitial;

  /// 对端指纹，用于推导头像配色（同一台设备永远同一个颜色）。
  ///
  /// 只用于取色，不参与任何网络请求或身份校验。
  final String peerFingerprint;

  final VoidCallback? onFileTap;

  /// [FORK] 右键（桌面）点击气泡时回调，参数是全局坐标，用于在该点弹出菜单。
  final ValueChanged<Offset>? onSecondaryTap;

  /// [FORK] 长按（移动端）气泡时回调，参数是全局坐标，用于在该点弹出菜单。
  ///
  /// 手机上没有任何「右键」入口，长按是气泡菜单唯一的打开方式。
  /// 桌面端不接这个手势（鼠标长按没有语义），保持原来的拖选 + 右键。
  final ValueChanged<Offset>? onLongPress;

  /// [FORK] 点击「发送失败」的红色感叹号时重发。
  final VoidCallback? onRetry;

  /// [FORK] 点击「发送中」的转圈时取消这次发送。
  final VoidCallback? onCancel;

  /// [FORK] 「发送中」已经挂得太久时回调，由页面直接把它标成失败。
  ///
  /// 这是纯 UI 侧的兜底：不依赖任何后台任务，只要气泡还在屏幕上就生效。
  final VoidCallback? onStalePending;

  /// 超过这个时长仍是「发送中」就触发 [onStalePending]。
  final Duration staleAfter;

  const MessageBubble({
    super.key,
    required this.message,
    required this.peerInitial,
    required this.peerFingerprint,
    this.onFileTap,
    this.onSecondaryTap,
    this.onLongPress,
    this.onRetry,
    this.onCancel,
    this.onStalePending,
    this.staleAfter = const Duration(minutes: 3),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOutgoing = message.isOutgoing;
    // [FORK] 对方气泡走聊天页配色（Local Chat 浅色 = 纯白），其余主题退化为 surfaceContainer。
    final bubbleColor = isOutgoing ? kOutgoingBubbleColor : ChatPalette.of(context).incomingBubble;
    final onBubbleColor = isOutgoing ? kOnOutgoingBubbleColor : theme.colorScheme.onSurface;
    final failed = message.status == ChatMessageStatus.failed;

    final Widget bubbleChild;
    if (message.kind == ChatMessageKind.text) {
      bubbleChild = Text(
        message.text ?? '',
        style: TextStyle(
          fontSize: 14,
          color: onBubbleColor,
        ),
      );
    } else {
      bubbleChild = FileMessageCard(
        message: message,
        isOutgoing: isOutgoing,
        onTap: onFileTap,
      );
    }

    // [FORK] 头像：对端按指纹从 16 色板取固定色，自己跟主题色走。
    // 颜色由 peer_avatar.dart 统一绘制，与会话列表复用同一个部件。
    final avatar = PeerAvatar(
      initial: isOutgoing ? t.conversation.you : peerInitial,
      colors: isOutgoing
          ? selfAvatarColors(theme.colorScheme)
          : avatarColorsFor(peerFingerprint, theme.brightness),
      size: 36,
    );

    final statusHint = switch (message.status) {
      ChatMessageStatus.pending => t.conversation.sending,
      ChatMessageStatus.failed => message.errorMessage ?? t.conversation.sendFailed,
      _ => null,
    };

    // [FORK] 气泡左侧的状态圆圈：发送中转圈，失败红色感叹号，成功不占位。
    final Widget? statusIndicator;
    if (!isOutgoing) {
      statusIndicator = null;
    } else {
      statusIndicator = switch (message.status) {
        ChatMessageStatus.pending => Tooltip(
          // [FORK] 转圈不再是只读的：点一下就把这次发送停掉，
          // 不必等满两分钟的重试窗口。
          message: onCancel == null ? t.conversation.sending : t.conversation.cancelSend,
          child: InkResponse(
            onTap: onCancel,
            radius: 16,
            containedInkWell: false,
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        ChatMessageStatus.failed => Tooltip(
          message: onRetry == null ? statusHint ?? '' : t.conversation.retryHint,
          child: InkResponse(
            onTap: onRetry,
            radius: 16,
            containedInkWell: false,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.error,
                size: 18,
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ),
        _ => null,
      };
    }

    return GestureDetector(
      // 整行可右键（含气泡外侧留白），菜单由页面统一弹。
      // 用 translucent：子节点（文件卡片）自己的点击照旧生效。
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: onSecondaryTap == null ? null : (details) => onSecondaryTap!(details.globalPosition),
      // [FORK] 手机上的右键：长按。桌面端 onLongPress 为 null，不参与手势竞技场。
      onLongPressStart: onLongPress == null ? null : (details) => onLongPress!(details.globalPosition),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        child: Row(
          mainAxisAlignment: isOutgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isOutgoing) avatar,
            if (!isOutgoing) const SizedBox(width: 8),
            // [FORK] 发送状态圆圈（转圈 / 红色感叹号），只在发出方向显示。
            if (statusIndicator != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 6),
                child: statusIndicator,
              ),
            Flexible(
              child: Column(
                crossAxisAlignment: isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Container(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    decoration: BoxDecoration(
                      color: bubbleColor,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: bubbleChild,
                  ),
                  // [FORK] 发出方向「发送中」时显示上传进度条；没有进度可报
                  // （还没进入上传，例如正在算校验和）就退回原来那行文字。
                  if (isOutgoing && message.status == ChatMessageStatus.pending)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: _SendProgressFooter(
                        messageId: message.id,
                        color: theme.colorScheme.primary,
                        staleAfter: staleAfter,
                        onStale: onStalePending,
                      ),
                    )
                  else if (statusHint != null)
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
      ),
    );
  }
}

/// [FORK] 气泡下方的上传进度。
///
/// 只订阅**这一条消息**的进度：[ChatTransferNotifier] 给每条消息一个独立的
/// [ValueNotifier]，所以并发传几个文件时，进度事件不会让整个消息列表重绘。
///
/// 进度为 null 表示还没开始上传（例如仍在计算校验和，或者正在等对方接受）。
///
/// 这段等待原本只有一个「发送中…」，用户等上几十秒就无法判断是在正常工作
/// 还是已经卡死。现在分两段表达：
/// - 前 [indeterminateAfter] 秒只说事实「发送中 3s…」，避免每条小消息都闪一下；
/// - 超过之后补一条**不确定态**的进度条（来回扫动），明确「在动，
///   只是还不知道百分比」。
///
/// 之所以需要后者：`createChecksums` 默认开启，几十 MB 的文件在真正上传前
/// 要先整个读一遍算校验和，这个阶段 Rust 侧不会发出任何进度事件。
class _SendProgressFooter extends StatefulWidget {
  /// 超过这个时长仍没有真实进度，就从纯文字切到「不确定态进度条 + 文字」。
  static const indeterminateAfter = Duration(seconds: 3);

  final String messageId;
  final Color color;
  final Duration staleAfter;
  final VoidCallback? onStale;

  const _SendProgressFooter({
    required this.messageId,
    required this.color,
    required this.staleAfter,
    this.onStale,
  });

  @override
  State<_SendProgressFooter> createState() => _SendProgressFooterState();
}

class _SendProgressFooterState extends State<_SendProgressFooter> {
  Timer? _ticker;
  int _seconds = 0;

  /// 兜底只触发一次：调用方会把它标失败，气泡随即被替换成红叹号。
  bool _reportedStale = false;

  @override
  void initState() {
    super.initState();
    // 每秒一次，只重建这行小字，不触碰消息列表。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() => _seconds++);
      if (!_reportedStale && _seconds >= widget.staleAfter.inSeconds) {
        _reportedStale = true;
        widget.onStale?.call();
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.ref.read(chatTransferProvider).progressOf(widget.messageId);

    return ValueListenableBuilder<double?>(
      valueListenable: notifier,
      builder: (context, progress, _) {
        if (progress == null) {
          final hint = Text(
            t.conversation.sendingCountdown(seconds: _seconds),
            style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.outline),
          );
          if (_seconds < _SendProgressFooter.indeterminateAfter.inSeconds) {
            return hint;
          }
          // 等太久了还不知道百分比：画一条扫动的条，至少让人看到它没停。
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _bar(value: null),
              const SizedBox(width: 6),
              hint,
            ],
          );
        }

        // 用 floor 而不是 round：99.6% 还没传完，显示 100% 会让人以为卡住了。
        final percent = (progress * 100).floor().clamp(0, 100);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _bar(value: progress),
            const SizedBox(width: 6),
            Text(
              t.conversation.sendingProgress(percent: percent),
              style: TextStyle(fontSize: 10, color: widget.color),
            ),
          ],
        );
      },
    );
  }

  /// 固定 96px 宽、3px 厚：确定态与不确定态共用同一尺寸，切换时不跳布局。
  Widget _bar({required double? value}) {
    return SizedBox(
      width: 96,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          // null = 不确定态（来回扫动），由 Flutter 自带的 indeterminate 动画驱动。
          value: value,
          minHeight: 3,
          backgroundColor: widget.color.withValues(alpha: 0.2),
          valueColor: AlwaysStoppedAnimation<Color>(widget.color),
        ),
      ),
    );
  }
}
