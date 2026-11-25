import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

part 'android_channel.mapper.dart';

const _methodChannel = MethodChannel('org.localsend.localsend_app/localsend');
final _logger = Logger('AndroidSaf');

/// From Android 10 and above, we need to use the Storage Access Framework (SAF) to access files due to the scoped storage.
/// SAF itself is available from Android 4.4 (API level 19).
/// We implemented our own algorithm to build encode and decode content URIs.
/// Older versions might also work but the encoded content URI is not guaranteed to work with our algorithm.
const contentUriMinSdk = 27;

Future<PickDirectoryResult?> pickDirectoryAndroid() async {
  final result = await _methodChannel.invokeMethod<Map>('pickDirectory');
  if (result == null) {
    return null;
  }

  return PickDirectoryResultMapper.fromJson({
    'directoryUri': result['directoryUri'],
    'files': (result['files'] as List).map((e) => FileInfoMapper.fromJson((e as Map).cast<String, dynamic>())).toList(),
  });
}

Future<String?> pickDirectoryPathAndroid() async {
  final result = await _methodChannel.invokeMethod<String>('pickDirectoryPath');
  return result;
}

Future<List<FileInfo>?> pickFilesAndroid() async {
  final result = await _methodChannel.invokeMethod<List>('pickFiles');
  if (result == null) {
    return null;
  }

  return result.map((e) => FileInfoMapper.fromJson((e as Map).cast<String, dynamic>())).toList();
}

/// Returns the global "Download" directory, e.g. /storage/emulated/0/Download.
Future<String?> getDownloadsDirectoryAndroid() async {
  try {
    return await _methodChannel.invokeMethod<String>('getDownloadsDirectory');
  } catch (e) {
    _logger.warning('Could not get downloads directory', e);
    return null;
  }
}

Future<bool> getSystemAnimationsStatusAndroid() async {
  return await _methodChannel.invokeMethod('isAnimationsEnabled') ?? true;
}

/// Requests the "Nearby devices" permission gating local network access on Android 17+.
/// Returns true when granted or when running on an older Android version.
Future<bool> requestLocalNetworkPermissionAndroid() async {
  try {
    return await _methodChannel.invokeMethod<bool>('requestLocalNetworkPermission') ?? false;
  } catch (e) {
    _logger.warning('Could not request local network permission', e);
    return false;
  }
}

/// [FORK] 原生「打开文件」的结果。
///
/// 和 boolean 相比，这四种状态各自对应一句不同的话：
/// - [opened]：已经交给系统打开了；
/// - [noApp]：手机上根本没有能打开这种格式的应用 → 提示「不支持」；
/// - [notFound]：本来有、现在找不到了 → 提示「已被移动或删除」；
/// - [failed]：其它异常（URI 不可用、启动被拒），退化成通用提示。
enum AndroidOpenResult {
  opened,
  noApp,
  notFound,
  failed,
}

AndroidOpenResult _parseOpenResult(Object? value) {
  return switch (value) {
    'opened' => AndroidOpenResult.opened,
    'noApp' => AndroidOpenResult.noApp,
    'notFound' => AndroidOpenResult.notFound,
    _ => AndroidOpenResult.failed,
  };
}

/// 打开一个 content URI，交给系统按 MIME 挑对应的应用。
///
/// [mimeType] 一定要给具体值（`image/jpeg` 而不是 `image/*`）：给通配类型时，
/// 声明了 `*/*` 的文件管理器也会进候选，很容易抢走默认打开方式。
///
/// [isDirectory] 用于「在文件管理器中显示」：打开文件夹本来就该交给文档 UI，
/// 原生侧会跳过文件管理器过滤。
Future<AndroidOpenResult> openContentUri({
  required String uri,
  String? mimeType,
  bool isDirectory = false,
}) async {
  _logger.info('Opening content URI: $uri ($mimeType)');
  try {
    final result = await _methodChannel.invokeMethod<String>('openContentUri', {
      'uri': uri,
      'mimeType': mimeType,
      'isDirectory': isDirectory,
    });
    return _parseOpenResult(result);
  } catch (e) {
    _logger.warning('Could not open content URI: $uri', e);
    return AndroidOpenResult.failed;
  }
}

/// 打开本机某个绝对路径上的文件。
///
/// 原生侧用 FileProvider 换成 content URI，和 [openContentUri] 共用同一套
/// 「按 MIME 挑对应应用、剔掉文件管理器」的逻辑。
Future<AndroidOpenResult> openFilePath({
  required String path,
  String? mimeType,
}) async {
  _logger.info('Opening file path: $path ($mimeType)');
  try {
    final result = await _methodChannel.invokeMethod<String>('openFilePath', {
      'path': path,
      'mimeType': mimeType,
    });
    return _parseOpenResult(result);
  } catch (e) {
    _logger.warning('Could not open file path: $path', e);
    return AndroidOpenResult.failed;
  }
}

/// 打开一个「只写进了系统相册」的文件。
///
/// 原生侧按文件名 / 大小 / 接收时间回查 MediaStore，拿到 content URI 后再用对应
/// 应用打开（图片→图片查看器，视频→播放器），而不是把用户丢进相册列表自己翻。
Future<AndroidOpenResult> openGalleryFile({
  String? fileName,
  required int fileSize,
  int? timestampMs,
}) async {
  _logger.info('Opening gallery file: $fileName ($fileSize bytes)');
  try {
    final result = await _methodChannel.invokeMethod<String>('openGalleryFile', {
      'fileName': fileName,
      'fileSize': fileSize,
      'timestampMs': timestampMs,
    });
    return _parseOpenResult(result);
  } catch (e) {
    _logger.warning('Could not open gallery file: $fileName', e);
    return AndroidOpenResult.failed;
  }
}

/// Tells MainActivity that the Dart side is now subscribed to the share_handler media stream,
/// so share intents that were held back during app start can be replayed.
Future<void> flushPendingShareIntentsAndroid() async {
  try {
    await _methodChannel.invokeMethod('shareIntentReady');
  } catch (e) {
    _logger.warning('Could not flush pending share intents', e);
  }
}

Future<void> openGallery() async {
  _logger.info('Opening gallery');
  await _methodChannel.invokeMethod('openGallery');
}

@MappableClass()
class PickDirectoryResult with PickDirectoryResultMappable {
  final String directoryUri;
  final List<FileInfo> files;

  PickDirectoryResult({
    required this.directoryUri,
    required this.files,
  });
}

@MappableClass()
class FileInfo with FileInfoMappable {
  final String name;
  final int size;
  final String uri;

  /// RFC 3339 in UTC. Null when the document provider does not know it.
  final String? lastModified;

  FileInfo({
    required this.name,
    required this.size,
    required this.uri,
    required this.lastModified,
  });
}
