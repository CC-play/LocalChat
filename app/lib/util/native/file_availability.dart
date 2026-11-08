import 'dart:io';

import 'package:localchat_app/util/native/platform_check.dart';
import 'package:path/path.dart' as p;

/// [FORK] 本机是否还有这个路径对应的文件。
///
/// 会话里的文件卡片、右键菜单的「打开文件所在位置」都靠它判断「这个文件还在不在」，
/// 规则必须只有一处，否则会出现「卡片说丢了、菜单还能点」这种自相矛盾。
///
/// 三条约定：
/// - `null` / 空串直接算不存在：这条消息本来就没有本地副本（例如接收时只存进了相册）。
/// - **只在桌面端判断**。Android 的绝对路径可能落在 scoped storage 里，`exists()`
///   会因权限不足误报 false，宁可说「有」也不能把能打开的文件说成丢了。
/// - **只判绝对路径**。`content://` 这类 URI 不归 `File` 管，`exists()` 对它只会
///   返回 false；不确定的情况一律按「有」处理。
Future<bool> localFileExists(String? path) async {
  if (path == null || path.isEmpty) {
    return false;
  }
  if (!checkPlatformIsDesktop() || !p.isAbsolute(path)) {
    return true;
  }
  return File(path).exists();
}
