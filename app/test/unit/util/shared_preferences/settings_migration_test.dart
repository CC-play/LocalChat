import 'dart:io';

import 'package:localchat_app/util/shared_preferences/settings_migration.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('localchat_settings_migration_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 造一份「改名前的设置」，内容用 JSON 片段当指纹，方便断言搬的是同一份。
  File writePreRenameSettings(String content) {
    final file = File(preRenameSettingsPath(tempDir.path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  test('搬到新目录，且旧文件不留在原处', () {
    final oldFile = writePreRenameSettings('{"ls_conversations":"[1,2,3]"}');

    expect(migratePreRenameSettings(appDataDir: tempDir.path), isTrue);

    expect(oldFile.existsSync(), isFalse, reason: '搬动而非复制，否则两份配置会互相打架');
    expect(File(settingsPath(tempDir.path)).readAsStringSync(), '{"ls_conversations":"[1,2,3]"}');
  });

  test('新位置已有设置时不覆盖，旧文件原样保留', () {
    final oldFile = writePreRenameSettings('{"source":"old"}');
    final newFile = File(settingsPath(tempDir.path));
    newFile.parent.createSync(recursive: true);
    newFile.writeAsStringSync('{"source":"new"}');

    expect(migratePreRenameSettings(appDataDir: tempDir.path), isFalse);

    expect(newFile.readAsStringSync(), '{"source":"new"}', reason: '两个版本都跑过时以新版为准');
    expect(oldFile.readAsStringSync(), '{"source":"old"}');
  });

  test('新旧都没有时什么都不做，也不顺手建目录', () {
    expect(migratePreRenameSettings(appDataDir: tempDir.path), isFalse);

    expect(File(settingsPath(tempDir.path)).existsSync(), isFalse);
    expect(
      Directory(tempDir.path).listSync(),
      isEmpty,
      reason: '首次启动不该因为迁移多出一个空目录',
    );
  });

  test('新目录已存在但文件不在时，仍然照搬', () {
    final oldFile = writePreRenameSettings('{"ls_conversations":"[]"}');
    Directory(File(settingsPath(tempDir.path)).parent.path).createSync(recursive: true);

    expect(migratePreRenameSettings(appDataDir: tempDir.path), isTrue);

    expect(oldFile.existsSync(), isFalse);
    expect(File(settingsPath(tempDir.path)).existsSync(), isTrue);
  });

  test('路径全部落在 appDataDir 之下，不会写到真实 %APPDATA%', () {
    for (final path in [settingsPath(tempDir.path), preRenameSettingsPath(tempDir.path), legacySettingsPath(tempDir.path)]) {
      expect(path.startsWith(tempDir.path), isTrue, reason: path);
    }
  });
}
