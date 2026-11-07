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

    test('十六种颜色全部可达，且互不重复', () {
      for (final brightness in Brightness.values) {
        final found = _collect(brightness);
        expect(found.length, avatarColorCount, reason: '$brightness');
        expect(avatarColorCount, 16);
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
