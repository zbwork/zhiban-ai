import 'dart:convert';

import 'package:test/test.dart';
import 'package:zhiban_core/session/local_token_claims.dart';

String _jwt(String claim, DateTime value) =>
    'header.${base64Url.encode(utf8.encode(jsonEncode({claim: value.millisecondsSinceEpoch ~/ 1000})))}.sig';

void main() {
  final now = DateTime.utc(2026, 6, 10);
  for (final (offset, expired) in [(-1, true), (900, false)]) {
    test('expiry offset $offset seconds', () {
      expect(
        LocalTokenClaims.isExpired(
          _jwt('exp', now.add(Duration(seconds: offset))),
          now: now,
        ),
        expired,
      );
    });
  }
  test('malformed token is expired', () {
    expect(LocalTokenClaims.isExpired('not-a-jwt'), isTrue);
  });
  test('sliding refresh uses iat and tolerates missing iat', () {
    for (final (hours, refresh) in [(25, true), (23, false)]) {
      expect(
        LocalTokenClaims.isIssuedBefore(
          _jwt('iat', now.subtract(Duration(hours: hours))),
          const Duration(hours: 24),
          now: now,
        ),
        refresh,
      );
    }
    expect(
      LocalTokenClaims.isIssuedBefore(
        _jwt('exp', now),
        const Duration(hours: 24),
        now: now,
      ),
      isFalse,
    );
  });
}
