import 'dart:io';

import 'package:path/path.dart' as p;

/// [FORK] 设置文件的落盘位置（Windows）。
///
/// 抽成纯函数是为了能测：`APPDATA` 只能从环境里读，测试没法改环境变量，
/// 所以把目录当参数传进来，跟 `buildSettingsPath` 一个路子。

/// 改名后（LocalChat）的设置文件。
String settingsPath(String appDataDir) => p.join(appDataDir, 'LocalChat', 'settings.json');

/// 改名前（LocalSend 时期）的设置文件。
///
/// 只用于把老数据搬到新目录；[settingsPath] 一旦存在就不再读这里。
String preRenameSettingsPath(String appDataDir) => p.join(appDataDir, 'LocalSend', 'settings.json');

/// 上古位置：LocalSend v1 时代 `shared_preferences` 插件自己选的目录。
String legacySettingsPath(String appDataDir) =>
    p.join(appDataDir, 'org.localsend', 'localsend_app', 'shared_preferences.json');

/// 把改名前的设置文件搬到新目录，返回是否真的搬了。
///
/// 三个行为要点（都有测试盯着）：
/// - **搬动而非复制**：两份配置同时存在迟早互相打架。
/// - 新位置已有设置就不动它：用户可能两个版本都跑过，以新版为准。
/// - 旧文件不存在时什么都不做，也别顺手建空目录。
bool migratePreRenameSettings({required String appDataDir}) {
  final oldFile = File(preRenameSettingsPath(appDataDir));
  if (!oldFile.existsSync()) {
    return false;
  }

  final newFile = File(settingsPath(appDataDir));
  if (newFile.existsSync()) {
    return false;
  }

  newFile.parent.createSync(recursive: true);
  oldFile.renameSync(newFile.path);
  return true;
}
