import 'package:flutter/services.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';

final _logger = Logger('ChatNotification');

const _channel = MethodChannel('org.localsend.localsend_app/localsend');

/// 消息通知到底卡在哪一步。
///
/// 拆这么细是因为修法完全不同：没权限要弹系统权限框，App 通知被关只能跳设置，
/// 渠道被关要跳渠道页。vivo / 小米这类 ROM 经常连权限都没来得及问就把通知关了。
enum ChatNotificationBlocker {
  /// 一切正常，消息会正常提醒。
  none,

  /// Android 13+ 的通知权限没给，可以就地弹权限框。
  permission,

  /// 系统设置里把整个 App 的通知关掉了。
  appDisabled,

  /// 只有「消息」这个渠道被单独关掉了。
  channelDisabled,

  /// 非 Android 平台，没有这套系统通知。
  unsupported,
}

/// 消息通知的 Dart 入口。
///
/// [FORK] 整个文件为 fork 新增（上游 LocalSend 没有聊天，也就没有消息提醒）。
///
/// 实现放在原生侧（`MainActivity` 的既有 MethodChannel 上）：项目里只有
/// `flutter_foreground_task`，它那个渠道是 LOW 优先级、静音、不能弹出的，
/// 只能用于传输进度；消息提醒需要 IMPORTANCE_HIGH 才会响铃 + 横幅。
class ChatNotification {
  ChatNotification._();

  static void Function(String peerFingerprint)? _onTap;

  static bool get supported => checkPlatform([TargetPlatform.android]);

  /// 安装「点击通知」回调，并把 App 启动期间攒下的点击补收回来。
  ///
  /// 冷启动时 Activity 是被通知的 PendingIntent 拉起来的，那次点击没有 onNewIntent
  /// 可走，只能靠这次握手把它们取回来。
  static Future<void> init({required void Function(String peerFingerprint) onTap}) async {
    if (!supported) {
      return;
    }
    _onTap = onTap;

    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onChatNotificationTap') {
        return null;
      }
      final peer = call.arguments;
      if (peer is String && peer.isNotEmpty) {
        _onTap?.call(peer);
      }
      return null;
    });

    try {
      await _channel.invokeMethod('chatNotificationsReady');
    } catch (e, st) {
      _logger.warning('Could not hand over pending chat notification taps', e, st);
    }
  }

  /// 发一条消息通知。
  ///
  /// 同一个对端会合并成一封（原生侧按指纹分配通知 id），重复调用不会刷屏。
  /// 返回 false 表示通知没能显示出来，通常是权限或渠道被关。
  static Future<bool> show({
    required String peerFingerprint,
    required String title,
    required String body,
  }) async {
    if (!supported) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('showChatNotification', {
            'peerFingerprint': peerFingerprint,
            'title': title,
            'body': _previewOf(body),
            'channelName': t.conversation.title,
          }) ??
          false;
    } catch (e, st) {
      _logger.warning('Could not show chat notification', e, st);
      return false;
    }
  }

  /// 通知栏一行大概放得下这么多字符；再长就被系统从中间截断，很难看。
  static const _maxPreviewLength = 160;

  /// 折叠成一行再截断。
  ///
  /// 多行文本（聊天里很常见）如果原样塞进通知，`InboxStyle` 会把它当成好几条消息，
  /// 折叠状态下还可能只显示其中一段，跟真正的未读对不上。
  static String _previewOf(String body) {
    final normalized = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= _maxPreviewLength) {
      return normalized;
    }
    return '${normalized.substring(0, _maxPreviewLength)}…';
  }

  /// 撤掉某个对端的通知（会话被打开、消息已读时调用）。
  static Future<void> clear(String peerFingerprint) async {
    if (!supported || peerFingerprint.isEmpty) {
      return;
    }
    try {
      await _channel.invokeMethod('clearChatNotification', {'peerFingerprint': peerFingerprint});
    } catch (e, st) {
      _logger.warning('Could not clear chat notification', e, st);
    }
  }

  /// 查现在能不能弹通知。
  static Future<ChatNotificationBlocker> blocker() async {
    if (!supported) {
      return ChatNotificationBlocker.unsupported;
    }

    final Map? status;
    try {
      status = await _channel.invokeMethod<Map>('getChatNotificationStatus');
    } catch (e, st) {
      _logger.warning('Could not read chat notification status', e, st);
      return ChatNotificationBlocker.unsupported;
    }
    if (status == null) {
      return ChatNotificationBlocker.unsupported;
    }

    final enabled = status['enabled'] == true;
    final permissionGranted = status['permissionGranted'] == true;
    final channelExists = status['channelExists'] == true;
    final channelImportance = status['channelImportance'] as int?;

    // 渠道还没建过（一条消息都没收过）时它是默认状态，不算被关。
    const importanceNone = 0;
    if (channelExists && channelImportance == importanceNone) {
      return ChatNotificationBlocker.channelDisabled;
    }
    if (!enabled) {
      return ChatNotificationBlocker.appDisabled;
    }
    if (!permissionGranted) {
      return ChatNotificationBlocker.permission;
    }
    return ChatNotificationBlocker.none;
  }

  /// 点「去开启」之后该做什么。
  ///
  /// 没问过权限就先问；已经问过或被永久拒绝（ROM 常见）再去系统设置，
  /// 否则权限框根本不会出现，用户会觉得按钮没反应。
  static Future<ChatNotificationBlocker> requestAccess() async {
    if (!supported) {
      return ChatNotificationBlocker.unsupported;
    }

    final current = await blocker();
    if (current == ChatNotificationBlocker.none) {
      return ChatNotificationBlocker.none;
    }

    if (current == ChatNotificationBlocker.permission) {
      final result = await Permission.notification.request();
      if (result.isGranted) {
        return ChatNotificationBlocker.none;
      }
      // 被拒（含永久拒绝）就落到系统设置，那里至少能手动打开。
    }

    await openSettings();
    return current;
  }

  /// 打开本 App 的消息通知设置。
  static Future<void> openSettings() async {
    if (!supported) {
      return;
    }
    try {
      await _channel.invokeMethod('openChatNotificationSettings', {'channelName': t.conversation.title});
    } catch (e, st) {
      _logger.warning('Could not open notification settings', e, st);
    }
  }
}
