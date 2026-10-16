import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/network/api_image_auth.dart';

void main() {
  group('api image auth helpers', () {
    test('message-files paths require auth and resolve under agent-bus base',
        () {
      const path = '/message-files/file-1/preview';

      expect(apiImageNeedsAuth(path), isTrue);
      expect(
        apiImageResolveUrl(path),
        'http://127.0.0.1:8080/api/agent-bus/v1/message-files/file-1/preview',
      );
    });

    test('absolute agent-bus message-files URLs still require auth', () {
      const url =
          'http://127.0.0.1:8080/api/agent-bus/v1/message-files/file-1/preview';

      expect(apiImageNeedsAuth(url), isTrue);
      expect(apiImageResolveUrl(url), url);
    });

    test('absolute agent-bus chat media URLs still require auth', () {
      const url =
          'http://127.0.0.1:8080/api/agent-bus/v1/chat/media/ref-1/preview';

      expect(apiImageNeedsAuth(url), isTrue);
      expect(apiImageResolveUrl(url), url);
    });

    test('knowledge document download paths require auth', () {
      const path = '/knowledge-bases/kb-1/documents/doc-1/download';

      expect(apiImageNeedsAuth(path), isTrue);
      expect(
        apiImageResolveUrl(path),
        'http://127.0.0.1:8080/api/agent-bus/v1/knowledge-bases/kb-1/documents/doc-1/download',
      );
    });
  });
}
