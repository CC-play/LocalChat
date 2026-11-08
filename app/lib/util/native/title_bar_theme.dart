import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localchat_app/util/native/platform_check.dart';

/// [FORK] 让 Windows 的标题栏颜色跟随 App 主题。
///
/// Windows 的标题栏（以及窗口那圈 1px 边框）是 DWM 画的非客户区，Flutter 完全碰不到。
/// 默认它只认**系统**是不是深色模式，所以系统主题是深色时，即使 App 自己切到浅色主题，
/// 标题栏也一直是黑的。
///
/// 做法：原生侧（`windows/runner/title_bar_ext.cpp`）用
/// `DwmSetWindowAttribute` 设置 caption / text / border 颜色，
/// 这里在主题变化时把当前 `ColorScheme` 的对应颜色推下去。
///
/// 挂在 `MaterialApp.builder` 里——那个位置能拿到已经解析好的 `Theme`（含
/// `themeMode` 与 OLED 覆盖），也不受 Navigator 重建影响：
///
/// ```dart
/// builder: (context, child) => TitleBarTheme(child: child ?? const SizedBox.shrink()),
/// ```
class TitleBarTheme extends StatefulWidget {
  final Widget child;

  const TitleBarTheme({required this.child, super.key});

  @override
  State<TitleBarTheme> createState() => _TitleBarThemeState();
}

/// 一次要下发的一组颜色（ARGB，0xAARRGGBB）。
typedef TitleBarColors = ({bool dark, int caption, int text, int border});

/// 从 `ColorScheme` 推导 DWM 需要的三个颜色。
///
/// 抽成纯函数是为了能单测（这个仓库没有 widget test，测试统一用 `package:test`）。
TitleBarColors titleBarColorsFor(ColorScheme scheme) => (
  dark: scheme.brightness == Brightness.dark,
  // 标题栏与页面背景同色，避免窗口顶部出现一条明显不同的色带。
  caption: scheme.surface.toARGB32(),
  // 标题文字：浅色主题下是深色字，深色主题下是浅色字，都由 onSurface 给出。
  text: scheme.onSurface.toARGB32(),
  // 窗口四周那圈 1px 边框；不设的话 Windows 会按强调色画，深色主题下很扎眼。
  border: scheme.outlineVariant.toARGB32(),
);

class _TitleBarThemeState extends State<TitleBarTheme> {
  static const _channel = MethodChannel('org.localsend.localsend_app/title_bar');

  /// 主题切换走 `AnimatedTheme`（200ms 插值），期间 `didChangeDependencies` 每帧都会
  /// 触发，插值出来的 surface 每帧都不同。攒一下再发，避免几十次 DWM 重绘。
  static const _debounce = Duration(milliseconds: 120);

  Timer? _timer;
  TitleBarColors? _applied;
  TitleBarColors? _pending;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule(Theme.of(context).colorScheme);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule(ColorScheme scheme) {
    // 用 checkPlatform 而不是 Platform.isWindows：测试里可以靠
    // debugDefaultTargetPlatformOverride 走到这条分支。
    if (!checkPlatform([TargetPlatform.windows])) {
      return;
    }

    final next = titleBarColorsFor(scheme);

    if (_applied == next || _pending == next) {
      return;
    }
    _pending = next;

    // 首帧别等：启动时希望一开始就是对的颜色，闪烁一次很难看。
    if (_applied == null) {
      _applied = next;
      unawaited(_apply(next));
      return;
    }

    _timer?.cancel();
    _timer = Timer(_debounce, () {
      _applied = next;
      unawaited(_apply(next));
    });
  }

  Future<void> _apply(TitleBarColors colors) async {
    try {
      await _channel.invokeMethod<void>('setTheme', {
        'dark': colors.dark,
        'caption': colors.caption,
        'text': colors.text,
        'border': colors.border,
      });
    } on MissingPluginException {
      // 没有原生侧（单测 / 普通 Dart 环境），忽略即可。
    } on PlatformException catch (e, stackTrace) {
      // 老版本 Windows 不支持其中几个 DWM 属性，已经尽力，不要影响界面。
      debugPrint('title bar theme failed: ${e.message}\n$stackTrace');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
