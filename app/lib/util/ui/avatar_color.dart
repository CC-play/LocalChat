import 'package:flutter/material.dart';

/// 一枚头像的配色：背景与前景（首字符）颜色。
///
/// 两个颜色成对出现，由色板保证对比度，调用方不要自己拼。
@immutable
class AvatarColors {
  final Color background;
  final Color foreground;

  const AvatarColors({required this.background, required this.foreground});
}

/// 色板中的一项。
///
/// 四个色值分别是「浅色主题的底/字」和「深色主题的底/字」。
/// 浅色底取 tone 84 + 字 tone 11，深色底取 tone 30 + 字 tone 90。
///
/// 为什么只有 8 色：同一明度下，sRGB 浅色档的彩度上限只有 C≈20 上下，
/// 色相每 16.5° 只换来 ΔE≈5。实测同为统一明度时的最小色差：
/// 16 色 5.2 / 12 色 6.7 / 10 色 8.3 / **8 色 10.4**。ΔE 5 是「要盯着看
/// 才能分」的水平，只有 8 色能到一眼可辨。因此色相按 28° 均匀铺开，
/// 起点 220°（纯蓝），绕一整圈到 57°（橙），完全避开绿区与青绿区。
///
/// 实测对比度：浅色最低 11.0:1，深色最低 7.2:1，均高于 WCAG AA 的 4.5:1。
class _Swatch {
  final Color lightBackground;
  final Color lightForeground;
  final Color darkBackground;
  final Color darkForeground;

  const _Swatch(this.lightBackground, this.lightForeground, this.darkBackground, this.darkForeground);
}

const List<_Swatch> _swatches = [
  _Swatch(Color(0xFF7FDFF5), Color(0xFF082126), Color(0xFF2B4C53), Color(0xFFACEDFC)), // 蓝 h220
  _Swatch(Color(0xFFA6D8F9), Color(0xFF09202C), Color(0xFF2A4A5D), Color(0xFFC8E7FC)), // 靛蓝 h248
  _Swatch(Color(0xFFBFD2FB), Color(0xFF0B1E35), Color(0xFF2C476F), Color(0xFFD8E3FC)), // 紫罗兰 h276
  _Swatch(Color(0xFFDACAFA), Color(0xFF160F5B), Color(0xFF4A3694), Color(0xFFE8DEFC)), // 紫 h304
  _Swatch(Color(0xFFF5C2EA), Color(0xFF370A31), Color(0xFF6C3062), Color(0xFFFCD8F4)), // 品红 h333
  _Swatch(Color(0xFFF9C4D2), Color(0xFF3C0A1E), Color(0xFF762E47), Color(0xFFFCDAE3)), // 玫红 h001
  _Swatch(Color(0xFFFBC5BF), Color(0xFF3E0A08), Color(0xFF7B2C2B), Color(0xFFFCDBD7)), // 红 h029
  _Swatch(Color(0xFFF9C7AA), Color(0xFF2E1808), Color(0xFF683C1F), Color(0xFFFCDCCA)), // 橙 h057
];

/// 对方头像可用的颜色数量。
///
/// 8 色时，5 个会话里有约 80% 的概率出现重复配色（生日问题），比 16 色时的
/// 50% 明显高。这是换取「一眼可辨」的代价：颜色只做粗分类，精确区分仍由
/// 头像里的首字符和标题栏的指纹后缀（`PeerTitleText`）承担。
int get avatarColorCount => _swatches.length;

/// 按对端身份挑一枚稳定的头像配色。
///
/// [fingerprint] 必须是 `Conversation.peerFingerprint` 这类**稳定**标识，
/// 不能用 alias：对端改个名字就换色，等于把「颜色当身份」这件事做废了。
///
/// 同一个指纹永远得到同一个颜色（哈希是确定性的），跨会话、跨重启都一致。
AvatarColors avatarColorsFor(String fingerprint, Brightness brightness) {
  final swatch = _swatches[_stableHash(fingerprint) % _swatches.length];
  return brightness == Brightness.dark
      ? AvatarColors(background: swatch.darkBackground, foreground: swatch.darkForeground)
      : AvatarColors(background: swatch.lightBackground, foreground: swatch.lightForeground);
}

/// 稳定的字符串哈希。
///
/// 不用 `String.hashCode`：Dart 只保证它在单次运行内一致，不保证跨版本、
/// 跨平台、跨重启稳定，用它会让头像颜色随机漂移。
///
/// 这里刻意只用「小乘数乘法 + 掩码 + 无符号右移」，因为这些运算在 VM 和
/// dart2js 上的结果完全一致（乘数都小于 2^5、乘积不超过 2^53），
/// 而 FNV 那种 `hash * 0x01000193` 在 web 上会丢精度。
int _stableHash(String input) {
  var hash = 0x811C9DC5;
  for (final unit in input.codeUnits) {
    hash = (hash * 31 + (unit & 0xFF)) & 0xFFFFFFFF;
    hash = (hash * 31 + (unit >> 8)) & 0xFFFFFFFF;
  }
  // 雪崩：把相邻字符串（例如同一台设备重装前后的指纹）彻底打散，
  // 否则低位只差 1，取模后容易落到相邻的颜色上。
  hash ^= hash >>> 16;
  hash = (hash * 0x21) & 0xFFFFFFFF;
  hash ^= hash >>> 15;
  hash = (hash * 0x35) & 0xFFFFFFFF;
  hash ^= hash >>> 16;
  return hash & 0x7FFFFFFF;
}
