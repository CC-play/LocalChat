import 'package:localchat_app/util/conversation/clipboard_image.dart';
import 'package:test/test.dart';

void main() {
  group('ClipboardImage.fileName', () {
    test('keeps png for png payloads', () {
      expect(
        ClipboardImage.fileName('image/png', DateTime(2026, 11, 3, 11, 30, 45)),
        'clipboard-20261103-113045.png',
      );
    });

    test('shortens image/jpeg to .jpg', () {
      expect(
        ClipboardImage.fileName('image/jpeg', DateTime(2026, 1, 2, 3, 4, 5)),
        'clipboard-20260102-030405.jpg',
      );
    });

    test('falls back to png for unknown types', () {
      expect(
        ClipboardImage.fileName('application/octet-stream', DateTime(2026, 11, 3)),
        'clipboard-20261103-000000.png',
      );
    });

    test('is case insensitive', () {
      expect(
        ClipboardImage.fileName('IMAGE/WEBP', DateTime(2026, 12, 31, 23, 59, 59)),
        'clipboard-20261231-235959.webp',
      );
    });
  });

  group('ClipboardFiles.cacheFileName', () {
    test('keeps the original name so the bubble is recognizable', () {
      expect(
        ClipboardFiles.cacheFileName('holiday.JPG', 'image/jpeg', DateTime(2026, 11, 3, 11, 30, 45)),
        'clipboard-20261103-113045-holiday.JPG',
      );
    });

    test('strips directories to avoid escaping the cache folder', () {
      expect(
        ClipboardFiles.cacheFileName(r'C:\Users\me\Desktop\a.png', 'image/png', DateTime(2026, 11, 3)),
        'clipboard-20261103-000000-a.png',
      );
      expect(
        ClipboardFiles.cacheFileName('/home/me/a.png', 'image/png', DateTime(2026, 11, 3)),
        'clipboard-20261103-000000-a.png',
      );
    });

    test('replaces characters that are illegal on Windows', () {
      expect(
        ClipboardFiles.cacheFileName('a<b>c:d"e|f?g*h.png', 'image/png', DateTime(2026, 11, 3)),
        'clipboard-20261103-000000-a_b_c_d_e_f_g_h.png',
      );
    });

    test('drops trailing dots and spaces', () {
      expect(
        ClipboardFiles.cacheFileName('report. ', 'text/plain', DateTime(2026, 11, 3)),
        'clipboard-20261103-000000-report',
      );
    });

    test('falls back to a generated name when nothing is left', () {
      expect(
        ClipboardFiles.cacheFileName('...', 'image/png', DateTime(2026, 11, 3)),
        'clipboard-20261103-000000.png',
      );
    });
  });
}
