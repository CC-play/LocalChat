import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/conversation/chat_transfer_provider.dart';

void main() {
  group('ChatTransferNotifier', () {
    test('没有气泡登记时 report 不创建条目', () {
      final notifier = ChatTransferNotifier();

      notifier.report(messageId: 'm1', progress: 0.5);

      // 之后才登记：拿到的应该是初始 null，而不是被之前的进度污染。
      expect(notifier.progressOf('m1').value, isNull);
    });

    test('登记之后能收到进度', () {
      final notifier = ChatTransferNotifier();
      final listenable = notifier.progressOf('m1');

      notifier.report(messageId: 'm1', progress: 0.42);

      expect(listenable.value, closeTo(0.42, 1e-9));
    });

    test('同一 id 永远返回同一个实例，订阅才稳定', () {
      final notifier = ChatTransferNotifier();

      expect(identical(notifier.progressOf('m1'), notifier.progressOf('m1')), isTrue);
    });

    test('小于 0.5% 的增量被忽略，避免每个上传分块都重绘', () {
      final notifier = ChatTransferNotifier();
      final listenable = notifier.progressOf('m1');

      notifier.report(messageId: 'm1', progress: 0.2);
      var notified = 0;
      listenable.addListener(() => notified++);

      notifier.report(messageId: 'm1', progress: 0.201);
      notifier.report(messageId: 'm1', progress: 0.202);
      expect(notified, 0);

      notifier.report(messageId: 'm1', progress: 0.21);
      expect(notified, 1);
    });

    test('允许进度回退（重发会从 0 重来）', () {
      final notifier = ChatTransferNotifier();
      final listenable = notifier.progressOf('m1');

      notifier.report(messageId: 'm1', progress: 0.8);
      notifier.report(messageId: 'm1', progress: 0.01);

      expect(listenable.value, closeTo(0.01, 1e-9));
    });

    test('越界的进度会被夹到 [0, 1]', () {
      final notifier = ChatTransferNotifier();
      final listenable = notifier.progressOf('m1');

      notifier.report(messageId: 'm1', progress: 1.7);
      expect(listenable.value, 1.0);

      notifier.report(messageId: 'm1', progress: -3);
      expect(listenable.value, 0.0);
    });

    test('finish 之后不再接受进度', () {
      final notifier = ChatTransferNotifier();
      final listenable = notifier.progressOf('m1');
      notifier.report(messageId: 'm1', progress: 0.3);

      notifier.finish('m1');
      notifier.report(messageId: 'm1', progress: 0.9);

      expect(listenable.value, closeTo(0.3, 1e-9));
      // 清理过再登记是全新的一条，不该带着上一轮的进度。
      expect(notifier.progressOf('m1').value, isNull);
    });

    test('reset 把进度清空但不销毁订阅', () {
      final notifier = ChatTransferNotifier();
      final listenable = notifier.progressOf('m1');
      notifier.report(messageId: 'm1', progress: 1);

      notifier.reset('m1');

      expect(listenable.value, isNull);
      expect(identical(notifier.progressOf('m1'), listenable), isTrue);
    });
  });
}
