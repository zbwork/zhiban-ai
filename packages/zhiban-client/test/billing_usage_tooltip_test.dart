import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/models/billing_models.dart';
import 'package:zhiban_client/pages/settings/widgets/billing_usage_tooltip.dart';

void main() {
  final complete = BillingUsageEvent.fromJson({
    'metering_source': 'beebridge',
    'resource_type': 'llm',
    'input_tokens': '2',
    'output_tokens': '276',
    'cache_read_input_tokens': '0',
    'cache_creation_input_tokens': '243093',
    'amount': 278,
    'amount_known': true,
  });
  Widget page(BillingUsageEvent event) => MaterialApp(
        home: Scaffold(
            body: Center(
                child: BillingUsageTooltip(
          event: event,
          child: Text(event.usageLabel)),
        ),),
      );

  testWidgets('hover reveals only input and output without moving the total',
      (tester) async {
    await tester.pumpWidget(page(complete));
    final total = find.text('278 tokens');
    final rect = tester.getRect(total);
    expect(find.text(complete.tokenDetailLabel), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(total));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('输入 2\n输出 276'), findsOneWidget);
    expect(tester.getRect(total), rect);
    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  testWidgets('long press shows unknown input separately from zero',
      (tester) async {
    final event = BillingUsageEvent.fromJson({
      'metering_source': 'beebridge',
      'resource_type': 'llm',
      'input_tokens': null,
      'output_tokens': '0',
      'cache_read_input_tokens': '0',
      'cache_creation_input_tokens': null,
      'amount': 0,
      'amount_known': false,
    });
    await tester.pumpWidget(page(event));
    await tester.longPress(find.text('Token 未知'));
    await tester.pumpAndSettle();
    expect(find.text('输入 未知\n输出 0'), findsOneWidget);
  });

  testWidgets('non-model consumption has no token tooltip', (tester) async {
    final event = BillingUsageEvent.fromJson(
        {'resource_type': 'rtc_minute', 'amount': 10});
    await tester.pumpWidget(page(event));
    expect(find.byType(Tooltip), findsNothing);
  });
}
