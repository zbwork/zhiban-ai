import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/services/analytics_service.dart';

void main() {
  test('active session deduplicates within 30 minutes', () {
    final tracker = ActiveSessionTracker();
    final start = DateTime.utc(2026, 7, 3, 8);
    final first = tracker.next(start);
    expect(first.shouldReport, isTrue);
    expect(tracker.next(start.add(const Duration(minutes: 29))).shouldReport,
        isFalse);
    final renewed = tracker.next(start.add(const Duration(minutes: 31)));
    expect(renewed.shouldReport, isTrue);
    expect(renewed.sessionId, isNot(first.sessionId));
  });

  test('custom event session lookup does not consume active report', () {
    final tracker = ActiveSessionTracker();
    final start = DateTime.utc(2026, 7, 3, 8);

    final customSession = tracker.sessionId(start);
    final active = tracker.next(start.add(const Duration(seconds: 1)));

    expect(active.sessionId, customSession);
    expect(active.shouldReport, isTrue);
    expect(
      tracker.next(start.add(const Duration(minutes: 1))).shouldReport,
      isFalse,
    );
  });
}
