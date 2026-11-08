#include "title_bar_ext.h"

#include <dwmapi.h>
#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace {

// 与 Android / 剪贴板通道风格一致：一个 App 级通道，Dart 只需要一份调用代码。
constexpr char kChannelName[] = "org.localsend.localsend_app/title_bar";

// DWM 的属性号是「公开可用但不在头文件里」的一组常量，SDK 版本不同宏名也不同，
// 这里直接用数值，省得被 SDK 头文件的定义差异卡住。
constexpr DWORD kAttributeImmersiveDarkMode = 20;        // Win10 20H1+ / Win11
constexpr DWORD kAttributeImmersiveDarkModeLegacy = 19;  // Win10 1809 ~ 1909
constexpr DWORD kAttributeBorderColor = 34;              // Win11 22000+
constexpr DWORD kAttributeCaptionColor = 35;             // Win11 22000+
constexpr DWORD kAttributeTextColor = 36;                // Win11 22000+

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
HWND g_window = nullptr;

// Dart 传过来的是 0xAARRGGBB，DWM 要的是 COLORREF（0x00BBGGRR）。
COLORREF ToColorRef(int argb) {
  return RGB(static_cast<BYTE>((argb >> 16) & 0xFF), static_cast<BYTE>((argb >> 8) & 0xFF),
             static_cast<BYTE>(argb & 0xFF));
}

const flutter::EncodableValue* FindArg(const flutter::EncodableMap& args, const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr : &it->second;
}

bool ReadBool(const flutter::EncodableMap& args, const char* key, bool fallback) {
  const flutter::EncodableValue* value = FindArg(args, key);
  if (value == nullptr) {
    return fallback;
  }
  const bool* decoded = std::get_if<bool>(value);
  return decoded == nullptr ? fallback : *decoded;
}

int ReadInt(const flutter::EncodableMap& args, const char* key, int fallback) {
  const flutter::EncodableValue* value = FindArg(args, key);
  if (value == nullptr) {
    return fallback;
  }
  // 小整数在 codec 里可能是 int32，也可能是 int64。
  if (const int32_t* decoded = std::get_if<int32_t>(value)) {
    return *decoded;
  }
  if (const int64_t* decoded = std::get_if<int64_t>(value)) {
    return static_cast<int>(*decoded);
  }
  return fallback;
}

void ApplyTitleBarTheme(HWND window, bool dark, int caption, int text, int border) {
  if (window == nullptr) {
    return;
  }

  BOOL use_dark = dark ? TRUE : FALSE;
  // 先按新号设置，老系统（Win10 1909 及以前）只认 19。
  if (FAILED(DwmSetWindowAttribute(window, kAttributeImmersiveDarkMode, &use_dark, sizeof(use_dark)))) {
    DwmSetWindowAttribute(window, kAttributeImmersiveDarkModeLegacy, &use_dark, sizeof(use_dark));
  }

  const COLORREF caption_ref = ToColorRef(caption);
  const COLORREF text_ref = ToColorRef(text);
  const COLORREF border_ref = ToColorRef(border);
  // Win10 上这三条会返回 E_INVALIDARG，忽略就行 —— 那时只能靠 immersive dark mode
  // 区分深浅，颜色跟不了 App 的具体配色。
  DwmSetWindowAttribute(window, kAttributeCaptionColor, &caption_ref, sizeof(caption_ref));
  DwmSetWindowAttribute(window, kAttributeTextColor, &text_ref, sizeof(text_ref));
  DwmSetWindowAttribute(window, kAttributeBorderColor, &border_ref, sizeof(border_ref));

  // 属性改完 DWM 不会主动重画非客户区，得自己把框架刷一遍。
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  RedrawWindow(window, nullptr, nullptr, RDW_FRAME | RDW_INVALIDATE | RDW_UPDATENOW);
}

}  // namespace

void RegisterTitleBarChannel(flutter::BinaryMessenger* messenger, HWND window) {
  g_window = window;
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "setTheme") {
          result->NotImplemented();
          return;
        }

        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Error("bad_args", "setTheme expects a map");
          return;
        }

        ApplyTitleBarTheme(g_window, ReadBool(*args, "dark", false), ReadInt(*args, "caption", 0),
                           ReadInt(*args, "text", 0), ReadInt(*args, "border", 0));
        result->Success();
      });
}
