import 'package:zhiban_client/models/wallet_transaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses wallet transaction response and formats signed amount', () {
    final result = WalletTransactionsResult.fromJson({
      'items': [
        {
          'direction': 'debit',
          'amount': 653,
          'amountYuan': '0.0653',
          'balanceAfter': 152671,
          'reason': 'consume',
          'remark': '会议智记消费',
          'bizNo': 'bill-001',
          'usedAt': '2026-05-06T16:03:00+08:00',
          'createdAt': '2026-05-06T16:03:01+08:00',
        },
        {
          'direction': 'credit',
          'amount': 1000000,
          'amountYuan': '100.0000',
          'balanceAfter': 1152671,
          'reason': 'recharge',
          'remark': '',
          'bizNo': 'pay-001',
          'usedAt': '2026-05-06T17:03:00+08:00',
          'createdAt': '2026-05-06T17:03:01+08:00',
        },
      ],
      'total': 2,
    });

    expect(result.total, 2);
    expect(result.items, hasLength(2));
    expect(result.items.first.title, '会议智记消费');
    expect(result.items.first.signedAmountLabel, '-0.0653');
    expect(result.items.first.balanceAfterYuan, '15.2671');
    expect(result.items.last.title, '充值');
    expect(result.items.last.signedAmountLabel, '+100.0000');
  });
}
