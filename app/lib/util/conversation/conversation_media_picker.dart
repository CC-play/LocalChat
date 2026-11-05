import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:localchat_app/config/theme.dart';
import 'package:localchat_app/model/cross_file.dart';
import 'package:localchat_app/util/native/cross_file_converters.dart';
import 'package:localchat_app/util/ui/asset_picker_translated_text_delegate.dart';
import 'package:localchat_isolates/util/sleep.dart';
import 'package:logging/logging.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

final _logger = Logger('ConversationMediaPicker');

/// [FORK] 会话页「相册」入口：打开系统相册多选，返回可发送的文件列表。
///
/// 与 [pickConversationFiles]（系统文件选择器）并列，供输入条空态下的
/// 附件面板使用。返回 `null` 表示用户取消；选择器出错也返回 `null`（已记日志）。
///
/// 为什么不复用 `file_picker.dart` 的 `_pickMedia`：那里直接把结果派发进
/// `selectedSendingFilesProvider`（发送页的待发列表），而会话页要的是
/// 「拿到就发」，两者状态归属不同，硬复用会把会话文件塞进发送页。
Future<List<CrossFile>?> pickConversationMedia(BuildContext? context) async {
  final anchor = context;
  if (anchor == null) {
    return null;
  }

  try {
    // Android 13+ 走系统的照片选择权限；低版本仍需要读相册权限。
    if (Platform.isAndroid || Platform.isIOS) {
      await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.common,
            mediaLocation: true,
          ),
        ),
      );
    }

    if (!anchor.mounted) {
      return null;
    }

    // 相册页会自己切换系统状态栏样式（深色背景 + 浅色图标），
    // 退出后要还原，否则聊天页的标题栏图标会一直发白。
    final oldBrightness = Theme.of(anchor).brightness;
    final assets = await AssetPicker.pickAssets(
      anchor,
      pickerConfig: const AssetPickerConfig(
        maxAssets: 999,
        textDelegate: TranslatedAssetPickerTextDelegate(),
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await sleepAsync(500);
      if (anchor.mounted) {
        await updateSystemOverlayStyleWithBrightness(oldBrightness);
      }
    });

    if (assets == null || assets.isEmpty) {
      return null;
    }

    final files = <CrossFile>[];
    for (final asset in assets) {
      files.add(await CrossFileConverters.convertAssetEntity(asset));
    }
    return files;
  } catch (e) {
    _logger.warning('Failed to pick media for a conversation', e);
    return null;
  }
}
