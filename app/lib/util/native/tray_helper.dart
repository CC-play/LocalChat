import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:localchat_app/gen/assets.gen.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/provider/animation_provider.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/util/native/tray_unread.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:tray_manager/tray_manager.dart' as tm;
import 'package:window_manager/window_manager.dart';

final _logger = Logger('TrayHelper');

enum TrayEntry {
  open,
  close,
}

/// [FORK] 托盘是否真的建起来了。
///
/// 「关闭时最小化到托盘」默认开启之后，这个判断变得必要：托盘初始化失败时
/// （缺 libayatana-appindicator、Wayland 没有 StatusNotifier 宿主……）把窗口
/// 藏起来，用户既看不到程序，也没有图标把它叫回来——只能去任务管理器结束进程。
/// 所以藏之前先确认托盘在。
bool get isTrayReady => _trayReady;

bool _trayReady = false;

Future<void> initTray() async {
  if (!checkPlatformHasTray()) {
    return;
  }
  try {
    if (checkPlatform([TargetPlatform.windows])) {
      await tm.trayManager.setIcon(Assets.img.logo);
    } else if (checkPlatform([TargetPlatform.macOS])) {
      // The menu bar icon will created in AppDelegate.swift
      _trayReady = true;
      return;
    } else if (checkPlatform([TargetPlatform.linux])) {
      String icon;
      if (await File('/.flatpak-info').exists()) {
        // Icon for Flatpak, which must exist in /app/share/icons/hicolor/*x*/apps.
        icon = 'org.localsend.localsend_app-tray';
      } else {
        icon = Assets.img.logo32White.path;
      }
      _logger.info('Using "$icon" as path of system tray icon');
      await tm.trayManager.setIcon(icon);
    } else {
      await tm.trayManager.setIcon(Assets.img.logo32.path);
    }

    final items = [
      tm.MenuItem(
        key: TrayEntry.open.name,
        label: t.tray.open,
      ),
      tm.MenuItem(
        key: TrayEntry.close.name,
        label: defaultTargetPlatform == TargetPlatform.windows ? t.tray.closeWindows : t.tray.close,
      ),
    ];
    await tm.trayManager.setContextMenu(tm.Menu(items: items));
    // 图标和菜单都建好了，托盘才算真的可用。
    _trayReady = true;
    // No Linux implementation for setToolTip available as of tray_manager 0.2.2
    // https://pub.dev/packages/tray_manager#api
    if (!checkPlatform([TargetPlatform.linux])) {
      await tm.trayManager.setToolTip(t.appName);
    }
  } catch (e) {
    _logger.warning('Failed to init tray', e);
  }
}

Future<void> hideToTray() async {
  await windowManager.hide();
  if (checkPlatform([TargetPlatform.macOS])) {
    // This will crash on Windows
    // https://github.com/localsend/localsend/issues/32
    await windowManager.setSkipTaskbar(true);
  }

  // [FORK] 窗口藏起来了，未读消息只能靠托盘图标提示（有未读时开始闪）。
  await TrayUnreadIndicator.setWindowActive(false);

  // Disable animations
  try {
    RefenaScope.defaultRef.notifier(sleepProvider).setState((_) => true);
  } catch (e) {
    _logger.warning('Failed to update sleep state (Refena not yet initialized)', e);
  }
}

Future<void> showFromTray() async {
  await windowManager.show();
  await windowManager.focus();
  if (checkPlatform([TargetPlatform.macOS])) {
    // This will crash on Windows
    // https://github.com/localsend/localsend/issues/32
    await windowManager.setSkipTaskbar(false);
  }

  // [FORK] 回到前台：停止闪烁，图标恢复常显。
  await TrayUnreadIndicator.setWindowActive(true);

  // Enable animations
  try {
    RefenaScope.defaultRef.notifier(sleepProvider).setState((_) => false);
  } catch (e) {
    _logger.warning('Failed to update sleep state (Refena not yet initialized)', e);
  }
}

Future<void> destroyTray() async {
  if (!checkPlatform([TargetPlatform.linux])) {
    await tm.trayManager.destroy();
  }
  // [FORK] 托盘没了，闪烁定时器必须一起停，否则会继续对空图标 setIcon。
  TrayUnreadIndicator.stop();
}
