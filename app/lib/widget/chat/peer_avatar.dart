import 'package:flutter/material.dart';
import 'package:localchat_app/util/ui/avatar_color.dart';

/// 设备/联系人头像：圆角方块 + 一个字符。
///
/// 会话列表与聊天气泡共用同一个部件，保证同一个身份在两处的形状、
/// 圆角比例、字重完全一致（此前列表是圆形、气泡是圆角方块，同一台设备
/// 在两个页面长得不一样）。
///
/// 颜色不在这里推导，由调用方用 [avatarColorsFor] / [selfAvatarColors] 算好传进来，
/// 这样部件本身不依赖任何身份信息，也方便单独预览。
class PeerAvatar extends StatelessWidget {
  final String initial;
  final AvatarColors colors;
  final double size;

  /// 圆角半径。默认是边长的 18%（36px → 6.5，40px → 7.2），
  /// 与聊天气泡头像原本的 6/36 视觉一致。
  final double? radius;

  /// 字号。默认是边长的 40%（36px → 14.4，40px → 16）。
  final double? fontSize;

  const PeerAvatar({
    super.key,
    required this.initial,
    required this.colors,
    this.size = 40,
    this.radius,
    this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(radius ?? size * 0.18),
      ),
      child: Text(
        initial.isEmpty ? '?' : initial,
        maxLines: 1,
        // 单字符本身不换行，但 emoji 的代理对可能被系统字体撑宽，
        // 缩放兜底避免溢出。
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: fontSize ?? size * 0.4,
          fontWeight: FontWeight.w600,
          height: 1,
          color: colors.foreground,
        ),
      ),
    );
  }
}
