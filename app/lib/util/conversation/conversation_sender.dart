import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:localsend_app/model/conversation/conversation.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/conversation_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/util/conversation/conversation_recorder.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_isolates/constants.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

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
/// LocalSend 把文本塞进 `preview`，整个 prepare-upload 请求是一个 JSON。
/// 太长既浪费内存也不符合局域网瞬时消息的定位，这里保守地限制在 4000 字符。
const int maxTextMessageLength = 4000;

/// 「对方不在线」时的重试窗口。
///
/// 注意 LocalSend 并没有一个「发送超时」常量可以调大：prepare-upload 是一次普通
/// TCP 请求，对方的 App 没开时连接会立即失败（通常是秒级，由系统 TCP 栈决定，
/// 不是我们能配置的值）。所以「给对方时间去拿起手机、打开 App」只能靠在时间窗口
/// 内**反复重试**，而不是把某个 timeout 改大。
const Duration textSendRetryWindow = Duration(minutes: 2);

/// 两次重试之间的间隔。
///
/// 局域网一次连接尝试通常在 1 秒内就有结论，2 秒足够及时地命中「对方刚好打开 App」，
/// 又不会把连接请求打得太密。
const Duration _retryInterval = Duration(seconds: 2);

/// 文本消息发送失败的原因，由 UI 层翻译成文案。
enum SendFailure {
  /// 对方点了拒绝。
  peerDeclined,

  /// 对方正在与另一台设备传输。
  peerBusy,

  /// 找不到对方的地址（设备已离线且没有历史 IP）。
  unreachable,

  /// 其它错误（网络、TLS 指纹不匹配等）。
  unknown,
}

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
  return Device(
    signalingId: null,
    ip: ip,
    version: protocolVersion,
    port: port,
    https: false,
    fingerprint: conversation.peerFingerprint,
    alias: conversation.peerAlias,
    deviceModel: null,
    deviceType: DeviceType.desktop,
    download: false,
    channels: [HttpChannel(host: ip, port: port, https: false)],
  );
}

/// 发送一条文本消息。
///
/// 返回 `null` 表示成功，否则为失败原因。
/// 「发送中」气泡会立刻写入，因此用户在请求往返期间就能看到反馈。
///
/// 对方不在线时会在 [textSendRetryWindow] 内反复重试：LocalSend 没有离线消息队列，
/// 对方 App 没打开时请求会立刻被拒绝，只有重试才能等到「对方打开 App」的那一刻。
Future<SendFailure?> sendTextMessage({
  required Ref ref,
  required Device target,
  required String text,
}) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final bytes = Uint8List.fromList(utf8.encode(trimmed));
  // 消息 id 与文件 id 复用同一个值：气泡、重试、去重都靠它对齐。
  final messageId = _uuid.v4();
  final sessionId = _uuid.v4();
  final fileName = '$messageId.txt';

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

  final deadline = DateTime.now().add(textSendRetryWindow);
  SendFailure? failure;
  try {
    var attempt = 0;
    while (true) {
      attempt++;
      failure = await _attemptTextSend(
        ref: ref,
        target: target,
        file: file,
        sessionId: sessionId,
      );

      if (failure == null) {
        break;
      }
      // 对方明确拒绝 / 正在忙：重试只会打扰对方，立刻结束。
      if (!_isRetryable(failure)) {
        break;
      }
      if (!DateTime.now().isBefore(deadline)) {
        _logger.info('Giving up after $attempt attempt(s): $failure');
        break;
      }

      _logger.info('Attempt $attempt failed ($failure), retrying in ${_retryInterval.inSeconds}s');
      await Future<void>.delayed(_retryInterval);
    }
  } finally {
    // 失败的后台会话会留在 map 里，聊天场景不需要它继续存在。
    ref.notifier(sendProvider).closeSession(sessionId);
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
  );

  return failure;
}

/// 单次发送尝试。会话 id 在多次重试间复用，避免 fileTransfer 里堆积大量一次性状态。
Future<SendFailure?> _attemptTextSend({
  required Ref ref,
  required Device target,
  required CrossFile file,
  required String sessionId,
}) async {
  try {
    await ref.notifier(sendProvider).startSession(
      target: target,
      files: [file],
      background: true,
      // 传入固定 id，才能在结束后读回这次会话的结局。
      sessionIdOverride: sessionId,
    );

    // 成功时 startSession 会把会话收掉（收到 204 后 fileMap 为空）。
    final session = ref.read(sendProvider)[sessionId];
    if (session == null) {
      return null;
    }
    return _failureOf(session.status);
  } catch (e) {
    _logger.warning('Failed to send a text message', e);
    return SendFailure.unknown;
  }
}

/// 值得重试的失败：连接层面的问题（对方离线、网络抖动）。
///
/// 「对方拒绝」和「对方忙」是明确的答复，重试没有意义。
bool _isRetryable(SendFailure failure) {
  switch (failure) {
    case SendFailure.unreachable:
    case SendFailure.unknown:
      return true;
    case SendFailure.peerDeclined:
    case SendFailure.peerBusy:
      return false;
  }
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
}) async {
  if (files.isEmpty) {
    return null;
  }

  // 文件 id 预分配：气泡、上传事件、失败标记三处必须用同一批 id。
  final fileIds = [for (final _ in files) _uuid.v4()];

  // 先把「发送中」气泡落下来。对方离线时最长要等两分钟，
  // 这期间界面上必须看得见「这条正在等」，否则用户会以为没发出去。
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

  final sessionId = _uuid.v4();
  final deadline = DateTime.now().add(textSendRetryWindow);
  // 校验和跨重试复用：几百 MB 的文件不该在两分钟里被反复读盘哈希。
  final checksums = <String, String>{};

  SendFailure? failure;
  var enteredTransfer = false;
  var attempt = 0;

  while (true) {
    attempt++;
    final result = await _attemptFileSend(
      ref: ref,
      target: target,
      files: files,
      fileIds: fileIds,
      sessionId: sessionId,
      checksums: checksums,
    );

    if (result.enteredTransfer) {
      enteredTransfer = true;
      // 多选时对端可能只勾了其中几个：没拿到 token 的那些永远不会有
      // upload 事件，气泡会一直转圈，这里直接标失败。
      final rejected = [
        for (var i = 0; i < files.length; i++)
          if (!result.acceptedIds.contains(fileIds[i])) i,
      ];
      if (rejected.isNotEmpty) {
        await _failFilesAt(ref: ref, target: target, files: files, fileIds: fileIds, indexes: rejected);
      }
      break;
    }

    failure = result.failure;
    // 对方明确拒绝 / 正在忙：重试只会打扰对方。
    if (failure == null || !_isRetryable(failure)) {
      break;
    }
    if (!DateTime.now().isBefore(deadline)) {
      _logger.info('Giving up on files after $attempt attempt(s): $failure');
      break;
    }

    _logger.info('File send attempt $attempt failed ($failure), retrying in ${_retryInterval.inSeconds}s');
    // 失败的会话会留在 map 里，重试前清掉，避免旧状态干扰下一轮。
    ref.notifier(sendProvider).closeSession(sessionId);
    await Future<void>.delayed(_retryInterval);
  }

  if (enteredTransfer) {
    // 上传已开始，后续状态由 upload 事件写入，这里不能收会话。
    return null;
  }

  ref.notifier(sendProvider).closeSession(sessionId);
  final pendingCount = await _failPendingFiles(ref: ref, target: target, files: files, fileIds: fileIds);
  if (pendingCount == 0) {
    // 所有气泡都已是终态：说明它们在重试期间已经传完了，不该报失败。
    return null;
  }
  return failure;
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
    await ref.notifier(sendProvider).startSession(
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
    return (failure: SendFailure.unknown, enteredTransfer: false, acceptedIds: const <String>{});
  }

  final session = ref.read(sendProvider)[sessionId];
  if (session == null) {
    // startSession 内部已把会话收掉：对端一个文件都没接受（空 fileMap / 204）。
    return (failure: SendFailure.peerDeclined, enteredTransfer: false, acceptedIds: const <String>{});
  }

  final accepted = {
    for (final entry in session.files.entries)
      if (entry.value.token != null) entry.key,
  };
  if (accepted.isNotEmpty) {
    return (failure: null, enteredTransfer: true, acceptedIds: accepted);
  }

  return (failure: _failureOf(session.status), enteredTransfer: false, acceptedIds: const <String>{});
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

  return _failFilesAt(ref: ref, target: target, files: files, fileIds: fileIds, indexes: indexes);
}

Future<int> _failFilesAt({
  required Ref ref,
  required Device target,
  required List<CrossFile> files,
  required List<String> fileIds,
  required List<int> indexes,
}) async {
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
    );
  }
  return indexes.length;
}

SendFailure? _failureOf(SessionStatus status) {
  switch (status) {
    case SessionStatus.finished:
      return null;
    case SessionStatus.declined:
      return SendFailure.peerDeclined;
    case SessionStatus.recipientBusy:
    case SessionStatus.tooManyAttempts:
      return SendFailure.peerBusy;
    default:
      return SendFailure.unknown;
  }
}
