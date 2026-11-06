import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_app/util/conversation/peer_label.dart';
import 'package:test/test.dart';

Conversation _conversation({
  required String fingerprint,
  required String alias,
}) {
  return Conversation(
    peerFingerprint: fingerprint,
    peerAlias: alias,
    lastActivity: DateTime(2026, 11, 6),
    unreadCount: 0,
    messages: const [],
  );
}

void main() {
  group('peerShortCode', () {
    test('取指纹末 4 位并转大写', () {
      final fingerprint = '${'A1B2C3D4' * 7}0f3a';
      expect(peerShortCode(fingerprint), '0F3A');
    });

    test('长度不足 4 位的十六进制键不会越界', () {
      expect(peerShortCode('AB'), 'AB');
    });

    test('空键返回空串', () {
      expect(peerShortCode(''), '');
    });

    test('非十六进制的退化键保留尾部原字符', () {
      // 拿不到指纹的对端会退化成 alias:<名字>，这里不能把字母剔掉留下残码。
      expect(peerShortCode('alias:phone'), 'hone');
    });

    test('同一个指纹永远得到同一个短码', () {
      final fingerprint = 'F' * 60 + '1a2b';
      expect(peerShortCode(fingerprint), peerShortCode(fingerprint));
    });
  });

  group('peerNameCounts / peerNameCollides', () {
    test('不同名时不算重名', () {
      final a = _conversation(fingerprint: 'A' * 64, alias: 'Alice');
      final b = _conversation(fingerprint: 'B' * 64, alias: 'Bob');
      final counts = peerNameCounts([a, b]);

      expect(peerNameCollides(a, counts), isFalse);
      expect(peerNameCollides(b, counts), isFalse);
    });

    test('同名时两台都算重名（A 把名字改成 B 的场景）', () {
      final a = _conversation(fingerprint: 'A' * 64, alias: 'Bob');
      final b = _conversation(fingerprint: 'B' * 64, alias: 'Bob');
      final counts = peerNameCounts([a, b]);

      expect(peerNameCollides(a, counts), isTrue);
      expect(peerNameCollides(b, counts), isTrue);
    });

    test('空名字不参与消歧', () {
      final a = _conversation(fingerprint: 'A' * 64, alias: '');
      final b = _conversation(fingerprint: 'B' * 64, alias: '');
      final counts = peerNameCounts([a, b]);

      expect(peerNameCollides(a, counts), isFalse);
    });

    test('会话对象的引用变化不影响判定（不可变对象每次重建）', () {
      final a = _conversation(fingerprint: 'A' * 64, alias: 'Bob');
      final b = _conversation(fingerprint: 'B' * 64, alias: 'Bob');
      final counts = peerNameCounts([a, b]);
      final aRebuilt = _conversation(fingerprint: 'A' * 64, alias: 'Bob');

      expect(peerNameCollides(aRebuilt, counts), isTrue);
    });
  });

  group('peerLabel', () {
    test('不重名时就是显示名', () {
      final a = _conversation(fingerprint: 'A' * 60 + '1a2b', alias: 'Alice');
      expect(peerLabel(a), 'Alice');
    });

    test('重名时带短码，供删除确认框这类纯文本场景使用', () {
      final a = _conversation(fingerprint: 'A' * 60 + '1a2b', alias: 'Bob');
      expect(peerLabel(a, ambiguous: true), 'Bob · 1A2B');
    });
  });
}
