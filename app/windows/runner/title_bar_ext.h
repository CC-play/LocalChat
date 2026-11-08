#ifndef RUNNER_TITLE_BAR_EXT_H_
#define RUNNER_TITLE_BAR_EXT_H_

#include <windows.h>

#include <flutter/binary_messenger.h>

// [FORK] 让 Windows 的标题栏跟随 App 主题。
//
// 标题栏是 DWM 画的（非客户区），Flutter 完全碰不到它：默认只认系统是不是
// 深色模式，所以系统用深色主题时，App 切到浅色主题标题栏仍然是黑的。
// 这里注册一个方法通道，Dart 每次主题变化就把窗口标题栏/边框/标题文字的颜色
// 推下来，由 DWM 直接按给定颜色绘制。
void RegisterTitleBarChannel(flutter::BinaryMessenger* messenger, HWND window);

#endif  // RUNNER_TITLE_BAR_EXT_H_
