import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:localchat_app/util/conversation/chat_presence.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:logging/logging.dart';

final _logger = Logger('NotificationSound');

/// 收到消息 / 文件时的提示音。
///
/// [FORK] 整个文件为 fork 新增。
///
/// 之所以自己出声而不是只靠系统通知：
/// - 桌面端（Windows / macOS / Linux）没有任何系统通知，托盘藏着的时候收消息完全无感；
/// - 文件接收请求从来不发通知（会直接弹接收页），没有声音就只能指望用户盯着屏幕；
/// - 手机前台时通知按设计不弹（用户正看着 App），也就没有声音。
///
/// 反过来，**手机后台绝不自己出声**：那条路径由系统通知渠道负责，两边都响就是双声。
class NotificationSound {
  NotificationSound._();

  static const _messageAsset = 'audio/notify_message.wav';
  static const _fileAsset = 'audio/notify_file.wav';

  static Future<AudioPlayer>? _player;
  static final _gate = NotificationSoundGate();

  static bool get _isMobile => checkPlatform([TargetPlatform.android, TargetPlatform.iOS]);

  /// 预热：建好播放器，并把两个音频从 asset 解到临时目录。
  ///
  /// 不预热的话第一声会迟到 100~300ms（MediaPlayer / Media Foundation 初始化），
  /// 听感上是「消息到了，过一会儿才响」，比不响还怪。
  static Future<void> warmUp() async {
    try {
      await _ensurePlayer();
      await AudioCache.instance.loadAll([_messageAsset, _fileAsset]);
    } catch (e, st) {
      _logger.warning('Could not warm up the notification sound', e, st);
    }
  }

  /// 收到文本消息。
  static Future<void> playMessage({required bool enabled}) async {
    final allowed = _gate.allowMessage(
      enabled: enabled,
      mobileInBackground: _isMobile && !ChatPresence.isForeground,
      now: DateTime.now(),
    );
    if (!allowed) {
      return;
    }
    await _play(_messageAsset);
  }

  /// 收到文件：请求到达（需要用户点接受）或自动接收落盘完成。
  ///
  /// 同一个会话只响一次——多文件传输会走同一条会话，逐文件响就成了连发警报。
  static Future<void> playFile({required bool enabled, required String sessionId}) async {
    if (!_gate.allowFile(enabled: enabled, sessionId: sessionId)) {
      return;
    }
    await _play(_fileAsset);
  }

  static Future<void> _play(String asset) async {
    try {
      final player = await _ensurePlayer();
      // 每次播前再重申一次音量：播放器是长生命周期的，原生侧一旦重建就回落 1.0，
      // 那种「偶尔特别响」最难查，索性每次都说一遍。
      await player.setVolume(_volume);
      await player.play(AssetSource(asset));
    } catch (e, st) {
      // 播放失败只记日志：提示音是锦上添花，绝不能影响收发本身。
      _logger.warning('Could not play $asset', e, st);
    }
  }

  static Future<AudioPlayer> _ensurePlayer() {
    return _player ??= _createPlayer().onError<Object>((error, stackTrace) {
      // 建失败就把失败的 future 清掉，下一次还能重试，否则会永久失效。
      _player = null;
      throw error;
    });
  }

  /// 手机音量档位。
  ///
  /// 同一份 wav 在桌面音箱上刚好，搁在手机扬声器上（离人 30cm 且无衰减）就偏吵。
  /// 演进：1.0 → 0.6（-4.4 dB，仍偏大）→ 0.35（-9 dB）→ **0.2（约 -14 dB）**。
  /// 用户要的是「只压这个 App 的自定义音频」，不能靠调系统通知音量，
  /// 所以增益只能一路往下走；真到听不见时再回一档即可，改这个常数重装就行。
  /// 桌面端维持 1.0，两端共用同一份 asset，不重做音频文件。
  static const _mobileVolume = 0.2;

  static double get _volume => _isMobile ? _mobileVolume : 1.0;

  static Future<AudioPlayer> _createPlayer() async {
    final player = AudioPlayer(playerId: 'localchat_notification');
    // 默认是 release：每次播完把原生播放器释放掉，下一声又要重新初始化。
    await player.setReleaseMode(ReleaseMode.stop);
    await player.setAudioContext(_audioContext());
    // 音量放在上下文之后：Android 侧设置 AudioContext 可能在底层重建播放器，
    // 先设音量有被重置回 1.0 的风险（这也是「改了但听着没变」的可疑来源之一）。
    await player.setVolume(_volume);
    return player;
  }

  /// 通知类音频上下文。
  ///
  /// 默认的 `usage = media` 走 STREAM_MUSIC，**会绕过静音和勿扰**——半夜收到消息照响。
  /// 这里显式声明「这是一条通知音」，系统才会按静音 / 勿扰规则决定要不要真的出声。
  /// iOS 用 `ambient`：静音键拨下来时同样不响。
  static AudioContext _audioContext() => AudioContext(
    android: const AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.notification,
      audioFocus: AndroidAudioFocus.none,
    ),
    iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
  );
}

/// 什么时候该响。
///
/// 抽成纯逻辑是为了能单测：项目里只有 `package:test`，没有 widget test，
/// 而播放本身依赖平台通道，只能靠真机听。
@visibleForTesting
class NotificationSoundGate {
  NotificationSoundGate({this.mergeWindow = const Duration(milliseconds: 600)});

  /// 合并窗口要比音频本身（500ms）长一点，否则对方连发两条会把第一声截成半声。
  final Duration mergeWindow;

  DateTime? _lastMessageAt;
  final Set<String> _fileSessions = {};

  /// 记录文件会话的上限，只是防止长时间运行后无限增长。
  static const _maxSessions = 64;

  bool allowMessage({
    required bool enabled,
    required bool mobileInBackground,
    required DateTime now,
  }) {
    if (!enabled || mobileInBackground) {
      return false;
    }
    final last = _lastMessageAt;
    if (last != null && now.difference(last) < mergeWindow) {
      return false;
    }
    _lastMessageAt = now;
    return true;
  }

  bool allowFile({required bool enabled, required String sessionId}) {
    if (!enabled) {
      return false;
    }
    if (!_fileSessions.add(sessionId)) {
      return false;
    }
    if (_fileSessions.length > _maxSessions) {
      // 默认 Set 是 LinkedHashSet，first 就是最早插入的那个。
      _fileSessions.remove(_fileSessions.first);
    }
    return true;
  }
}
