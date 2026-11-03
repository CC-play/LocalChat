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

class ChatTransferNotifier {
  /// messageId -> 进度（0..1）。条目只在「确实有一条气泡在等这个进度」时存在。
  final _progress = <String, ValueNotifier<double?>>{};

  /// 聊天气泡订阅入口。
  ///
  /// 惰性创建：气泡第一次渲染时登记，之后 [report] 才有地方可写。
  /// 同一 id 永远返回同一个实例，`ValueListenableBuilder` 才能稳定订阅。
  ValueListenable<double?> progressOf(String messageId) {
    return _progress.putIfAbsent(messageId, () => ValueNotifier<double?>(null));
  }

  /// 回报上传进度。
  ///
  /// 没有气泡在等（例如这是「发送文件」页发出去的，不是聊天消息）就直接丢弃，
  /// 避免给每个普通传输都建一个没人用的 [ValueNotifier]。
  void report({required String messageId, required double progress}) {
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
  }

  /// 重发前复位，否则新的一轮会先闪一下上一轮的 100%。
  void reset(String messageId) {
    _progress[messageId]?.value = null;
  }
}
