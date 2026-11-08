import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localchat_app/util/ui/avatar_color.dart';
import 'package:test/test.dart';

/// WCAG 相对亮度对比度。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// sRGB → CIELAB（D65），只用于算色差。
List<double> _toLab(Color c) {
  double lin(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  double f(double t) => t > 216 / 24389 ? math.pow(t, 1 / 3).toDouble() : (841 / 108) * t + 4 / 29;
  final r = lin(c.r);
  final g = lin(c.g);
  final b = lin(c.b);
  final x = f((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047);
  final y = f(0.2126 * r + 0.7152 * g + 0.0722 * b);
  final z = f((0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883);
  return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
}

/// CIE76 色差。ΔE 10 左右是「一眼可辨」，5 左右要盯着看才分得清。
double _deltaE76(Color a, Color b) {
  final p = _toLab(a);
  final q = _toLab(b);
  final dl = p[0] - q[0];
  final da = p[1] - q[1];
  final db = p[2] - q[2];
  return math.sqrt(dl * dl + da * da + db * db);
}

/// 用一堆合成指纹去撞色板，收集所有实际出现过的配色。
///
/// 顺带证明「每种颜色都可达」——如果某个色值永远取不到，这里会少一个。
Map<Color, AvatarColors> _collect(Brightness brightness, {int samples = 4000}) {
  final found = <Color, AvatarColors>{};
  for (var i = 0; i < samples; i++) {
    final colors = avatarColorsFor('fingerprint-$i', brightness);
    found.putIfAbsent(colors.background, () => colors);
  }
  return found;
}

void main() {
  group('avatarColorsFor', () {
    test('同一个指纹永远得到同一个颜色', () {
      for (final fp in ['abc', 'A1B2C3D4E5F6', '张三的手机']) {
        for (final brightness in Brightness.values) {
          final first = avatarColorsFor(fp, brightness);
          final second = avatarColorsFor(fp, brightness);
          expect(first.background, second.background, reason: '$fp / $brightness');
          expect(first.foreground, second.foreground, reason: '$fp / $brightness');
        }
      }
    });

    test('相邻指纹不会退化成同一个颜色', () {
      // 哈希尾部不做雪崩时，连续字符串容易落到相邻颜色上。
      final distinct = <Color>{
        for (var i = 0; i < 32; i++) avatarColorsFor('device-$i', Brightness.light).background,
      };
      expect(distinct.length, greaterThanOrEqualTo(8));
    });

    test('八种颜色全部可达，且互不重复', () {
      for (final brightness in Brightness.values) {
        final found = _collect(brightness);
        expect(found.length, avatarColorCount, reason: '$brightness');
        expect(avatarColorCount, 8);
      }
    });

    test('两两之间的色差足够大，浅色底上也能一眼分辨', () {
      // 浅色档的彩度上限低，色数一多就会退化成「几乎同色」。
      // 8 色是实测出来的上限：ΔE76 浅色最小 10.4、深色 8.1；
      // 加到 10 色浅色掉到 8.3，16 色只剩 5.2。低于这个门槛
      // 就说明有人往色板里塞了相近的颜色。
      for (final brightness in Brightness.values) {
        final colors = _collect(brightness).values.toList();
        for (var i = 0; i < colors.length; i++) {
          for (var j = i + 1; j < colors.length; j++) {
            final deltaE = _deltaE76(colors[i].background, colors[j].background);
            expect(
              deltaE,
              greaterThanOrEqualTo(7.5),
              reason: '$brightness ${colors[i].background} 与 '
                  '${colors[j].background} 只差 ${deltaE.toStringAsFixed(1)}',
            );
          }
        }
      }
    });

    test('每一种配色的对比度都不低于 WCAG AA（4.5:1）', () {
      for (final brightness in Brightness.values) {
        for (final colors in _collect(brightness).values) {
          final ratio = _contrast(colors.background, colors.foreground);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason: '$brightness ${colors.background} on ${colors.foreground} = ${ratio.toStringAsFixed(2)}',
          );
        }
      }
    });

    test('色板不含绿色系（HSV 色相 70°～165°）', () {
      // 绿色在 tone 90 浅底上偏灰、在 tone 30 深底上偏荧光，是用户明确排除的色系。
      // 青（teal，约 178°）不在这个区间内，会正常通过。
      for (final brightness in Brightness.values) {
        for (final colors in _collect(brightness).values) {
          final hue = HSVColor.fromColor(colors.background).hue;
          expect(
            hue < 70 || hue > 165,
            isTrue,
            reason: '$brightness ${colors.background} 的色相是 ${hue.toStringAsFixed(1)}°，落在绿色区间',
          );
        }
      }
    });

    test('深色模式的底色比浅色模式暗（两套色板没有写反）', () {
      final light = _collect(Brightness.light).values.toList();
      final dark = _collect(Brightness.dark).values.toList();
      final lightLum = light.map((e) => e.background.computeLuminance()).reduce((a, b) => a + b) / light.length;
      final darkLum = dark.map((e) => e.background.computeLuminance()).reduce((a, b) => a + b) / dark.length;
      expect(darkLum, lessThan(lightLum));
    });

    test('空指纹（理论上不该出现）不抛异常', () {
      final colors = avatarColorsFor('', Brightness.light);
      expect(colors.background, isNot(colors.foreground));
    });
  });

  group('selfAvatarColors', () {
    test('跟随主题的 primaryContainer，与色板明度档位对齐', () {
      for (final brightness in Brightness.values) {
        final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF1E90FF), brightness: brightness);
        final colors = selfAvatarColors(scheme);

        expect(colors.background, scheme.primaryContainer);
        expect(colors.foreground, scheme.onPrimaryContainer);
        expect(_contrast(colors.background, colors.foreground), greaterThanOrEqualTo(4.5));
      }
    });
  });
}
