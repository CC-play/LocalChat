import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:logging/logging.dart';
import 'package:tray_manager/tray_manager.dart' as tm;

final _logger = Logger('TrayUnread');

/// [FORK] 整个文件为 fork 新增：桌面端托盘图标的「有未读消息」指示。
///
/// 桌面端没有系统级消息通知（`ChatNotification` 只实现了 Android），窗口不在
/// 前台时收到消息，用户能看到的唯一信号就是托盘。行为分三档：
///
/// - **有未读 + 窗口不在前台**：图标在「显示」与「完全隐藏」之间每 350ms 切一次，
///   也就是闪烁。用的始终是原生图标本身，不改颜色、不加角标。
/// - **有未读 + 窗口在前台**：图标常显，不闪 —— 用户已经在看会话列表，再闪属于干扰。
/// - **无未读**：图标常显。
///
/// 未读的唯一真相是 `unreadConversationCountProvider`。这里只把它翻译成「闪不闪」，
/// 不自己维护计数：否则「已读 / 删消息 / 清空会话」任意一条路径漏了，
/// 图标就会一直闪到应用退出。
///
/// 为什么「隐藏」要靠一张全透明占位图：`tray_manager` 只能换文件路径，没有设置
/// 透明度或隐藏图标的接口；而删掉图标会让任务栏的托盘格子跟着挪位。
class TrayUnreadIndicator {
  TrayUnreadIndicator._();

  /// 显示 / 隐藏各停多久。350ms 是「看得出在闪」又不至于晃眼的下限。
  static const _blinkInterval = Duration(milliseconds: 350);

  static const _macOsChannel = MethodChannel('main-delegate-channel');

  /// 托盘上当前画的是「显示」还是「隐藏」，用于避免无意义的重复 `setIcon`。
  static bool _paintedVisible = true;

  /// 上一次 `setIcon` 还没返回就不做下一次切换，避免慢平台把调用堆起来。
  static bool _painting = false;

  static bool _hasUnread = false;

  /// 窗口是否在前台且未最小化。默认按「在」处理：应用刚起来时窗口就是可见的。
  static bool _windowActive = true;

  static Timer? _timer;

  /// 未读数从「有」变「无」或反之。
  static Future<void> setUnread(bool value) async {
    if (_hasUnread == value) {
      return;
    }
    _hasUnread = value;
    await _sync();
  }

  /// 窗口获得 / 失去焦点、最小化 / 还原、藏进托盘 / 从托盘唤出。
  static Future<void> setWindowActive(bool value) async {
    if (_windowActive == value) {
      return;
    }
    _windowActive = value;
    await _sync();
  }

  /// 托盘被销毁（关闭应用）时停表，避免对已经不存在的图标继续 setIcon。
  static void stop() {
    _stopBlinking();
    _hasUnread = false;
    _windowActive = true;
    _paintedVisible = true;
    _painting = false;
  }

  static Future<void> _sync() async {
    if (!checkPlatformHasTray()) {
      return;
    }

    if (_hasUnread && !_windowActive) {
      _startBlinking();
      return;
    }

    _stopBlinking();
    // 停闪后必须把图标推回「显示」：上一次可能停在隐藏那一拍上。
    await _paint(visible: true);
  }

  static void _startBlinking() {
    if (_timer != null) {
      return;
    }
    unawaited(_paint(visible: true));
    _timer = Timer.periodic(_blinkInterval, (_) => _tick());
  }

  static void _stopBlinking() {
    _timer?.cancel();
    _timer = null;
  }

  static void _tick() {
    if (_painting) {
      return;
    }
    // `_paintedVisible` 在 `_paint` 里是同步翻转的，所以这里取反就是目标状态。
    unawaited(_paint(visible: !_paintedVisible));
  }

  static Future<void> _paint({required bool visible}) async {
    if (_paintedVisible == visible) {
      return;
    }
    // 先置位再 await：`setIcon` 在 macOS 上要读 bundle 再 base64，
    // 耗时可能超过一个间隔，不置位就会叠出多次调用。
    final previous = _paintedVisible;
    _paintedVisible = visible;
    _painting = true;

    try {
      if (checkPlatform([TargetPlatform.macOS])) {
        // macOS 的菜单栏图标由 AppDelegate 的 NSStatusItem 持有，
        // 走 tray_manager 会额外造出第二个图标，只能回原生侧改透明度。
        await _macOsChannel.invokeMethod('setStatusBarAlpha', visible ? 1.0 : 0.0);
        return;
      }

      final icon = _iconFor(visible: visible);
      if (icon == null) {
        return;
      }
      await tm.trayManager.setIcon(icon);
    } catch (e, st) {
      // 换图失败就回滚，让下一次 tick 再试；不回滚会一直卡在「以为换了」的状态。
      _paintedVisible = previous;
      _logger.warning('Failed to switch tray icon (visible=$visible)', e, st);
    } finally {
      _painting = false;
    }
  }

  /// 各平台的图标路径。`tray_manager` 会把相对路径拼到 `data/flutter_assets` 下，
  /// 与 `initTray()` 里的用法保持一致。
  static String? _iconFor({required bool visible}) {
    if (checkPlatform([TargetPlatform.windows])) {
      return visible ? 'assets/img/logo.ico' : 'assets/img/logo-blank.ico';
    }

    if (checkPlatform([TargetPlatform.linux])) {
      // Flatpak 里托盘用的是主机侧的主题图标名，改不了，只能放弃闪烁。
      if (File('/.flatpak-info').existsSync()) {
        return null;
      }
      return visible ? 'assets/img/logo-32-white.png' : 'assets/img/logo-32-white-blank.png';
    }

    return null;
  }
}
