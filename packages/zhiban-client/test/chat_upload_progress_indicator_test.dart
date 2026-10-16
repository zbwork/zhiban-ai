import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_upload_progress_indicator.dart';

// 媒体上传进度 / 取消(P2/P3)。人↔人与群聊 pane 共用 ChatUploadProgressIndicator;
// pane 用 msg.isUploading 在 uploading 时选它、否则用 ChatSendStatusIndicator(在 controller/indicator 测试覆盖)。

void main() {
  group('ChatUploadProgressIndicator', () {

    testWidgets('点击「取消」触发 onCancel', (tester) async {
      var cancels = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatUploadProgressIndicator(
                progress: 10, onCancel: () => cancels++),
          ),
        ),
      );
      expect(find.text('上传中 10%'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      await tester.tap(find.text('取消'));
      expect(cancels, 1);
    });

    testWidgets('progress<0 → 显示 indeterminate「上传中」', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatUploadProgressIndicator(progress: -1, onCancel: () {}),
          ),
        ),
      );
      expect(find.text('上传中'), findsOneWidget);
    });
  });

  // ImMessage.isUploading 门控(pane 据此选 ChatUploadProgressIndicator vs ChatSendStatusIndicator)。
  group('ImMessage.isUploading 门控', () {
    ImMessage mk({
      required ImSendStatus status,
      String localPath = '/p/a.png',
      int progress = 0,
    }) =>
        ImMessage(
          messageId: 'x',
          clientMsgNo: '',
          fromUid: 'me',
          channelId: 'ch',
          channelType: 2,
          timestamp: 0,
          text: '[图片]',
          sendStatus: status,
          mediaKind: ImMediaKind.image,
          mediaLocalPath: localPath,
          uploadProgress: progress,
        );

    test('pending + 本地路径 + 进度>=0 → isUploading', () {
      expect(mk(status: ImSendStatus.pending).isUploading, isTrue);
    });
    test('sent → 非 uploading', () {
      expect(mk(status: ImSendStatus.sent).isUploading, isFalse);
    });
    test('failed(已取消/失败)→ 非 uploading(显示重发)', () {
      expect(
          mk(status: ImSendStatus.failed, progress: -1).isUploading, isFalse);
    });
    test('无本地路径(SDK pending)→ 非 uploading', () {
      expect(
          mk(status: ImSendStatus.pending, localPath: '').isUploading, isFalse);
    });
  });
}
