import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/services/clipboard_image_paste.dart';

void main() {
  group('clipboard image paste classification', () {
    test('PDF file paths block bitmap preview paste', () {
      expect(clipboardContainsFilePaths(['/tmp/resume.pdf']), isTrue);
      expect(clipboardFirstImagePath(['/tmp/resume.pdf']), isNull);
    });

    test('image file paths are still pasteable as images', () {
      expect(
        clipboardFirstImagePath(['/tmp/screenshot.png', '/tmp/resume.pdf']),
        '/tmp/screenshot.png',
      );
    });
  });
}
