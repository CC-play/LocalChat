import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localchat_app/util/native/directories.dart';
import 'package:logging/logging.dart';

final _logger = Logger('ClipboardImage');

/// 与 Android 的 MainActivity、Windows 的 clipboard_ext.cpp 使用同一个通道名。
const _channel = MethodChannel('org.localsend.localsend_app/localsend');

/// [FORK] 从系统剪贴板读出来的一张图片。
class ClipboardImagePayload {
  final Uint8List bytes;

  /// 原始 MIME 只用来决定临时文件的扩展名，内容本身不再转码。
  final String mimeType;

  const ClipboardImagePayload({
    required this.bytes,
    required this.mimeType,
  });
}

/// [FORK] 剪贴板里的一个文件条目。
///
/// Windows 的「复制文件」给的是路径（文件本来就在磁盘上），
/// Android 的 content URI 拿不到路径，只能把字节读出来。
class ClipboardFileEntry {
  final String? path;
  final Uint8List? bytes;
  final String name;
  final String mimeType;

  const ClipboardFileEntry({
    required this.path,
    required this.bytes,
    required this.name,
    required this.mimeType,
  });
}

/// [FORK] 读取剪贴板图片。
///
/// 为什么不能直接用 `Clipboard.getData`：Flutter 的 `ClipboardData` 里只有
/// `text` 字段，`Clipboard.getData` 也只解析返回结果里的 text，位图根本传不上来。
/// 所以这里自己走一条原生通道（Windows: runner/clipboard_ext.cpp 用 WIC 把 DIB
/// 转成 PNG；Android: MainActivity.kt 读 ClipData 的 content URI）。
///
/// 返回 `null` 表示剪贴板里没有图片，调用方据此退回普通文本粘贴。
class ClipboardImage {
  /// 目前只有 Windows 与 Android 实现了原生侧。
  static bool get isSupported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.android);

  static Future<ClipboardImagePayload?> read() async {
    if (!isSupported) {
      return null;
    }

    try {
      final result = await _channel.invokeMapMethod<String, Object?>('getClipboardImage');
      if (result == null) {
        return null;
      }

      final bytes = result['bytes'];
      if (bytes is! Uint8List || bytes.isEmpty) {
        return null;
      }

      return ClipboardImagePayload(
        bytes: bytes,
        mimeType: result['mime'] as String? ?? 'image/png',
      );
    } on MissingPluginException {
      // 原生侧还没接（例如 Linux），当作「剪贴板里没有图片」处理。
      return null;
    } catch (e) {
      _logger.warning('Failed to read an image from the clipboard', e);
      return null;
    }
  }

  /// 把图片落到缓存目录，返回可发送的文件。
  ///
  /// 上传是按路径流式读的，图片必须先有实体文件；放在缓存目录里，
  /// 系统清理时不会影响用户数据。
  static Future<File> writeToCache(ClipboardImagePayload payload, {DateTime? now}) async {
    final dir = await getCacheDirectory();
    final file = File('$dir/${fileName(payload.mimeType, now ?? DateTime.now())}');
    await file.writeAsBytes(payload.bytes, flush: true);
    return file;
  }

  /// `clipboard-20261103-113045.png`：纯 ASCII，双端文件系统都安全。
  @visibleForTesting
  static String fileName(String mimeType, DateTime now) {
    final ext = switch (mimeType.toLowerCase()) {
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      'image/bmp' => 'bmp',
      _ => 'png',
    };

    return 'clipboard-${_stamp(now)}.$ext';
  }
}

/// [FORK] 读取剪贴板里的「文件列表」。
///
/// 在资源管理器里 Ctrl+C 一个文件（包括 .jpg）时，剪贴板里放的是 CF_HDROP
/// （一组路径），**不是位图** —— 这就是「复制一张 JPG 粘贴不进来」的真正原因，
/// 跟编码格式无关。Android 上对应的是一次复制多个文件时的多条 ClipData。
class ClipboardFiles {
  static bool get isSupported => ClipboardImage.isSupported;

  static Future<List<ClipboardFileEntry>> read() async {
    if (!isSupported) {
      return const [];
    }

    try {
      final result = await _channel.invokeListMethod<Object?>('getClipboardFiles');
      if (result == null || result.isEmpty) {
        return const [];
      }

      final entries = <ClipboardFileEntry>[];
      for (final raw in result) {
        if (raw is! Map) {
          continue;
        }
        final path = raw['path'] as String?;
        final bytes = raw['bytes'];
        final mimeType = raw['mime'] as String? ?? 'application/octet-stream';
        final name = raw['name'] as String? ?? (path == null ? null : _basename(path));
        if (name == null || (path == null && bytes is! Uint8List)) {
          continue;
        }
        entries.add(
          ClipboardFileEntry(
            path: path,
            bytes: bytes is Uint8List ? bytes : null,
            name: name,
            mimeType: mimeType,
          ),
        );
      }
      return entries;
    } on MissingPluginException {
      return const [];
    } catch (e) {
      _logger.warning('Failed to read files from the clipboard', e);
      return const [];
    }
  }

  /// 拿到可发送的实体文件：有路径直接用，只有字节就落到缓存目录。
  static Future<File> materialize(ClipboardFileEntry entry, {DateTime? now}) async {
    final path = entry.path;
    if (path != null) {
      return File(path);
    }

    final dir = await getCacheDirectory();
    final file = File('$dir/${cacheFileName(entry.name, entry.mimeType, now ?? DateTime.now())}');
    await file.writeAsBytes(entry.bytes!, flush: true);
    return file;
  }

  /// 缓存文件名：保留原始名字（用户能在气泡里认出是什么），但必须先消毒。
  ///
  /// Android 的 `DISPLAY_NAME` 与 Windows 的路径尾段理论上都合法，
  /// 但名字来自外部应用，斜杠 / 冒号 / 控制字符在双端都会让路径非法。
  @visibleForTesting
  static String cacheFileName(String rawName, String mimeType, DateTime now) {
    final base = rawName.split(RegExp(r'[/\\]')).last;
    var safe = base.replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_').trim();
    // Windows 不允许文件名以点或空格结尾。
    safe = safe.replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty) {
      return ClipboardImage.fileName(mimeType, now);
    }
    return 'clipboard-${_stamp(now)}-$safe';
  }

  static String _basename(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? path : parts.last;
  }
}

String _stamp(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
}
