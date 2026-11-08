import 'package:flutter/material.dart';
import 'package:localchat_app/util/native/title_bar_theme.dart';
import 'package:test/test.dart';

const _seed = Color(0xFF1E90FF);

void main() {
  group('titleBarColorsFor', () {
    test('浅色主题：dark=false，标题栏跟 surface，标题字跟 onSurface', () {
      final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.light);
      final colors = titleBarColorsFor(scheme);

      expect(colors.dark, isFalse);
      expect(colors.caption, scheme.surface.toARGB32());
      expect(colors.text, scheme.onSurface.toARGB32());
      expect(colors.border, scheme.outlineVariant.toARGB32());
    });

    test('深色主题：dark=true，颜色来自深色 scheme 而不是浅色', () {
      final light = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.light);
      final dark = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark);
      final colors = titleBarColorsFor(dark);

      expect(colors.dark, isTrue);
      expect(colors.caption, dark.surface.toARGB32());
      expect(colors.caption, isNot(light.surface.toARGB32()));
      expect(colors.text, dark.onSurface.toARGB32());
    });

    test('OLED 纯黑底：标题栏也是纯黑，标题字仍用亮色 onSurface 保证可读', () {
      final scheme = ColorScheme.fromSeed(
        seedColor: _seed,
        brightness: Brightness.dark,
      ).copyWith(surface: const Color(0xFF000000));
      final colors = titleBarColorsFor(scheme);

      expect(colors.dark, isTrue);
      expect(colors.caption, 0xFF000000);
      // 纯黑底上标题字必须是亮的，否则窗口标题看不见。
      expect(colors.text, scheme.onSurface.toARGB32());
      expect(colors.text, isNot(0xFF000000));
    });
  });
}
