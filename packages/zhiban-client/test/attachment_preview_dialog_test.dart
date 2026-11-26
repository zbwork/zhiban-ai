import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/attachment_preview_dialog.dart';

import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_panel.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';

void main() {
  test('recognizes M4A as audio without classifying MP4 video as audio', () {
    expect(attachmentPreviewFormat('voice.m4a', '', ''), 'audio');
    expect(attachmentPreviewFormat('voice', '', 'audio/mp4; codecs=mp4a'),
        'audio');
    expect(attachmentPreviewFormat('clip.mp4', '', 'video/mp4'), 'video');
  });

  testWidgets('a short inline preview keeps error actions scrollable',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 320,
          height: 180,
          child: AttachmentPreviewPanel(
            target: const AttachmentPreviewTarget(url: '', name: 'unknown.bin'),
            onClose: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('外部打开'));
    expect(find.text('外部打开').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('normalizeAttachmentPreviewUrl', () {
    test('converts a relative message-file download URL to preview', () {
      expect(
        normalizeAttachmentPreviewUrl('/message-files/file-1/download'),
        '/message-files/file-1/preview',
      );
    });

    test('preserves origin and query parameters', () {
      expect(
        normalizeAttachmentPreviewUrl(
          'https://bus.example.com/api/agent-bus/v1/message-files/file-1/download?x=1',
        ),
        'https://bus.example.com/api/agent-bus/v1/message-files/file-1/preview?x=1',
      );
    });

    test('keeps existing preview and unrelated downloads unchanged', () {
      expect(
        normalizeAttachmentPreviewUrl('/message-files/file-1/preview'),
        '/message-files/file-1/preview',
      );
      expect(
        normalizeAttachmentPreviewUrl('https://example.com/report/download'),
        'https://example.com/report/download',
      );
    });
  });
}
