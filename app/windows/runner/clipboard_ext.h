#ifndef RUNNER_CLIPBOARD_EXT_H_
#define RUNNER_CLIPBOARD_EXT_H_

#include <flutter/binary_messenger.h>

// [FORK] 聊天输入框的「粘贴图片」通道。
//
// Flutter 自带的 Clipboard.getData 只处理纯文本（ClipboardData 里只有 text 字段），
// 拿不到剪贴板里的位图。这里在 runner 里注册一个方法通道，用 WIC 把剪贴板里的
// DIB 转成 PNG 交给 Dart。
void RegisterClipboardChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_CLIPBOARD_EXT_H_
