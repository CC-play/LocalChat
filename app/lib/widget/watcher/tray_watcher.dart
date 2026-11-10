import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localchat_app/provider/conversation_provider.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/util/native/tray_helper.dart';
import 'package:localchat_app/util/native/tray_unread.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:tray_manager/tray_manager.dart';

class TrayWatcher extends StatefulWidget {
  final Widget child;

  const TrayWatcher({required this.child, super.key});

  @override
  State<TrayWatcher> createState() => _TrayWatcherState();
}

class _TrayWatcherState extends State<TrayWatcher> with TrayListener, Refena {
  /// 上一次推给托盘的状态，null 表示还没推过。
  bool? _lastHasUnread;

  @override
  Widget build(BuildContext context) {
    // [FORK] 未读数变化 → 托盘图标闪不闪。
    // 放这里而不是接收回调里：已读、删消息、清空会话都会改变未读数，
    // 挂在状态上才不会漏掉任何一条让图标停下来的路径。
    final hasUnread = ref.watch(unreadConversationCountProvider) > 0;
    if (hasUnread != _lastHasUnread) {
      _lastHasUnread = hasUnread;
      // build 期间不能做副作用，推到本帧之后。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        unawaited(TrayUnreadIndicator.setUnread(hasUnread));
      });
    }

    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    super.dispose();
  }

  @override
  void onTrayIconMouseDown() async {
    if (checkPlatform([TargetPlatform.macOS])) {
      await trayManager.popUpContextMenu();
    } else {
      await showFromTray();
    }
  }

  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    final entry = TrayEntry.values.firstWhereOrNull((e) => e.name == menuItem.key);
    switch (entry) {
      case TrayEntry.open:
        await showFromTray();
        break;
      case TrayEntry.close:
        exit(0);
      default:
    }
  }
}
