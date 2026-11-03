import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:localsend_app/model/conversation/conversation.dart';
import 'package:localsend_app/model/cross_file.dart';
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

  SendFailure? failure;
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
    if (session != null) {
      failure = _failureOf(session.status);
    }
  } catch (e) {
    _logger.warning('Failed to send a text message', e);
    failure = SendFailure.unknown;
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

/// 打开系统文件选择器并把选中的文件发到该会话。
///
/// 返回 `null` 表示要么用户取消了选择，要么传输已交给上游的文件流程
/// （后续状态由 `send_provider` 的事件写入会话）。
Future<SendFailure?> sendFilesToConversation({
  required Ref ref,
  required Device target,
}) async {
  final List<CrossFile> files;
  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final picked = await android_channel.pickFilesAndroid();
      if (picked == null || picked.isEmpty) {
        return null;
      }
      files = [for (final info in picked) await CrossFileConverters.convertFileInfo(info)];
    } else {
      final picked = await openFiles();
      if (picked.isEmpty) {
        return null;
      }
      files = [for (final xfile in picked) await CrossFileConverters.convertXFile(xfile)];
    }
  } catch (e) {
    _logger.warning('Failed to pick files', e);
    return SendFailure.unknown;
  }

  final sessionId = _uuid.v4();
  try {
    await ref.notifier(sendProvider).startSession(
      target: target,
      files: files,
      background: true,
      sessionIdOverride: sessionId,
    );
  } catch (e) {
    _logger.warning('Failed to send files', e);
    await _recordFailedFiles(ref: ref, target: target, files: files);
    return SendFailure.unknown;
  }

  final session = ref.read(sendProvider)[sessionId];
  if (session == null) {
    // 会话已被收掉：文件正在后台传输，后续由 upload 事件记录到会话里。
    return null;
  }

  final failure = _failureOf(session.status);
  if (failure != null) {
    await _recordFailedFiles(ref: ref, target: target, files: files);
    ref.notifier(sendProvider).closeSession(sessionId);
  }
  return failure;
}

/// 文件没进入传输阶段时（被拒绝 / 对方忙 / 断网），补一条失败气泡。
///
/// 正常传输由 `send_provider` 的 Started / Finished 事件记录，
/// 这里只处理「一次 upload 事件都不会有」的情况。
Future<void> _recordFailedFiles({
  required Ref ref,
  required Device target,
  required List<CrossFile> files,
}) async {
  for (final file in files) {
    await markSentFile(
      ref: ref,
      target: target,
      messageId: _uuid.v4(),
      fileName: file.name,
      filePath: file.path,
      fileSize: file.size,
      fileType: file.fileType,
      success: false,
    );
  }
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
