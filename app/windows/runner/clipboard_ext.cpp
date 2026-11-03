#include "clipboard_ext.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <utility>
#include <vector>

#include "clipboard_files_win.h"
#include "clipboard_image_win.h"

namespace {

// 与 Android 侧 MainActivity 里的通道名保持一致，Dart 只需要一份调用代码。
constexpr char kChannelName[] = "org.localsend.localsend_app/localsend";

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

void HandleGetClipboardImage(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::vector<uint8_t> png = ReadClipboardImageAsPng();
  if (png.empty()) {
    // null 表示「剪贴板里没有图片」，Dart 会退回普通文本粘贴。
    result->Success();
    return;
  }

  // 和 Android 侧返回同样的结构，Dart 只写一份解析逻辑。
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("bytes")] = flutter::EncodableValue(std::move(png));
  payload[flutter::EncodableValue("mime")] = flutter::EncodableValue("image/png");
  result->Success(flutter::EncodableValue(std::move(payload)));
}

void HandleGetClipboardFiles(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::vector<std::string> paths = ReadClipboardFilePathsUtf8();
  flutter::EncodableList list;
  list.reserve(paths.size());
  for (std::string& path : paths) {
    // Windows 侧文件已经在磁盘上，只要把路径带过去，不用读字节。
    flutter::EncodableMap entry;
    entry[flutter::EncodableValue("path")] = flutter::EncodableValue(std::move(path));
    list.emplace_back(flutter::EncodableValue(std::move(entry)));
  }
  result->Success(flutter::EncodableValue(std::move(list)));
}

}  // namespace

void RegisterClipboardChannel(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler([](const flutter::MethodCall<flutter::EncodableValue>& call,
                                     std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "getClipboardImage") {
      HandleGetClipboardImage(std::move(result));
      return;
    }
    if (call.method_name() == "getClipboardFiles") {
      HandleGetClipboardFiles(std::move(result));
      return;
    }
    result->NotImplemented();
  });
}
