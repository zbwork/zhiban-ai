import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/models/billing_models.dart';
import 'package:zhiban_client/pages/case_fee_payment/case_fee_payment.dart';

BillingPaymentOrder _order(
  String orderType, {
  int amountCents = 68800,
  Map<String, dynamic>? productSnapshot,
}) {
  return BillingPaymentOrder.fromJson({
    'out_trade_no': 'CASE-FEE-1',
    'order_type': orderType,
    'product_snapshot': productSnapshot,
    'amount_cents': amountCents,
    'currency': 'CNY',
    'status': 'paying',
    'provider': 'wechat',
    'fulfilled': false,
  });
}

void main() {
  test('registration fee amount is labeled as a one-time charge', () {
    expect(caseFeeAmountLabel(_order('registration_fee')), '¥688.00（一次性）');
    expect(caseFeeBillingSummary(_order('registration_fee')), isNull);
  });

  test('annual bookkeeping order shows monthly quote and annual payment', () {
    final order = _order(
      'bookkeeping_fee',
      amountCents: 312000,
      productSnapshot: {
        'monthly_price': 260,
        'billing_months': 12,
        'billing_cycle': 'yearly',
        'annual_price': 3120,
      },
    );
    expect(caseFeeAmountLabel(order), '¥260.00 / 月');
    expect(caseFeeBillingSummary(order), '按年支付 ¥3120.00（12个月）');
  });

  test('legacy bookkeeping order keeps its original monthly display', () {
    final order = _order('bookkeeping_fee');
    expect(caseFeeAmountLabel(order), '¥688.00 / 月');
    expect(caseFeeBillingSummary(order), isNull);
  });
}
