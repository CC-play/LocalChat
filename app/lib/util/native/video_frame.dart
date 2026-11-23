import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 取本机视频文件的首帧，返回 PNG 字节；取不到时返回 null。
///
/// 为什么要绕系统：`ChatMessage` 只记了文件路径，没有缩略图字段，而聊天记录是本地
/// 持久化的，历史消息不可能回头补一张图。Flutter 自己不解码视频，纯 Dart 也做不到，
/// 所以交给系统的缩略图服务——Windows 上用 Shell 的 `IShellItemImageFactory`，拿到的
/// 正是资源管理器里显示的那张封面，走系统解码器（Media Foundation）和系统缩略图缓存，
/// 既不额外打包解码库，也不增加安装体积。
///
/// 另一条路是引入 media_kit / ffmpeg 之类的播放器内核，为了一个 40dp 的缩略图背上
/// 几十 MB 的二进制，不划算。
///
/// 其它平台（Android / Linux / macOS）暂时返回 null，调用方回落到类型图标。
class VideoFrameLoader {
  VideoFrameLoader._();

  /// 缓存上限。一条 96px 的 PNG 约 3~10KB，120 条最多 1MB 出头。
  static const int _maxCacheEntries = 120;

  /// 已取过的结果（含 null，避免失败的路径每次重建都重试一遍）。
  static final Map<String, Uint8List?> _cache = {};

  /// 正在取的路径。列表滚动时同一张卡片会重建多次，不去重就会并发跑好几遍。
  static final Map<String, Future<Uint8List?>> _inFlight = {};

  /// 取 [path] 的首帧。[size] 传目标显示尺寸的 2~3 倍即可。
  static Future<Uint8List?> load(String path, {int size = 96}) {
    final key = '$path#$size';
    if (_cache.containsKey(key)) {
      return Future.value(_cache[key]);
    }
    final running = _inFlight[key];
    if (running != null) {
      return running;
    }
    // 用 Future(...) 把实际工作推到微任务之后，保证下面那行先登记、再执行；
    // 否则非 Windows 分支会同步跑完，_inFlight 里留下一个永远不清理的条目。
    final future = Future<Uint8List?>(() => _extract(path, size))
        .then((bytes) {
          _remember(key, bytes);
          return bytes;
        })
        // 必须写成块体：`=> _inFlight.remove(key)` 会把 remove 的返回值——也就是
        // 这个正在构造的 future 自己——交给 whenComplete 去等待，形成自等待死锁，
        // 结果永远不完成（表现为界面一直没有缩略图、await 永不返回）。
        .whenComplete(() {
          // remove 返回的就是这个 future 本身，必须明确丢弃，别让 whenComplete 去等它。
          unawaited(_inFlight.remove(key));
        });
    _inFlight[key] = future;
    return future;
  }

  static Future<Uint8List?> _extract(String path, int size) async {
    if (!Platform.isWindows || path.startsWith('content://')) {
      return null;
    }
    try {
      // 首次取一帧可能要上百毫秒（要拉解码器），放后台 isolate 里做，别卡住列表滚动。
      return await Isolate.run(() => _extractWindowsThumbnail(path, size));
    } catch (_) {
      // 解码器缺失、文件被独占、Shell 拒绝…… 一律归到「没有缩略图」。
      return null;
    }
  }

  static void _remember(String key, Uint8List? bytes) {
    if (_cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = bytes;
  }
}

// ---------------------------------------------------------------------------
// Win32 绑定
//
// 这里不用 package:win32：它在文件顶层就 DynamicLibrary.open('shell32.dll')，
// 一旦被 import，Android 上编译/运行会直接炸。手写这几条绑定，就可以只在
// Platform.isWindows 为真时才碰 FFI。
// ---------------------------------------------------------------------------

const int _coinitApartmentThreaded = 0x2;
const int _rpcEChangedMode = -2147417850; // 0x80010106：本线程已在别的套间
const int _siigbfBiggerSizeOk = 0x1;
const int _siigbfThumbnailOnly = 0x8; // 只要缩略图，别拿类型图标糊弄
const int _biRgb = 0;

/// `IID_IShellItemImageFactory` = {bcc18b79-ba16-442f-80c4-8a59c30c463b}
const List<int> _iidShellItemImageFactoryTail = [0x80, 0xC4, 0x8A, 0x59, 0xC3, 0x0C, 0x46, 0x3B];

final class _Guid extends Struct {
  @Uint32()
  external int data1;

  @Uint16()
  external int data2;

  @Uint16()
  external int data3;

  @Array(8)
  external Array<Uint8> data4;
}

final class _NativeSize extends Struct {
  @Int32()
  external int cx;

  @Int32()
  external int cy;
}

final class _Bitmap extends Struct {
  @Int32()
  external int bmType;

  @Int32()
  external int bmWidth;

  @Int32()
  external int bmHeight;

  @Int32()
  external int bmWidthBytes;

  @Uint16()
  external int bmPlanes;

  @Uint16()
  external int bmBitsPixel;

  external Pointer<Void> bmBits;
}

final class _BitmapInfoHeader extends Struct {
  @Uint32()
  external int biSize;

  @Int32()
  external int biWidth;

  @Int32()
  external int biHeight;

  @Uint16()
  external int biPlanes;

  @Uint16()
  external int biBitCount;

  @Uint32()
  external int biCompression;

  @Uint32()
  external int biSizeImage;

  @Int32()
  external int biXPelsPerMeter;

  @Int32()
  external int biYPelsPerMeter;

  @Uint32()
  external int biClrUsed;

  @Uint32()
  external int biClrImportant;
}

final class _BitmapInfo extends Struct {
  external _BitmapInfoHeader bmiHeader;

  /// BI_RGB 时用不到调色板，留一格满足结构体最小长度即可。
  @Array(4)
  external Array<Uint32> bmiColors;
}

class _Win32 {
  _Win32._(
    this.coInitializeEx,
    this.coUninitialize,
    this.coTaskMemAlloc,
    this.coTaskMemFree,
    this.shCreateItemFromParsingName,
    this.getObject,
    this.getDC,
    this.releaseDC,
    this.getDIBits,
    this.deleteObject,
  );

  final int Function(Pointer<Void>, int) coInitializeEx;
  final void Function() coUninitialize;
  final Pointer<Void> Function(int) coTaskMemAlloc;
  final void Function(Pointer<Void>) coTaskMemFree;
  final int Function(Pointer<Uint16>, Pointer<Void>, Pointer<_Guid>, Pointer<Pointer<Void>>) shCreateItemFromParsingName;
  final int Function(int, int, Pointer<Void>) getObject;
  final int Function(int) getDC;
  final int Function(int, int) releaseDC;
  final int Function(int, int, int, int, Pointer<Void>, Pointer<_BitmapInfo>, int) getDIBits;
  final int Function(int) deleteObject;

  static _Win32? _instance;
  static bool _attempted = false;

  /// 只在 Windows 上、且第一次真正要用时才加载。
  static _Win32? get instance {
    if (_attempted) {
      return _instance;
    }
    _attempted = true;
    if (!Platform.isWindows) {
      return null;
    }
    try {
      _instance = _load();
    } catch (_) {
      _instance = null;
    }
    return _instance;
  }

  static _Win32 _load() {
    final ole32 = DynamicLibrary.open('ole32.dll');
    final shell32 = DynamicLibrary.open('shell32.dll');
    final user32 = DynamicLibrary.open('user32.dll');
    final gdi32 = DynamicLibrary.open('gdi32.dll');

    return _Win32._(
      ole32.lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>('CoInitializeEx'),
      ole32.lookupFunction<Void Function(), void Function()>('CoUninitialize'),
      ole32.lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>('CoTaskMemAlloc'),
      ole32.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CoTaskMemFree'),
      shell32.lookupFunction<
        Int32 Function(Pointer<Uint16>, Pointer<Void>, Pointer<_Guid>, Pointer<Pointer<Void>>),
        int Function(Pointer<Uint16>, Pointer<Void>, Pointer<_Guid>, Pointer<Pointer<Void>>)
      >('SHCreateItemFromParsingName'),
      gdi32.lookupFunction<Int32 Function(IntPtr, Int32, Pointer<Void>), int Function(int, int, Pointer<Void>)>('GetObjectW'),
      user32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetDC'),
      user32.lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>('ReleaseDC'),
      gdi32.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Uint32, Uint32, Pointer<Void>, Pointer<_BitmapInfo>, Uint32),
        int Function(int, int, int, int, Pointer<Void>, Pointer<_BitmapInfo>, int)
      >('GetDIBits'),
      gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteObject'),
    );
  }

  // --- 内存 ---

  // sizeOf<T> 的类型参数必须是编译期常量，不能写成泛型方法，只好逐个列出来。

  Pointer<_Guid> allocGuid() => _checkedAlloc(sizeOf<_Guid>()).cast<_Guid>();

  Pointer<_NativeSize> allocSize() => _checkedAlloc(sizeOf<_NativeSize>()).cast<_NativeSize>();

  Pointer<_Bitmap> allocBitmap() => _checkedAlloc(sizeOf<_Bitmap>()).cast<_Bitmap>();

  Pointer<_BitmapInfo> allocBitmapInfo() => _checkedAlloc(sizeOf<_BitmapInfo>()).cast<_BitmapInfo>();

  Pointer<IntPtr> allocIntPtr() => _checkedAlloc(sizeOf<IntPtr>()).cast<IntPtr>();

  Pointer<Pointer<Void>> allocPointerSlot() => _checkedAlloc(sizeOf<Pointer<Void>>()).cast<Pointer<Void>>();

  Pointer<Uint8> allocBytes(int count) => _checkedAlloc(count).cast<Uint8>();

  Pointer<Void> _checkedAlloc(int bytes) {
    final pointer = coTaskMemAlloc(bytes);
    if (pointer.address == 0) {
      throw StateError('CoTaskMemAlloc($bytes) failed');
    }
    return pointer;
  }

  void free(Pointer pointer) => coTaskMemFree(pointer.cast<Void>());

  Pointer<Uint16> allocUtf16(String value) {
    // Dart 的 String 本来就是 UTF-16 码元序列，逐个写入即可（含代理对）。
    final units = value.codeUnits;
    final pointer = allocBytes((units.length + 1) * 2).cast<Uint16>();
    for (var i = 0; i < units.length; i++) {
      pointer[i] = units[i];
    }
    pointer[units.length] = 0;
    return pointer;
  }

  Pointer<_Guid> allocShellItemImageFactoryIid() {
    final pointer = allocGuid();
    pointer.ref
      ..data1 = 0xBCC18B79
      ..data2 = 0xBA16
      ..data3 = 0x442F;
    for (var i = 0; i < 8; i++) {
      pointer.ref.data4[i] = _iidShellItemImageFactoryTail[i];
    }
    return pointer;
  }

  // --- COM 手工调用 ---

  /// `IShellItemImageFactory::GetImage`（vtable 第 3 项，另 2 项是 QueryInterface
  /// / AddRef，第 2 项是 Release）。
  int getImage(Pointer<Void> item, _NativeSize size, int flags, Pointer<IntPtr> hBitmap) {
    final method = _vtableEntry(item, 3);
    final call = method
        .cast<NativeFunction<Int32 Function(Pointer<Void>, _NativeSize, Int32, Pointer<IntPtr>)>>()
        .asFunction<int Function(Pointer<Void>, _NativeSize, int, Pointer<IntPtr>)>();
    return call(item, size, flags, hBitmap);
  }

  void release(Pointer<Void> item) {
    final method = _vtableEntry(item, 2);
    method.cast<NativeFunction<Uint32 Function(Pointer<Void>)>>().asFunction<int Function(Pointer<Void>)>()(item);
  }

  /// 取 COM 对象 vtable 里第 [index] 个方法指针。
  ///
  /// 对象指针指向「vtable 指针」，所以要先解一层：object → vtable → method。
  Pointer<Void> _vtableEntry(Pointer<Void> object, int index) {
    final vtable = object.cast<Pointer<Void>>().value;
    return (vtable.cast<Pointer<Void>>() + index).value;
  }
}

/// 在后台 isolate 里跑：拿一张视频首帧，转成 PNG。
Uint8List? _extractWindowsThumbnail(String rawPath, int size) {
  final api = _Win32.instance;
  if (api == null) {
    return null;
  }

  // SHCreateItemFromParsingName 只认反斜杠。`filePath` 有可能来自别处（比如用 '/'
  // 拼出来的路径），正斜杠会让它直接返回 E_INVALIDARG。
  final path = rawPath.replaceAll('/', r'\');

  Pointer<Uint16>? pathPointer;
  Pointer<_Guid>? iidPointer;
  Pointer<Pointer<Void>>? itemPointer;
  Pointer<IntPtr>? bitmapHandlePointer;
  Pointer<_Bitmap>? bitmapPointer;
  Pointer<_BitmapInfo>? infoPointer;
  Pointer<_NativeSize>? sizePointer;
  Pointer<Uint8>? pixelPointer;
  Pointer<Void>? item;
  var hdc = 0;
  var hBitmap = 0;
  var comInitialized = false;

  try {
    final hrInit = api.coInitializeEx(nullptr, _coinitApartmentThreaded);
    if (hrInit == _rpcEChangedMode) {
      // 线程已在别的套间（引擎可能已经初始化过），别去动它的引用计数。
      comInitialized = false;
    } else {
      // S_OK / S_FALSE 都算「这次调用完成了初始化」，收尾时把计数减回去。
      comInitialized = hrInit >= 0;
    }

    pathPointer = api.allocUtf16(path);
    iidPointer = api.allocShellItemImageFactoryIid();
    itemPointer = api.allocPointerSlot();
    final hrCreate = api.shCreateItemFromParsingName(pathPointer, nullptr, iidPointer, itemPointer);
    if (hrCreate < 0) {
      return null;
    }
    item = itemPointer.value;
    if (item.address == 0) {
      return null;
    }

    sizePointer = api.allocSize();
    sizePointer.ref
      ..cx = size
      ..cy = size;
    bitmapHandlePointer = api.allocIntPtr();
    final hrImage = api.getImage(item, sizePointer.ref, _siigbfBiggerSizeOk | _siigbfThumbnailOnly, bitmapHandlePointer);
    if (hrImage < 0) {
      return null;
    }
    hBitmap = bitmapHandlePointer.value;
    if (hBitmap == 0) {
      return null;
    }

    bitmapPointer = api.allocBitmap();
    if (api.getObject(hBitmap, sizeOf<_Bitmap>(), bitmapPointer.cast()) == 0) {
      return null;
    }
    final width = bitmapPointer.ref.bmWidth;
    final height = bitmapPointer.ref.bmHeight;
    if (width <= 0 || height <= 0) {
      return null;
    }

    // 统一按 32bpp 读：GDI 会把 24/16bpp 的位图转换过来，行宽固定 width*4，
    // 不用自己算 4 字节对齐；biHeight 取负数表示自上而下，省一次整行翻转。
    infoPointer = api.allocBitmapInfo();
    final header = infoPointer.ref.bmiHeader;
    header.biSize = sizeOf<_BitmapInfoHeader>();
    header.biWidth = width;
    header.biHeight = -height;
    header.biPlanes = 1;
    header.biBitCount = 32;
    header.biCompression = _biRgb;
    infoPointer.ref.bmiColors[0] = 0;

    pixelPointer = api.allocBytes(width * height * 4);
    hdc = api.getDC(0);
    if (hdc == 0) {
      return null;
    }
    if (api.getDIBits(hdc, hBitmap, 0, height, pixelPointer.cast(), infoPointer, 0) == 0) {
      return null;
    }

    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: pixelPointer.asTypedList(width * height * 4).buffer,
      numChannels: 4,
      order: img.ChannelOrder.bgra,
    );
    // BI_RGB 下第 4 个字节未定义，Shell 常常给 0；不补成不透明就是一张全透明的图。
    for (final pixel in image) {
      pixel.a = 255;
    }

    final result = (width > size * 2 || height > size * 2)
        ? img.copyResize(image, width: width >= height ? size * 2 : null, height: height > width ? size * 2 : null)
        : image;
    return Uint8List.fromList(img.encodePng(result));
  } catch (_) {
    return null;
  } finally {
    if (hdc != 0) {
      api.releaseDC(0, hdc);
    }
    if (hBitmap != 0) {
      api.deleteObject(hBitmap);
    }
    if (item != null && item.address != 0) {
      api.release(item);
    }
    if (sizePointer != null) {
      api.free(sizePointer);
    }
    if (pixelPointer != null) {
      api.free(pixelPointer);
    }
    if (infoPointer != null) {
      api.free(infoPointer);
    }
    if (bitmapPointer != null) {
      api.free(bitmapPointer);
    }
    if (bitmapHandlePointer != null) {
      api.free(bitmapHandlePointer);
    }
    if (itemPointer != null) {
      api.free(itemPointer);
    }
    if (iidPointer != null) {
      api.free(iidPointer);
    }
    if (pathPointer != null) {
      api.free(pathPointer);
    }
    if (comInitialized) {
      api.coUninitialize();
    }
  }
}
