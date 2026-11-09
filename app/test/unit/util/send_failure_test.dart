import 'package:localchat_app/util/conversation/send_failure.dart';
import 'package:localchat_isolates/model/session_status.dart';
import 'package:localchat_isolates/rust/api/http.dart' as rust_http;
import 'package:test/test.dart';

void main() {
  group('classifySendErrorText', () {
    test('端口拒绝连接 → 对方没在运行', () {
      // Windows 的真实文案（reqwest 把 io::Error 原文带了出来）
      expect(
        classifySendErrorText(
          'error sending request for url (https://192.168.1.5:53317/api/localsend/v2/prepare-upload): '
          'client error (Connect): tcp connect error: Connection refused (os error 10061)',
        ),
        SendFailure.peerOffline,
      );
      // Android / Linux 的写法
      expect(classifySendErrorText('Os { code: 111, kind: ConnectionRefused, message: "Connection refused" }'), SendFailure.peerOffline);
    });

    test('主机不可达 → 对方没在运行', () {
      expect(classifySendErrorText('No route to host (os error 65)'), SendFailure.peerOffline);
    });

    test('证书问题 → 指纹不匹配', () {
      expect(classifySendErrorText('invalid peer certificate: UnknownIssuer'), SendFailure.tlsMismatch);
      expect(classifySendErrorText('received fatal alert: handshake failure'), SendFailure.tlsMismatch);
    });

    test('超时 → 对方无响应', () {
      expect(classifySendErrorText('operation timed out'), SendFailure.peerNoResponse);
      expect(classifySendErrorText('deadline has elapsed'), SendFailure.peerNoResponse);
    });

    test('对端侧的具体原因', () {
      expect(classifySendErrorText('No space left on device (os error 28)'), SendFailure.receiverStorageFull);
      // 接收端 save.rs 里写死的文案
      expect(classifySendErrorText('Checksum mismatch'), SendFailure.checksumMismatch);
    });

    test('连接被重置 → 传输中断', () {
      expect(classifySendErrorText('Connection reset by peer (os error 104)'), SendFailure.uploadInterrupted);
    });

    test('本机网络问题', () {
      expect(classifySendErrorText('failed to lookup address information: Name or service not known'), SendFailure.localNetwork);
      expect(classifySendErrorText('Network is unreachable (os error 101)'), SendFailure.localNetwork);
    });

    test('认不出来就返回 null，交给上层兜底', () {
      expect(classifySendErrorText('something completely unexpected'), isNull);
      expect(classifySendErrorText(''), isNull);
      expect(classifySendErrorText(null), isNull);
    });

    test('具体原因优先于「超时」大类', () {
      // 组合文案里既有 timeout 又有具体原因时，不能退化成「无响应」
      expect(classifySendErrorText('request timed out: No space left on device'), SendFailure.receiverStorageFull);
    });
  });

  group('failureForStatusCode', () {
    test('状态码映射', () {
      expect(failureForStatusCode(401), SendFailure.authRejected);
      expect(failureForStatusCode(403), SendFailure.peerDeclined);
      expect(failureForStatusCode(409), SendFailure.peerBusy);
      expect(failureForStatusCode(429), SendFailure.peerRateLimited);
      expect(failureForStatusCode(500), SendFailure.receiverError);
      expect(failureForStatusCode(503), SendFailure.receiverError);
      expect(failureForStatusCode(200), SendFailure.unknown);
    });
  });

  group('classifySendError', () {
    test('结构化错误优先于文本', () {
      expect(classifySendError(const rust_http.RsHttpClientError.statusCode(status: 403)), SendFailure.peerDeclined);
      expect(classifySendError(const rust_http.RsHttpClientError.reqwest('Connection refused (os error 10061)')), SendFailure.peerOffline);
      expect(classifySendError(const rust_http.RsHttpClientError.json('expected value at line 1')), SendFailure.receiverError);
    });

    test('非 Rust 异常落到 unknown', () {
      expect(classifySendError(StateError('boom')), SendFailure.unknown);
      expect(classifySendError(null), SendFailure.unknown);
    });
  });

  group('sendFailureOfStatus', () {
    test('明确的结局', () {
      expect(sendFailureOfStatus(SessionStatus.declined), SendFailure.peerDeclined);
      expect(sendFailureOfStatus(SessionStatus.recipientBusy), SendFailure.peerBusy);
      expect(sendFailureOfStatus(SessionStatus.tooManyAttempts), SendFailure.peerRateLimited);
      expect(sendFailureOfStatus(SessionStatus.canceledBySender), SendFailure.cancelled);
      expect(sendFailureOfStatus(SessionStatus.canceledByReceiver), SendFailure.peerAborted);
    });

    test('failed 状态用原文细分', () {
      expect(
        sendFailureOfStatus(SessionStatus.finishedWithErrors, errorMessage: '[500] No space left on device'),
        SendFailure.receiverStorageFull,
      );
    });

    test('finished 不算失败（调用方按 session 是否被收掉判断 204）', () {
      expect(sendFailureOfStatus(SessionStatus.finished), isNull);
    });
  });
}
