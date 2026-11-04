/// 会话（按对端设备聚合）与单条消息的领域模型。
///
/// 设计要点（相对 M1 的改进）：
/// 1. 会话以 `peerFingerprint` 为稳定主键。M1 用 `senderAlias`（显示名）分组，
///    对端改个名字就会分裂成两个会话，两台同名设备又会错误合并。
/// 2. 支持收发双向。上游只有 `receiveHistory`，从来不记录已发送内容。
/// 3. 消息数量上限按会话独立计算，不再受 `receiveHistory` 全局 30 条的限制。
/// 4. 自带 JSON 序列化，不依赖 build_runner，避免与上游的 dart_mappable 代码生成耦合。
library;

import 'package:collection/collection.dart';
import 'package:localchat_isolates/model/file_type.dart';


/// 会话中单条消息的方向。
enum ChatMessageDirection {
  sent,
  received,
}

/// 会话中单条消息的类型。
enum ChatMessageKind {
  /// 纯文本消息（LocalSend 协议的 message 字段）。
  text,

  /// 文件消息。
  file,
}

/// 消息的投递状态。
///
/// 接收侧恒为 [received]；发送侧经历 [pending] -> [sent] 或 [failed]。
enum ChatMessageStatus {
  pending,
  sent,
  received,
  failed,
}

class ChatMessage {
  /// 全局唯一 ID（UUID）。用于去重，保证重复写入是幂等的。
  final String id;

  final ChatMessageDirection direction;
  final ChatMessageKind kind;
  final DateTime timestamp;
  final ChatMessageStatus status;

  /// 文本消息的内容。当 [kind] 为 [ChatMessageKind.text] 时非空。
  final String? text;

  /// 文件名。当 [kind] 为 [ChatMessageKind.file] 时非空。
  final String? fileName;

  /// 本地绝对路径。
  ///
  /// - 接收方向：文件落盘后的路径（可能为 null，例如仅保存到相册）。
  /// - 发送方向：发送前的源文件路径。
  final String? filePath;

  final int fileSize;
  final FileType? fileType;

  /// 失败原因，仅在 [status] == [ChatMessageStatus.failed] 时有意义。
  final String? errorMessage;

  const ChatMessage({
    required this.id,
    required this.direction,
    required this.kind,
    required this.timestamp,
    required this.status,
    this.text,
    this.fileName,
    this.filePath,
    this.fileSize = 0,
    this.fileType,
    this.errorMessage,
  });

  bool get isOutgoing => direction == ChatMessageDirection.sent;

  /// 会话列表里显示的摘要文本。
  ///
  /// 返回 `null` 表示这条消息没有可显示的正文（空文本 / 无名文件），由 UI 层
  /// 填充占位文案。占位文案要走 i18n，而模型层刻意不依赖 `gen/strings.g.dart`。
  String? get preview {
    if (kind == ChatMessageKind.text) {
      final value = text ?? '';
      return value.isEmpty ? null : value;
    }
    return fileName;
  }

  ChatMessage copyWith({
    ChatMessageStatus? status,
    String? filePath,
    String? errorMessage,
    /// [FORK] 为 true 时把 [errorMessage] 清空（重发时要抹掉上一次的失败原因）。
    bool clearError = false,
  }) {
    return ChatMessage(
      id: id,
      direction: direction,
      kind: kind,
      timestamp: timestamp,
      status: status ?? this.status,
      text: text,
      fileName: fileName,
      filePath: filePath ?? this.filePath,
      fileSize: fileSize,
      fileType: fileType,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'direction': direction.name,
      'kind': kind.name,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'status': status.name,
      if (text != null) 'text': text,
      if (fileName != null) 'fileName': fileName,
      if (filePath != null) 'filePath': filePath,
      'fileSize': fileSize,
      if (fileType != null) 'fileType': fileType!.name,
      if (errorMessage != null) 'errorMessage': errorMessage,
    };
  }

  /// 容错解析。
  ///
  /// 持久化数据可能来自更早的版本，字段缺失或枚举值未知时一律降级，
  /// 绝不因为一条脏数据让整个会话列表加载失败。
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String? ?? '',
      direction: ChatMessageDirection.values.firstWhereOrNull((e) => e.name == json['direction']) ?? ChatMessageDirection.received,
      kind: ChatMessageKind.values.firstWhereOrNull((e) => e.name == json['kind']) ?? ChatMessageKind.file,
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      status: ChatMessageStatus.values.firstWhereOrNull((e) => e.name == json['status']) ?? ChatMessageStatus.received,
      text: json['text'] as String?,
      fileName: json['fileName'] as String?,
      filePath: json['filePath'] as String?,
      fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
      fileType: FileType.values.firstWhereOrNull((e) => e.name == json['fileType']),
      errorMessage: json['errorMessage'] as String?,
    );
  }
}

class Conversation {
  /// 对端设备指纹，稳定主键。
  ///
  /// 若上游某条路径拿不到指纹，会退化为 `alias:<别名>` 形式的伪键，
  /// 以保证消息不丢失（代价是这类会话在对方改名后可能分裂）。
  final String peerFingerprint;

  /// 对端最新显示的别名（可随对端改名而更新）。
  final String peerAlias;

  /// 最近一次交互时对端的 IP 与端口，便于从会话页直接发文件。
  final String? peerIp;
  final int? peerPort;

  /// 最近一条消息的时间，用于会话列表排序。
  final DateTime lastActivity;

  /// 未读消息数（仅统计接收方向）。
  final int unreadCount;

  /// 消息列表，按时间正序（旧 -> 新）。
  final List<ChatMessage> messages;

  const Conversation({
    required this.peerFingerprint,
    required this.peerAlias,
    required this.lastActivity,
    required this.unreadCount,
    required this.messages,
    this.peerIp,
    this.peerPort,
  });

  ChatMessage? get lastMessage => messages.isEmpty ? null : messages.last;

  String get displayName => peerAlias.isEmpty ? peerFingerprint : peerAlias;

  /// 头像占位字符。
  ///
  /// 用 runes 而非 substring，避免把 emoji 的代理对截断成乱码。
  String get initial {
    final name = displayName;
    if (name.isEmpty) {
      return '?';
    }
    return String.fromCharCode(name.runes.first);
  }

  Conversation copyWith({
    String? peerAlias,
    String? peerIp,
    int? peerPort,
    DateTime? lastActivity,
    int? unreadCount,
    List<ChatMessage>? messages,
  }) {
    return Conversation(
      peerFingerprint: peerFingerprint,
      peerAlias: peerAlias ?? this.peerAlias,
      peerIp: peerIp ?? this.peerIp,
      peerPort: peerPort ?? this.peerPort,
      lastActivity: lastActivity ?? this.lastActivity,
      unreadCount: unreadCount ?? this.unreadCount,
      messages: messages ?? this.messages,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'peerFingerprint': peerFingerprint,
      'peerAlias': peerAlias,
      if (peerIp != null) 'peerIp': peerIp,
      if (peerPort != null) 'peerPort': peerPort,
      'lastActivity': lastActivity.toUtc().toIso8601String(),
      'unreadCount': unreadCount,
      'messages': messages.map((m) => m.toJson()).toList(),
    };
  }

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final rawMessages = (json['messages'] as List?) ?? const [];
    final messages = rawMessages
        .whereType<Map>()
        .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
        .where((m) => m.id.isNotEmpty)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return Conversation(
      peerFingerprint: json['peerFingerprint'] as String? ?? '',
      peerAlias: json['peerAlias'] as String? ?? '',
      peerIp: json['peerIp'] as String?,
      peerPort: (json['peerPort'] as num?)?.toInt(),
      lastActivity: DateTime.tryParse(json['lastActivity'] as String? ?? '')?.toLocal() ??
          (messages.isEmpty ? DateTime.now() : messages.last.timestamp),
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
      messages: messages,
    );
  }
}

/// 单个会话保留的最大消息条数。
///
/// 与上游 `receiveHistory` 的全局 30 条不同，这里是「每会话」独立上限。
const int maxMessagesPerConversation = 500;

/// 保留的最大会话数量，超出时丢弃最久未活动的会话。
const int maxConversations = 200;

/// 会话列表的排序：按最近活动时间倒序。
List<Conversation> sortConversations(List<Conversation> input) {
  final sorted = [...input]..sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
  return sorted;
}
