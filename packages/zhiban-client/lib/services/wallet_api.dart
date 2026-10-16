import 'package:zhiban_client/models/recharge_order.dart';
import 'package:zhiban_client/models/wallet_transaction.dart';
import 'package:zhiban_client/network/network.dart';

class WalletService {
  Future<WalletTransactionsResult> fetchTransactions({
    int page = 1,
    int pageSize = 20,
  }) async {
    final response = await request.get(
      '/account/wallet/transactions',
      queryParameters: {
        'page': page,
        'pageSize': pageSize
      },
    );
    final raw = response.data;
    final data = raw is Map<String, dynamic>
        ? raw
        : raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
    return WalletTransactionsResult.fromJson(data);
  }

  Future<NativeRechargeOrder> createNativeRechargeOrder({
    required int amountFen,
  }) async {
    final response = await request.post(
      '/apppay/native/prepay',
      data: {
        'amount': amountFen,
        'description': '钱包充值',
        'attach': 'desktop-recharge',
      },
    );
    return NativeRechargeOrder.fromJson(_asMap(response.data));
  }

  Future<AppRechargeOrder> createAppRechargeOrder({
    required int amountFen,
  }) async {
    final response = await request.post(
      '/apppay/prepay',
      data: {
        'amount': amountFen,
        'description': '钱包充值',
        'attach': 'user-recharge',
      },
    );
    return AppRechargeOrder.fromJson(_asMap(response.data));
  }

  Future<RechargePaymentStatus> queryRechargePaymentStatus({
    required String outTradeNo,
  }) async {
    final response = await request.get(
      '/apppay/order/payment-status',
      queryParameters: {'outTradeNo': outTradeNo},
    );
    return RechargePaymentStatus.fromJson(_asMap(response.data));
  }

  Future<void> closeRechargeOrder({required String outTradeNo}) async {
    await request.post(
      '/apppay/order/close',
      data: {'outTradeNo': outTradeNo}
    );
  }
}

Map<String, dynamic> _asMap(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return <String, dynamic>{};
}
