import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:localchat_app/config/init.dart';
import 'package:localchat_app/config/init_error.dart';
import 'package:localchat_app/config/theme.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/model/persistence/color_mode.dart';
import 'package:localchat_app/pages/conversation_page.dart';
import 'package:localchat_app/pages/home_page.dart';
import 'package:localchat_app/provider/local_ip_provider.dart';
import 'package:localchat_app/provider/network/nearby_devices_provider.dart';
import 'package:localchat_app/provider/network/server/server_provider.dart';
import 'package:localchat_app/provider/settings_provider.dart';
import 'package:localchat_app/util/native/chat_notification.dart';
import 'package:localchat_app/util/native/notification_sound.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/util/native/title_bar_theme.dart';
import 'package:localchat_app/util/ui/dynamic_colors.dart';
import 'package:localchat_app/widget/watcher/life_cycle_watcher.dart';
import 'package:localchat_app/widget/watcher/shortcut_watcher.dart';
import 'package:localchat_app/widget/watcher/tray_watcher.dart';
import 'package:localchat_app/widget/watcher/window_watcher.dart';
import 'package:localchat_isolates/isolate.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

Future<void> main(List<String> args) async {
  final RefenaContainer container;
  try {
    container = await preInit(args);
  } catch (e, stackTrace) {
    showInitErrorApp(
      error: e,
      stackTrace: stackTrace,
    );
    return;
  }

  runApp(
    RefenaScope.withContainer(
      container: container,
      child: TranslationProvider(
        child: const LocalChatApp(),
      ),
    ),
  );

  // [FORK] 系统通知：装上「点了通知」的回调，并把冷启动那一刻的点击取回来。
  //
  // 必须等首帧之后：回调里要 push 会话页，Navigator 还没建好就推会直接抛异常。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      ChatNotification.init(
        onTap: (peerFingerprint) => unawaited(
          Routerino.context.push(() => ConversationPage(peerFingerprint: peerFingerprint)),
        ),
      ),
    );
    // [FORK] 预热提示音：第一声迟到 100~300ms 比不响还怪。
    unawaited(NotificationSound.warmUp());
  });
}

class LocalChatApp extends StatelessWidget {
  const LocalChatApp();

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final (themeMode, colorMode, customColor) = ref.watch(
      settingsProvider.select((settings) => (settings.theme, settings.colorMode, settings.customColor)),
    );
    final dynamicColors = ref.watch(dynamicColorsProvider);
    return TrayWatcher(
      child: WindowWatcher(
        child: LifeCycleWatcher(
          onChangedState: (AppLifecycleState state) {
            switch (state) {
              case AppLifecycleState.resumed:
                ref.redux(localIpProvider).dispatch(InitLocalIpAction());
                // A device that started while this app was in the background
                // never got an answer from us and has no reason to announce
                // again, so it is missing from the nearby list until someone
                // speaks up. Announce again whenever the app comes back.
                ref.redux(nearbyDevicesProvider).dispatch(StartMulticastScan());
                if (checkPlatform([TargetPlatform.iOS, TargetPlatform.android])) {
                  // The OS may have invalidated the sockets of the suspended app without any error ever reaching the accept loop.
                  // ignore: discarded_futures
                  ref.notifier(serverProvider).ensureRunning();
                }
                if (checkPlatform([TargetPlatform.iOS])) {
                  // The multicast sockets die the same silent way but cannot be probed, so always rebind them.
                  ref.redux(parentIsolateProvider).dispatch(IsolateDiscoveryRestartAction());
                }
                break;
              case AppLifecycleState.detached:
                // The main isolate is only exited when all child isolates are exited.
                // https://github.com/localsend/localsend/issues/1568
                ref.redux(parentIsolateProvider).dispatch(IsolateDisposeAction());
                break;
              default:
                break;
            }
          },
          child: ShortcutWatcher(
            child: MaterialApp(
              title: t.appName,
              locale: TranslationProvider.of(context).flutterLocale,
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              debugShowCheckedModeBanner: false,
              theme: getTheme(colorMode, customColor, Brightness.light, dynamicColors),
              darkTheme: getTheme(colorMode, customColor, Brightness.dark, dynamicColors),
              themeMode: colorMode == ColorMode.oled ? ThemeMode.dark : themeMode,
              // [FORK] Windows 的标题栏由 DWM 画，挂在这里才能拿到解析后的主题，
              // 让标题栏颜色跟随 App 主题而不是系统深浅色。
              builder: (context, child) => TitleBarTheme(
                child: child ?? const SizedBox.shrink(),
              ),
              navigatorKey: context.read(navigationProvider).key,
              home: RouterinoHome(
                builder: () => const HomePage(
                  // [FORK] 启动默认落在会话页
                  initialTab: HomeTab.conversations,
                  appStart: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
