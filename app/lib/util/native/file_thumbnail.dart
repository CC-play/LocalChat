import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localchat_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localchat_app/util/native/platform_check.dart';

/// [FORK] 文件卡片缩略图的统一入口（Android）。
///
/// 为什么需要这层：卡片里有两类图**不能**用 `Image.file` 画 ——
/// 1. 只写进了系统相册的媒体，消息里根本没有路径；
/// 2. `content://` 的 URI，它不是文件系统路径，`Image.file` / `VideoFrameLoader`
///    都读不了。
/// 这两种都交给原生（`GalleryThumbnail.kt`）取一张小图回来。
///
/// 三件事是这里负责的、卡片不该自己做的：
/// - **缓存**：列表滚动时卡片会反复重建，每次重建都跨一次 MethodChannel 是浪费。
///   取到的结果（含 null，避免失败的项每次重试）留着，上限 [_maxCacheEntries] 条。
/// - **去重**：同一张卡片重建两次会并发发起两次请求，第二次直接复用第一次的 future。
/// - **平台判定**：只有 Android 有这套原生实现，其它平台立刻返回 null，卡片回落到
///   类型图标（桌面端图片本来就走 `Image.file`，视频走 `VideoFrameLoader`）。
class FileThumbnailLoader {
  FileThumbnailLoader._();

  /// 一条 96px 的 JPEG 约 3~10KB，200 条最多 2MB 上下。
  static const int _maxCacheEntries = 200;

  /// 已取过的结果，含 null（失败也记下来，别每次重建都重试一遍）。
  static final Map<String, Uint8List?> _cache = {};

  /// 正在取的 key。同一张卡片重建多次时复用这里，避免并发重复解码。
  static final Map<String, Future<Uint8List?>> _inFlight = {};

  /// 取一张缩略图。
  ///
  /// [key] 是这个文件的稳定标识（调用方用消息 id 即可），缓存按它 + [size] 分桶。
  /// [path] 为空表示「只存进了相册」：这时原生侧按 [fileName] / [fileSize] /
  /// [timestampMs] 回查 MediaStore。
  static Future<Uint8List?> load({
    required String key,
    String? path,
    String? fileName,
    int fileSize = 0,
    int? timestampMs,
    int size = 96,
  }) {
    final cacheKey = '$key#$size';
    if (_cache.containsKey(cacheKey)) {
      return Future.value(_cache[cacheKey]);
    }
    final running = _inFlight[cacheKey];
    if (running != null) {
      return running;
    }
    // 和 `VideoFrameLoader` 一样用 Future(...) 把实际工作推到微任务之后：
    // 否则非 Android 分支会同步跑完，_inFlight 里留下一个永远不清理的条目。
    final future = Future<Uint8List?>(
      () => _load(
        path: path,
        fileName: fileName,
        fileSize: fileSize,
        timestampMs: timestampMs,
        size: size,
      ),
    ).then((bytes) {
      _remember(cacheKey, bytes);
      return bytes;
    }).whenComplete(() {
      // 必须写成块体并丢弃 remove 的返回值：`=> _inFlight.remove(key)` 会把这个
      // 正在构造的 future 自己交给 whenComplete 去等待，形成自等待死锁。
      unawaited(_inFlight.remove(cacheKey));
    });
    _inFlight[cacheKey] = future;
    return future;
  }

  static Future<Uint8List?> _load({
    String? path,
    String? fileName,
    int fileSize = 0,
    int? timestampMs,
    int size = 96,
  }) async {
    if (!checkPlatform([TargetPlatform.android])) {
      return null;
    }
    return android_channel.getFileThumbnail(
      path: path,
      fileName: fileName,
      fileSize: fileSize,
      timestampMs: timestampMs,
      maxSize: size,
    );
  }

  static void _remember(String key, Uint8List? bytes) {
    if (_cache.length >= _maxCacheEntries) {
      // 简单的先进先出：缩略图体积很小，不需要 LRU 那套。
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = bytes;
  }
}
