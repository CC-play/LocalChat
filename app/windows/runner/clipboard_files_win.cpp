#include "clipboard_files_win.h"

#include <windows.h>

#include <shellapi.h>

#include <algorithm>
#include <cstddef>

namespace {

// 一次最多带 100 个路径过去：防止「复制整个盘」这类操作把 Dart 侧撑爆。
constexpr UINT kMaxFiles = 100;

bool OpenClipboardWithRetry() {
  // 剪贴板常被别的程序短暂占用，OpenClipboard 会直接失败，重试几次更稳。
  for (int attempt = 0; attempt < 5; ++attempt) {
    if (attempt > 0) {
      ::Sleep(20);
    }
    if (::OpenClipboard(nullptr)) {
      return true;
    }
  }
  return false;
}

std::string ToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr,
                                         nullptr);
  if (size <= 0) {
    return {};
  }
  std::string out(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), out.data(), size, nullptr, nullptr);
  return out;
}

}  // namespace

std::vector<std::string> ReadClipboardFilePathsUtf8() {
  std::vector<std::string> paths;

  if (!::IsClipboardFormatAvailable(CF_HDROP)) {
    return paths;
  }
  if (!OpenClipboardWithRetry()) {
    return paths;
  }

  if (HDROP drop = static_cast<HDROP>(::GetClipboardData(CF_HDROP))) {
    const UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    const UINT limit = std::min(count, kMaxFiles);
    paths.reserve(limit);
    for (UINT i = 0; i < limit; ++i) {
      const UINT length = ::DragQueryFileW(drop, i, nullptr, 0);
      if (length == 0) {
        continue;
      }
      std::wstring buffer(static_cast<size_t>(length) + 1, L'\0');
      if (::DragQueryFileW(drop, i, buffer.data(), length + 1) == 0) {
        continue;
      }
      buffer.resize(length);
      paths.push_back(ToUtf8(buffer));
    }
  }

  ::CloseClipboard();
  return paths;
}
