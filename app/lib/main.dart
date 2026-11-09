import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:localchat_app/config/init.dart';
import 'package:localchat_app/config/init_error.dart';
import 'package:localchat_app/config/theme.dart';
import 'package:localchat_app/gen/assets.gen.dart';
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
import 'package:localchat_app/widget/local_chat_logo.dart';
import 'package:localchat_app/widget/startup_splash.dart';
import 'package:localchat_app/widget/watcher/life_cycle_watcher.dart';
import 'package:localchat_app/widget/watcher/shortcut_watcher.dart';
import 'package:localchat_app/widget/watcher/tray_watcher.dart';
import 'package:localchat_app/widget/watcher/window_watcher.dart';
import 'package:localchat_isolates/isolate.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

Future<void> main(List<String> args) async {
  // [FORK] 引擎一起来就进 runApp，先把启动动画画上去。
  //
  // 原来 preInit 跑在 runApp 之前：那段时间 Flutter 一帧都没画，屏幕上是原生
  // 窗口的底色（Android 白、Windows 黑），Rust 初始化 + 读设置 + 桌面端
  // showFromTray 全在这段里，慢起来就是用户看到的「启动一片白」。
  // 现在 preInit 挪到首帧之后（见 _BootstrapAppState.initState），它跑多久，
  // 屏幕上都是那个转圈的蓝底 logo。
  WidgetsFlutterBinding.ensureInitialized();
  await _precacheStartupLogo();
  runApp(_BootstrapApp(args: args));
}

/// [FORK] 把启动画面的 logo 提前解码进 ImageCache。
///
/// 蓝底是 [ColoredBox]，第一帧就画得出来；logo 是 512×512 的 PNG，要走 asset
/// 通道读完、解码、再上传纹理，实测（debug 包）要几百毫秒。不预加载的话用户先
/// 看到一整片蓝，图形过一会儿才「冒」出来 —— 就是这个等待期。
///
/// 把这段等待挪到 `runApp` 之前：此时屏幕上是原生启动窗口，底色已经改成同一个
/// 品牌蓝，所以视觉上是一整块连续的蓝，而不是蓝底上先空一块。
///
/// 这里的 [ImageConfiguration] 必须和 `LocalChatLogo` 里 Image widget 实际用的
/// 完全一致（bundle / devicePixelRatio / platform / size / locale），否则会落到
/// ImageCache 的另一个槽位，预加载等于白做。
Future<void> _precacheStartupLogo() async {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  if (view == null) {
    return;
  }
  final stream = Assets.img.logo512.provider().resolve(
    ImageConfiguration(
      bundle: rootBundle,
      devicePixelRatio: view.devicePixelRatio,
      platform: defaultTargetPlatform,
      // 启动画面在 MaterialApp 之外，没有 Localizations，locale 保持 null。
      size: const Size(kLogoSize, kLogoSize),
    ),
  );

  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) {
      done.complete();
    }
  }

  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (image, synchronousCall) => finish(),
    onError: (error, stackTrace) => finish(),
  );
  stream.addListener(listener);
  // 图片坏了或者通道卡住时别把启动一起拖死：超时就按老样子让 logo 后到。
  await done.future.timeout(const Duration(seconds: 2), onTimeout: finish);
  stream.removeListener(listener);
}

/// [FORK] 启动壳：启动动画 → 首帧 → 初始化 → 交叉淡出到真实应用。
class _BootstrapApp extends StatefulWidget {
  final List<String> args;

  const _BootstrapApp({required this.args});

  @override
  State<_BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<_BootstrapApp> {
  /// 启动画面至少停留这么久。
  ///
  /// preInit 在本机常常三百毫秒就结束了，不兜底的话动画还没转起来就没了，
  /// 比不放动画更像闪屏。
  static const Duration _minSplashDuration = Duration(milliseconds: 700);

  /// 启动画面淡出时长，和真实应用第一帧交叉。
  static const Duration _fadeOutDuration = Duration(milliseconds: 280);

  RefenaContainer? _container;

  /// 淡出结束后把启动画面整棵摘掉，省得一直挂在上面占一层合成。
  bool _splashMounted = true;

  @override
  void initState() {
    super.initState();
    // 必须等首帧真的画上去再开始初始化：桌面端的窗口是在 preInit 里
    // showFromTray 出来的，早于首帧就会先亮一块空白窗口。
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_boot()));
  }

  Future<void> _boot() async {
    final stopwatch = Stopwatch()..start();
    final RefenaContainer container;
    try {
      container = await preInit(widget.args);
    } catch (e, stackTrace) {
      // 错误页自己会 runApp 一棵新树，启动画面随之消失，不需要在这里收尾。
      showInitErrorApp(
        error: e,
        stackTrace: stackTrace,
      );
      return;
    }

    // 初始化比最短展示时长还快时，补足剩下的时间再切。
    final remaining = _minSplashDuration - stopwatch.elapsed;
    if (remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }
    if (!mounted) {
      return;
    }
    setState(() => _container = container);

    // [FORK] 系统通知：装上「点了通知」的回调，并把冷启动那一刻的点击取回来。
    //
    // 等的是真实应用那一帧：回调里要 push 会话页，Navigator 还没建好就推会直接抛异常。
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

  @override
  Widget build(BuildContext context) {
    final container = _container;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery.fromView(
        // 启动画面在 MaterialApp 之外，没有 MediaQuery 的话图片会按
        // devicePixelRatio = 1 解码，3x 屏上 200dp 的 logo 会糊成一片。
        view: View.of(context),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (container != null)
              RefenaScope.withContainer(
                container: container,
                child: TranslationProvider(
                  child: const LocalChatApp(),
                ),
              ),
            if (_splashMounted)
              IgnorePointer(
                // 启动画面永远不吃点击：淡出那 280ms 里，用户的点击应该直接
                // 落到下面的真实界面上。
                child: AnimatedOpacity(
                  opacity: container == null ? 1 : 0,
                  duration: _fadeOutDuration,
                  curve: Curves.easeOut,
                  onEnd: () {
                    if (mounted && _container != null) {
                      setState(() => _splashMounted = false);
                    }
                  },
                  child: const StartupSplash(),
                ),
              ),
          ],
        ),
      ),
    );
  }
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
