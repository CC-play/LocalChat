import 'package:flutter/foundation.dart';
import 'package:localchat_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:logging/logging.dart';
import 'package:open_dir/open_dir.dart';
import 'package:open_filex/open_filex.dart';

final _logger = Logger('OpenFolder');

/// Opens the folder and optionally selects the file in the folder.
Future<void> openFolder({
  required String folderPath,
  String? fileName,
}) async {
  if (folderPath.startsWith('content://')) {
    // 打开的是目录：明确告诉原生侧走文档 UI，别当成文件去猜 MIME。
    await android_channel.openContentUri(uri: folderPath, isDirectory: true);
    return;
  }

  if (fileName != null && checkPlatform([TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS])) {
    // open folder and select file

    if (defaultTargetPlatform == TargetPlatform.windows) {
      folderPath = folderPath.replaceAll('/', '\\');
    }

    final result = await OpenDir().openNativeDir(path: folderPath, highlightedFileName: fileName);
    _logger.info('Open folder result: $result, path: $folderPath, file: $fileName');
  } else {
    // only open folder

    if (!folderPath.endsWith('/')) {
      folderPath = '$folderPath/';
    }

    final result = await OpenFilex.open(folderPath);
    _logger.info('Open folder result: ${result.message}, path: $folderPath');
  }
}
