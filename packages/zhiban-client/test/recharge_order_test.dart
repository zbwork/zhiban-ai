import 'package:zhiban_client/models/recharge_order.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('converts recharge yuan input to fen', () {
    expect(rechargeYuanToFen('100'), 10000);
    expect(rechargeYuanToFen('¥200.50'), 20050);
    expect(rechargeYuanToFen('0.99'), isNull);
    expect(rechargeYuanToFen('abc'), isNull);
  });

  test('parses native recharge order and payment status', () {
    final order = NativeRechargeOrder.fromJson({
      'outTradeNo': 'A001',
      'codeUrl': 'weixin://wxpay/bizpayurl?pr=test',
    });
    expect(order.outTradeNo, 'A001');
    expect(order.codeUrl, startsWith('weixin://'));

    final status = RechargePaymentStatus.fromJson({
      'outTradeNo': 'A001',
      'transactionId': '420',
      'status': 'paid',
      'wechatTradeState': 'SUCCESS',
      'wechatTradeDesc': '支付成功',
      'walletProcessed': true,
      'paymentSuccess': true,
      'paymentSuccessDesc': '微信支付成功且账户已到账',
      'paidAt': '2026-05-06T12:00:00+08:00',
      'walletProcessedAt': '2026-05-06T12:00:01+08:00',
    });

    expect(status.paymentSuccess, isTrue);
    expect(status.isPending, isFalse);
    expect(status.walletProcessed, isTrue);
  });
}
