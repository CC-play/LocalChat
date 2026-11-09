import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform, SecureSocket, Socket, SocketException;

import 'package:collection/collection.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_app/model/cross_file.dart';
import 'package:localchat_app/provider/conversation/chat_transfer_provider.dart';
import 'package:localchat_app/provider/conversation_provider.dart';
import 'package:localchat_app/provider/network/nearby_devices_provider.dart';
import 'package:localchat_app/provider/network/send_provider.dart';
import 'package:localchat_app/provider/settings_provider.dart';
import 'package:localchat_app/util/conversation/conversation_recorder.dart';
import 'package:localchat_app/util/conversation/send_failure.dart';
import 'package:localchat_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localchat_app/util/native/cross_file_converters.dart';
import 'package:localchat_isolates/constants.dart';
import 'package:localchat_isolates/model/device.dart';
import 'package:localchat_isolates/model/file_type.dart';
import 'package:localchat_isolates/model/session_status.dart';
import 'package:localchat_isolates/rust/api/cancel.dart' as rust_cancel;
import 'package:localchat_isolates/util/file_hash.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

// 失败原因的定义挪到了 `send_failure.dart`（`send_provider` 也要用，放在这里
// 会形成循环依赖）。这里原样再导出一次，调用方import 本文件就够了。
export 'package:localchat_app/util/conversation/send_failure.dart';

/// 会话页的「发送」入口。
///
/// 上游的 LocalSend 没有独立的聊天协议：一条「消息」就是一个
/// `FileType.text` 的单文件请求，文本内容放在 `preview` 字段里。
/// 接收端（`ReceiveSessionState.message`）据此识别为消息请求，
/// 不做任何落盘，因此文本消息不占用两端磁盘，也不需要额外的协议端点。
///
/// 这个文件只负责「把聊天语义翻译成一次 sendSession」，不涉及 UI。
final _logger = Logger('ConversationSender');
const _uuid = Uuid();

/// 文本消息的长度上限。
///
/// 文本消息沿用 LocalSend 协议的做法：塞进 `preview`，整个 prepare-upload 请求是一个 JSON。
/// 太长既浪费内存也不符合局域网瞬时消息的定位，这里保守地限制在 4000 字符。
const int maxTextMessageLength = 4000;

/// 「对方不在线」时的重试窗口。
///
/// 注意 `send_provider` 里并没有一个「发送超时」常量可以调大：prepare-upload 是一次普通
/// TCP 请求，对方的 App 没开时连接会立即失败（通常是秒级，由系统 TCP 栈决定，
/// 不是我们能配置的值）。所以「给对方时间去拿起手机、打开 App」只能靠在时间窗口
/// 内**反复重试**，而不是把某个 timeout 改大。
const Duration textSendRetryWindow = Duration(minutes: 2);

/// 两次重试之间的间隔。
///
/// 局域网一次连接尝试通常在 1 秒内就有结论，2 秒足够及时地命中「对方刚好打开 App」，
/// 又不会把连接请求打得太密。
const Duration _retryInterval = Duration(seconds: 2);

/// 硬上限相对 [textSendRetryWindow] 的余量。
///
/// 内部的 deadline 判断会在「最后一次尝试结束后」正常返回，硬超时只负责兜住
/// 「某次 await 永远不返回」的情况，所以要比窗口本身略长，避免抢先一步
/// 把本来会正常结束的流程判成超时。
const Duration _timeoutGrace = Duration(seconds: 10);

/// 上传阶段的无进展上限。
///
/// 进入上传之后不再有任何重试（重来会在对端留下半截文件），结局完全由
/// upload 事件写入。如果对端在传输中途消失、TCP 半开，事件就再也不来了。
/// 局域网上正常传输每秒都会有进度回报，60 秒毫无进展即可判定已停滞。
const Duration uploadStallTimeout = Duration(seconds: 60);

/// 看门狗的巡检间隔。
const Duration _stallCheckInterval = Duration(seconds: 10);

/// 超时之后复检对端状态的等待上限。
///
/// 只是「再握一次手」，局域网内 0.1 秒内就会有结论；2 秒是给冻结进程留的
/// 观察窗口——它连 ServerHello 都不会回，早晚都是超时。
const Duration _diagnosisTimeout = Duration(seconds: 2);

/// 一次 prepare-upload 尝试超过这个时长仍未返回，就认为请求**已经送达**，
/// 对端应用层正在等用户点「接受」。
///
/// 局域网内 TCP + TLS + 请求体通常几十毫秒就完成（实测 0.03 s），2 秒还没
/// 返回只可能是对端卡在等人决策。用它把「连不上」和「在等对方」区分开，
/// 气泡页脚才能说清楚那句「发送中」到底在等什么。
const Duration _acceptAwaitThreshold = Duration(seconds: 2);

/// 界面兜底阈值：超过这个时间仍显示「发送中」，就由气泡直接把它标失败。
///
/// 发送流程自己会在 [textSendRetryWindow] + [_timeoutGrace] 后收尾，这个阈值
/// 只负责兜住「流程已经不在了、气泡却还挂着」的情况：异常逃逸、页面销毁导致
/// ref 失效（上传看门狗依赖页面 ref，此时会静默退出）。
/// 它不依赖任何后台任务，只要那条气泡还在屏幕上就会生效。
final Duration chatSendWatchdogTimeout = textSendRetryWindow + _timeoutGrace + const Duration(seconds: 5);

/// 一条消息正在进行的发送。
///
/// 用户可以在气泡上点「取消」直接把这条停下来，不必等满 [textSendRetryWindow]。
/// 光靠 `closeSession` 不够：它只取消当前还挂着的 prepare-upload，
/// 重试循环下一轮还会再发一次，所以循环里必须自己检查 [cancelled]。
class _SendTicket {
  _SendTicket(this.sessionId);

  /// 会话 id：取消时要靠它清掉后台会话（顺带取消挂起的请求）。
  final String sessionId;

  bool cancelled = false;
}

/// 正在进行的发送，按消息 id 索引。
///
/// 放在模块级而不是 provider 里：它只是「有没有人在等」的临时登记，
/// 没有任何 UI 需要观察它，不值得引入一个 provider 的生命周期管理。
final _inFlight = <String, _SendTicket>{};

/// 正在进行的校验和计算，按会话 id 索引。
///
/// 哈希已经从重试窗口里移出来单独成段，但它仍然必须可取消：用户点了气泡上的
/// 转圈，不能让它继续闷头读几十 GB 磁盘。
final _hashCancel = <String, rust_cancel.RsCancellationToken>{};

/// 解析会话对应的可发送设备。
///
/// 优先用本次局域网扫描到的设备（信息最新、带 https 与 webrtc 通道）；
/// 找不到时用会话里记录的历史 IP/端口合成一个最小设备对象。
Device? resolveConversationTarget(Ref ref, Conversation conversation) {
  final nearby = ref.read(nearbyDevicesProvider).devices[conversation.peerFingerprint];
  if (nearby != null && (nearby.ip?.isNotEmpty ?? false)) {
    return nearby;
  }

  final ip = conversation.peerIp;
  if (ip == null || ip.isEmpty) {
    return null;
  }

  final port = conversation.peerPort ?? defaultPort;
  // [FORK] 必须用 https：LocalSend v2 的 53317 是 TLS 端口，对端只接受 TLS 握手。
  // 这里曾经写死 `https: false`，结果是「从发送 Tab 发得出去（设备来自扫描，带 https），
  // 从会话页发永远失败」——明文 HTTP 打到 TLS 端口，服务端握手失败后直接断连，
  // 手机侧只看到一连串 TIME_WAIT，最终报「对方不可达」。
  // 会话记录里没有协议字段，而关了 https 的对端属于少数配置，先按默认值来。
  return Device(
    signalingId: null,
    ip: ip,
    version: protocolVersion,
    port: port,
    https: true,
    fingerprint: conversation.peerFingerprint,
    alias: conversation.peerAlias,
    deviceModel: null,
    deviceType: DeviceType.desktop,
    download: false,
    channels: [HttpChannel(host: ip, port: port, https: true)],
  );
}

/// 发送一条文本消息。
///
/// 返回 `null` 表示成功，否则为失败原因。
/// 「发送中」气泡会立刻写入，因此用户在请求往返期间就能看到反馈。
///
/// 对方不在线时会在 [textSendRetryWindow] 内反复重试：LocalSend 协议没有离线消息队列，
/// 对方 App 没打开时请求会立刻被拒绝，只有重试才能等到「对方打开 App」的那一刻。
Future<SendFailure?> sendTextMessage({
  required Ref ref,
  required Device target,
  required String text,

  /// [FORK] 重发时传入原消息 id：复用已有气泡，不再插一条新的。
  String? messageIdOverride,
}) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final bytes = Uint8List.fromList(utf8.encode(trimmed));
  // 消息 id 与文件 id 复用同一个值：气泡、重试、去重都靠它对齐。
  final messageId = messageIdOverride ?? _uuid.v4();
  final sessionId = _uuid.v4();
  final fileName = '$messageId.txt';

  if (messageIdOverride == null) {
    await recordSentFileStart(
      ref: ref,
      target: target,
      messageId: messageId,
      fileName: fileName,
      filePath: null,
      fileSize: bytes.length,
      fileType: FileType.text,
      text: trimmed,
    );
  }

  final file = CrossFile(
    name: fileName,
    fileType: FileType.text,
    size: bytes.length,
    thumbnail: null,
    asset: null,
    path: null,
    bytes: bytes,
    lastModified: null,
    lastAccessed: null,
  );

  // 登记取消令牌：气泡上的「取消」按钮靠它找到这次发送。
  final ticket = _SendTicket(sessionId);
  _inFlight[messageId] = ticket;

  SendFailure? failure;
  try {
    // [FORK] 硬上限：光靠循环里的 deadline 检查是不够的。
    // Rust 的 reqwest 客户端没有配总超时（`http_provider.dart` 建 client 时
    // 没传 timeout），prepare-upload 对着一个「TCP 能连上但不应答」的地址会
    // 永久挂起，循环里的 deadline 判断在 await 之后，永远执行不到，
    // 气泡就会一直转圈。整段再包一层超时，保证最坏情况也能落到失败态。
    failure = await _sendTextWithRetry(
      ref: ref,
      target: target,
      file: file,
      messageId: messageId,
      sessionId: sessionId,
      ticket: ticket,
    ).timeout(textSendRetryWindow + _timeoutGrace);
  } on TimeoutException {
    _logger.warning('Text message did not finish within $textSendRetryWindow');
    // 130 秒里一次答复都没等到：复检一次，区分「对端被冻结」和「没人点接受」。
    failure = await _diagnoseTimeout(target);
  } catch (e, st) {
    // 任何逃逸的异常都必须落成失败，否则气泡会永远停在「发送中」。
    _logger.warning('Failed to send a text message', e, st);
    failure = classifySendError(e);
  } finally {
    _inFlight.remove(messageId);
    // 失败的后台会话会留在 map 里，聊天场景不需要它继续存在。
    // closeSession 同时会取消还挂着的 prepare-upload（cancel token），
    // 所以超时之后不会留下一个仍在跑的请求。
    ref.notifier(sendProvider).closeSession(sessionId);
  }

  if (ticket.cancelled) {
    // 取消时气泡已经被 [cancelChatMessage] 写成终态了。
    // 这里再写一次会把它覆盖成「发送失败」或者更糟——把用户刚取消的那条
    // 又标成已发送，所以直接返回，让取消的结果保持唯一。
    return SendFailure.cancelled;
  }

  await markSentFile(
    ref: ref,
    target: target,
    messageId: messageId,
    fileName: fileName,
    filePath: null,
    fileSize: bytes.length,
    fileType: FileType.text,
    success: failure == null,
    text: trimmed,
    // 失败原因必须落到气泡上：否则 UI 只能显示那句笼统的「发送失败」。
    errorMessage: failure == null ? null : describeSendFailure(failure),
  );

  return failure;
}

/// 在 [textSendRetryWindow] 内反复尝试，直到成功、被对方明确拒绝或超出窗口。
Future<SendFailure?> _sendTextWithRetry({
  required Ref ref,
  required Device target,
  required CrossFile file,
  required String messageId,
  required String sessionId,
  required _SendTicket ticket,
}) async {
  final deadline = DateTime.now().add(textSendRetryWindow);
  var attempt = 0;
  while (true) {
    // 用户点了取消：每轮开头都查一次，避免取消后还继续发出去。
    if (ticket.cancelled) {
      return SendFailure.cancelled;
    }

    attempt++;
    final failure = await _attemptTextSend(
      ref: ref,
      target: target,
      file: file,
      messageId: messageId,
      sessionId: sessionId,
    );

    // 这次尝试可能正是在用户点取消的瞬间完成的：成功也当取消处理，
    // 否则对方收到了、用户界面上却显示「已取消」。
    if (ticket.cancelled) {
      return SendFailure.cancelled;
    }

    if (failure == null) {
      return null;
    }
    // 对方明确拒绝 / 正在忙：重试只会打扰对方，立刻结束。
    if (!_isRetryable(failure)) {
      return failure;
    }
    if (!DateTime.now().isBefore(deadline)) {
      _logger.info('Giving up after $attempt attempt(s): $failure');
      return failure;
    }

    _logger.info('Attempt $attempt failed ($failure), retrying in ${_retryInterval.inSeconds}s');
    await Future<void>.delayed(_retryInterval);
  }
}

/// 单次发送尝试。会话 id 在多次重试间复用，避免 fileTransfer 里堆积大量一次性状态。
Future<SendFailure?> _attemptTextSend({
  required Ref ref,
  required Device target,
  required CrossFile file,
  required String messageId,
  required String sessionId,
}) async {
  try {
    await ref
        .notifier(sendProvider)
        .startSession(
          target: target,
          files: [file],
          background: true,
          // 传入固定 id，才能在结束后读回这次会话的结局。
          sessionIdOverride: sessionId,
          // 固定文件 id = 消息 id。少了这一条，`startSession` 会另外生成一个 uuid，
          // 上传事件按那个 id 又写一条「发送中」气泡，于是同一条消息出现两个气泡
          // （接收端只收到一份）。
          fileIdsOverride: [messageId],
        );

    // 成功时 startSession 会把会话收掉（收到 204 后 fileMap 为空）。
    final session = ref.read(sendProvider)[sessionId];
    if (session == null) {
      return null;
    }
    // `finished` 在这里仍然是「成功」：文本没有「一个都没选中」这种结局。
    return sendFailureOfStatus(session.status, errorMessage: session.errorMessage);
  } catch (e) {
    _logger.warning('Failed to send a text message', e);
    return classifySendError(e);
  }
}

/// 值得重试的失败：只有「再等一下对方可能就好了」的那几类。
///
/// 判据是「对端有没有作出明确答复」：连接层面没通（离线、无响应、本机网络断）
/// 重试有意义——对方可能刚好打开 App、刚好解锁屏幕。
/// 而拒绝、忙、限流、密码错、证书不符、空间不足都是确定的结论，
/// 重试只是把同一个错误再问一遍。
bool _isRetryable(SendFailure failure) {
  return switch (failure) {
    SendFailure.peerOffline || SendFailure.peerNoResponse || SendFailure.localNetwork || SendFailure.unknown => true,
    _ => false,
  };
}

/// 打开系统文件选择器。
///
/// 返回 `null` 表示用户取消了选择；选择器本身出错也返回 `null`（已记日志）。
Future<List<CrossFile>?> pickConversationFiles() async {
  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final picked = await android_channel.pickFilesAndroid();
      if (picked == null || picked.isEmpty) {
        return null;
      }
      return [for (final info in picked) await CrossFileConverters.convertFileInfo(info)];
    }

    final picked = await openFiles();
    if (picked.isEmpty) {
      return null;
    }
    return [for (final xfile in picked) await CrossFileConverters.convertXFile(xfile)];
  } catch (e) {
    _logger.warning('Failed to pick files', e);
    return null;
  }
}

/// 把选中的文件投递到会话。
///
/// 与文本消息同一套语义：先落一条「发送中」气泡，然后在 [textSendRetryWindow]
/// 内反复重试，等对方把 App 打开。返回 `null` 表示成功或已交给后台传输，
/// 否则为最终失败原因。
///
/// 与文本的关键差别：**一旦有文件进入上传阶段就不再重试**。上传是流式的，
/// 断在中途重来一遍会在对端留下半截文件；这之后的失败由对端/协议决定，
/// 交给 upload 事件记录。
Future<SendFailure?> deliverFiles({
  required Ref ref,
  required Device target,
  required List<CrossFile> files,

  /// [FORK] 重发时传入原消息 id：复用已有气泡，不再插新的。
  List<String>? messageIds,
}) async {
  if (files.isEmpty) {
    return null;
  }

  // 文件 id 预分配：气泡、上传事件、失败标记三处必须用同一批 id。
  final fileIds = messageIds ?? [for (final _ in files) _uuid.v4()];

  // 先把「发送中」气泡落下来。对方离线时最长要等两分钟，
  // 这期间界面上必须看得见「这条正在等」，否则用户会以为没发出去。
  // 重发场景气泡已经存在（页面已把它改回「发送中」），不能再插一条。
  if (messageIds == null) {
    for (var i = 0; i < files.length; i++) {
      await recordSentFileStart(
        ref: ref,
        target: target,
        messageId: fileIds[i],
        fileName: files[i].name,
        filePath: files[i].path,
        fileSize: files[i].size,
        fileType: files[i].fileType,
      );
    }
  }

  final sessionId = _uuid.v4();
  // 校验和跨重试复用：几百 MB 的文件不该在两分钟里被反复读盘哈希。
  final checksums = <String, String>{};

  SendFailure? failure;
  var enteredTransfer = false;
  // 一个批次共用一个令牌：多点几个文件时，取消其中任意一条就整批停下，
  // 否则会出现「取消了一条，剩下几条还在后台排队上传」的怪状态。
  final ticket = _SendTicket(sessionId);
  for (final id in fileIds) {
    _inFlight[id] = ticket;
  }

  try {
    // [FORK] 校验和先单独算完，再进重试窗口。
    //
    // 原实现把哈希留在 startSession 内部，外面套着 textSendRetryWindow：
    // 读盘和「等对方接受」抢同一个 2 分钟。debug 构建下 30 GiB 的哈希要
    // 7 分钟，请求一次都没发出就被判超时（见 2026-11-08 传输失败诊断）。
    // 现在它可取消、有进度、不设上限，也不占「等对方」的额度。
    await _precomputeChecksums(
      ref: ref,
      files: files,
      fileIds: fileIds,
      checksums: checksums,
      ticket: ticket,
    );
    if (ticket.cancelled) {
      return SendFailure.cancelled;
    }

    // [FORK] 与文本同一个硬上限：握手阶段的 await 可能永不返回，
    // 不能只靠循环内的 deadline 判断。
    final result = await _deliverWithRetry(
      ref: ref,
      target: target,
      files: files,
      fileIds: fileIds,
      sessionId: sessionId,
      checksums: checksums,
      ticket: ticket,
    ).timeout(textSendRetryWindow + _timeoutGrace);
    failure = result.failure;
    enteredTransfer = result.enteredTransfer;
  } on TimeoutException {
    _logger.warning('File delivery did not finish within $textSendRetryWindow');
    // 与文本同款复检：这次是文件，但「冻结 / 没点接受」的判定逻辑一致。
    failure = await _diagnoseTimeout(target);
  } catch (e, st) {
    // 异常也必须落到下面的 _failPendingFiles，否则气泡永远转圈。
    _logger.warning('Failed to deliver files', e, st);
    failure = classifySendError(e);
  } finally {
    for (final id in fileIds) {
      // 只在还是自己的令牌时才移除：重发会在旧流程收尾前就注册新令牌。
      if (identical(_inFlight[id], ticket)) {
        _inFlight.remove(id);
      }
    }
  }

  if (ticket.cancelled) {
    // 取消时 [cancelChatMessage] 已经把气泡写成终态，这里不能再覆盖。
    return SendFailure.cancelled;
  }

  if (enteredTransfer) {
    // 上传已开始，后续状态由 upload 事件写入，这里不能收会话。
    // 但事件可能永远不来（对端中途消失 / TCP 半开），所以另起一个看门狗。
    unawaited(
      _watchStalledUploads(
        ref: ref,
        target: target,
        files: files,
        fileIds: fileIds,
        sessionId: sessionId,
        ticket: ticket,
      ),
    );
    return null;
  }

  ref.notifier(sendProvider).closeSession(sessionId);
  final pendingCount = await _failPendingFiles(ref: ref, target: target, files: files, fileIds: fileIds, failure: failure);
  if (pendingCount == 0) {
    // 所有气泡都已是终态：说明它们在重试期间已经传完了，不该报失败。
    return null;
  }
  return failure;
}

/// [FORK] 在进入网络阶段之前，把这一批文件的校验和算完。
///
/// 单独成段的原因见调用处：它必须是**可取消**、**有进度**、**不设上限**的，
/// 而不是塞进一个「等对方接受」的窗口里。算不出来不阻塞发送——协议里
/// `sha256` 本来就是可选字段，接收端只在收到它时才校验。
Future<void> _precomputeChecksums({
  required Ref ref,
  required List<CrossFile> files,
  required List<String> fileIds,
  required Map<String, String> checksums,
  required _SendTicket ticket,
}) async {
  final ChatTransferNotifier transfer;
  try {
    // 设置里关掉了「发送时生成校验和」，就没有这一段要算，
    // 页脚也不该假装在校验。
    if (!ref.read(settingsProvider).createChecksums) {
      return;
    }
    transfer = ref.read(chatTransferProvider);
  } catch (e) {
    // 容器已失效：交给网络阶段自己的错误路径收尾。
    _logger.warning('Cannot precompute checksums, ref is no longer valid', e);
    return;
  }

  final cancelToken = rust_cancel.createCancellationToken();
  _hashCancel[ticket.sessionId] = cancelToken;
  try {
    // 整批一起标成「校验中」：多文件是逐个读盘的，若只给当前那个文件设阶段，
    // 排在后面的文件会停在「发送中」并被 135 秒的 UI 兜底误判成失败。
    _setPhaseAll(transfer, fileIds, ChatTransferPhase.hashing);
    for (var i = 0; i < files.length; i++) {
      if (ticket.cancelled) {
        return;
      }
      final id = fileIds[i];
      final file = files[i];
      transfer.setPhase(id, ChatTransferPhase.hashing);
      try {
        checksums[id] = await calculateFileHash(
          path: file.path,
          bytes: file.bytes,
          cancelToken: cancelToken,
          onProgress: (hashed) {
            transfer.report(
              messageId: id,
              progress: file.size == 0 ? 1 : (hashed / file.size).clamp(0, 1),
            );
          },
        );
      } catch (e) {
        // 与 send_provider 原有行为一致：读不出来就不带校验和发，
        // 不能因为没法校验就整条发不出去。
        _logger.warning('Could not calculate the checksum of ${file.name}', e);
      }
      // 算完（或失败）都推到满，否则页脚会永远停在 63%。
      transfer.report(messageId: id, progress: 1);
    }
  } finally {
    _hashCancel.remove(ticket.sessionId);
  }
}

/// 批量切换一批气泡所在的阶段。
///
/// 多文件是一次 prepare-upload 请求带上去的，对端会同时接受或拒绝，
/// 所以这些气泡的阶段天然同步，不需要逐条判断。
void _setPhaseAll(ChatTransferNotifier? transfer, List<String> fileIds, ChatTransferPhase phase) {
  if (transfer == null) {
    return;
  }
  for (final id in fileIds) {
    transfer.setPhase(id, phase);
  }
}

/// 握手阶段的重试循环。
///
/// 返回的 `enteredTransfer` 为真表示至少有一个文件拿到了上传 token，
/// 此后不能再重试（会在对端留下重复文件）。
Future<({SendFailure? failure, bool enteredTransfer})> _deliverWithRetry({
  required Ref ref,
  required Device target,
  required List<CrossFile> files,
  required List<String> fileIds,
  required String sessionId,
  required Map<String, String> checksums,
  required _SendTicket ticket,
}) async {
  final deadline = DateTime.now().add(textSendRetryWindow);
  SendFailure? failure;
  var attempt = 0;

  // [FORK] 阶段提示用。拿不到 notifier 就只是没有页脚文案，不影响发送。
  ChatTransferNotifier? transfer;
  try {
    transfer = ref.read(chatTransferProvider);
  } catch (_) {
    transfer = null;
  }

  while (true) {
    if (ticket.cancelled) {
      return (failure: SendFailure.cancelled, enteredTransfer: false);
    }

    attempt++;
    _setPhaseAll(transfer, fileIds, ChatTransferPhase.connecting);
    // 久到不像「被拒绝」，就说明请求已经躺在对端应用层里等用户点接受了。
    final awaitAcceptWatch = Timer(_acceptAwaitThreshold, () {
      _setPhaseAll(transfer, fileIds, ChatTransferPhase.waitingAccept);
    });
    ({SendFailure? failure, bool enteredTransfer, Set<String> acceptedIds}) result;
    try {
      result = await _attemptFileSend(
        ref: ref,
        target: target,
        files: files,
        fileIds: fileIds,
        sessionId: sessionId,
        checksums: checksums,
      );
    } finally {
      awaitAcceptWatch.cancel();
    }

    // 令牌拿到手之后用户才点取消：此时文件已经在往对端写了，
    // 交给 upload 事件收尾（看门狗也会看到取消标记），不能在这里标失败，
    // 否则对端收到了、本地却显示失败。
    if (ticket.cancelled) {
      if (result.enteredTransfer) {
        final rejected = [
          for (var i = 0; i < files.length; i++)
            if (!result.acceptedIds.contains(fileIds[i])) i,
        ];
        if (rejected.isNotEmpty) {
          await _failFilesAt(
            ref: ref,
            target: target,
            files: files,
            fileIds: fileIds,
            indexes: rejected,
            failure: SendFailure.cancelled,
          );
        }
        return (failure: null, enteredTransfer: true);
      }
      return (failure: SendFailure.cancelled, enteredTransfer: false);
    }

    if (result.enteredTransfer) {
      // 多选时对端可能只勾了其中几个：没拿到 token 的那些永远不会有
      // upload 事件，气泡会一直转圈，这里直接标失败。
      final rejected = [
        for (var i = 0; i < files.length; i++)
          if (!result.acceptedIds.contains(fileIds[i])) i,
      ];
      if (rejected.isNotEmpty) {
        await _failFilesAt(
          ref: ref,
          target: target,
          files: files,
          fileIds: fileIds,
          indexes: rejected,
          failure: SendFailure.peerDismissed,
        );
      }
      return (failure: null, enteredTransfer: true);
    }

    failure = result.failure;
    // 对方明确拒绝 / 正在忙：重试只会打扰对方。
    if (failure == null || !_isRetryable(failure)) {
      return (failure: failure, enteredTransfer: false);
    }
    if (!DateTime.now().isBefore(deadline)) {
      _logger.info('Giving up on files after $attempt attempt(s): $failure');
      return (failure: failure, enteredTransfer: false);
    }

    _logger.info('File send attempt $attempt failed ($failure), retrying in ${_retryInterval.inSeconds}s');
    // 失败的会话会留在 map 里，重试前清掉，避免旧状态干扰下一轮。
    ref.notifier(sendProvider).closeSession(sessionId);
    await Future<void>.delayed(_retryInterval);
  }
}

/// 上传看门狗：进入上传后，若 [uploadStallTimeout] 内毫无进展就把气泡标失败。
///
/// 进入上传阶段后 `deliverFiles` 就返回了，终态完全依赖 upload 事件。
/// 对端在传输中途消失时事件再也不会来，没有这个看门狗气泡会永远转圈。
Future<void> _watchStalledUploads({
  required Ref ref,
  required Device target,
  required List<CrossFile> files,
  required List<String> fileIds,
  required String sessionId,
  required _SendTicket ticket,
}) async {
  final peerKey = peerKeyOf(target);
  final ChatTransferNotifier transfer;
  try {
    transfer = ref.read(chatTransferProvider);
  } catch (e, st) {
    // 容器已失效：看门狗无从工作，直接退出，别让异常变成未处理的 future 错误。
    _logger.warning('Cannot watch uploads, ref is no longer valid', e, st);
    return;
  }
  final startedAt = DateTime.now();

  while (true) {
    await Future<void>.delayed(_stallCheckInterval);

    // 用户已取消：气泡状态由 [cancelChatMessage] 负责，看门狗直接退出，
    // 免得 60 秒后又把「已取消」改写成「传输失败」。
    if (ticket.cancelled) {
      return;
    }

    final List<ChatMessage> messages;
    try {
      messages = ref.read(conversationProvider).firstWhereOrNull((c) => c.peerFingerprint == peerKey)?.messages ?? const <ChatMessage>[];
    } catch (e) {
      // 容器已销毁：没有气泡可更新，继续看下去也没有意义。
      return;
    }

    final pending = [
      for (var i = 0; i < fileIds.length; i++)
        if (messages.firstWhereOrNull((m) => m.id == fileIds[i])?.status == ChatMessageStatus.pending) i,
    ];
    if (pending.isEmpty) {
      // 全部已有终态（成功或失败），看门狗使命结束。
      return;
    }

    // 按「整批文件」而不是单个文件判断活跃度：多文件是顺序上传的，
    // 逐文件计时会误伤那些排在后面、还没开始传的正常文件。
    var lastActivity = startedAt;
    for (final id in fileIds) {
      final at = transfer.lastProgressOf(id);
      if (at != null && at.isAfter(lastActivity)) {
        lastActivity = at;
      }
    }

    if (DateTime.now().difference(lastActivity) < uploadStallTimeout) {
      continue;
    }

    _logger.warning('Upload stalled for over $uploadStallTimeout, aborting ${pending.length} file(s)');
    try {
      ref.notifier(sendProvider).closeSession(sessionId);
    } catch (e, st) {
      _logger.warning('Failed to close a stalled session', e, st);
    }
    await _failFilesAt(
      ref: ref,
      target: target,
      files: files,
      fileIds: fileIds,
      indexes: pending,
      // 传输中途彻底没动静：对端可能息屏被冻结、Wi-Fi 掉了，或者干脆退出了 App。
      failure: SendFailure.uploadInterrupted,
    );
    return;
  }
}

/// 主动取消一条正在发送的消息（点气泡左侧转圈的那颗按钮）。
///
/// 返回 `true` 表示确实停掉了某次发送；`false` 表示这条已经不在发送中
/// （多半是在点下去的同一瞬间刚好发完了），但**气泡状态仍会被修正**。
///
/// 取消立即生效：先把气泡写成终态、再断开后台会话，不等下一条 upload 事件。
/// 发送循环里对令牌的检查只是为了阻止它继续往后发，不代表取消的时机。
///
/// `_inFlight` 里找不到条目时同样会标失败：那种情况说明发送流程已经消失
/// （异常逃逸、页面销毁导致 ref 失效），气泡却还挂在「发送中」——这正是
/// 「一直转圈」最难看的样子，必须能被修掉。
Future<bool> cancelChatMessage({
  required Ref ref,
  required Device target,
  required String messageId,

  /// 气泡下方显示的原因文案（通常是「已取消」）。
  String? errorMessage,
}) async {
  final ticket = _inFlight[messageId];
  ticket?.cancelled = true;

  // 停在哈希阶段时，光取消网络请求没有用：读盘还在闷头跑，
  // 得把哈希的取消令牌一起停掉，取消才是立即生效的。
  if (ticket != null) {
    _hashCancel.remove(ticket.sessionId)?.cancel();
  }

  // 同一批文件共用一个令牌：整批一起停。否则会出现「取消了一条、
  // 剩下几条还在后台排队上传」的怪状态。
  final ids = ticket == null
      ? [messageId]
      : [
          for (final entry in _inFlight.entries)
            if (identical(entry.value, ticket)) entry.key,
        ];

  if (ticket != null) {
    try {
      // closeSession 会顺带取消还挂着的 prepare-upload。
      ref.notifier(sendProvider).closeSession(ticket.sessionId);
    } catch (e, st) {
      _logger.warning('Failed to close a cancelled session', e, st);
    }
  }

  final peerFingerprint = peerKeyOf(target);
  final messages = ref.read(conversationProvider).firstWhereOrNull((c) => c.peerFingerprint == peerFingerprint)?.messages ?? const <ChatMessage>[];

  for (final id in ids) {
    // 只动还在「发送中」的：已经传完的那几条不能被改回失败。
    if (messages.firstWhereOrNull((m) => m.id == id)?.status != ChatMessageStatus.pending) {
      continue;
    }

    try {
      ref.read(chatTransferProvider).finish(id);
    } catch (e, st) {
      _logger.warning('Failed to clear progress of a cancelled message', e, st);
    }

    try {
      await ref
          .redux(conversationProvider)
          .dispatchAsync(
            UpdateChatMessageAction(
              peerFingerprint: peerFingerprint,
              messageId: id,
              status: ChatMessageStatus.failed,
              errorMessage: errorMessage,
            ),
          );
    } catch (e, st) {
      _logger.warning('Failed to mark a cancelled message', e, st);
    }
  }

  // 没有令牌 = 已经没有流程可停，只是替它收了个尾。
  return ticket != null;
}

/// 重发一条发送失败的消息（点气泡左侧的红色感叹号）。
///
/// **复用原消息 id**：不新增气泡，状态在原来那条上 `pending -> sent/failed`，
/// 所以重发后消息仍停在历史位置，不会跳到最下面，也不会出现「一条变两条」。
///
/// 返回 `null` 表示已发出（或已交给后台传输），否则为失败原因。
Future<SendFailure?> retryChatMessage({
  required Ref ref,
  required Device target,
  required ChatMessage message,
}) async {
  if (!message.isOutgoing || message.status != ChatMessageStatus.failed) {
    return null;
  }

  // 先恢复成「发送中」：点下去立刻有反馈，也顺手挡掉连点。
  await ref
      .redux(conversationProvider)
      .dispatchAsync(
        MarkChatMessagePendingAction(
          peerFingerprint: peerKeyOf(target),
          messageId: message.id,
        ),
      );

  // [FORK] 进度复位：上一轮的 100% 会先闪一下，否则用户以为新的一轮已经传完了。
  ref.read(chatTransferProvider).reset(message.id);

  if (message.kind == ChatMessageKind.text) {
    final text = message.text;
    if (text == null || text.trim().isEmpty) {
      await _markMessageFailed(ref, target, message, failure: SendFailure.unknown);
      return SendFailure.unknown;
    }
    return sendTextMessage(
      ref: ref,
      target: target,
      text: text,
      messageIdOverride: message.id,
    );
  }

  // 文件：源文件必须还在。它可能被移动/删除，或者缓存目录被系统清理过
  // （粘贴图片就是落在缓存里的），这两种情况只能明确告诉用户「找不到了」。
  final path = message.filePath;
  if (path == null || !File(path).existsSync()) {
    _logger.info('Cannot retry, source file is gone: $path');
    await _markMessageFailed(ref, target, message, failure: SendFailure.fileMissing);
    return SendFailure.fileMissing;
  }

  final file = CrossFile(
    name: message.fileName ?? path.split(Platform.pathSeparator).last,
    fileType: message.fileType ?? FileType.other,
    size: message.fileSize,
    thumbnail: null,
    asset: null,
    path: path,
    bytes: null,
    lastModified: null,
    lastAccessed: null,
  );
  return deliverFiles(
    ref: ref,
    target: target,
    files: [file],
    messageIds: [message.id],
  );
}

/// 把气泡标回失败（重发过程中发现根本发不出去时用）。
Future<void> _markMessageFailed(Ref ref, Device target, ChatMessage message, {SendFailure? failure}) async {
  try {
    await ref
        .redux(conversationProvider)
        .dispatchAsync(
          UpdateChatMessageAction(
            peerFingerprint: peerKeyOf(target),
            messageId: message.id,
            status: ChatMessageStatus.failed,
            errorMessage: failure == null ? null : describeSendFailure(failure),
          ),
        );
  } catch (e, st) {
    _logger.warning('Failed to mark message as failed', e, st);
  }
}

/// 单次投递尝试。
///
/// `enteredTransfer` 为真表示至少有一个文件拿到了上传 token，
/// 此时再重试会导致对端出现重复文件。
Future<({SendFailure? failure, bool enteredTransfer, Set<String> acceptedIds})> _attemptFileSend({
  required Ref ref,
  required Device target,
  required List<CrossFile> files,
  required List<String> fileIds,
  required String sessionId,
  required Map<String, String> checksums,
}) async {
  try {
    await ref
        .notifier(sendProvider)
        .startSession(
          target: target,
          files: files,
          background: true,
          // 固定会话 id，才能回读这次的结局。
          sessionIdOverride: sessionId,
          // 固定文件 id，上传事件才能对上已经画出来的气泡。
          fileIdsOverride: fileIds,
          checksumCache: checksums,
        );
  } catch (e) {
    _logger.warning('Failed to send files', e);
    return (failure: classifySendError(e), enteredTransfer: false, acceptedIds: const <String>{});
  }

  final session = ref.read(sendProvider)[sessionId];
  if (session == null) {
    // startSession 内部已把会话收掉：对端一个文件都没接受（204 → 空 fileMap）。
    // 真正的成功同样会把会话收掉，但那时气泡已经被 upload 事件写成「已发送」，
    // 调用方只会去动仍是 pending 的那几条，所以这里的结论不会覆盖成功的记录。
    return (failure: SendFailure.peerDismissed, enteredTransfer: false, acceptedIds: const <String>{});
  }

  final accepted = {
    for (final entry in session.files.entries)
      if (entry.value.token != null) entry.key,
  };
  if (accepted.isNotEmpty) {
    return (failure: null, enteredTransfer: true, acceptedIds: accepted);
  }

  // 对端整批拒绝时，失败原因常常只落在文件级 errorMessage 上（上传阶段失败的
  // 场景），所以两者一起交给分类器。
  final fileError = session.files.values.map((f) => f.errorMessage).firstWhere((e) => e != null && e.isNotEmpty, orElse: () => null);
  final classified = sendFailureOfStatus(session.status, errorMessage: session.errorMessage ?? fileError);
  return (
    // 一个 token 都没拿到却报「已完成」：对端把整批都取消勾选了。
    failure: classified ?? (session.status == SessionStatus.finished ? SendFailure.peerDismissed : SendFailure.unknown),
    enteredTransfer: false,
    acceptedIds: const <String>{},
  );
}

/// 把仍是「发送中」的气泡标成失败，返回实际改动的条数。
///
/// 只动 pending 的那几条：重试场景下可能已有部分文件传成功，
/// 那些必须保持「已发送」。
Future<int> _failPendingFiles({
  required Ref ref,
  required Device target,
  required List<CrossFile> files,
  required List<String> fileIds,

  /// 写进气泡的失败原因。不传就只有那句笼统的「发送失败」。
  SendFailure? failure,
}) async {
  final peerKey = peerKeyOf(target);
  final messages = ref.read(conversationProvider).firstWhereOrNull((c) => c.peerFingerprint == peerKey)?.messages ?? const <ChatMessage>[];

  final indexes = <int>[];
  for (var i = 0; i < files.length; i++) {
    final current = messages.firstWhereOrNull((m) => m.id == fileIds[i]);
    if (current == null || current.status == ChatMessageStatus.pending) {
      indexes.add(i);
    }
  }

  return _failFilesAt(ref: ref, target: target, files: files, fileIds: fileIds, indexes: indexes, failure: failure);
}

Future<int> _failFilesAt({
  required Ref ref,
  required Device target,
  required List<CrossFile> files,
  required List<String> fileIds,
  required List<int> indexes,
  SendFailure? failure,
}) async {
  final errorMessage = failure == null ? null : describeSendFailure(failure);
  for (final i in indexes) {
    await markSentFile(
      ref: ref,
      target: target,
      messageId: fileIds[i],
      fileName: files[i].name,
      filePath: files[i].path,
      fileSize: files[i].size,
      fileType: files[i].fileType,
      success: false,
      errorMessage: errorMessage,
    );
  }
  return indexes.length;
}

/// 硬超时之后，回头确认一次对端到底处于什么状态。
///
/// 这一步能把两种长得一模一样的情况分开：
/// - 手机被系统冻结 → TCP 能连上，但 TLS 握手永远等不到 ServerHello；
/// - 手机正常、接收页开着，只是没人点「接受」→ 握手秒过，请求就躺在应用层。
///
/// 只在对端已经「130 秒没回话」之后跑一次，正常发送路径上没有任何额外开销。
/// 证书校验必须关掉：这里只判断「对面的进程还活着吗」，不涉及任何数据。
Future<SendFailure> _diagnoseTimeout(Device target) async {
  final ip = target.ip;
  if (ip == null || ip.isEmpty) {
    return SendFailure.peerOffline;
  }

  // 对端不开 HTTPS 时，明文端口连得上就说明进程活着。
  if (!target.https) {
    try {
      final socket = await Socket.connect(ip, target.port, timeout: _diagnosisTimeout);
      socket.destroy();
      return SendFailure.acceptTimeout;
    } on SocketException {
      return SendFailure.peerOffline;
    } on TimeoutException {
      return SendFailure.peerNoResponse;
    } catch (_) {
      return SendFailure.unknown;
    }
  }

  try {
    final socket = await SecureSocket.connect(
      ip,
      target.port,
      timeout: _diagnosisTimeout,
      onBadCertificate: (_) => true,
    );
    socket.destroy();
    // 握手成功 = 对端服务在跑、能处理请求，那 130 秒就只是没人在手机上点接受。
    return SendFailure.acceptTimeout;
  } on TimeoutException {
    // TCP 连上了却迟迟没有 ServerHello：Android 冻结进程的典型指纹。
    return SendFailure.peerNoResponse;
  } on SocketException {
    return SendFailure.peerOffline;
  } catch (_) {
    // 握手被对端拒绝（比如它只接受已知指纹）同样说明进程活着。
    return SendFailure.acceptTimeout;
  }
}
