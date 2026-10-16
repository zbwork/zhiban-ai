import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/services/analytics_service.dart';

void main() {
  test('error properties redact sensitive data and produce stable fingerprint',
      () {
    const sanitizer = AnalyticsEventSanitizer();
    final first = sanitizer.errorProperties(
      StateError('phone 13800138000 email user@example.com token=secret'),
      StackTrace.fromString(
        '#0 Foo.run (/Users/alice/app/lib/foo.dart:12:3)\n'
        '#1 https://host/path?access_token=secret\n'
        '#2 id 11111111-1111-4111-8111-111111111111',
      ),
      mechanism: 'flutter',
    );
    final second = sanitizer.errorProperties(
      StateError('phone 13900139000 email other@example.com token=changed'),
      StackTrace.fromString(
        '#0 Foo.run (/Users/bob/app/lib/foo.dart:99:8)\n'
        '#1 https://host/path?access_token=changed',
      ),
      mechanism: 'flutter',
    );

    final serialized = first.values.join('\n');
    expect(serialized, isNot(contains('13800138000')));
    expect(serialized, isNot(contains('user@example.com')));
    expect(serialized, isNot(contains('secret')));
    expect(serialized, isNot(contains('/Users/alice/')));
    expect(serialized, isNot(contains('11111111-1111-4111-8111-111111111111')));
    expect(first['fingerprint'], hasLength(64));
    expect(first['fingerprint'], second['fingerprint']);
    expect(first['mechanism'], 'flutter');
    expect(first['severity'], 'error');
  });

  test('custom event accepts only namespaced low-cardinality properties', () {
    const sanitizer = AnalyticsEventSanitizer();

    expect(
      sanitizer.customProperties('custom_export_completed', {
        'format': 'pdf',
        'success': true,
        'count': 2,
        'phone': '13800138000',
        'nested': {'value': 1},
      }),
      {'format': 'pdf', 'success': true, 'count': 2},
    );
    expect(sanitizer.isCustomEventName('export_completed'), isFalse);
    expect(sanitizer.isCustomEventName('custom_export_completed'), isTrue);
  });
}
