import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/utils/url_utils.dart';

void main() {
  test('avatar keys normalize signatures and fragments without losing identity',
      () {
    for (final (label, url, expected) in <(String, String?, String?)>[
      (
        'signature A',
        'https://oss.example.com/bucket/agent-avatars/abc.png?X-Amz-Signature=AAA&X-Amz-Date=20260101T000000Z&X-Amz-Expires=3600',
        'https://oss.example.com/bucket/agent-avatars/abc.png'
      ),
      (
        'signature B',
        'https://oss.example.com/bucket/agent-avatars/abc.png?X-Amz-Signature=BBB&X-Amz-Date=20260630T235959Z&X-Amz-Expires=3600',
        'https://oss.example.com/bucket/agent-avatars/abc.png'
      ),
      (
        'fragment',
        'https://cdn.example.com/avatar/x.jpg#frag',
        'https://cdn.example.com/avatar/x.jpg'
      ),
      (
        'query and fragment',
        'https://cdn.example.com/avatar/x.jpg?v=1#frag',
        'https://cdn.example.com/avatar/x.jpg'
      ),
      (
        'relative A',
        '/api/agent-bus/v1/assets/agent-avatars/x.jpg?v=1',
        '/api/agent-bus/v1/assets/agent-avatars/x.jpg'
      ),
      (
        'relative B',
        '/api/agent-bus/v1/assets/agent-avatars/x.jpg?v=2',
        '/api/agent-bus/v1/assets/agent-avatars/x.jpg'
      ),
      ('http', 'http://h.example.com/a.png?s=1', 'http://h.example.com/a.png'),
      (
        'port',
        'https://cdn.example.com:8443/avatar/a.png?sig=1',
        'https://cdn.example.com:8443/avatar/a.png'
      ),
      (
        'credentials excluded',
        // Synthetic userinfo must still be removed from the cache key.
        'https://' 'user:pass@cdn.example.com/avatar/a.png',
        'https://cdn.example.com/avatar/a.png'
      ),
      ('null', null, null),
      ('empty', '', null),
      ('blank', '   ', null),
      ('storage URI', 'oss://agent-avatars/abc.png', null),
      ('data URI', 'data:image/png;base64,AAAA', null),
    ]) {
      expect(stableAvatarCacheKey(url), expected, reason: label);
    }
  });

  test('avatar keys keep different paths, hosts and ports distinct', () {
    for (final (label, a, b) in [
      (
        'path',
        'https://oss.example.com/bucket/agent-avatars/aaa.png?sig=1',
        'https://oss.example.com/bucket/agent-avatars/bbb.png?sig=1'
      ),
      (
        'host',
        'https://a.example.com/avatar/x.jpg',
        'https://b.example.com/avatar/x.jpg'
      ),
      (
        'port',
        'https://cdn.example.com:8443/avatar/a.png?sig=1',
        'https://cdn.example.com/avatar/a.png?sig=1'
      ),
    ]) {
      expect(stableAvatarCacheKey(a), isNot(stableAvatarCacheKey(b)),
          reason: label);
    }
  });
}
