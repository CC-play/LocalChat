import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:localchat_app/config/theme.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/model/state/server/receive_session_state.dart';
import 'package:localchat_app/pages/conversation_page.dart';
import 'package:localchat_app/pages/home_page.dart';
import 'package:localchat_app/pages/home_page_controller.dart';
import 'package:localchat_app/pages/web_share_page.dart';
import 'package:localchat_app/provider/conversation_provider.dart';
import 'package:localchat_app/provider/file_transfer_provider.dart';
import 'package:localchat_app/provider/network/send_provider.dart';
import 'package:localchat_app/provider/network/server/server_provider.dart';
import 'package:localchat_app/provider/settings_provider.dart';
import 'package:localchat_app/util/conversation/conversation_recorder.dart';
import 'package:localchat_app/util/native/open_file.dart';
import 'package:localchat_app/util/native/open_folder.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/util/native/taskbar_helper.dart';
import 'package:localchat_app/util/notification_strings.dart';
import 'package:localchat_app/util/ui/nav_bar_padding.dart';
import 'package:localchat_app/widget/custom_progress_bar.dart';
import 'package:localchat_app/widget/dialogs/cancel_session_dialog.dart';
import 'package:localchat_app/widget/dialogs/error_dialog.dart';
import 'package:localchat_app/widget/file_thumbnail.dart';
import 'package:localchat_isolates/model/dto/file_dto.dart';
import 'package:localchat_isolates/model/file_status.dart';
import 'package:localchat_isolates/model/session_status.dart';
import 'package:localchat_isolates/util/file_size_helper.dart';
import 'package:localchat_isolates/util/file_speed_helper.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// Extra space needed below the file list while the progress details are expanded.
const _advancedProgressPanelExtraPadding = 100.0;

class ProgressPage extends StatefulWidget {
  final bool showAppBar;
  final bool closeSessionOnClose;
  final String sessionId;

  const ProgressPage({
    required this.showAppBar,
    required this.closeSessionOnClose,
    required this.sessionId,
  });

  @override
  State<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends State<ProgressPage> with Refena {
  int _totalBytes = double.maxFinite.toInt();
  int _lastRemainingTimeUpdate = 0; // millis since epoch
  String? _remainingTime;
  List<FileDto> _files = []; // also contains declined files (files without token)
  Set<String> _selectedFiles = {};
  SessionStatus? _lastStatus;

  /// [FORK] 对端在会话存储里的主键（进页面时算好并缓存）。
  ///
  /// 必须提前抓：`_exit` 会先把这个 session 关掉，之后再读 `sendProvider` /
  /// `serverProvider` 已经拿不到设备信息，想算主键也来不及了。
  String? _peerKey;

  // If [autoFinish] is enabled, we wait a few seconds before automatically closing the session.
  int _finishCounter = 3;
  Timer? _finishTimer;
  Timer? _wakelockPlusTimer;

  bool _advanced = false;

  /// On Android the foreground service keeps the process and the connection alive,
  /// so there is no reason to also keep the screen on.
  bool get _useWakelock => checkPlatformIsNot([TargetPlatform.android]);

  @override
  void initState() {
    super.initState();

    // init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // [FORK] session 还在时先把对端主键记下来，供传输完成后跳会话使用。
      _peerKey = _resolvePeerKey();

      if (_useWakelock) {
        try {
          unawaited(WakelockPlus.enable());
        } catch (_) {}

        // Poll for completion and disable the wakelock once.
        // We must NOT call WakelockPlus.enable() repeatedly here: on Linux (FreeDesktop D-Bus ScreenSaver)
        // each enable() acquires a new inhibit cookie while disable() only releases one, so re-calling
        // enable() every 30s leaks inhibit locks that keep the screen awake indefinitely (issue #3209).
        _wakelockPlusTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
          // an empty iterable (session already removed) also counts as finished
          final finished = ref.read(fileTransferProvider).getStatuses(widget.sessionId).isFinishedOrSkipped;
          if (finished) {
            timer.cancel();
            try {
              unawaited(WakelockPlus.disable());
            } catch (_) {}
          }
        });
      }

      if (ref.read(settingsProvider).autoFinish) {
        _finishTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          // an empty iterable (session already removed) also counts as finished
          final finished = ref.read(fileTransferProvider).getStatuses(widget.sessionId).isFinishedOrSkipped;
          if (finished) {
            if (_finishCounter == 1) {
              timer.cancel();
              // [FORK] 自动关闭时带上 openConversation：传成功了就落到对端会话。
              _exit(closeSession: true, openConversation: true);
            } else {
              setState(() {
                _finishCounter--;
              });
            }
          }
        });
      }

      setState(() {
        final receiveSession = ref.read(serverProvider)?.session;
        if (receiveSession != null) {
          _files = receiveSession.files.values.map((f) => f.file).toList();
        } else {
          final sendSession = ref.read(sendProvider)[widget.sessionId];
          if (sendSession != null) {
            _files = sendSession.files.values.map((f) => f.file).toList();
          }
        }

        // We previously used f.token != null here, but this may not work on very fast networks.
        final transferNotifier = ref.read(fileTransferProvider);
        _selectedFiles = _files
            .where((f) => transferNotifier.getStatus(sessionId: widget.sessionId, fileId: f.id) != FileStatus.skipped)
            .map((f) => f.id)
            .toSet();

        _totalBytes = _files.where((f) => _selectedFiles.contains(f.id)).fold(0, (prev, curr) => prev + curr.size);
      });
    });
  }

  void _exit({required bool closeSession, bool openConversation = false}) async {
    final receiveSession = ref.read(serverProvider.select((s) => s?.session));
    final sendSession = ref.read(sendProvider)[widget.sessionId];
    final SessionStatus? status = receiveSession?.status ?? sendSession?.status;
    final keepSession = !closeSession && (status == SessionStatus.sending || status == SessionStatus.finishedWithErrors);
    final result = status == null || keepSession || await _askCancelConfirmation(status);

    if (result && mounted) {
      if (ref.read(serverProvider)?.webUpload == true) {
        context.global.dispatch(NavigateAction.popUntil<WebSharePage>());
      } else if (openConversation && _lastKnownStatus(status) == SessionStatus.finished && _openPeerConversation()) {
        // [FORK] 已经落在对端会话页，不需要再回首页。
      } else {
        context.global.dispatch(NavigateAction.popUntilRoot());
      }
    }
  }

  /// 状态取「当前能读到的」，读不到（session 已被上层关掉）就退回上一次渲染时的值。
  ///
  /// 自动关闭的最后一步可能正好撞上 session 被移除，这时 [status] 是 null，
  /// 但传输其实已经成功——只看 null 会漏掉这种最该跳会话的情况。
  SessionStatus? _lastKnownStatus(SessionStatus? status) => status ?? _lastStatus;

  /// [FORK] 当前传输对端在会话存储里的主键。
  ///
  /// 走 [peerKeyOf] 而不是直接读 `fingerprint`：它和写会话时用的是同一套规则
  /// （指纹优先，没有指纹才退化成 `alias:<别名>`），否则 Web 对端永远对不上。
  String? _resolvePeerKey() {
    final device = ref.read(serverProvider)?.session?.sender ?? ref.read(sendProvider)[widget.sessionId]?.target;
    if (device == null) {
      return null;
    }
    final key = peerKeyOf(device);
    // `alias:` 是「指纹和别名都为空」时拼出来的空壳键，不能拿去匹配。
    return key.isEmpty || key == 'alias:' ? null : key;
  }

  /// [FORK] 传输成功后直接进对端会话页。
  ///
  /// 只在会话列表里确实存在这条会话时才跳：没有会话（用户清空过列表、对端是
  /// 从没聊过的设备）就保持原来的行为——回首页。
  ///
  /// 返回 true 表示已经完成导航，调用方不要再 pop。
  bool _openPeerConversation() {
    final peerKey = _peerKey;
    if (peerKey == null) {
      return false;
    }
    final exists = ref.read(conversationProvider).any((c) => c.peerFingerprint == peerKey);
    if (!exists) {
      return false;
    }

    // 先用全局 navigator 清到首页，再压入会话页，这样用户从会话页返回落在列表上。
    // 两个调用都不能用本页 context：popUntilRoot 已经把本页移出路由栈了。
    //
    // 顺带把底部 Tab 切到会话：从发送页发起的传输同样会跳过来，返回时落在会话列表
    // 比落回「发送」更连贯（会话 Tab 也是首页的初始 Tab）。
    ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.conversations));
    final navigation = ref.read(navigationProvider);
    navigation.popUntilRoot();
    unawaited(Routerino.context.push(() => ConversationPage(peerFingerprint: peerKey)));
    return true;
  }

  Future<bool> _askCancelConfirmation(SessionStatus status) async {
    final bool result = switch (status == SessionStatus.sending) {
      true => (await context.pushBottomSheet(() => const CancelSessionDialog())) == true,
      false => true,
    };
    if (result) {
      final receiveSession = ref.read(serverProvider)?.session;
      final sendState = ref.read(sendProvider)[widget.sessionId];

      if (receiveSession != null) {
        if (receiveSession.status == SessionStatus.sending) {
          ref.notifier(serverProvider).cancelSession();
        } else {
          ref.notifier(serverProvider).closeSession();
        }
      } else if (sendState != null) {
        if (sendState.status == SessionStatus.sending) {
          ref.notifier(sendProvider).cancelSession(widget.sessionId);
        } else {
          ref.notifier(sendProvider).closeSession(widget.sessionId);
        }
      }
    }
    return result;
  }

  @override
  void dispose() {
    super.dispose();
    _finishTimer?.cancel();
    _wakelockPlusTimer?.cancel();
    TaskbarHelper.clearProgressBar(); // ignore: discarded_futures
    if (_useWakelock) {
      try {
        WakelockPlus.disable(); // ignore: discarded_futures
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final transferNotifier = ref.watch(fileTransferProvider);
    final currBytes = _files.fold<int>(
      0,
      (prev, curr) => prev + ((transferNotifier.getProgress(sessionId: widget.sessionId, fileId: curr.id) * curr.size).round()),
    );

    // No select: comparing the selected session runs the dart_mappable deep equality
    // over the whole files map on every state change.
    final receiveSession = ref.watch(serverProvider)?.session;
    final sendSession = ref.watch(sendProvider)[widget.sessionId];

    final SessionState? commonSessionState = receiveSession ?? sendSession;

    if (commonSessionState == null) {
      // The session no longer exists, e.g. a multi-send session that finished successfully
      // in background gets removed while this page is still open.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        if (ref.read(serverProvider)?.webUpload == true) {
          context.global.dispatch(NavigateAction.popUntil<WebSharePage>());
        } else if (_lastStatus == SessionStatus.finished && _openPeerConversation()) {
          // [FORK] 后台完成了、session 已被移除：同样落到对端会话页。
        } else {
          context.global.dispatch(NavigateAction.popUntilRoot());
        }
      });
      return Scaffold(
        body: Container(),
      );
    }

    final status = commonSessionState.status;

    if (status == SessionStatus.sending) {
      // ignore: discarded_futures
      TaskbarHelper.setProgressBar(currBytes, _totalBytes);
    } else if (status != _lastStatus) {
      _lastStatus = status;
      // ignore: discarded_futures
      TaskbarHelper.visualizeStatus(status);
    }

    final title = receiveSession != null ? t.progressPage.titleReceiving : t.progressPage.titleSending;
    final startTime = commonSessionState.startTime;
    final endTime = commonSessionState.endTime;
    final int? speedInBytes;
    if (startTime != null && currBytes >= 500 * 1024) {
      speedInBytes = getFileSpeed(start: startTime, end: endTime ?? DateTime.now().millisecondsSinceEpoch, bytes: currBytes);

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastRemainingTimeUpdate >= 1000) {
        _remainingTime = getRemainingTime(bytesPerSeconds: speedInBytes, remainingBytes: _totalBytes - currBytes, strings: notificationStrings);
        _lastRemainingTimeUpdate = now;
      }
    } else {
      speedInBytes = null;
    }

    final finishedCount = transferNotifier.getStatuses(widget.sessionId).where((s) => s == FileStatus.finished).length;

    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          // Already popped.
          // Because the user cannot pop this page, we can safely assume that all sessions are closed if they should be.
          return;
        }
        _exit(closeSession: widget.closeSessionOnClose);
      },
      canPop: false,
      child: Scaffold(
        appBar: widget.showAppBar
            ? AppBar(
                title: Text(title),
              )
            : null,
        body: Stack(
          children: [
            ListView.builder(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 20,
                bottom: 150 + (_advanced ? _advancedProgressPanelExtraPadding : 0) + getNavBarPadding(context),
                left: 15,
                right: 30,
              ),
              itemCount: _files.length + 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  // title
                  if (widget.showAppBar) {
                    return Container();
                  }

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: Theme.of(context).textTheme.titleLarge),
                        if (checkPlatformWithFileSystem() && receiveSession != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${t.settingsTab.receive.destination}: ',
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                                  TextSpan(
                                    text: receiveSession.destinationDirectory,
                                    style: TextStyle(
                                      color: checkPlatform([TargetPlatform.iOS]) ? Colors.grey : Theme.of(context).colorScheme.primary,
                                    ),
                                    recognizer: checkPlatform([TargetPlatform.iOS])
                                        ? null
                                        : (TapGestureRecognizer()
                                            ..onTap = () async {
                                              await openFolder(folderPath: receiveSession.destinationDirectory);
                                            }),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                }

                if (index == 1) {
                  // error card
                  final errorMessage = sendSession?.errorMessage;
                  if (errorMessage == null) {
                    return Container();
                  }

                  return SelectableText(errorMessage, style: TextStyle(color: Theme.of(context).colorScheme.warning));
                }

                final file = _files[index - 2];
                final String fileName = receiveSession?.files[file.id]?.desiredName ?? file.fileName;

                final fileStatus = transferNotifier.getStatus(sessionId: widget.sessionId, fileId: file.id);
                final savedToGallery = receiveSession?.files[file.id]?.savedToGallery ?? false;

                final String? filePath;
                if (receiveSession != null && fileStatus == FileStatus.finished && !savedToGallery) {
                  filePath = receiveSession.files[file.id]!.path;
                } else if (sendSession != null) {
                  filePath = sendSession.files[file.id]!.path;
                } else {
                  filePath = null;
                }

                final String? errorMessage;
                if (receiveSession != null) {
                  errorMessage = receiveSession.files[file.id]!.errorMessage;
                } else if (sendSession != null) {
                  errorMessage = sendSession.files[file.id]!.errorMessage;
                } else {
                  errorMessage = null;
                }

                final Uint8List? thumbnail;
                final AssetEntity? asset;
                if (sendSession != null) {
                  thumbnail = sendSession.files[file.id]!.thumbnail;
                  asset = sendSession.files[file.id]!.asset;
                } else {
                  thumbnail = null;
                  asset = null;
                }

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: InkWell(
                    splashColor: Colors.transparent,
                    splashFactory: NoSplash.splashFactory,
                    highlightColor: Colors.transparent,
                    hoverColor: Colors.transparent,
                    onTap: filePath != null && receiveSession != null ? () async => openFile(context, file.fileType, filePath!) : null,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SmartFileThumbnail(
                          bytes: thumbnail,
                          asset: asset,
                          path: filePath,
                          fileType: file.fileType,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      fileName,
                                      style: const TextStyle(fontSize: 16, height: 1),
                                      maxLines: 1,
                                      overflow: TextOverflow.fade,
                                      softWrap: false,
                                    ),
                                  ),
                                  Text(' (${file.size.asReadableFileSize})', style: const TextStyle(fontSize: 16, height: 1)),
                                ],
                              ),
                              const SizedBox(height: 5),
                              if (fileStatus == FileStatus.sending)
                                Padding(
                                  padding: const EdgeInsets.only(top: 5),
                                  child: CustomProgressBar(
                                    progress: transferNotifier.getProgress(sessionId: widget.sessionId, fileId: file.id),
                                  ),
                                )
                              else
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        savedToGallery ? t.progressPage.savedToGallery : fileStatus.label,
                                        style: TextStyle(color: fileStatus.getColor(context), height: 1),
                                      ),
                                    ),
                                    if (errorMessage != null) ...[
                                      const SizedBox(width: 5),
                                      InkWell(
                                        onTap: () async {
                                          await showDialog(
                                            context: context,
                                            builder: (_) => ErrorDialog(error: errorMessage!),
                                          );
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 5),
                                          child: Icon(Icons.info, color: Theme.of(context).colorScheme.warning, size: 20),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                            ],
                          ),
                        ),
                        if (sendSession != null && fileStatus == FileStatus.failed)
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            onPressed: () async {
                              await ref
                                  .notifier(sendProvider)
                                  .sendFile(
                                    sessionId: widget.sessionId,
                                    file: sendSession.files[file.id]!,
                                    isRetry: true,
                                  );
                            },
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(left: 10, right: 10, bottom: 10),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 15, right: 15, bottom: 5, top: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            status.getLabel(
                              remainingTime: _remainingTime ?? '-',
                            ),
                            style: const TextStyle(fontSize: 20),
                          ),
                          const SizedBox(height: 5),
                          TweenAnimationBuilder(
                            tween: Tween<double>(begin: 0, end: _totalBytes == 0 ? 0 : currBytes / _totalBytes),
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            builder: (context, value, child) {
                              return CustomProgressBar(
                                progress: value,
                                borderRadius: 5,
                              );
                            },
                          ),
                          AnimatedCrossFade(
                            crossFadeState: _advanced ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                            duration: const Duration(milliseconds: 200),
                            alignment: Alignment.topLeft,
                            firstChild: Container(),
                            secondChild: Padding(
                              padding: const EdgeInsets.only(top: 10, bottom: 5),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t.progressPage.total.count(
                                      curr: finishedCount,
                                      n: _selectedFiles.length,
                                    ),
                                  ),
                                  Text(
                                    t.progressPage.total.size(
                                      curr: currBytes.asReadableFileSize,
                                      n: _totalBytes == double.maxFinite.toInt() ? '-' : _totalBytes.asReadableFileSize,
                                    ),
                                  ),
                                  if (speedInBytes != null)
                                    Text(
                                      t.progressPage.total.speed(
                                        speed: speedInBytes.asReadableFileSize,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton.icon(
                                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
                                onPressed: () {
                                  setState(() => _advanced = !_advanced);
                                },
                                icon: const Icon(Icons.info),
                                label: Text(_advanced ? t.general.hide : t.general.advanced),
                              ),
                              TextButton.icon(
                                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
                                onPressed: () => _exit(closeSession: true),
                                icon: Icon(status == SessionStatus.sending ? Icons.close : Icons.check_circle),
                                label: Text(
                                  status == SessionStatus.sending
                                      ? t.general.cancel
                                      : _finishTimer != null
                                      ? '${t.general.done} ($_finishCounter)'
                                      : t.general.done,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension on FileStatus {
  String get label {
    switch (this) {
      case FileStatus.queue:
        return t.general.queue;
      case FileStatus.skipped:
        return t.general.skipped;
      case FileStatus.sending:
        return ''; // progress bar will be showed here
      case FileStatus.failed:
        return t.general.error;
      case FileStatus.finished:
        return t.general.done;
    }
  }

  Color getColor(BuildContext context) {
    switch (this) {
      case FileStatus.queue:
        return Theme.of(context).colorScheme.primary;
      case FileStatus.skipped:
        return Colors.grey;
      case FileStatus.sending:
        return Theme.of(context).colorScheme.primary;
      case FileStatus.failed:
        return Theme.of(context).colorScheme.warning;
      case FileStatus.finished:
        return Theme.of(context).colorScheme.primary;
    }
  }
}

extension on SessionStatus {
  String getLabel({required String remainingTime}) {
    switch (this) {
      case SessionStatus.sending:
        return t.progressPage.total.title.sending(
          time: remainingTime,
        );
      case SessionStatus.finished:
        return t.general.finished;
      case SessionStatus.finishedWithErrors:
        return t.progressPage.total.title.finishedError;
      case SessionStatus.canceledBySender:
        return t.progressPage.total.title.canceledSender;
      case SessionStatus.canceledByReceiver:
        return t.progressPage.total.title.canceledReceiver;
      default:
        return '';
    }
  }
}
