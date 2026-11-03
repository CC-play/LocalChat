#ifndef RUNNER_CLIPBOARD_IMAGE_WIN_H_
#define RUNNER_CLIPBOARD_IMAGE_WIN_H_

#include <cstdint>
#include <vector>

// [FORK] 读取剪贴板里的图片，统一转成 PNG 字节；剪贴板里没有图片时返回空。
//
// 单独放在这里（不依赖 Flutter）是为了能脱离 app 单独编译验证：
// 剪贴板的 DIB 解析和 WIC 编码都比较容易出错，值得一条独立的验证路径。
std::vector<uint8_t> ReadClipboardImageAsPng();

#endif  // RUNNER_CLIPBOARD_IMAGE_WIN_H_
