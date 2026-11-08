import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localchat_app/config/chat_palette.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/model/persistence/color_mode.dart';
import 'package:localchat_app/provider/device_info_provider.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/util/ui/dynamic_colors.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:yaru/yaru.dart' as yaru;

final _borderRadius = BorderRadius.circular(5);

ThemeData getTheme(ColorMode colorMode, Color customColor, Brightness brightness, DynamicColors? dynamicColors) {
  if (colorMode == ColorMode.yaru) {
    return _getYaruTheme(brightness);
  }

  final colorScheme = _determineColorScheme(colorMode, customColor, brightness, dynamicColors);

  final lightInputBorder = OutlineInputBorder(
    borderSide: BorderSide(color: colorScheme.secondaryContainer),
    borderRadius: _borderRadius,
  );

  final darkInputBorder = OutlineInputBorder(
    borderSide: BorderSide(color: colorScheme.secondaryContainer),
    borderRadius: _borderRadius,
  );

  // https://github.com/localsend/localsend/issues/52
  final String? fontFamily;
  if (checkPlatform([TargetPlatform.windows])) {
    fontFamily = switch (LocaleSettings.currentLocale) {
      AppLocale.ja => 'Yu Gothic UI',
      AppLocale.ko => 'Malgun Gothic',
      AppLocale.zhCn => 'Microsoft YaHei UI',
      AppLocale.zhHk || AppLocale.zhTw => 'Microsoft JhengHei UI',
      _ => 'Segoe UI Variable Display',
    };
  } else if (checkPlatform([TargetPlatform.linux])) {
    fontFamily = switch (LocaleSettings.currentLocale) {
      AppLocale.ja => 'Noto Sans CJK JP',
      AppLocale.ko => 'Noto Sans CJK KR',
      AppLocale.zhCn => 'Noto Sans CJK SC',
      AppLocale.zhHk || AppLocale.zhTw => 'Noto Sans CJK TC',
      _ => 'Noto Sans',
    };
  } else {
    fontFamily = null;
  }

  return ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    // [FORK] 聊天页专用配色（Local Chat + 浅色 → 中性灰底 + 纯白对方气泡）
    extensions: <ThemeExtension<dynamic>>[
      chatPaletteFor(colorMode, brightness, colorScheme),
    ],
    // same density on all platforms so desktop matches mobile (defaults to compact on desktop)
    visualDensity: VisualDensity.standard,
    navigationBarTheme: colorScheme.brightness == Brightness.dark
        ? NavigationBarThemeData(
            iconTheme: WidgetStateProperty.all(const IconThemeData(color: Colors.white)),
          )
        : null,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.secondaryContainer,
      border: colorScheme.brightness == Brightness.light ? lightInputBorder : darkInputBorder,
      focusedBorder: colorScheme.brightness == Brightness.light ? lightInputBorder : darkInputBorder,
      enabledBorder: colorScheme.brightness == Brightness.light ? lightInputBorder : darkInputBorder,
      contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 10),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: colorScheme.brightness == Brightness.dark ? Colors.white : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
    fontFamily: fontFamily,
  );
}

Future<void> updateSystemOverlayStyle(BuildContext context) async {
  final brightness = Theme.of(context).brightness;
  await updateSystemOverlayStyleWithBrightness(brightness);
}

Future<void> updateSystemOverlayStyleWithBrightness(Brightness brightness) async {
  if (checkPlatform([TargetPlatform.android])) {
    // See https://github.com/flutter/flutter/issues/90098
    final darkMode = brightness == Brightness.dark;
    final androidSdkInt = RefenaScope.defaultRef.read(deviceInfoProvider).androidSdkInt ?? 0;
    final bool edgeToEdge = androidSdkInt >= 29;

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge); // ignore: unawaited_futures

    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: brightness == Brightness.light ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: edgeToEdge ? Colors.transparent : (darkMode ? Colors.black : Colors.white),
        systemNavigationBarContrastEnforced: false,
        systemNavigationBarIconBrightness: darkMode ? Brightness.light : Brightness.dark,
      ),
    );
  } else {
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarBrightness: brightness, // iOS
        statusBarColor: Colors.transparent, // Not relevant to this issue
      ),
    );
  }
}

extension ThemeDataExt on ThemeData {
  /// This is the actual [cardColor] being used.
  Color get cardColorWithElevation {
    return ElevationOverlay.applySurfaceTint(cardColor, colorScheme.surfaceTint, 1);
  }
}

extension ColorSchemeExt on ColorScheme {
  Color get warning {
    return Colors.orange;
  }

  Color? get secondaryContainerIfDark {
    return brightness == Brightness.dark ? secondaryContainer : null;
  }

  Color? get onSecondaryContainerIfDark {
    return brightness == Brightness.dark ? onSecondaryContainer : null;
  }
}

extension InputDecorationThemeExt on InputDecorationThemeData {
  BorderRadius get borderRadius => _borderRadius;
}

/// [FORK] Local Chat 主题的种子色（上游是 Material Teal `#009688`）。
///
/// 同时也是「动态取色不可用」时 `system` 模式的兜底配色，所以只在这里改一次，
/// [ColorMode.localchat] 走 null 分支自动跟随。
const kSeedColor = Color(0xFF1E90FF);

/// [FORK] 深色模式下 surface 系列的整体抬升量，单位是 M3 tone（等价于 CIE L*）。
///
/// `ColorScheme.fromSeed(kSeedColor, dark)` 给出的 `surface` 是 `#111318`，
/// 即 M3 neutral tone 6（实测 L* 5.88）——在桌面上几乎与纯黑无异，整片背景
/// 发闷，窗口和桌面也分不开。抬 6 档后是 `#1D1F24`（L* 11.9），与 VS Code
/// 深色主题（`#1E1E1E`，L* 12.2）落在同一水平。
///
/// 平台强调色（`ColorMode.system`）生成的深色方案同样从 tone 6 起步，所以
/// 所有深色分支都走这套抬升，见 [_determineColorScheme]。
///
/// 想再调深浅只改这个数字即可：每 +1 ≈ +1 L*。
const double kDarkSurfaceLift = 6;

const double _wpX = 0.95047;
const double _wpY = 1.0;
const double _wpZ = 1.08883;

double _toLinear(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _toSrgb(double c) => c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

/// CIE Lab 的 `f(t)`：XYZ 相对白点比值的立方根压缩（低亮度走线性段）。
double _labF(double t) => t > 216 / 24389 ? math.pow(t, 1 / 3).toDouble() : (24389 / 27 * t + 16) / 116;

double _labFInv(double t) {
  final c = t * t * t;
  return c > 216 / 24389 ? c : (116 * t - 16) * 27 / 24389;
}

/// 在 CIE Lab 空间里把颜色沿 L* 抬高 [lift] 档，保持 a* 和 b* 不变。
///
/// 为什么不用 HSL 或朝白色 lerp：那两种做法在低亮度区给出的 L* 增量不一致，
/// 会把 surface 阶梯的相对间距压扁，气泡和背景就贴到一起了。Lab 的 L*
/// 正是 M3 tone 的定义，改多少就是多少，阶梯形状原样平移。
Color _liftTone(Color color, double lift) {
  final argb = color.toARGB32();
  final r = _toLinear(((argb >> 16) & 0xFF) / 255.0);
  final g = _toLinear(((argb >> 8) & 0xFF) / 255.0);
  final b = _toLinear((argb & 0xFF) / 255.0);

  final fx = _labF((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / _wpX);
  final fy = _labF((0.2126729 * r + 0.7151522 * g + 0.0721750 * b) / _wpY);
  final fz = _labF((0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / _wpZ);

  final a = 500.0 * (fx - fy);
  final bStar = 200.0 * (fy - fz);
  final l = math.min(116.0 * fy - 16.0 + lift, 100.0);

  final ny = (l + 16) / 116;
  final nx = ny + a / 500;
  final nz = ny - bStar / 200;
  final x = _labFInv(nx) * _wpX;
  final y = _labFInv(ny) * _wpY;
  final z = _labFInv(nz) * _wpZ;

  int channel(double linear) => (_toSrgb(linear.clamp(0.0, 1.0).toDouble()) * 255).round().clamp(0, 255);

  return Color.fromARGB(
    (argb >> 24) & 0xFF,
    channel(3.2404548 * x - 1.5371389 * y - 0.4985315 * z),
    channel(-0.9692664 * x + 1.8760109 * y + 0.0415561 * z),
    channel(0.0556434 * x - 0.2040259 * y + 1.0572252 * z),
  );
}

/// 把 `surface` 及其容器阶梯整体抬亮，层次间距保持不变。
///
/// 不动 `onSurface` / `onSurfaceVariant` / `outline`：文字与描边的对比度会
/// 因此从 14.4:1 降到 12.6:1，仍远超 WCAG AAA 的 7:1。
/// 也不动 `primary` / `secondary` 等强调色——只抬"底"，不抬"字"和"色"。
ColorScheme _liftDarkSurfaces(ColorScheme scheme) {
  return scheme.copyWith(
    surface: _liftTone(scheme.surface, kDarkSurfaceLift),
    surfaceDim: _liftTone(scheme.surfaceDim, kDarkSurfaceLift),
    surfaceBright: _liftTone(scheme.surfaceBright, kDarkSurfaceLift),
    surfaceContainerLowest: _liftTone(scheme.surfaceContainerLowest, kDarkSurfaceLift),
    surfaceContainerLow: _liftTone(scheme.surfaceContainerLow, kDarkSurfaceLift),
    surfaceContainer: _liftTone(scheme.surfaceContainer, kDarkSurfaceLift),
    surfaceContainerHigh: _liftTone(scheme.surfaceContainerHigh, kDarkSurfaceLift),
    surfaceContainerHighest: _liftTone(scheme.surfaceContainerHighest, kDarkSurfaceLift),
  );
}

ColorScheme _determineColorScheme(ColorMode mode, Color customColor, Brightness brightness, DynamicColors? dynamicColors) {
  final isDark = brightness == Brightness.dark;

  ColorScheme lift(ColorScheme scheme) => isDark ? _liftDarkSurfaces(scheme) : scheme;
  ColorScheme? liftOrNull(ColorScheme? scheme) => scheme == null ? null : lift(scheme);

  final seeded = ColorScheme.fromSeed(
    seedColor: kSeedColor,
    brightness: brightness,
  );

  final colorScheme = switch (mode) {
    // 平台强调色生成的深色方案同样从 tone 6 起步，一并抬亮
    ColorMode.system => liftOrNull(brightness == Brightness.light ? dynamicColors?.light : dynamicColors?.dark),
    ColorMode.localchat => null,
    // OLED 的卖点是纯黑底，surface 必须留在 #000；容器照常抬亮，靠容器拉开层次
    ColorMode.oled => lift(dynamicColors?.dark ?? seeded).copyWith(surface: Colors.black),
    ColorMode.yaru => throw 'Should reach here',
    ColorMode.custom => lift(ColorScheme.fromSeed(
      seedColor: customColor,
      brightness: brightness,
    )),
  };

  return colorScheme ?? lift(seeded);
}

ThemeData _getYaruTheme(Brightness brightness) {
  final baseTheme = brightness == Brightness.light ? yaru.yaruLight : yaru.yaruDark;
  final colorScheme = baseTheme.colorScheme;

  final lightInputBorder = OutlineInputBorder(
    borderSide: BorderSide(color: colorScheme.secondaryContainer),
    borderRadius: _borderRadius,
  );

  final darkInputBorder = OutlineInputBorder(
    borderSide: BorderSide(color: colorScheme.secondaryContainer),
    borderRadius: _borderRadius,
  );

  InputDecorationThemeData;

  return baseTheme.copyWith(
    // same density on all platforms so desktop matches mobile (defaults to compact on desktop)
    visualDensity: VisualDensity.standard,
    navigationBarTheme: colorScheme.brightness == Brightness.dark
        ? NavigationBarThemeData(
            iconTheme: WidgetStateProperty.all(const IconThemeData(color: Colors.white)),
          )
        : null,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.secondaryContainer,
      border: colorScheme.brightness == Brightness.light ? lightInputBorder : darkInputBorder,
      focusedBorder: colorScheme.brightness == Brightness.light ? lightInputBorder : darkInputBorder,
      enabledBorder: colorScheme.brightness == Brightness.light ? lightInputBorder : darkInputBorder,
      contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 10),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: colorScheme.brightness == Brightness.dark ? Colors.white : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
  );
}
