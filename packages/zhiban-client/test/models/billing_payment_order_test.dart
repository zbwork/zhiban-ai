import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/models/billing_models.dart';

void main() {
  test('admin credit purchase is a recorded grant, not an online payment', () {
    final order = BillingPaymentOrder.fromJson({
      'order_type': 'credit_pack',
      'provider': 'manual',
      'status': 'paid',
      'amount_cents': 1,
      'fulfilled': true,
      'product_snapshot': {
        'source': 'admin_credit_purchase',
        'name': '后台增购积分',
        'credits': 10
      },
    });
    expect(order.isAdminCreditPurchase, isTrue);
    expect(order.orderTypeLabel, '后台增购积分');
    expect(order.providerLabel, '后台增购');
    expect(order.statusLabel, '已到账');
    expect(order.amountYuan, '0.01');
    expect(order.productId, isNull);
    expect(order.paymentUrl, isEmpty);
    final ordinary = BillingPaymentOrder.fromJson(
        {'order_type': 'credit_pack', 'provider': 'wechat', 'status': 'paid'});
    expect(ordinary.providerLabel, '微信支付');
    expect(ordinary.statusLabel, '已支付');
  });

  test('parses nested WeChat APP payment parameters', () {
    final order = BillingPaymentOrder.fromJson({
      'out_trade_no': 'PAY-1',
      'provider_prepay': {
        'trade_type': 'app',
        'appid': 'wx-app',
        'prepay': {
          'partnerId': 'mch-1',
          'prepayId': 'prepay-1',
          'package': 'Sign=WXPay',
          'nonceStr': 'nonce',
          'timeStamp': '123',
          'sign': 'signature',
        },
      },
    });

    final params = order.wechatAppPayParams;
    expect(params?.isValid, isTrue);
    expect(params?.appId, 'wx-app');
    expect(params?.partnerId, 'mch-1');
    expect(params?.timestamp, 123);
  });

  test('does not accept incomplete WeChat APP payment parameters', () {
    final order = BillingPaymentOrder.fromJson({
      'out_trade_no': 'PAY-2',
      'provider_prepay': {
        'trade_type': 'app',
        'prepay': {'appId': 'wx-app'},
      },
    });

    expect(order.wechatAppPayParams?.isValid, isFalse);
  });

  test('normalizes RFC3339 order timestamps to device local time', () {
    final order = BillingPaymentOrder.fromJson({
      'id': 2,
      'out_trade_no': 'X2',
      'order_type': 'credit_pack',
      'amount_cents': 20,
      'currency': 'CNY',
      'status': 'paid',
      'provider': 'wechat',
      'fulfilled': true,
      'created_at': '2026-07-21T09:59:00Z',
      'paid_at': '2026-07-21T10:00:00Z',
    });

    expect(
      order.createdAt,
      DateTime.parse('2026-07-21T09:59:00Z').toLocal()
    );
    expect(
      order.paidAt,
      DateTime.parse('2026-07-21T10:00:00Z').toLocal()
    );
    expect(order.createdAt!.isUtc, isFalse);
    expect(order.paidAt!.isUtc, isFalse);
  });
}
