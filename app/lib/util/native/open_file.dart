import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/widget/chat/top_toast.dart';
import 'package:localchat_app/widget/dialogs/cannot_open_file_dialog.dart';
import 'package:localchat_isolates/model/file_type.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

/// Opens the selected file which is stored on the device.
Future<void> openFile(
  BuildContext context,
  FileType fileType,
  String filePath, {
  void Function()? onDeleteTap,
}) async {
  if ((fileType == FileType.apk || filePath.toLowerCase().endsWith('.apk')) && checkPlatform([TargetPlatform.android])) {
    await Permission.requestInstallPackages.request();
  }

  // [FORK] Android：统一按 MIME 交给「对应的应用」打开。
  //
  // 以前 content URI 走原生打开器时，MIME 是按 URI 末尾的扩展名猜的，而
  // `content://media/external/images/media/123` 这类 URI 根本没有扩展名，猜不出来
  // 就兜底成「目录」类型，系统便把请求交给了文档 UI / 文件管理器 —— 点了图片跳进
  // 文件管理器就是这个原因。现在 MIME 由扩展名 + `ContentResolver` 决定，原生侧还会
  // 把文件管理器从候选里剔除，并且把「没有应用能打开」明确回传上来。
  if (checkPlatform([TargetPlatform.android])) {
    final mimeType = _mimeTypeOf(filePath);
    final isContentUri = filePath.startsWith('content://');
    var result = isContentUri
        ? await android_channel.openContentUri(uri: filePath, mimeType: mimeType)
        : await android_channel.openFilePath(path: filePath, mimeType: mimeType);

    // 原生侧生成 FileProvider URI 失败（路径不在 provider 允许的范围内等）时，
    // 退回第三方打开器 —— 它至少不会比改动之前更差。
    if (result == android_channel.AndroidOpenResult.failed && !isContentUri) {
      result = _fromOpenFilex(await OpenFilex.open(filePath, type: mimeType));
    }

    if (result != android_channel.AndroidOpenResult.opened && context.mounted) {
      TopToast.show(
        context,
        switch (result) {
          android_channel.AndroidOpenResult.notFound => t.conversation.fileMovedOrDeleted,
          // noApp / failed 对用户是同一件事：这台手机打不开它。
          _ => t.conversation.noAppForFile,
        },
      );
    }
    return;
  }

  // [FORK] 桌面端先把「文件已经不在了」拦下来。
  //
  // 直接把不存在的路径丢给系统打开器时，Windows 的 ShellExecute 会先弹一个
  // 系统级模态框「Windows 找不到文件」—— 它不属于 App、样式不受主题控制、
  // 还挡在 App 前面。这里提前判一次，改由 App 自己提示。
  //
  // 提示方式刻意用顶部 toast 而不是对话框：文件不见了是「点一下才知道」的
  // 轻量信息，弹框还得再点一次「关闭」才能继续，反而打断聊天。
  //
  // 两条限制：
  // - 只对桌面端生效。Android 的绝对路径可能落在 scoped storage 里，
  //   `exists()` 会因权限不足误报 false，反而把能打开的文件挡掉。
  // - 只判绝对路径。`file://` 这类 URI 交给 OpenFilex 自己处理，
  //   `File()` 对它们只会返回 false。
  if (checkPlatformIsDesktop() && p.isAbsolute(filePath) && !await File(filePath).exists()) {
    if (context.mounted) {
      TopToast.show(context, t.conversation.fileMovedOrDeleted);
    }
    return;
  }

  final fileOpenResult = await OpenFilex.open(filePath);
  if (fileOpenResult.type != ResultType.done && context.mounted) {
    await CannotOpenFileDialog.open(context, filePath, onDeleteTap);
  }
}

/// 交给打开器的 MIME 类型。
///
/// `content://` 的末段是数字 id，提取不出扩展名，返回 null 让原生侧去问
/// `ContentResolver`（它才是这类 URI 的权威来源）。
String? _mimeTypeOf(String filePath) {
  if (filePath.startsWith('content://')) {
    return lookupMimeType(filePath);
  }
  return lookupMimeType(p.basename(filePath));
}

android_channel.AndroidOpenResult _fromOpenFilex(OpenResult result) {
  return switch (result.type) {
    ResultType.done => android_channel.AndroidOpenResult.opened,
    ResultType.noAppToOpen => android_channel.AndroidOpenResult.noApp,
    ResultType.fileNotFound => android_channel.AndroidOpenResult.notFound,
    ResultType.permissionDenied || ResultType.error => android_channel.AndroidOpenResult.failed,
  };
}
