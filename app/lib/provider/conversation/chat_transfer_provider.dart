import 'package:flutter/foundation.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// [FORK] 聊天视图的「上传进度」旁路。
///
/// 为什么不把进度写进 [ChatMessage]：会话状态每次变更都要整份序列化写盘
/// （见 `ConversationService` 里的 `setConversations`），而上传进度每秒会来
/// 好几次，几百条消息的会话会被高频全量写盘拖垮。上游的 `fileTransferProvider`
/// 出于同样的理由用 `ChangeNotifier` 而不是 provider 状态。
///
/// 这里再细一层：**每条消息一个 [ValueNotifier]**，进度变化只重建那一条气泡，
/// 不会像单一 notifier 那样惊动整页所有气泡。
///
/// 键是 `messageId`。聊天场景里消息 id 与上传使用的 fileId 是同一个值
/// （`ConversationSender` 里刻意复用），所以 `sendProvider` 拿到 upload 事件后
/// 可以直接按 fileId 回报进度。
final chatTransferProvider = Provider<ChatTransferNotifier>((ref) => ChatTransferNotifier());

/// [FORK] 一条聊天消息当前处在发送流程的哪一段。
///
/// 分段的意义：这四段的时间量级差两个数量级（校验几十秒、连接几十毫秒、
/// 等对方接受最多两分钟、上传十几分钟），合成一句「发送中」之后，用户
/// 无法判断到底是在正常干活还是已经卡死，也就无法决定要不要取消。
enum ChatTransferPhase {
  /// 正在本地读盘算 SHA-256。不占网络，慢只该慢自己。
  hashing,

  /// 正在连接对端；连接被拒后也会停在这里（表示「对方还没接上」）。
  connecting,

  /// 请求已送达，等对方点「接受」。这才是真正意义上的「等」。
  waitingAccept,

  /// 对方已接受，正在上传字节。
  uploading,
}

class ChatTransferNotifier {
  /// messageId -> 进度（0..1）。条目只在「确实有一条气泡在等这个进度」时存在。
  final _progress = <String, ValueNotifier<double?>>{};

  /// messageId -> 当前阶段。与 [_progress] 同样是**每条消息一个** notifier，
  /// 阶段变化只重建那一条气泡的页脚。
  final _phase = <String, ValueNotifier<ChatTransferPhase?>>{};

  /// messageId -> 最后一次收到进度事件的时间。
  ///
  /// 与 [_progress] 不同，这里**无条件**记录：上传看门狗需要在「用户根本没打开
  /// 会话页、没有气泡在等」的情况下也能判断传输是否还活着。少了它，看门狗会
  /// 把后台正常传输的大文件误判成停滞。
  final _lastProgressAt = <String, DateTime>{};

  /// 聊天气泡订阅入口。
  ///
  /// 惰性创建：气泡第一次渲染时登记，之后 [report] 才有地方可写。
  /// 同一 id 永远返回同一个实例，`ValueListenableBuilder` 才能稳定订阅。
  ValueListenable<double?> progressOf(String messageId) {
    return _progress.putIfAbsent(messageId, () => ValueNotifier<double?>(null));
  }

  /// 气泡订阅阶段变化的入口，惰性创建。
  ValueListenable<ChatTransferPhase?> phaseOf(String messageId) {
    return _phase.putIfAbsent(messageId, () => ValueNotifier<ChatTransferPhase?>(null));
  }

  /// 切换某条消息所在的阶段。
  ///
  /// 这里**无条件**建 notifier（与 [report] 不同）：用户可能中途切走再回到会话页，
  /// 气泡重新订阅时必须还能读到当前阶段，否则会退回「发送中」这句废话。
  /// 只有聊天发送流程会调它，数量就是正在发的那几条，不会失控。
  void setPhase(String messageId, ChatTransferPhase? phase) {
    final notifier = _phase.putIfAbsent(messageId, () => ValueNotifier<ChatTransferPhase?>(null));
    if (notifier.value == phase) {
      return;
    }
    notifier.value = phase;
  }

  /// 最后一次进度事件的时间；从未有过进度时返回 null。
  DateTime? lastProgressOf(String messageId) => _lastProgressAt[messageId];

  /// 回报上传进度。
  ///
  /// 没有气泡在等（例如这是「发送文件」页发出去的，不是聊天消息）就只更新时间戳，
  /// 不建 [ValueNotifier]，避免给每个普通传输都留一个没人用的对象。
  void report({required String messageId, required double progress}) {
    _lastProgressAt[messageId] = DateTime.now();

    final notifier = _progress[messageId];
    if (notifier == null) {
      return;
    }

    final value = progress.clamp(0.0, 1.0);
    final current = notifier.value;
    // 每 0.5% 才刷一次：上传事件按块回报，1GB 的文件会有上千次，
    // 逐次重绘没有意义，反而把 raster 线程压满。允许回退（重发会从 0 重来）。
    if (current != null && value > current && value < 1 && value - current < 0.005) {
      return;
    }
    notifier.value = value;
  }

  /// 传输结束（成功 / 失败）：整条移除。
  ///
  /// 不做 `dispose`：气泡可能还在同一帧里挂着监听，dispose 过的 notifier
  /// 再加监听会抛错。移除引用即可，剩下的交给 GC。
  void finish(String messageId) {
    _progress.remove(messageId);
    _lastProgressAt.remove(messageId);
    // 终态之后页脚不再渲染，阶段表也不需要再留着。
    _phase.remove(messageId);
  }

  /// 重发前复位，否则新的一轮会先闪一下上一轮的 100%。
  void reset(String messageId) {
    _progress[messageId]?.value = null;
    _lastProgressAt.remove(messageId);
    _phase[messageId]?.value = null;
  }
}
