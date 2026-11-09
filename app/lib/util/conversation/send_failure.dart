import 'dart:async';

import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_isolates/model/session_status.dart';
import 'package:localchat_isolates/rust/api/http.dart' as rust_http;

/// [FORK] 整个文件为 fork 新增。上游没有聊天层，自然也没有「一条消息为什么没发出去」
/// 这套分类。
///
/// 一次发送失败的原因，由 [describeSendFailure] 翻译成文案。
///
/// 每个取值都必须对应一种**用户能据此采取行动**的情况。原来的六类过于笼统：
/// 「连不上」「连上了但对方没反应」「对方看到了但没点接受」「对方空间满了」
/// 全落到同一个 `unknown`，气泡只能显示「发送失败」——这正是 2026-11-08
/// 那次 30 GB 传输看不出问题在哪的原因。
///
/// 放在这里而不是发送流程里：发送页、聊天页、以及 `send_provider` 给气泡
/// 收尾时都要用同一套分类，放进 `conversation_sender.dart` 会形成循环依赖
/// （它本身要 import `send_provider`）。
enum SendFailure {
  /// 用户自己点了取消。
  cancelled,

  /// 对方点了拒绝（HTTP 403）。
  peerDeclined,

  /// 对方正在与另一台设备传输（HTTP 409）。
  peerBusy,

  /// 对方短时间内拒绝了太多次，被限流（HTTP 429）。
  peerRateLimited,

  /// 对方关掉了接收窗口，一个文件都没选中（HTTP 204）。
  peerDismissed,

  /// 连不上：端口拒绝连接，或主机不可达。最常见的原因是对方 App 没在运行。
  peerOffline,

  /// TCP 连上了，但对方一个字节都没回：TLS / HTTP 都没有应答。
  ///
  /// Android 把后台进程冻结之后就是这样——内核仍替它接住连接，
  /// 进程却没被调度，于是既不回 ServerHello，也不 RST。
  peerNoResponse,

  /// 请求已经送达，但对方在等待窗口内没有点「接受」。
  ///
  /// 与 [peerNoResponse] 的区别靠超时后的复检来判定：能重新握上手
  /// 说明对端进程活着，只是没人操作；连握手都超时才是被冻结。
  acceptTimeout,

  /// 对方在传输途中主动中断（关掉接收页 / 取消了这次传输）。
  peerAborted,

  /// 对方的连接密码（PIN）不正确，或用户取消了密码输入。
  authRejected,

  /// TLS 证书 / 指纹校验失败：对端可能重装过，或链路上有中间人。
  tlsMismatch,

  /// 本机网络异常：Wi-Fi 断开、DNS 失败、路由不可达。
  localNetwork,

  /// 对方磁盘空间不足。
  receiverStorageFull,

  /// 对方写盘失败，或返回了 5xx。
  receiverError,

  /// 对方收到的字节与校验和不一致。
  checksumMismatch,

  /// 传输中途断开，或长时间没有任何进展。
  uploadInterrupted,

  /// 重发时原文件已经不在了（被移动 / 删除，或缓存目录被系统清理）。
  fileMissing,

  /// 其它错误。兜底的兜底：真正分类不出来时才用它。
  unknown,
}

/// 把 HTTP 状态码翻译成失败原因。
///
/// 401 只在「对端设了 PIN」时出现，密码错或用户关掉了输入框都算这一类。
SendFailure failureForStatusCode(int status) {
  return switch (status) {
    401 => SendFailure.authRejected,
    403 => SendFailure.peerDeclined,
    409 => SendFailure.peerBusy,
    429 => SendFailure.peerRateLimited,
    >= 400 => SendFailure.receiverError,
    _ => SendFailure.unknown,
  };
}

/// 从错误文本里猜失败原因，认不出来返回 `null`。
///
/// Rust 侧把 `reqwest` / `io::Error` 的原文透传了上来，这些字串在
/// Windows 和 Android 上都很稳定：
/// - `Connection refused (os error 10061)` / `errno 111` → 端口没有监听者；
/// - `invalid peer certificate` / `handshake failure` → 证书；
/// - `No space left on device` → 对端空间不足；
/// - `Checksum mismatch` → 对端校验不一致（`save.rs` 里写死的文案）。
///
/// 关键词顺序有讲究：先判具体原因，再判「超时」这种兜底大类。
SendFailure? classifySendErrorText(String? text) {
  if (text == null || text.isEmpty) {
    return null;
  }
  final s = text.toLowerCase();
  bool has(List<String> keys) => keys.any(s.contains);

  if (has(const ['no space left', 'enospc', 'not enough space', 'disk quota'])) {
    return SendFailure.receiverStorageFull;
  }
  if (has(const ['checksum', 'hash mismatch'])) {
    return SendFailure.checksumMismatch;
  }
  if (has(const ['certificate', 'unknownissuer', 'invalid peer', 'handshake', 'fingerprint', 'bad_ssl'])) {
    return SendFailure.tlsMismatch;
  }
  if (has(const ['invalid pin', 'wrong pin', 'unauthorized'])) {
    return SendFailure.authRejected;
  }
  if (has(const ['connection refused', 'os error 10061', 'actively refused', 'no route to host', 'host unreachable', 'errno 111'])) {
    return SendFailure.peerOffline;
  }
  if (has(const [
    'network is unreachable',
    'network unreachable',
    'name resolution',
    'nodename nor servname',
    'dns error',
    'failed to lookup address',
  ])) {
    return SendFailure.localNetwork;
  }
  if (has(const ['timed out', 'timeout', 'deadline'])) {
    return SendFailure.peerNoResponse;
  }
  if (has(const ['connection reset', 'reset by peer', 'broken pipe', 'unexpected eof', 'early eof', 'connection closed', 'channel closed'])) {
    return SendFailure.uploadInterrupted;
  }
  return null;
}

/// 把一次异常翻译成失败原因。
///
/// 结构化类型优先（状态码、JSON 解析失败是确定的），其次看错误文本。
SendFailure classifySendError(Object? error) {
  if (error is rust_http.RsHttpClientError_StatusCode) {
    return failureForStatusCode(error.status);
  }
  if (error is rust_http.RsHttpClientError_Reqwest) {
    return classifySendErrorText(error.field0) ?? SendFailure.unknown;
  }
  if (error is rust_http.RsHttpClientError_Io) {
    return classifySendErrorText(error.field0) ?? SendFailure.unknown;
  }
  if (error is rust_http.RsHttpClientError_Other) {
    return classifySendErrorText(error.field0) ?? SendFailure.unknown;
  }
  if (error is rust_http.RsHttpClientError_Json) {
    // 对端回了一段读不懂的 JSON：协议层面对不上，多半是版本差异，或者它写盘前就崩了。
    return SendFailure.receiverError;
  }
  if (error is TimeoutException) {
    return SendFailure.peerNoResponse;
  }
  return SendFailure.unknown;
}

/// 会话结束时的状态 → 失败原因。`null` 表示「这个状态没有失败可言」。
///
/// [errorMessage] 是对端或 Rust 侧留下的原文，只在 [SessionStatus.finishedWithErrors]
/// 这类「什么都没说清楚」的状态下用来进一步细分。
SendFailure? sendFailureOfStatus(SessionStatus status, {String? errorMessage}) {
  switch (status) {
    case SessionStatus.finished:
      // 成功结束时调用方根本读不到这条状态（会话已被收掉）；真走到这里
      // 说明对端回的是 204——但 204 的会话同样会被立刻收掉，所以
      // 真正的「一个都没选中」由调用方按 `session == null` 判定。
      return null;
    case SessionStatus.declined:
      return SendFailure.peerDeclined;
    case SessionStatus.recipientBusy:
      return SendFailure.peerBusy;
    case SessionStatus.tooManyAttempts:
      return SendFailure.peerRateLimited;
    case SessionStatus.canceledBySender:
      return SendFailure.cancelled;
    case SessionStatus.canceledByReceiver:
      return SendFailure.peerAborted;
    case SessionStatus.finishedWithErrors:
    case SessionStatus.sending:
    case SessionStatus.waiting:
      // 还在途中、或者什么都没说清楚：尽力从原文里认一个。
      return classifySendErrorText(errorMessage);
  }
}

/// 把一段错误原文翻译成可读文案：认得出就换成归类后的说法，认不出原样返回。
///
/// 用在「手里只有字符串」的地方（upload 事件带回的对端原文），
/// 让气泡的措辞和不带原文的失败路径保持一致。
String describeSendErrorText(String? text) {
  final failure = classifySendErrorText(text);
  if (failure == null) {
    return text ?? describeSendFailure(SendFailure.unknown);
  }
  return describeSendFailure(failure);
}

/// 把失败原因翻译成用户能看懂的文案。
///
/// 发送流程自己也要用它写 [ChatMessage.errorMessage]，否则气泡只能退回
/// 那句笼统的「发送失败」。
String describeSendFailure(SendFailure failure) {
  return switch (failure) {
    SendFailure.cancelled => t.conversation.sendCancelled,
    SendFailure.peerDeclined => t.conversation.peerDeclined,
    SendFailure.peerBusy => t.conversation.peerBusy,
    SendFailure.peerRateLimited => t.conversation.peerRateLimited,
    SendFailure.peerDismissed => t.conversation.peerDismissed,
    SendFailure.peerOffline => t.conversation.peerUnreachable,
    SendFailure.peerNoResponse => t.conversation.peerNoResponse,
    SendFailure.acceptTimeout => t.conversation.acceptTimeout,
    SendFailure.peerAborted => t.conversation.peerAborted,
    SendFailure.authRejected => t.conversation.authRejected,
    SendFailure.tlsMismatch => t.conversation.tlsMismatch,
    SendFailure.localNetwork => t.conversation.localNetwork,
    SendFailure.receiverStorageFull => t.conversation.receiverStorageFull,
    SendFailure.receiverError => t.conversation.receiverError,
    SendFailure.checksumMismatch => t.conversation.checksumMismatch,
    SendFailure.uploadInterrupted => t.conversation.uploadInterrupted,
    SendFailure.fileMissing => t.conversation.fileMissing,
    SendFailure.unknown => t.conversation.sendFailed,
  };
}
