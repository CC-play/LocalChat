import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localchat_app/config/theme.dart';
import 'package:localchat_app/widget/local_chat_logo.dart';

/// [FORK] 启动画面：整屏品牌蓝，中间是白色 logo，箭头环顺时针转、气泡不动。
///
/// 与接收标签页用的是同一个 [LocalChatLogo]，只改了两处：颜色（蓝底上要白的）
/// 和转速。接收页 15 秒一圈是「在转但不抢眼」，启动画面只存在一秒左右，照搬
/// 那个速度等于看不见在动。
class StartupSplash extends StatelessWidget {
  /// One full turn of the arrow ring.
  ///
  /// 2.4 秒：比接收页快六倍，一眼能看出在转，又不至于像转盘那样催人。
  static const Duration spinDuration = Duration(milliseconds: 2400);

  /// 底色取主色种子的原值，不用主题里派生出来的 primary。
  ///
  /// primary 会被深浅色模式改写（深色下调亮、OLED 下偏冷），而启动画面在主题
  /// 加载完成之前就要画出来，必须是固定的同一个蓝。
  static const Color background = kSeedColor;

  const StartupSplash({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 蓝底配白色状态栏图标。没有这层，浅色系统主题下状态栏图标是深色的，
      // 压在蓝底上几乎看不见。
      value: SystemUiOverlayStyle.light,
      child: const ColoredBox(
        color: background,
        child: Center(
          child: LocalChatLogo(
            withText: false,
            spinning: true,
            spinDuration: spinDuration,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
