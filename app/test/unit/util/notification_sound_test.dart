import 'package:localchat_app/util/native/notification_sound.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime(2026, 11, 9, 12);

  group('提示音 · 消息', () {
    test('关闭时不响', () {
      final gate = NotificationSoundGate();
      expect(gate.allowMessage(enabled: false, mobileInBackground: false, now: t0), isFalse);
    });

    test('手机在后台不响（那一声由系统通知负责）', () {
      final gate = NotificationSoundGate();
      expect(gate.allowMessage(enabled: true, mobileInBackground: true, now: t0), isFalse);
    });

    test('第一次响，合并窗口内再来的消息不响', () {
      final gate = NotificationSoundGate(mergeWindow: const Duration(milliseconds: 600));
      expect(gate.allowMessage(enabled: true, mobileInBackground: false, now: t0), isTrue);
      // 500ms 后来第二条：第一声还没播完，不能把播放重置成半声
      expect(
        gate.allowMessage(enabled: true, mobileInBackground: false, now: t0.add(const Duration(milliseconds: 500))),
        isFalse,
      );
    });

    test('过了合并窗口又能响', () {
      final gate = NotificationSoundGate(mergeWindow: const Duration(milliseconds: 600));
      expect(gate.allowMessage(enabled: true, mobileInBackground: false, now: t0), isTrue);
      expect(
        gate.allowMessage(enabled: true, mobileInBackground: false, now: t0.add(const Duration(milliseconds: 601))),
        isTrue,
      );
    });
  });

  group('提示音 · 文件', () {
    test('关闭时不响', () {
      final gate = NotificationSoundGate();
      expect(gate.allowFile(enabled: false, sessionId: 'session-1'), isFalse);
    });

    test('同一个会话只响一次（请求一次 + 每个文件落盘都会调用）', () {
      final gate = NotificationSoundGate();
      expect(gate.allowFile(enabled: true, sessionId: 'session-1'), isTrue);
      // 同一个会话的第二个文件
      expect(gate.allowFile(enabled: true, sessionId: 'session-1'), isFalse);
      // 手动接受时「请求」已经响过，落盘完成这一处要被挡住
      expect(gate.allowFile(enabled: true, sessionId: 'session-1'), isFalse);
    });

    test('不同会话互不影响', () {
      final gate = NotificationSoundGate();
      expect(gate.allowFile(enabled: true, sessionId: 'session-1'), isTrue);
      expect(gate.allowFile(enabled: true, sessionId: 'session-2'), isTrue);
    });
  });
}
