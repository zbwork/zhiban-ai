import 'package:zhiban_client/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/widgets/human_direct_media.dart';

void main() {
  setUp(
      () => AppConfig.serverApiUrl = 'http://127.0.0.1:8080/api/agent-bus/v1');
  tearDown(() => AppConfig.serverApiUrl = null);
  test('resolveChatMediaUrl prefixes relative chat media paths with API base',
      () {
    expect(
      resolveChatMediaUrl('/chat/media/ref-1/preview'),
      'http://127.0.0.1:8080/api/agent-bus/v1/chat/media/ref-1/preview',
    );
  });

  test('resolveChatMediaUrl leaves absolute URLs unchanged', () {
    expect(
      resolveChatMediaUrl('https://example.test/chat/media/ref-1/preview'),
      'https://example.test/chat/media/ref-1/preview',
    );
  });
}
