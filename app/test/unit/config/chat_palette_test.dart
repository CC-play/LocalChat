import 'package:flutter/material.dart';
import 'package:localchat_app/config/chat_palette.dart';
import 'package:localchat_app/model/persistence/color_mode.dart';
import 'package:test/test.dart';

ColorScheme _scheme(Brightness brightness) =>
    ColorScheme.fromSeed(seedColor: const Color(0xFF1E90FF), brightness: brightness);

void main() {
  group('chatPaletteFor', () {
    test('Local Chat + 浅色：中性灰底 + 纯白对方气泡', () {
      final palette = chatPaletteFor(ColorMode.localchat, Brightness.light, _scheme(Brightness.light));

      expect(palette.background, kChatBackground);
      expect(palette.incomingBubble, kChatIncomingBubble);
      expect(palette.background, const Color(0xFFEBEBEB));
      expect(palette.incomingBubble, const Color(0xFFFFFFFF));
      // 头部与输入栏跟页面同色，避免一块近白条压在灰底上
      expect(palette.appBarBackground, kChatBackground);
      expect(palette.composerBackground, kChatBackground);
    });

    test('Local Chat + 深色：保持主题配色', () {
      final scheme = _scheme(Brightness.dark);
      final palette = chatPaletteFor(ColorMode.localchat, Brightness.dark, scheme);

      expect(palette.background, scheme.surface);
      expect(palette.incomingBubble, scheme.surfaceContainer);
    });

    test('其它主题（system / custom / oled）：不受影响', () {
      for (final mode in [ColorMode.system, ColorMode.custom, ColorMode.oled, ColorMode.yaru]) {
        for (final brightness in Brightness.values) {
          final scheme = _scheme(brightness);
          final palette = chatPaletteFor(mode, brightness, scheme);
          expect(palette.background, scheme.surface, reason: '$mode / $brightness');
          expect(palette.incomingBubble, scheme.surfaceContainer, reason: '$mode / $brightness');
        }
      }
    });
  });
}
