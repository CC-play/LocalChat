import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:localchat_app/model/cross_file.dart';
import 'package:localchat_app/model/send_mode.dart';
import 'package:localchat_app/model/state/send/send_session_state.dart';
import 'package:localchat_app/model/state/send/sending_file.dart';
import 'package:localchat_app/pages/home_page.dart';
import 'package:localchat_app/pages/home_page_controller.dart';
import 'package:localchat_app/pages/progress_page.dart';
import 'package:localchat_app/pages/send_page.dart';
import 'package:localchat_app/provider/conversation/chat_transfer_provider.dart';
import 'package:localchat_app/provider/device_info_provider.dart';
import 'package:localchat_app/provider/file_transfer_provider.dart';
import 'package:localchat_app/provider/http_provider.dart';
import 'package:localchat_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localchat_app/provider/settings_provider.dart';
import 'package:localchat_app/util/conversation/conversation_recorder.dart';
import 'package:localchat_app/util/conversation/send_failure.dart';
import 'package:localchat_app/widget/dialogs/pin_dialog.dart';
import 'package:localchat_isolates/isolate.dart';
import 'package:localchat_isolates/model/device.dart';
import 'package:localchat_isolates/model/dto/file_dto.dart';
import 'package:localchat_isolates/model/file_status.dart';
import 'package:localchat_isolates/model/file_type.dart';
import 'package:localchat_isolates/model/session_status.dart';
import 'package:localchat_isolates/rust/api/cancel.dart' as rust_cancel;
import 'package:localchat_isolates/rust/api/http.dart' as rust_http;
import 'package:localchat_isolates/rust/api/model.dart' as rust_model;
import 'package:localchat_isolates/util/file_hash.dart';
import 'package:localchat_isolates/util/rust.dart';
import 'package:localchat_isolates/util/sleep.dart';
import 'package:localchat_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:uri_content/uri_content.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();
final _logger = Logger('Send');

/// This provider manages sending files to other devices.
///
/// In contrast to [serverProvider], this provider does not manage a server.
/// Instead, it only does HTTP requests to other servers.
final sendProvider = NotifierProvider<SendNotifier, Map<String, SendSessionState>>((ref) {
  return SendNotifier();
});

class SendNotifier extends Notifier<Map<String, SendSessionState>> {
  SendNotifier();

  /// Cancel tokens of the running checksum calculations.
  /// Session ID -> Cancel token
  final _hashCancelTokens = <String, rust_cancel.RsCancellationToken>{};

  /// Cancel tokens of the running prepare-upload requests.
  /// Cancelling aborts the request, which tells the receiver that the sender
  /// is no longer waiting for a decision.
  /// Session ID -> Cancel token
  final _prepareUploadCancelTokens = <String, rust_cancel.RsCancellationToken>{};

  /// [FORK] 本 provider 预置的「发送中」气泡。Session ID -> message ids。
  ///
  /// 只有**不传 [startSession.fileIdsOverride]** 的调用方（发送 Tab / 收藏 / 地址 /
  /// 多设备）才登记，聊天页自己预置气泡（它需要精确 alias 与重发能力）。
  /// 收尾必须按这份名单来：`upload` 事件只覆盖「真的开始传」的文件，
  /// 连不上、被拒绝、对端一个都没勾选时不会有任何事件，气泡会永远转圈。
  final _preRecordedMessages = <String, List<String>>{};

  @override
  Map<String, SendSessionState> init() {
    return {};
  }

  /// The debug observer stringifies the state on every change,
  /// so large file maps must be summarized to keep transfers responsive in debug mode.
  @override
  String describeState(Map<String, SendSessionState> state) {
    if (state.values.every((session) => session.files.length <= 10)) {
      return state.toString();
    }
    return state.map((sessionId, session) {
      if (session.files.length <= 10) {
        return MapEntry(sessionId, session.toString());
      }
      return MapEntry(
        sessionId,
        session.copyWith(files: {}).toString().replaceFirst('files: {}', 'files: <${session.files.length} files>'),
      );
    }).toString();
  }

  /// [FORK] 在握手之前先把「发送中」气泡写进会话。
  ///
  /// 普通「发送」入口原来只在 `HttpUploadFileStartedEvent` 里写会话，也就是
  /// 「真的开始传」才有记录：连不上、被拒绝、对端一个都没勾选时，会话里什么都看不到。
  Future<void> _preRecordSessionMessages({
    required String sessionId,
    required Device target,
    required List<({String id, CrossFile file})> files,
    String? text,
  }) async {
    final ids = <String>[];
    for (final (:id, :file) in files) {
      ids.add(id);
      await recordSentFileStart(
        ref: ref,
        target: target,
        messageId: id,
        fileName: file.name,
        filePath: file.path,
        fileSize: file.size,
        fileType: file.fileType,
        // 单文件文本消息的正文（其余情况为 null，会按文件气泡呈现）。
        text: text,
      );
    }
    _preRecordedMessages[sessionId] = ids;
  }

  /// [FORK] 给预置气泡收尾：没有 upload 事件的文件统一标成发送失败。
  ///
  /// 幂等：登记过的会话只处理一次；已被 upload 事件写成终态（成功或失败）的文件跳过。
  Future<void> _settlePreRecorded({required String sessionId, String? errorMessage}) async {
    final ids = _preRecordedMessages.remove(sessionId);
    if (ids == null) {
      return;
    }
    final session = state[sessionId];
    if (session == null) {
      return;
    }
    final transferNotifier = ref.read(fileTransferProvider);
    // 细分失败原因：状态码能直接定性的先定性，剩下的按 Rust 侧留下的原文归类。
    // `finished` 走到这里说明对端回的是 204（一个都没选中），
    // 真正的成功不会留下未完成的文件，下面的 FileStatus.finished 判断已经挡掉了。
    final failure = switch (session.status) {
      SessionStatus.finished => SendFailure.peerDismissed,
      _ => sendFailureOfStatus(session.status, errorMessage: errorMessage),
    };
    final detail = failure == null ? errorMessage : describeSendFailure(failure);
    for (final id in ids) {
      final file = session.files[id];
      if (file == null) {
        continue;
      }
      if (transferNotifier.getStatus(sessionId: sessionId, fileId: id) == FileStatus.finished) {
        continue;
      }
      await markSentFile(
        ref: ref,
        target: session.target,
        messageId: id,
        fileName: file.file.fileName,
        filePath: file.path,
        fileSize: file.file.size,
        fileType: file.file.fileType,
        text: file.file.fileType == FileType.text ? file.file.preview : null,
        success: false,
        errorMessage: detail,
      );
    }
  }

  /// Starts a session.
  /// If [background] is true, then the session closes itself on success and no pages will be open
  /// If [background] is false, then this method will open pages by itself and waits for user input to close the session.
  Future<void> startSession({
    required Device target,
    required List<CrossFile> files,
    required bool background,
    // [FORK] 调用方可以指定会话 id。聊天页需要拿固定 id 才能回读这次会话的结局
    // （成功时会话会被立刻收掉，事后无法再从会话列表里定位它）。
    String? sessionIdOverride,
    // [FORK] 调用方可以预分配文件 id。聊天页要先把「发送中」气泡画出来，
    // 之后 upload 事件必须复用同一批 id，否则同一次发送会冒两条气泡。
    List<String>? fileIdsOverride,
    // [FORK] 校验和缓存（key 为文件 id）。聊天页对同一个文件会重试多次，
    // 若每次都重算，几百 MB 的文件会在两分钟里被反复读盘哈希。
    Map<String, String>? checksumCache,
  }) async {
    // Pinned to the device the user picked, so the request is not sent at all
    // if someone else answers on that address.
    final client = ref.read(httpProvider).pinnedTo(target.fingerprint);
    final sessionId = sessionIdOverride ?? _uuid.v4();
    final createChecksums = ref.read(settingsProvider).createChecksums;

    // The ids are assigned upfront, so the checksums calculated below
    // can be mapped back to the corresponding file.
    final selectedFiles = [
      for (var i = 0; i < files.length; i++)
        (
          id: fileIdsOverride != null && i < fileIdsOverride.length ? fileIdsOverride[i] : _uuid.v4(),
          file: files[i],
        ),
    ];

    // 单文件文本消息的正文。LocalSend 协议没有独立的「消息」类型，
    // 文本是靠 FileDto.preview 携带的。
    final embeddedText = files.length == 1 && files.first.fileType == FileType.text && files.first.bytes != null
        ? utf8.decode(files.first.bytes!)
        : null;

    state = state.updateSession(
      sessionId: sessionId,
      state: (_) => SendSessionState(
        sessionId: sessionId,
        remoteSessionId: null,
        background: background,
        status: SessionStatus.waiting,
        target: target,
        files: {
          for (final (:id, :file) in selectedFiles)
            id: SendingFile(
              file: FileDto(
                id: id,
                fileName: file.name,
                size: file.size,
                fileType: file.fileType,
                hash: null,
                // calculated below
                preview: embeddedText,
                metadata: file.lastModified != null || file.lastAccessed != null
                    ? FileMetadata(
                        lastModified: file.lastModified,
                        lastAccessed: file.lastAccessed,
                      )
                    : null,
              ),
              token: null,
              thumbnail: file.thumbnail,
              asset: file.asset,
              path: file.path,
              bytes: file.bytes,
              errorMessage: null,
            ),
        },
        // Skipping the checksums marks all files as hashed, so the UI does not
        // show the checksum progress.
        hashedFileCount: createChecksums ? 0 : selectedFiles.length,
        startTime: null,
        endTime: null,
        sendingTasks: [],
        errorMessage: null,
      ),
    );

    ref
        .notifier(fileTransferProvider)
        .setStatuses(
          sessionId: sessionId,
          statuses: {for (final f in selectedFiles) f.id: FileStatus.queue},
        );

    if (!background) {
      // ignore: use_build_context_synchronously, unawaited_futures
      Routerino.context.push(
        () => SendPage(showAppBar: false, closeSessionOnClose: true, sessionId: sessionId),
        transition: RouterinoTransition.fade(),
      );
    }

    // [FORK] 会话视图：连不上、被拒绝、对端没勾选这些结局不会产生任何 upload 事件，
    // 所以气泡必须在握手之前就写下来，否则「从发送 Tab 发过」这件事在会话里完全消失。
    // 聊天页自己预置（需要精确 alias / 重发），只接管没传 fileIdsOverride 的调用方。
    if (fileIdsOverride == null) {
      await _preRecordSessionMessages(
        sessionId: sessionId,
        target: target,
        files: selectedFiles,
        text: embeddedText,
      );
    }

    // Calculate the checksums which are part of the request.
    // The files are read and hashed in Rust, one file after another.
    final hashes = <String, String>{
      // [FORK] 命中缓存的文件不再重复哈希（聊天页重试时用）。
      ...?checksumCache,
    };
    if (createChecksums) {
      final hashCancelToken = rust_cancel.createCancellationToken();
      _hashCancelTokens[sessionId] = hashCancelToken;
      try {
        for (final selected in selectedFiles) {
          final id = selected.id;
          final file = selected.file;
          if (hashes.containsKey(id)) {
            // [FORK] 校验和已在上一轮算好：跳过读盘，直接补进度。
            ref.notifier(fileTransferProvider).setProgress(sessionId: sessionId, fileId: id, progress: 1);
            state = state.updateSession(
              sessionId: sessionId,
              state: (s) => s?.copyWith(hashedFileCount: s.hashedFileCount + 1),
            );
            continue;
          }
          try {
            hashes[id] = await calculateFileHash(
              path: file.path,
              bytes: file.bytes,
              cancelToken: hashCancelToken,
              onProgress: (bytes) {
                if (state[sessionId] == null) {
                  // session has been canceled while calculating the checksums
                  return;
                }
                ref
                    .notifier(fileTransferProvider)
                    .setProgress(
                      sessionId: sessionId,
                      fileId: id,
                      progress: file.size == 0 ? 1 : (bytes / file.size).clamp(0, 1),
                    );
              },
            );
          } catch (e) {
            if (state[sessionId] != null) {
              // Sending the checksum is optional, so a file that cannot be read
              // here still gets a chance to be sent.
              // Errors caused by the cancellation are not logged.
              _logger.warning('Could not calculate the checksum of ${file.name}', e);
            }
          }

          if (state[sessionId] == null) {
            // session has been canceled while calculating the checksums
            return;
          }

          // Also set for files whose hashing failed, so the progress bar stays
          // consistent with the files that are left.
          ref.notifier(fileTransferProvider).setProgress(sessionId: sessionId, fileId: id, progress: 1);
          state = state.updateSession(
            sessionId: sessionId,
            state: (s) => s?.copyWith(hashedFileCount: s.hashedFileCount + 1),
          );
        }
      } finally {
        _hashCancelTokens.remove(sessionId);
        // [FORK] 把本轮算出的校验和回填给调用方，供下次重试复用。
        checksumCache?.addAll(hashes);
      }
    }

    final hashedState = state[sessionId];
    if (hashedState == null) {
      // session has been canceled while calculating the checksums
      return;
    }

    final requestState = hashedState.copyWith(
      files: hashedState.files.map(
        (id, sendingFile) => MapEntry(id, sendingFile.copyWith(file: sendingFile.file.withHash(hashes[id]))),
      ),
    );
    state = state.updateSession(
      sessionId: sessionId,
      state: (_) => requestState,
    );

    final originDevice = ref.read(deviceFullInfoProvider);
    final requestDto = rust_model.PrepareUploadRequestDto(
      info: rust_model.RegisterDto(
        alias: originDevice.alias,
        version: originDevice.version,
        deviceModel: originDevice.deviceModel,
        deviceType: originDevice.deviceType.toRust(),
        token: originDevice.fingerprint,
        port: originDevice.port,
        protocol: originDevice.https ? rust_model.ProtocolType.https : rust_model.ProtocolType.http,
        hasWebInterface: originDevice.download,
      ),
      files: {
        for (final entry in requestState.files.entries) entry.key: entry.value.file.toRust(),
      },
    );

    rust_http.PrepareUploadResult? response;
    bool invalidPin;
    bool pinFirstAttempt = true;
    String? pin;
    final prepareUploadCancelToken = rust_cancel.createCancellationToken();
    _prepareUploadCancelTokens[sessionId] = prepareUploadCancelToken;
    try {
      do {
        invalidPin = false;
        try {
          response = await client.prepareUpload(
            protocol: target.getProtocolType(),
            ip: target.ip!,
            port: target.port,
            payload: requestDto,
            // The peer is already verified during the TLS handshake by the
            // fingerprint the client is pinned to.
            publicKey: null,
            pin: pin,
            cancelToken: prepareUploadCancelToken,
          );
        } on rust_http.RsHttpClientError_StatusCode catch (e) {
          switch (e.status) {
            case 401:
              invalidPin = true;

              // wait until animation is finished
              await sleepAsync(500);

              pin = await showDialog<String>(
                context: Routerino.context, // ignore: use_build_context_synchronously
                builder: (_) => PinDialog(
                  obscureText: true,
                  showInvalidPin: !pinFirstAttempt,
                ),
              );

              pinFirstAttempt = false;

              if (pin == null) {
                state = state.updateSession(
                  sessionId: sessionId,
                  state: (s) => s?.copyWith(
                    status: SessionStatus.canceledBySender,
                  ),
                );
                // [FORK] 会话视图：握手阶段就结束的，气泡立刻收尾。
                await _settlePreRecorded(sessionId: sessionId, errorMessage: state[sessionId]?.errorMessage);
                return;
              }
              break;
            case 403:
              state = state.updateSession(
                sessionId: sessionId,
                state: (s) => s?.copyWith(
                  status: SessionStatus.declined,
                ),
              );
              await _settlePreRecorded(sessionId: sessionId, errorMessage: state[sessionId]?.errorMessage);
              return;
            case 409:
              state = state.updateSession(
                sessionId: sessionId,
                state: (s) => s?.copyWith(
                  status: SessionStatus.recipientBusy,
                ),
              );
              await _settlePreRecorded(sessionId: sessionId, errorMessage: state[sessionId]?.errorMessage);
              return;
            case 429:
              state = state.updateSession(
                sessionId: sessionId,
                state: (s) => s?.copyWith(
                  status: SessionStatus.tooManyAttempts,
                ),
              );
              await _settlePreRecorded(sessionId: sessionId, errorMessage: state[sessionId]?.errorMessage);
              return;
            default:
              state = state.updateSession(
                sessionId: sessionId,
                state: (s) => s?.copyWith(
                  status: SessionStatus.finishedWithErrors,
                  errorMessage: e.humanErrorMessage,
                ),
              );
              await _settlePreRecorded(sessionId: sessionId, errorMessage: state[sessionId]?.errorMessage);
              return;
          }
        } catch (e) {
          state = state.updateSession(
            sessionId: sessionId,
            state: (s) => s?.copyWith(
              status: SessionStatus.finishedWithErrors,
              errorMessage: e.humanErrorMessage,
            ),
          );
          await _settlePreRecorded(sessionId: sessionId, errorMessage: state[sessionId]?.errorMessage);
          return;
        }
      } while (invalidPin);
    } finally {
      _prepareUploadCancelTokens.remove(sessionId);
    }

    if (response == null) {
      await _settlePreRecorded(sessionId: sessionId, errorMessage: state[sessionId]?.errorMessage);
      return;
    }

    final Map<String, String> fileMap;
    if (response.statusCode == 204) {
      // Nothing selected
      // Interpret this as "Read and close"
      fileMap = {};
    } else {
      try {
        fileMap = response.response!.files;
        final remoteSessionId = response.response!.sessionId;
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(
            remoteSessionId: remoteSessionId,
          ),
        );
      } catch (e) {
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(
            status: SessionStatus.finishedWithErrors,
            errorMessage: e.humanErrorMessage,
          ),
        );
        await _settlePreRecorded(sessionId: sessionId, errorMessage: state[sessionId]?.errorMessage);
        return;
      }
    }

    if (fileMap.isEmpty) {
      // receiver has nothing selected
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(
          status: SessionStatus.finished,
        ),
      );

      if (state[sessionId]?.background == false) {
        // Pop back to the existing HomePage instead of pushing a new one:
        // a second HomePage attaches a second PageView to the shared PageController,
        // and removing routes without animation orphans a hero in flight.
        ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.send));
        ref.global.dispatch(NavigateAction.popUntilRoot());
      }

      closeSession(sessionId);
      return;
    }

    final sendingFiles = {
      for (final file in requestState.files.values)
        file.file.id: fileMap.containsKey(file.file.id) ? file.copyWith(token: fileMap[file.file.id]) : file,
    };

    // Recreate the transfer state: the hash progress is no longer needed and must not be
    // mistaken for upload progress, which starts at zero for every file.
    final transferNotifier = ref.notifier(fileTransferProvider);
    transferNotifier.removeSession(sessionId);
    transferNotifier.setStatuses(
      sessionId: sessionId,
      statuses: {for (final file in sendingFiles.values) file.file.id: file.token != null ? FileStatus.queue : FileStatus.skipped},
    );

    if (state[sessionId]?.background == false) {
      final background = ref.read(settingsProvider).sendMode == SendMode.multiple;

      unawaited(
        // ignore: use_build_context_synchronously
        Routerino.context
            .pushAndRemoveUntil(
              removeUntil: HomePage,
              transition: RouterinoTransition.fade(),
              // immediately is not possible: https://github.com/flutter/flutter/issues/121910
              builder: () => ProgressPage(
                showAppBar: background,
                closeSessionOnClose: !background,
                sessionId: sessionId,
              ),
            )
            .then((_) {
              if (background) {
                // The page was popped (e.g. backing out mid-transfer), so the session
                // runs in background again and is removed silently on success.
                setBackground(sessionId, true);
              }
            }),
      );
    }

    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(
        status: SessionStatus.sending,
        files: sendingFiles,
      ),
    );

    // Keep the process alive for the whole transfer. Started here, while the app is still in the
    // foreground, because Android 12+ rejects starting a foreground service from the background.
    TransferNotification.start(sessionId: sessionId, receiving: false);

    await _sendLoop(sessionId, sendingFiles);
  }

  /// Reports the total session progress to the foreground service notification,
  /// so that it stays up to date while the app is minimized.
  void _updateForegroundServiceProgress(String sessionId) {
    if (!TransferNotification.shouldUpdate) {
      // Checked before the sum below because progress events arrive several times per second per file.
      return;
    }

    final session = state[sessionId];
    if (session == null) {
      return;
    }

    final transferNotifier = ref.read(fileTransferProvider);
    int currentBytes = 0;
    int totalBytes = 0;
    for (final sendingFile in session.files.values) {
      if (transferNotifier.getStatus(sessionId: sessionId, fileId: sendingFile.file.id) == FileStatus.skipped) {
        // not accepted by the receiver
        continue;
      }
      final size = sendingFile.file.size;
      totalBytes += size;
      currentBytes += (transferNotifier.getProgress(sessionId: sessionId, fileId: sendingFile.file.id) * size).round();
    }

    TransferNotification.update(
      sessionId: sessionId,
      currentBytes: currentBytes,
      totalBytes: totalBytes,
      startTime: session.startTime,
      endTime: session.endTime,
    );
  }

  Future<void> _sendLoop(String sessionId, Map<String, SendingFile> files) async {
    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(startTime: DateTime.now().millisecondsSinceEpoch),
    );

    await _sendFiles(
      sessionId: sessionId,
      files: files.values.toList(),
    );

    _finish(sessionId: sessionId);
  }

  void _finish({required String sessionId}) {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      return;
    }

    // [FORK] 会话视图：给还没有结局的预置气泡收尾。
    // 典型场景是「对端一个文件都没勾选」——那些文件不会进入上传，永远不会有事件。
    unawaited(_settlePreRecorded(sessionId: sessionId, errorMessage: sessionState.errorMessage));

    // The transfer is over, the process no longer needs to be kept alive for it.
    TransferNotification.stop(sessionId);

    if (state[sessionId]!.status != SessionStatus.sending) {
      _logger.info('Transfer was canceled.');
    } else {
      final hasError = ref.read(fileTransferProvider).getStatuses(sessionId).any((status) => status == FileStatus.failed);
      if (!hasError && sessionState.background == true) {
        // close session because everything is fine and it is in background
        closeSession(sessionId);
        _logger.info('Transfer finished and session removed.');
      } else {
        // keep session alive when there are errors or currently in foreground
        state = state.updateSession(
          sessionId: sessionId,
          state: (s) => s?.copyWith(
            status: hasError ? SessionStatus.finishedWithErrors : SessionStatus.finished,
            endTime: DateTime.now().millisecondsSinceEpoch,
          ),
        );

        if (hasError) {
          _logger.info('Transfer finished with errors.');
        } else {
          _logger.info('Transfer finished successfully.');
        }
      }
    }
  }

  final uriContent = UriContent();

  /// Sends a single file. Currently only used to retry a failed file.
  Future<void> sendFile({
    required String sessionId,
    required SendingFile file,
    required bool isRetry,
  }) async {
    if (file.token == null) {
      return;
    }

    final status = state[sessionId]?.status;
    const allowedStates = {SessionStatus.sending, SessionStatus.finishedWithErrors};
    if (status == null || !allowedStates.contains(status)) {
      return;
    }

    if (isRetry) {
      _logger.info('Retrying ${file.file.fileName}');

      ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: file.file.id, status: FileStatus.queue);
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(
          status: SessionStatus.sending,
          files: s.files.map((key, value) {
            if (key == file.file.id) {
              return MapEntry(key, value.copyWith(errorMessage: null));
            }
            return MapEntry(key, value);
          }),
        ),
      );
    }

    await _sendFiles(
      sessionId: sessionId,
      files: [file],
    );

    if (isRetry) {
      if (state[sessionId] != null && ref.read(fileTransferProvider).getStatuses(sessionId).isFinishedOrError) {
        _finish(sessionId: sessionId);
      }
    }
  }

  /// Sends the given [files] as one isolate task.
  /// The isolate iterates through the list and reports the state of each file
  /// via [HttpUploadEvent]s.
  /// Files without a token (i.e. not selected by the receiver) are skipped.
  Future<void> _sendFiles({
    required String sessionId,
    required List<SendingFile> files,
  }) async {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      return;
    }

    final uploadFiles = [
      for (final file in files)
        if (file.token != null)
          HttpUploadFile(
            remoteFileToken: file.token!,
            fileId: file.file.id,
            filePath: file.path,
            fileBytes: file.bytes,
            fileSize: file.file.size,
          ),
    ];

    if (uploadFiles.isEmpty) {
      return;
    }

    final taskResult = ref
        .redux(parentIsolateProvider)
        .dispatchTakeResult(
          IsolateHttpUploadFilesAction(
            remoteSessionId: sessionState.remoteSessionId,
            files: uploadFiles,
            device: sessionState.target,
          ),
        );

    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(
        sendingTasks: [
          ...?s.sendingTasks,
          SendingTask(
            taskId: taskResult.taskId,
          ),
        ],
      ),
    );

    try {
      await for (final event in taskResult.events) {
        switch (event) {
          case HttpUploadFileStartedEvent():
            _logger.info('Sending ${state[sessionId]?.files[event.fileId]?.file.fileName}');
            ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: event.fileId, status: FileStatus.sending);
            // [FORK] 聊天视图：记录一条「发送中」气泡。
            final startedFile = state[sessionId]?.files[event.fileId];
            if (startedFile != null) {
              await recordSentFileStart(
                ref: ref,
                target: sessionState.target,
                messageId: startedFile.file.id,
                fileName: startedFile.file.fileName,
                filePath: startedFile.path,
                fileSize: startedFile.file.size,
                fileType: startedFile.file.fileType,
                text: startedFile.file.fileType == FileType.text ? startedFile.file.preview : null,
              );
            }
          case HttpUploadFileProgressEvent():
            ref
                .notifier(fileTransferProvider)
                .setProgress(
                  sessionId: sessionId,
                  fileId: event.fileId,
                  progress: event.progress,
                );
            // [FORK] 聊天视图：把上传进度同步给对应的气泡。
            // 普通（非聊天）发送没有气泡在等这个 id，notifier 内部会直接丢弃。
            final chatTransfer = ref.read(chatTransferProvider);
            chatTransfer.report(messageId: event.fileId, progress: event.progress);
            // 有字节在动 = 对方已经点了接受，页脚该从「等待对方接受」切到百分比。
            chatTransfer.setPhase(event.fileId, ChatTransferPhase.uploading);
            _updateForegroundServiceProgress(sessionId);
          case HttpUploadFileFinishedEvent():
            // set progress to 100% when successfully finished
            ref
                .notifier(fileTransferProvider)
                .setProgress(
                  sessionId: sessionId,
                  fileId: event.fileId,
                  progress: 1,
                );
            _updateForegroundServiceProgress(sessionId);
            ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: event.fileId, status: FileStatus.finished);
            // [FORK] 聊天视图：标记为已发送。
            final finishedFile = state[sessionId]?.files[event.fileId];
            if (finishedFile != null) {
              await markSentFile(
                ref: ref,
                target: sessionState.target,
                messageId: finishedFile.file.id,
                fileName: finishedFile.file.fileName,
                filePath: finishedFile.path,
                fileSize: finishedFile.file.size,
                fileType: finishedFile.file.fileType,
                success: true,
                text: finishedFile.file.fileType == FileType.text ? finishedFile.file.preview : null,
              );
            }
          case HttpUploadFileFailedEvent():
            _logger.warning('Error while sending file ${state[sessionId]?.files[event.fileId]?.file.fileName}: ${event.error}');
            ref.notifier(fileTransferProvider).setStatus(sessionId: sessionId, fileId: event.fileId, status: FileStatus.failed);
            state = state.updateSession(
              sessionId: sessionId,
              state: (s) => s?.withFileError(event.fileId, event.error),
            );
            // [FORK] 聊天视图：标记为发送失败。
            final failedFile = state[sessionId]?.files[event.fileId];
            if (failedFile != null) {
              await markSentFile(
                ref: ref,
                target: sessionState.target,
                messageId: failedFile.file.id,
                fileName: failedFile.file.fileName,
                filePath: failedFile.path,
                fileSize: failedFile.file.size,
                fileType: failedFile.file.fileType,
                text: failedFile.file.fileType == FileType.text ? failedFile.file.preview : null,
                success: false,
                // 上传阶段失败：对端写盘失败、校验不一致、连接中断都在这里。
                // 原文是 Rust/对端给的英文，能归类就换成可读文案。
                errorMessage: describeSendErrorText(event.error),
              );
            }
        }
      }
    } catch (e, st) {
      // the whole task failed, mark all files of this task that did not finish as failed
      _logger.warning('Error while sending files', e, st);
      final error = e.humanErrorMessage;
      final transferNotifier = ref.notifier(fileTransferProvider);
      final failedFileIds = uploadFiles
          .map((file) => file.fileId)
          .where((id) => const {FileStatus.queue, FileStatus.sending}.contains(transferNotifier.getStatus(sessionId: sessionId, fileId: id)))
          .toSet();
      transferNotifier.setStatuses(
        sessionId: sessionId,
        statuses: {for (final id in failedFileIds) id: FileStatus.failed},
      );
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(
          files: s.files.map((key, value) {
            if (failedFileIds.contains(key)) {
              return MapEntry(key, value.copyWith(errorMessage: error));
            }
            return MapEntry(key, value);
          }),
        ),
      );
    } finally {
      state = state.updateSession(
        sessionId: sessionId,
        state: (s) => s?.copyWith(
          sendingTasks: s.sendingTasks?.where((task) => task.taskId != taskResult.taskId).toList(),
        ),
      );
    }
  }

  /// Closes the send-session and sends a cancel event to the receiver.
  void cancelSession(String sessionId) {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      return;
    }
    final remoteSessionId = sessionState.remoteSessionId;

    _cancelRunningRequests(sessionState);

    if (remoteSessionId == null) {
      closeSession(sessionId);
      return;
    }

    // notify the receiver
    final target = sessionState.target;
    try {
      ref
          .read(httpProvider)
          .pinnedTo(target.fingerprint)
          // ignore: discarded_futures
          .cancel(
            protocol: target.getProtocolType(),
            ip: target.ip!,
            port: target.port,
            sessionId: remoteSessionId,
          );
    } catch (e) {
      _logger.warning('Error while canceling session', e);
    }

    // finally, close session locally
    closeSession(sessionId);
  }

  void cancelSessionByReceiver(String sessionId) {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      return;
    }
    TransferNotification.stop(sessionId);
    _cancelRunningRequests(sessionState);

    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(
        status: SessionStatus.canceledByReceiver,
        endTime: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  void _cancelRunningRequests(SendSessionState state) {
    _hashCancelTokens.remove(state.sessionId)?.cancel();
    _prepareUploadCancelTokens.remove(state.sessionId)?.cancel();

    for (final task in state.sendingTasks ?? <SendingTask>[]) {
      ref
          .redux(parentIsolateProvider)
          .dispatch(
            IsolateHttpUploadCancelAction(
              taskId: task.taskId,
            ),
          );
    }
  }

  /// Closes the session
  void closeSession(String sessionId) {
    final sessionState = state[sessionId];
    if (sessionState == null) {
      // 会话在计算校验和阶段被取消时状态已经没了，这里顺手把预置名单清掉。
      _preRecordedMessages.remove(sessionId);
      return;
    }
    // [FORK] 会话被关掉（用户从发送页返回、或握手阶段就失败）时，
    // 把预置的「发送中」气泡标成失败，别让它一直转圈。
    unawaited(_settlePreRecorded(sessionId: sessionId, errorMessage: sessionState.errorMessage));
    TransferNotification.stop(sessionId);
    _hashCancelTokens.remove(sessionId)?.cancel();
    _prepareUploadCancelTokens.remove(sessionId)?.cancel();
    state = state.removeSession(ref, sessionId);
    if (sessionState.status == SessionStatus.finished && ref.read(settingsProvider).sendMode == SendMode.single) {
      // clear selected files
      ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction());
    }
  }

  void clearAllSessions() {
    for (final sessionId in state.keys) {
      TransferNotification.stop(sessionId);
    }
    for (final cancelToken in _hashCancelTokens.values) {
      cancelToken.cancel();
    }
    _hashCancelTokens.clear();
    for (final cancelToken in _prepareUploadCancelTokens.values) {
      cancelToken.cancel();
    }
    _prepareUploadCancelTokens.clear();
    _preRecordedMessages.clear();
    state = {};
    ref.notifier(fileTransferProvider).removeAllSessions();
  }

  void setBackground(String sessionId, bool background) {
    state = state.updateSession(
      sessionId: sessionId,
      state: (s) => s?.copyWith(background: background),
    );
  }
}

extension on Map<String, SendSessionState> {
  Map<String, SendSessionState> updateSession({
    required String sessionId,
    required SendSessionState? Function(SendSessionState? old) state,
  }) {
    final newState = state(this[sessionId]);
    if (newState == null) {
      // no change
      return this;
    }
    return {
      ...this,
      sessionId: newState,
    };
  }

  Map<String, SendSessionState> removeSession(Ref ref, String sessionId) {
    ref.notifier(fileTransferProvider).removeSession(sessionId);
    return {...this}..remove(sessionId);
  }
}

extension on SendSessionState {
  SendSessionState withFileError(String fileId, String? errorMessage) {
    return copyWith(
      files: {...files}
        ..update(
          fileId,
          (file) => file.copyWith(
            errorMessage: errorMessage,
          ),
        ),
    );
  }
}
