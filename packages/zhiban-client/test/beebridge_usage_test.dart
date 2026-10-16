import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/models/billing_models.dart';

void main() {
  test('BeeBridge unknown tokens and refund display remain distinct from zero',
      () {
    final event = BillingUsageEvent.fromJson({
      'id': 1,
      'metering_source': 'beebridge',
      'resource_type': 'llm',
      'model': 'gpt-test',
      'input_tokens': null,
      'output_tokens': '120',
      'amount': 0,
      'amount_known': false,
      'credits_cost': -72,
      'charge_count': '2',
      'refund_count': '1',
      'occurred_at': '2026-09-16T01:02:00Z',
    });
    expect(event.usageLabel, 'Token 未知');
    expect(event.inputTokens, isNull);
    expect(event.outputTokens, 120);
    expect(event.accountLabel, '未归属成员');
    expect(event.modelLabel, 'gpt-test');
    expect(event.creditSign, '+');
    expect(event.chargeCount, 2);
    expect(event.minuteLabel.length, 16);
    expect(event.tokenDetailLabel, '输入 未知\n输出 120');
  });
  test('Known zero and aggregate incompleteness survive parsing', () {
    final event = BillingUsageEvent.fromJson({
      'metering_source': 'beebridge',
      'resource_type': 'llm',
      'amount': 0,
      'amount_known': true
    });
    expect(event.usageLabel, '0 tokens');
    expect(event.modelLabel, '未知模型');
    final aggregate = BillingUsageAggregate.fromJson(
        {'unknown_amount_count': 2, 'TotalAmount': 200});
    expect(aggregate.unknownAmountCount, 2);
    expect(aggregate.totalAmount, 200);
  });
  test('Reserved cache fields do not change the active display', () {
    final event = BillingUsageEvent.fromJson({
      'metering_source': 'beebridge',
      'resource_type': 'llm',
      'input_tokens': '2',
      'output_tokens': '276',
      'cache_creation_input_tokens': '243093',
      'cache_read_input_tokens': '0',
      'amount': 278,
      'amount_known': true,
      'credits_cost': 6593,
    });
    expect(event.usageLabel, '278 tokens');
    expect(event.cacheCreationInputTokens, 243093);
    expect(event.cacheReadInputTokens, 0);
    expect(event.tokenDetailLabel, '输入 2\n输出 276');
    expect(event.creditsCost, 6593);
  });
}
