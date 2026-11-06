import 'package:localchat_app/model/conversation/conversation.dart';

/// [FORK] 会话标题的「重名消歧」辅助。
///
/// 为什么需要：会话主键是证书指纹，显示名（alias）只是对端自报的一个字符串。
/// 两台设备可以合法地叫同一个名字（都叫 `vivo`，或者 A 干脆改成了 B 的名字），
/// 这时列表里会出现两行一模一样的标题，点进去也分不清是谁。
///
/// 解法：**只在重名时**在名字后面追加指纹短码（`B · 3F7A`）。平时零噪音，
/// 而指纹不会像 IP 那样随 DHCP 变化，也不受对方改名影响，是唯一稳定的区分依据。

/// 短码长度：4 位十六进制 = 65536 种组合，局域网内几十台设备碰撞概率可忽略。
const int peerShortCodeLength = 4;

/// 取会话主键的末 [peerShortCodeLength] 位作为区分码。
///
/// 正常是 64 位十六进制的证书指纹，取末 4 位即可（与设备详情页显示的完整指纹
/// 对得上尾巴）。拿不到指纹的对端会退化成 `alias:<名字>` 伪键，这种键不可能是
/// 十六进制，此时保留尾部原字符，避免把字母剔干净后出现残码。
String peerShortCode(String peerKey) {
  if (peerKey.isEmpty) {
    return '';
  }
  final isHex = RegExp(r'^[0-9A-Fa-f]{8,}$').hasMatch(peerKey);
  if (!isHex) {
    return peerKey.length <= peerShortCodeLength
        ? peerKey
        : peerKey.substring(peerKey.length - peerShortCodeLength);
  }
  final start = peerKey.length - peerShortCodeLength;
  return peerKey.substring(start < 0 ? 0 : start).toUpperCase();
}

/// 统计每个显示名出现了几次，用于判断哪些会话需要消歧。
Map<String, int> peerNameCounts(Iterable<Conversation> conversations) {
  final counts = <String, int>{};
  for (final conversation in conversations) {
    final name = conversation.displayName;
    counts[name] = (counts[name] ?? 0) + 1;
  }
  return counts;
}

/// 该会话是否与同一列表里的其它会话同名。
///
/// 注意排除自己：判断依据是主键，不是对象引用 —— 会话是不可变对象，
/// 每次追加消息都会重建，拿 `identical` 判断会漏。
bool peerNameCollides(Conversation target, Map<String, int> counts) {
  if (target.displayName.isEmpty) {
    return false;
  }
  return (counts[target.displayName] ?? 0) > 1;
}

/// 纯文本形式的标题（重名时带短码），供只能用字符串的地方使用，
/// 例如删除会话的确认文案。
String peerLabel(Conversation conversation, {bool ambiguous = false}) {
  if (!ambiguous) {
    return conversation.displayName;
  }
  return '${conversation.displayName} · ${peerShortCode(conversation.peerFingerprint)}';
}
