import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_time_divider.dart';

int _ms(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch;

void main() {
  final now = DateTime(2026, 6, 4, 20);
  test('time format covers calendar boundaries, invalid and second timestamps', () {
    for (final (label, timestamp, expected) in [
      ('today', _ms(2026, 6, 4, 18, 14), '18:14'),
      ('yesterday', _ms(2026, 6, 3, 18, 14), '昨天 18:14'),
      ('same year', _ms(2026, 6, 2, 18, 14), '06月02日 18:14'),
      ('previous year', _ms(2025, 12, 31, 18, 14), '2025年12月31日 18:14'),
      ('zero', 0, ''),
      ('negative', -1, ''),
      ('seconds', _ms(2026, 6, 4, 18, 14) ~/ 1000, '18:14'),
    ]) {
      expect(formatMessageTime(timestamp, now: now), expected, reason: label);
    }
  });

  test('divider gates first message, five-minute boundary and invalid time', () {
    final previous = _ms(2026, 6, 4, 18, 0);
    for (final (label, prev, current, expected) in <(String, int?, int, bool)>[
      ('first', null, previous, true),
      ('under five minutes', previous, previous + 4 * 60000, false),
      ('exactly five minutes', previous, previous + 5 * 60000, true),
      ('invalid current', previous, 0, false),
      ('invalid previous', 0, previous, true),
    ]) {
      expect(
        shouldShowTimeDivider(prevTimestampMs: prev, timestampMs: current),
        expected,
        reason: label,
      );
    }
  });

  testWidgets('divider renders valid time and hides invalid time', (tester) async {
    for (final timestamp in [_ms(2026, 6, 4, 18, 14), 0]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatMessageTimeDivider(timestampMs: timestamp, now: now),
        ),
      ));
      if (timestamp > 0) {
        expect(find.text('18:14'), findsOneWidget);
      } else {
        expect(find.byType(Text), findsNothing);
      }
    }
  });
}
