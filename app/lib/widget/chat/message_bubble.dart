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

  /// [FORK] 本机（发送方）的头像占位字符。
  ///
  /// 取本机别名的首字符——也就是对端收到我们的设备信息后画出来的那个字。
  final String selfInitial;

  /// [FORK] 本机指纹，用于推导发送方头像的配色。
  ///
  /// 与对端走同一条规则（`avatarColorsFor`），所以「我在这台机器上看到的自己」
  /// 和别人看到的我是同一个颜色，不再用主题色做特殊标记。
  final String selfFingerprint;

  final VoidCallback? onFileTap;

  /// [FORK] 点击文件卡片上的文件夹图标时回调（在系统文件管理器里定位文件）。
  ///
  /// 为 null 表示不给这个入口（多选态、移动端），卡片上不会出现那颗图标。
  final VoidCallback? onFileReveal;

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

  /// [FORK] 是否处于多选态。
  ///
  /// 多选态下整行只做一件事：切换选中。菜单、打开文件、取消发送全部让位，
  /// 否则「点一下变成打开文件」会让人以为选中没生效。
  final bool selectionMode;

  /// 多选态下这一条是否已选中。
  final bool selected;

  /// 多选态下点击整行时切换选中。
  final VoidCallback? onToggleSelected;

  /// 超过这个时长仍是「发送中」就触发 [onStalePending]。
  final Duration staleAfter;

  const MessageBubble({
    super.key,
    required this.message,
    required this.peerInitial,
    required this.peerFingerprint,
    required this.selfInitial,
    required this.selfFingerprint,
    this.onFileTap,
    this.onFileReveal,
    this.onSecondaryTap,
    this.onLongPress,
    this.onRetry,
    this.onCancel,
    this.onStalePending,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelected,
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
        // [FORK] 多选态不打开文件：子节点 InkWell 在手势竞技场里优先于外层
        // GestureDetector，不置空就是「点了选中不了、反而把文件打开了」。
        onTap: selectionMode ? null : onFileTap,
        // [FORK] 悬浮文件卡片时露出的「在文件管理器中显示」图标。和点卡片同理，
        // 多选态让位给「切换选中」，置空即整颗图标都不出现。
        onRevealInFolder: selectionMode ? null : onFileReveal,
      );
    }

    // [FORK] 头像两边同一套规则：指纹取固定色 + 别名首字符。
    // 自己不再画成「我」+ 主题色——那等于给自己开小灶，对端看到的我不是这样。
    final avatar = PeerAvatar(
      initial: isOutgoing ? selfInitial : peerInitial,
      colors: avatarColorsFor(isOutgoing ? selfFingerprint : peerFingerprint, theme.brightness),
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
            // 多选态下整行点击归「切换选中」，转圈不再接管点击。
            onTap: selectionMode ? null : onCancel,
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
            onTap: selectionMode ? null : onRetry,
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
      // [FORK] 多选态整行点击 = 切换选中。右键 / 长按由页面在多选态传 null 关掉，
      // 否则会在选择过程中又弹出菜单。
      onTap: selectionMode ? onToggleSelected : null,
      onSecondaryTapUp: onSecondaryTap == null ? null : (details) => onSecondaryTap!(details.globalPosition),
      // [FORK] 手机上的右键：长按。桌面端 onLongPress 为 null，不参与手势竞技场。
      onLongPressStart: onLongPress == null ? null : (details) => onLongPress!(details.globalPosition),
      // [FORK] 选中态整行铺一层淡主色：勾选圈在长列表里不够醒目，
      // 整行高亮才能一眼看出「这几条会被删掉」。
      child: Container(
        color: selectionMode && selected ? theme.colorScheme.primary.withValues(alpha: 0.10) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          child: Row(
            mainAxisAlignment: isOutgoing ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // [FORK] 勾选圈紧贴消息组（不做成固定左栏）：发送方向的气泡贴右，
              // 固定左栏会让圈和气泡之间空出一大片。
              if (selectionMode) _SelectionIndicator(selected: selected),
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
      ),
    );
  }
}

/// [FORK] 多选态的勾选圈。
///
/// 用图标而不是 `Checkbox`：`Checkbox` 自带 48×48 的点击热区与 Material 水波纹，
/// 会和整行点击抢手势，也让行高多出十几像素。
class _SelectionIndicator extends StatelessWidget {
  final bool selected;

  const _SelectionIndicator({required this.selected});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // top 12 让圈和气泡首行文字对齐：行 padding 6 + 气泡 padding 8，再减去
      // 图标自身留白，视觉上落在同一水平线。
      padding: const EdgeInsets.only(top: 12, right: 8),
      child: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 20,
        color: selected ? scheme.primary : scheme.outlineVariant,
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
      // 校验和阶段可能持续几分钟（大文件在 debug 构建下尤其明显），但它是
      // 本地读盘、有进度、随时可取消的工作，不该被「发送中太久」的兜底判定
      // 误杀。这一段不累加计时，等进入网络阶段再开始数。
      final phase = context.ref.read(chatTransferProvider).phaseOf(widget.messageId).value;
      if (phase == ChatTransferPhase.hashing) {
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
    final transfer = context.ref.read(chatTransferProvider);
    final progressListenable = transfer.progressOf(widget.messageId);
    final phaseListenable = transfer.phaseOf(widget.messageId);

    return AnimatedBuilder(
      animation: Listenable.merge([progressListenable, phaseListenable]),
      builder: (context, _) {
        final phase = phaseListenable.value;
        final progress = progressListenable.value;
        final theme = Theme.of(context);

        // 本地校验和上传一样有真实百分比；连接与等待接受没有，画扫动条。
        final double? barValue = switch (phase) {
          ChatTransferPhase.hashing => progress,
          ChatTransferPhase.uploading => progress,
          ChatTransferPhase.connecting => null,
          ChatTransferPhase.waitingAccept => null,
          null => progress,
        };

        // 用 floor 而不是 round：99.6% 还没传完，显示 100% 会让人以为卡住了。
        String uploadLabel(double? value) {
          if (value == null) {
            return t.conversation.sendingCountdown(seconds: _seconds);
          }
          return t.conversation.sendingProgress(percent: (value * 100).floor().clamp(0, 100));
        }

        final label = switch (phase) {
          ChatTransferPhase.hashing => t.conversation.verifyingChecksum(
            percent: ((progress ?? 0) * 100).floor().clamp(0, 100),
          ),
          ChatTransferPhase.connecting => t.conversation.connectingPeer,
          ChatTransferPhase.waitingAccept => t.conversation.waitingForPeer,
          ChatTransferPhase.uploading => uploadLabel(progress),
          null => uploadLabel(progress),
        };

        final text = Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: barValue == null ? theme.colorScheme.outline : widget.color,
          ),
        );

        if (barValue == null && _seconds < _SendProgressFooter.indeterminateAfter.inSeconds) {
          // 刚进入「连接 / 等待接受」的前几秒只给一句话，避免每条小消息都闪一下条。
          return text;
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _bar(value: barValue),
            const SizedBox(width: 6),
            text,
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
