import 'dart:convert';

/// Unverified JWT claims for local cache partitioning and refresh timing only.
/// Server authorization must never rely on this decoder.
abstract final class LocalTokenClaims {
  static bool isExpired(String token, {DateTime? now}) {
    final exp = _claimTime(token, 'exp');
    if (exp == null) return true;
    final current = (now ?? DateTime.now()).toUtc();
    return !current.isBefore(exp);
  }

  static bool isIssuedBefore(String token, Duration age, {DateTime? now}) =>
      _isIssuedBefore(token, age, now: now);

  static bool _isIssuedBefore(String token, Duration age, {DateTime? now}) {
    final iat = _claimTime(token, 'iat');
    if (iat == null) return false;
    final current = (now ?? DateTime.now()).toUtc();
    return current.difference(iat) > age;
  }

  static DateTime? _claimTime(String token, String claim) {
    final raw = read(token, claim);
    final seconds = raw is num ? raw.toInt() : int.tryParse('$raw');
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }

  static dynamic read(String token, String claim) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final json = jsonDecode(payload);
      if (json is! Map<String, dynamic>) return null;
      return json[claim];
    } catch (_) {
      return null;
    }
  }
}
