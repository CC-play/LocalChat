import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_app/provider/conversation/chat_transfer_provider.dart';
import 'package:localchat_app/provider/conversation_provider.dart';
import 'package:localchat_app/util/conversation/chat_presence.dart';
import 'package:localchat_app/util/native/chat_notification.dart';
import 'package:localchat_isolates/model/device.dart';
import 'package:localchat_isolates/model/file_type.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

/// 把「接收」事件写入会话存储的唯一入口。
///
/// 之所以单独抽一个文件：接收控制器（`receive_controller.dart`）属于上游代码，
/// 我们只在其中插入一次函数调用，把改动面压到最小，未来同步上游时冲突也最好解。
/// 所有 fork 相关的插入点都用 `[FORK]` 标记。

final _logger = Logger('ConversationRecorder');

const _uuid = Uuid();

/// 计算会话主键。
///
/// 优先用设备指纹；拿不到指纹时才退化为别名伪键（如 Web 端或旧版对端）。
String peerKeyOf(Device device) {
  if (device.fingerprint.isNotEmpty) {
    return device.fingerprint;
  }
  return 'alias:${device.alias}';
}

/// 记录失败绝不能影响收发主流程，因此异常在此吞掉并只记日志。
Future<void> _appendSafely(Ref ref, AppendChatMessageAction action) async {
  try {
    await ref.redux(conversationProvider).dispatchAsync(action);
  } catch (e, st) {
    _logger.warning('Failed to record conversation message', e, st);
  }
}

Future<void> recordReceivedText({
  required Ref ref,
  required Device sender,
  required String senderAlias,
  required String text,
}) async {
  await _appendSafely(
    ref,
    AppendChatMessageAction(
      peerFingerprint: peerKeyOf(sender),
      peerAlias: senderAlias,
      peerIp: sender.ip,
      peerPort: sender.port > 0 ? sender.port : null,
      message: ChatMessage(
        id: _uuid.v4(),
        direction: ChatMessageDirection.received,
        kind: ChatMessageKind.text,
        timestamp: DateTime.now(),
        status: ChatMessageStatus.received,
        text: text,
        fileSize: text.length,
        fileType: FileType.text,
      ),
    ),
  );

  // [FORK] 写完再提醒：通知失败绝不能影响收消息本身。
  // 只做文本 —— 收到文件本来就会弹接收确认页，再发一条通知是重复打扰。
  await _notifyIncomingText(sender: sender, senderAlias: senderAlias, text: text);
}

/// [FORK] App 不在前台时补一条系统通知。
///
/// 前台不弹是有意的：用户就看着 App，列表里的未读角标已经说明了新消息，
/// 系统通知只会打断他正在做的事。
Future<void> _notifyIncomingText({
  required Device sender,
  required String senderAlias,
  required String text,
}) async {
  final peerFingerprint = peerKeyOf(sender);
  // 留一行 info：真机上「没收到提醒」时，第一件事就是确认这里到底判成前台还是后台。
  _logger.info('Incoming text from $peerFingerprint (foreground=${ChatPresence.isForeground})');

  if (ChatPresence.isForeground) {
    // 用户回到前台了，之前留在通知栏里的消息已经没有意义。
    await ChatNotification.clear(peerFingerprint);
    return;
  }

  try {
    await ChatNotification.show(
      peerFingerprint: peerFingerprint,
      title: senderAlias.isEmpty ? sender.alias : senderAlias,
      body: text,
    );
  } catch (e, st) {
    _logger.warning('Failed to show incoming message notification', e, st);
  }
}

Future<void> recordReceivedFile({
  required Ref ref,
  required Device sender,
  required String senderAlias,
  required String messageId,
  required String fileName,
  required String? filePath,
  required int fileSize,
  required FileType fileType,
}) async {
  await _appendSafely(
    ref,
    AppendChatMessageAction(
      peerFingerprint: peerKeyOf(sender),
      peerAlias: senderAlias,
      peerIp: sender.ip,
      peerPort: sender.port > 0 ? sender.port : null,
      message: ChatMessage(
        // 复用 fileId 作为消息 ID：接收侧重传同一文件时天然幂等。
        id: messageId,
        direction: ChatMessageDirection.received,
        kind: ChatMessageKind.file,
        timestamp: DateTime.now(),
        status: ChatMessageStatus.received,
        fileName: fileName,
        filePath: filePath,
        fileSize: fileSize,
        fileType: fileType,
      ),
    ),
  );
}

/// 发送开始：插入一条「发送中」气泡。
///
/// 用源文件 id 作为消息 ID，重试时会走 [markSentFile] 的状态更新而不是新增气泡。
Future<void> recordSentFileStart({
  required Ref ref,
  required Device target,
  required String messageId,
  required String fileName,
  required String? filePath,
  required int fileSize,
  required FileType fileType,
  String? text,
}) async {
  await _appendSafely(
    ref,
    AppendChatMessageAction(
      peerFingerprint: peerKeyOf(target),
      peerAlias: target.alias,
      peerIp: target.ip,
      peerPort: target.port > 0 ? target.port : null,
      message: ChatMessage(
        id: messageId,
        direction: ChatMessageDirection.sent,
        // LocalSend 的「发消息」是伪装成 text 类型文件发送的，按文本气泡呈现更准确。
        kind: text == null ? ChatMessageKind.file : ChatMessageKind.text,
        timestamp: DateTime.now(),
        status: ChatMessageStatus.pending,
        text: text,
        fileName: text == null ? fileName : null,
        filePath: text == null ? filePath : null,
        fileSize: fileSize,
        fileType: fileType,
      ),
    ),
  );
}

/// 发送结果：把「发送中」更新为已发送或失败。
///
/// 若对应气泡不存在（例如 Started 事件丢失、或在应用重启后才收到结果），
/// 则补插一条终态消息，保证不会丢记录。
Future<void> markSentFile({
  required Ref ref,
  required Device target,
  required String messageId,
  required String fileName,
  required String? filePath,
  required int fileSize,
  required FileType fileType,
  required bool success,
  String? errorMessage,
  String? text,
}) async {
  final status = success ? ChatMessageStatus.sent : ChatMessageStatus.failed;
  final peerFingerprint = peerKeyOf(target);

  // [FORK] 进度条到此为止。所有终态都经过这里（成功、上传失败、对端未勾选、
  // 源文件丢失、重试超时），所以清理只需要放这一处。
  try {
    ref.read(chatTransferProvider).finish(messageId);
  } catch (e, st) {
    _logger.warning('Failed to clear chat transfer progress', e, st);
  }

  bool exists = false;
  try {
    exists = ref.read(conversationProvider).any(
          (c) => c.peerFingerprint == peerFingerprint && c.messages.any((m) => m.id == messageId),
        );
  } catch (e, st) {
    _logger.warning('Failed to inspect conversation state', e, st);
  }
  if (exists) {
    try {
      await ref.redux(conversationProvider).dispatchAsync(
            UpdateChatMessageAction(
              peerFingerprint: peerFingerprint,
              messageId: messageId,
              status: status,
              errorMessage: errorMessage,
            ),
          );
    } catch (e, st) {
      _logger.warning('Failed to update conversation message status', e, st);
    }
    return;
  }

  await _appendSafely(
    ref,
    AppendChatMessageAction(
      peerFingerprint: peerFingerprint,
      peerAlias: target.alias,
      peerIp: target.ip,
      peerPort: target.port > 0 ? target.port : null,
      message: ChatMessage(
        id: messageId,
        direction: ChatMessageDirection.sent,
        kind: text == null ? ChatMessageKind.file : ChatMessageKind.text,
        timestamp: DateTime.now(),
        status: status,
        text: text,
        fileName: text == null ? fileName : null,
        filePath: text == null ? filePath : null,
        fileSize: fileSize,
        fileType: fileType,
        errorMessage: errorMessage,
      ),
    ),
  );
}
