import 'package:flutter/widgets.dart';

/// App 是否在前台，只用来决定「收到消息要不要弹系统通知」。
///
/// [FORK] 整个文件为 fork 新增。
/// 之所以做成轻量静态状态而不是 provider：调用方是 `conversation_recorder`，
/// 它会被上游的接收控制器直接调用，保持零依赖最容易维护。
/// 前台一律不弹 —— 用户正看着 App，列表里的未读角标已经够了，系统通知反而打断。
class ChatPresence {
  ChatPresence._();

  /// 直接读引擎的生命周期状态，不自己维护副本。
  ///
  /// 副本很容易和真实状态错位：例如通知点击把 App 拉起来、或 ROM 跳过某些中间状态时，
  /// 少收一次回调就会一直以为在前台，表现就是「后台收消息永远不提醒」。
  /// `lifecycleState` 在 App 跑起来之后一定非空；为 null（极早期）时按前台处理，
  /// 免得启动瞬间就弹一条通知。
  static bool get isForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }
}
