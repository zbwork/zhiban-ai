import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/services/conversation_model_sources.dart';

void main() {
  String token(Map<String, dynamic> claims) =>
      'header.${base64Url.encode(utf8.encode(jsonEncode(claims)))}.signature';
  test('model configuration uses aid, never device identity sub', () {
    expect(
        modelConfigurationAccount(token({'aid': 1039, 'sub': 'account-uuid'})),
        '1039');
    expect(
        modelConfigurationAccount(
            token({'aid': '1040', 'sub': 'account-uuid'})),
        '1040');
  });
  test(
      'missing or invalid aid cannot fall back to another preference partition',
      () {
    for (final claims in [
      {'sub': '1039'},
      {'aid': 0},
      {'aid': -1},
      {'aid': 'anon'},
      {'aid': '../1039'}
    ]) {
      expect(modelConfigurationAccount(token(claims)), isNull);
    }
    expect(modelConfigurationAccount('bad'), isNull);
  });
}
