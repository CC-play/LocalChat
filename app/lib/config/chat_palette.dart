import 'package:flutter/material.dart';
import 'package:localchat_app/model/persistence/color_mode.dart';

/// [FORK] 聊天页背景（Local Chat 主题、浅色模式）。中性灰，区别于主题的
/// teal 系 surface，让白色气泡有对比度。
const kChatBackground = Color(0xFFEBEBEB);

/// [FORK] 对方气泡背景（Local Chat 主题、浅色模式）。
const kChatIncomingBubble = Color(0xFFFFFFFF);

/// [FORK] 聊天页专用配色。
///
/// 为什么单独抽一个 [ThemeExtension]，而不是直接改 [ColorScheme]：
/// ColorScheme 是全应用共用的，把 `surface` 改成中性灰会把设置页、发送页、
/// 对话框一起染灰；这里只暴露聊天页真正用到的四个颜色，由 `getTheme()`
/// 按 `ColorMode` 决定取值。
///
/// 缺省值完全等于改动前的行为（`surface` / `surfaceContainerLow` /
/// `surfaceContainer`），所以除「Local Chat + 浅色」以外的主题都不会有视觉变化。
@immutable
class ChatPalette extends ThemeExtension<ChatPalette> {
  /// 聊天区（消息列表）背景。
  final Color background;

  /// AppBar 背景。默认与 [background] 不同（跟随 `colorScheme.surface`）。
  final Color appBarBackground;

  /// 底部输入栏背景。
  final Color composerBackground;

  /// 对方（接收方向）气泡背景。
  final Color incomingBubble;

  const ChatPalette({
    required this.background,
    required this.appBarBackground,
    required this.composerBackground,
    required this.incomingBubble,
  });

  /// 改动前的取值：完全由 [scheme] 推导。
  factory ChatPalette.fromScheme(ColorScheme scheme) {
    return ChatPalette(
      background: scheme.surface,
      appBarBackground: scheme.surface,
      composerBackground: scheme.surfaceContainerLow,
      incomingBubble: scheme.surfaceContainer,
    );
  }

  /// 取当前主题的聊天配色；主题里没挂扩展时（例如 Yaru）退回 [fromScheme]。
  ///
  /// 用 `Theme.of(context)` 而不是自己去读设置：主题一变，依赖它的 widget
  /// 本来就会重建，不需要额外的订阅。
  static ChatPalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<ChatPalette>() ?? ChatPalette.fromScheme(theme.colorScheme);
  }

  @override
  ChatPalette copyWith({
    Color? background,
    Color? appBarBackground,
    Color? composerBackground,
    Color? incomingBubble,
  }) {
    return ChatPalette(
      background: background ?? this.background,
      appBarBackground: appBarBackground ?? this.appBarBackground,
      composerBackground: composerBackground ?? this.composerBackground,
      incomingBubble: incomingBubble ?? this.incomingBubble,
    );
  }

  @override
  ChatPalette lerp(ThemeExtension<ChatPalette>? other, double t) {
    if (other is! ChatPalette) {
      return this;
    }
    return ChatPalette(
      background: Color.lerp(background, other.background, t)!,
      appBarBackground: Color.lerp(appBarBackground, other.appBarBackground, t)!,
      composerBackground: Color.lerp(composerBackground, other.composerBackground, t)!,
      incomingBubble: Color.lerp(incomingBubble, other.incomingBubble, t)!,
    );
  }
}

/// [FORK] 按主题模式产出聊天配色。
///
/// 目前只有一处覆盖：「Local Chat + 浅色」→ 中性灰底 + 纯白对方气泡。
/// 深色模式保持原样（`surfaceContainer` 在深色下才有足够的层次）。
ChatPalette chatPaletteFor(ColorMode mode, Brightness brightness, ColorScheme scheme) {
  final base = ChatPalette.fromScheme(scheme);
  final neutralLocalChat = mode == ColorMode.localchat && brightness == Brightness.light;
  if (!neutralLocalChat) {
    return base;
  }
  return base.copyWith(
    background: kChatBackground,
    // 头部与页面同色：浅灰底上留一条近白色标题栏会显得是两块拼接。
    appBarBackground: kChatBackground,
    // 输入栏也归到同一个灰，靠顶部那条 outlineVariant 细线与消息区分开。
    composerBackground: kChatBackground,
    incomingBubble: kChatIncomingBubble,
  );
}
