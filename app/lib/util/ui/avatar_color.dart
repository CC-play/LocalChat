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
/// 取值按 M3 的 tone 体系定档：浅色底 tone 90 + 字 tone 12，深色底 tone 30 +
/// 字 tone 90。明度档位固定之后，十六个颜色的「轻重」才一致——一排头像看过去
/// 不会有的刺眼、有的发灰。实测对比度：浅色最低 12.6:1，深色最低 7.2:1，
/// 均高于 WCAG AA 的 4.5:1。
class _Swatch {
  final Color lightBackground;
  final Color lightForeground;
  final Color darkBackground;
  final Color darkForeground;

  const _Swatch(this.lightBackground, this.lightForeground, this.darkBackground, this.darkForeground);
}

const List<_Swatch> _swatches = [
  _Swatch(Color(0xFFCFE5FE), Color(0xFF002237), Color(0xFF144A6E), Color(0xFFCFE5FE)), // 蓝
  _Swatch(Color(0xFFAEECFF), Color(0xFF01232B), Color(0xFF044E5D), Color(0xFFAEECFF)), // 天蓝
  _Swatch(Color(0xFF9FF1EE), Color(0xFF012424), Color(0xFF02504F), Color(0xFF9FF1EE)), // 青
  _Swatch(Color(0xFFAFF0D7), Color(0xFF00251A), Color(0xFF0D503E), Color(0xFFAFF0D7)), // 蓝绿
  _Swatch(Color(0xFFC3EDC5), Color(0xFF012606), Color(0xFF294F2F), Color(0xFFC3EDC5)), // 绿
  _Swatch(Color(0xFFDCE8B6), Color(0xFF1C2200), Color(0xFF404B22), Color(0xFFDCE8B6)), // 黄绿
  _Swatch(Color(0xFFF4E1B1), Color(0xFF271F01), Color(0xFF51461D), Color(0xFFF4E1B1)), // 黄
  _Swatch(Color(0xFFFEDCC2), Color(0xFF311A00), Color(0xFF603F22), Color(0xFFFEDCC2)), // 琥珀
  _Swatch(Color(0xFFFFDBCF), Color(0xFF3B1300), Color(0xFF683B2B), Color(0xFFFFDBCF)), // 橙
  _Swatch(Color(0xFFFEDAD8), Color(0xFF3F0E11), Color(0xFF6D3737), Color(0xFFFEDAD8)), // 红
  _Swatch(Color(0xFFFED9E1), Color(0xFF3F0C1D), Color(0xFF6C3644), Color(0xFFFED9E1)), // 粉
  _Swatch(Color(0xFFFED8EB), Color(0xFF3B0E29), Color(0xFF673752), Color(0xFFFED8EB)), // 洋红
  _Swatch(Color(0xFFFED6FF), Color(0xFF321334), Color(0xFF5C3B5E), Color(0xFFFED6FF)), // 紫红
  _Swatch(Color(0xFFE9DDFF), Color(0xFF23193D), Color(0xFF4D4068), Color(0xFFE9DDFF)), // 紫罗兰
  _Swatch(Color(0xFFDCE1FF), Color(0xFF081F42), Color(0xFF38456E), Color(0xFFDCE1FF)), // 靛蓝
  _Swatch(Color(0xFFDBE3EE), Color(0xFF192028), Color(0xFF404750), Color(0xFFDBE3EE)), // 中性
];

/// 对方头像可用的颜色数量。
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

/// 自己（发出方向）的头像配色。
///
/// 故意不用色板：自己的身份是唯一的，跟主题色走更有「这是我」的感觉；
/// 而 `primaryContainer` 在 M3 里正好也是 tone 90 / tone 30 的档位，
/// 与色板的明度带天然对齐，放在一排里不会显得突兀。
AvatarColors selfAvatarColors(ColorScheme scheme) {
  return AvatarColors(background: scheme.primaryContainer, foreground: scheme.onPrimaryContainer);
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
