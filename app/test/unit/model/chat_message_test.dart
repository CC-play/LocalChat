import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_isolates/model/file_type.dart';
import 'package:test/test.dart';

/// [FORK] 「文件只存进了相册」这条判定的回归测试。
///
/// 背景：接收图片 / 视频时默认会搬进系统相册，落盘后不留路径。一旦把这种消息
/// 当成「本机没有这个文件」，聊天页点卡片就会弹「这个文件不在本机」——文件其实
/// 好好躺在相册里。判定错了的代价是用户以为文件丢了，所以这里把三种路径都钉住。
void main() {
  ChatMessage fileMessage({
    required ChatMessageDirection direction,
    required ChatMessageStatus status,
    String? filePath,
    FileType? fileType = FileType.image,
    bool savedToGallery = false,
  }) {
    return ChatMessage(
      id: 'id',
      direction: direction,
      kind: ChatMessageKind.file,
      timestamp: DateTime(2026, 11, 25),
      status: status,
      fileName: 'photo.jpg',
      filePath: filePath,
      fileSize: 1,
      fileType: fileType,
      savedToGallery: savedToGallery,
    );
  }

  group('ChatMessage.isOnlyInGallery', () {
    test('显式标记为相册时为 true', () {
      final message = fileMessage(
        direction: ChatMessageDirection.received,
        status: ChatMessageStatus.received,
        savedToGallery: true,
      );
      expect(message.isOnlyInGallery, isTrue);
    });

    test('旧记录没有标记时按「接收成功 + 媒体 + 无路径」推断', () {
      for (final type in [FileType.image, FileType.video]) {
        final message = fileMessage(
          direction: ChatMessageDirection.received,
          status: ChatMessageStatus.received,
          fileType: type,
        );
        expect(message.isOnlyInGallery, isTrue, reason: '$type 应当推断为相册');
      }
    });

    test('有路径的接收文件不是「只在相册」', () {
      final message = fileMessage(
        direction: ChatMessageDirection.received,
        status: ChatMessageStatus.received,
        filePath: '/storage/emulated/0/Download/photo.jpg',
        savedToGallery: true,
      );
      expect(message.isOnlyInGallery, isFalse);
    });

    test('非媒体类型没有路径也不算「只在相册」', () {
      final message = fileMessage(
        direction: ChatMessageDirection.received,
        status: ChatMessageStatus.received,
        fileType: FileType.pdf,
      );
      expect(message.isOnlyInGallery, isFalse);
    });

    test('自己发出的消息永远不是「只在相册」', () {
      final message = fileMessage(
        direction: ChatMessageDirection.sent,
        status: ChatMessageStatus.sent,
        savedToGallery: true,
      );
      expect(message.isOnlyInGallery, isFalse);
    });

    test('文本消息不受影响', () {
      final message = ChatMessage(
        id: 'id',
        direction: ChatMessageDirection.received,
        kind: ChatMessageKind.text,
        timestamp: DateTime(2026, 11, 25),
        status: ChatMessageStatus.received,
        text: 'hi',
        fileType: FileType.image,
      );
      expect(message.isOnlyInGallery, isFalse);
    });
  });

  test('savedToGallery 参与 JSON 往返，缺字段时降级为 false', () {
    final gallery = fileMessage(
      direction: ChatMessageDirection.received,
      status: ChatMessageStatus.received,
      savedToGallery: true,
    );
    expect(ChatMessage.fromJson(gallery.toJson()).savedToGallery, isTrue);

    // 旧版本写下的记录没有这个字段。
    final legacyJson = gallery.toJson()..remove('savedToGallery');
    expect(ChatMessage.fromJson(legacyJson).savedToGallery, isFalse);
  });
}
