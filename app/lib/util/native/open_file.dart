import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/widget/chat/top_toast.dart';
import 'package:localchat_app/widget/dialogs/cannot_open_file_dialog.dart';
import 'package:localchat_isolates/model/file_type.dart';
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

  if (filePath.startsWith('content://')) {
    await android_channel.openContentUri(uri: filePath);
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
