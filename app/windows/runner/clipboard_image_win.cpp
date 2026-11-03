#include "clipboard_image_win.h"

#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstring>
#include <utility>

namespace {

using Microsoft::WRL::ComPtr;

// BI_ALPHABITFIELDS 在较老的 SDK 里没有名字，这里显式写值。
constexpr DWORD kBiAlphaBitfields = 6;

// 把 BMP/DIB 流解码后重新编码成 PNG。
std::vector<uint8_t> EncodeStreamAsPng(IStream* source) {
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(::CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) {
    return {};
  }

  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromStream(source, nullptr, WICDecodeMetadataCacheOnDemand, &decoder))) {
    return {};
  }

  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, &frame))) {
    return {};
  }

  // 统一转 32bpp BGRA：PNG 编码器对这个格式支持最好，也能保住 alpha。
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter))) {
    return {};
  }
  if (FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom))) {
    return {};
  }

  ComPtr<IStream> output;
  if (FAILED(::CreateStreamOnHGlobal(nullptr, TRUE, &output))) {
    return {};
  }

  ComPtr<IWICBitmapEncoder> encoder;
  if (FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder))) {
    return {};
  }
  if (FAILED(encoder->Initialize(output.Get(), WICBitmapEncoderNoCache))) {
    return {};
  }

  ComPtr<IWICBitmapFrameEncode> frame_encode;
  ComPtr<IPropertyBag2> properties;
  if (FAILED(encoder->CreateNewFrame(&frame_encode, &properties))) {
    return {};
  }
  if (FAILED(frame_encode->Initialize(properties.Get()))) {
    return {};
  }

  UINT width = 0;
  UINT height = 0;
  if (FAILED(converter->GetSize(&width, &height))) {
    return {};
  }
  frame_encode->SetSize(width, height);

  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(frame_encode->SetPixelFormat(&format))) {
    return {};
  }
  if (FAILED(frame_encode->WriteSource(converter.Get(), nullptr))) {
    return {};
  }
  if (FAILED(frame_encode->Commit())) {
    return {};
  }
  if (FAILED(encoder->Commit())) {
    return {};
  }

  // 用 Seek 取长度，而不是 GlobalSize：HGLOBAL 的分配粒度会返回比实际更大的值。
  LARGE_INTEGER zero{};
  ULARGE_INTEGER end{};
  if (FAILED(output->Seek(zero, STREAM_SEEK_END, &end)) || end.QuadPart == 0) {
    return {};
  }
  std::vector<uint8_t> bytes(static_cast<size_t>(end.QuadPart));
  output->Seek(zero, STREAM_SEEK_SET, nullptr);
  ULONG read = 0;
  if (FAILED(output->Read(bytes.data(), static_cast<ULONG>(bytes.size()), &read))) {
    return {};
  }
  bytes.resize(read);
  return bytes;
}

// 剪贴板里的 DIB（截图工具只给这个格式）补上 BMP 文件头，再交给 WIC。
std::vector<uint8_t> ConvertDibToPng(HGLOBAL handle) {
  const size_t size = ::GlobalSize(handle);
  auto* dib = static_cast<const uint8_t*>(::GlobalLock(handle));
  if (dib == nullptr) {
    return {};
  }

  std::vector<uint8_t> png;
  if (size > sizeof(BITMAPINFOHEADER)) {
    BITMAPINFOHEADER info{};
    std::memcpy(&info, dib, sizeof(info));

    if (info.biSize >= sizeof(BITMAPINFOHEADER) && info.biSize <= size) {
      // 像素数据在 DIB 里的偏移 = 头 + 调色板（或位域掩码）。
      size_t extra = 0;
      if (info.biBitCount <= 8) {
        extra = sizeof(RGBQUAD) * (static_cast<size_t>(1) << info.biBitCount);
      } else if (info.biSize < sizeof(BITMAPV5HEADER)) {
        // BITMAPV5HEADER 已经把掩码写进头里了，不能再补一次。
        if (info.biCompression == BI_BITFIELDS) {
          extra = 3 * sizeof(DWORD);
        } else if (info.biCompression == kBiAlphaBitfields) {
          extra = 4 * sizeof(DWORD);
        }
      }

      BITMAPFILEHEADER file_header{};
      file_header.bfType = 0x4D42;  // 'BM'
      file_header.bfOffBits = sizeof(BITMAPFILEHEADER) + static_cast<DWORD>(info.biSize + extra);
      file_header.bfSize = sizeof(BITMAPFILEHEADER) + static_cast<DWORD>(size);

      ComPtr<IStream> stream;
      if (SUCCEEDED(::CreateStreamOnHGlobal(nullptr, TRUE, &stream))) {
        stream->Write(&file_header, sizeof(file_header), nullptr);
        stream->Write(dib, static_cast<ULONG>(size), nullptr);
        LARGE_INTEGER start{};
        stream->Seek(start, STREAM_SEEK_SET, nullptr);
        png = EncodeStreamAsPng(stream.Get());
      }
    }
  }

  ::GlobalUnlock(handle);
  return png;
}

}  // namespace

std::vector<uint8_t> ReadClipboardImageAsPng() {
  bool opened = false;
  // 剪贴板常被别的程序短暂占用，OpenClipboard 会直接失败，重试几次更稳。
  for (int attempt = 0; attempt < 5 && !opened; ++attempt) {
    if (attempt > 0) {
      ::Sleep(20);
    }
    opened = ::OpenClipboard(nullptr) != FALSE;
  }
  if (!opened) {
    return {};
  }

  std::vector<uint8_t> png;

  // 1) 浏览器 / 部分截图工具会同时放一份 PNG，直接拿来用，省一次重编码。
  const UINT png_format = ::RegisterClipboardFormatW(L"PNG");
  if (png_format != 0 && ::IsClipboardFormatAvailable(png_format)) {
    if (HANDLE handle = ::GetClipboardData(png_format)) {
      if (auto* data = static_cast<const uint8_t*>(::GlobalLock(handle))) {
        const size_t size = ::GlobalSize(handle);
        // PNG 魔法数，防止同名格式里塞了别的东西。
        if (size > 8 && data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G') {
          png.assign(data, data + size);
        }
        ::GlobalUnlock(handle);
      }
    }
  }

  // 2) 少数程序（老版画图、部分看图工具）不放 DIB，只放一份 JPEG/JFIF 流。
  //    剪贴板里没有「JPG 文件」这种东西，这里是唯一可能拿到 JPEG 编码 bytes 的路径。
  for (const wchar_t* name : {L"JFIF", L"JPEG"}) {
    if (!png.empty()) {
      break;
    }
    const UINT format = ::RegisterClipboardFormatW(name);
    if (format == 0 || !::IsClipboardFormatAvailable(format)) {
      continue;
    }
    HANDLE handle = ::GetClipboardData(format);
    if (handle == nullptr) {
      continue;
    }
    ComPtr<IStream> stream;
    if (FAILED(::CreateStreamOnHGlobal(static_cast<HGLOBAL>(handle), FALSE, &stream))) {
      continue;
    }
    LARGE_INTEGER start{};
    stream->Seek(start, STREAM_SEEK_SET, nullptr);
    png = EncodeStreamAsPng(stream.Get());
  }

  // 3) 兜底：Win+Shift+S 截图只提供 DIB。
  if (png.empty()) {
    const UINT dib_format = ::IsClipboardFormatAvailable(CF_DIBV5) ? CF_DIBV5 : CF_DIB;
    if (::IsClipboardFormatAvailable(dib_format)) {
      if (HANDLE handle = ::GetClipboardData(dib_format)) {
        png = ConvertDibToPng(handle);
      }
    }
  }

  ::CloseClipboard();
  return png;
}
