import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/attachment_preview_dialog.dart';

void main() {
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
