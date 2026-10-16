import 'package:dio/dio.dart';
import 'package:zhiban_client/models/billing_models.dart';
import 'package:zhiban_client/network/network.dart';

class BillingService {
  Future<List<BillingPlan>> listPlans() async {
    final response = await request.get('/billing/plans');
    final data = _asMap(response.data);
    final items = data['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(BillingPlan.fromJson)
        .toList();
  }

  Future<BillingSubscription?> getMySubscription() async {
    try {
      final response = await request.get(
        '/billing/my-subscription',
        options: Options(extra: const <String, dynamic>{'silent': true}),
      );
      if (response.data == null) return null;
      return BillingSubscription.fromJson(_asMap(response.data));
    } catch (_) {
      return null;
    }
  }

  Future<BillingWallet> getMyWallet() async {
    final response = await request.get('/billing/wallet');
    return BillingWallet.fromJson(_asMap(response.data));
  }

  Future<List<BillingEntitlement>> getMyEntitlements() async {
    final response = await request.get('/billing/entitlements');
    final data = _asMap(response.data);
    final items = data['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(BillingEntitlement.fromJson)
        .toList();
  }

  Future<List<BillingCreditPack>> listCreditPacks() async {
    final response = await request.get('/billing/credit-packs');
    final data = _asMap(response.data);
    final items = data['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(BillingCreditPack.fromJson)
        .toList();
  }

  Future<BillingPaymentOrder> subscribe({
    required int planId,
    String provider = '',
    String billingCycle = '',
    String tradeType = '',
  }) async {
    final response = await request.post(
      '/billing/subscribe',
      data: {
        'plan_id': planId,
        if (provider.isNotEmpty) 'provider': provider,
        if (billingCycle.isNotEmpty) 'billing_cycle': billingCycle,
        if (tradeType.isNotEmpty) 'trade_type': tradeType,
      },
    );
    return BillingPaymentOrder.fromJson(_asMap(response.data));
  }

  Future<BillingPaymentOrder> buyCreditPack({
    required int packId,
    String provider = '',
    String tradeType = '',
  }) async {
    final response = await request.post(
      '/billing/orders',
      data: {
        'order_type': 'credit_pack',
        'product_id': packId,
        if (provider.isNotEmpty) 'provider': provider,
        if (tradeType.isNotEmpty) 'trade_type': tradeType,
      },
    );
    return BillingPaymentOrder.fromJson(_asMap(response.data));
  }

  /// 垂域工单服务费下单（F24 收款线上化，代账/注册通用）：金额由服务端按
  /// 工单最终价决定，客户端只传工单 UUID 与支付形态。
  Future<BillingPaymentOrder> createCaseFeeOrder({
    required String caseId,
    String provider = 'wechat',
    String tradeType = '',
  }) async {
    final response = await request.post(
      '/billing/orders/case-fee',
      data: {
        'case_id': caseId,
        if (provider.isNotEmpty) 'provider': provider,
        if (tradeType.isNotEmpty) 'trade_type': tradeType,
      },
    );
    return BillingPaymentOrder.fromJson(_asMap(response.data));
  }

  Future<BillingPaymentOrder> getOrder(String outTradeNo) async {
    final response = await request.get('/billing/orders/$outTradeNo');
    return BillingPaymentOrder.fromJson(_asMap(response.data));
  }

  Future<BillingPaymentOrder> syncOrder(String outTradeNo) async {
    final response = await request.post('/billing/orders/$outTradeNo/sync');
    return BillingPaymentOrder.fromJson(_asMap(response.data));
  }

  Future<ChangePlanResult> changePlan({
    required int newPlanId,
    String provider = '',
    String billingCycle = '',
    String tradeType = '',
  }) async {
    final response = await request.post(
      '/billing/subscription/change-plan',
      data: {
        'new_plan_id': newPlanId,
        if (provider.isNotEmpty) 'provider': provider,
        if (billingCycle.isNotEmpty) 'billing_cycle': billingCycle,
        if (tradeType.isNotEmpty) 'trade_type': tradeType,
      },
    );
    return ChangePlanResult.fromJson(_asMap(response.data));
  }

  Future<List<BillingPaymentOrder>> listOrders({
    int limit = 20,
    int offset = 0,
  }) async {
    final response = await request.get(
      '/billing/orders',
      queryParameters: {'limit': limit, 'offset': offset},
    );
    final data = _asMap(response.data);
    final items = data['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(BillingPaymentOrder.fromJson)
        .toList();
  }

  Future<List<BillingUsageAggregate>> listUsageAggregates({
    String period = 'monthly',
    String periodStart = '',
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await request.get(
      '/billing/usage',
      queryParameters: {
        'period': period,
        if (periodStart.isNotEmpty) 'period_start': periodStart,
        'limit': limit,
        'offset': offset,
      },
    );
    final data = _asMap(response.data);
    final items = data['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(BillingUsageAggregate.fromJson)
        .toList();
  }

  /// 积分消耗汇总（本月或指定时间窗）。[from]/[to] 为 RFC3339 或 YYYY-MM-DD，省略默认当月。
  Future<BillingUsageSummary> getUsageSummary({
    String from = '',
    String to = '',
    String scope = '',
  }) async {
    final response = await request.get(
      '/billing/usage/summary',
      queryParameters: {
        if (from.isNotEmpty) 'from': from,
        if (to.isNotEmpty) 'to': to,
        if (scope.isNotEmpty) 'scope': scope,
      },
    );
    return BillingUsageSummary.fromJson(_asMap(response.data));
  }

  /// 月度积分消耗对账单（预付费积分，非后付费 invoice）。[month] 格式 YYYY-MM，省略默认当月。
  Future<BillingMonthlyStatement> getMonthlyStatement(
      {String month = ''}) async {
    final response = await request.get(
      '/billing/usage/monthly-statement',
      queryParameters: {if (month.isNotEmpty) 'month': month},
    );
    return BillingMonthlyStatement.fromJson(_asMap(response.data));
  }

  /// 消耗明细列表。[type]=resource_type 过滤，[scene]=source_scene 过滤。
  Future<List<BillingUsageEvent>> listUsageEvents({
    String from = '',
    String to = '',
    String type = '',
    String scene = '',
    String scope = '',
    bool includeFree = false,
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await request.get(
      '/billing/usage/events',
      queryParameters: {
        if (from.isNotEmpty) 'from': from,
        if (to.isNotEmpty) 'to': to,
        if (type.isNotEmpty) 'type': type,
        if (scene.isNotEmpty) 'scene': scene,
        if (scope.isNotEmpty) 'scope': scope,
        if (includeFree) 'include_free': '1',
        'limit': limit,
        'offset': offset,
      },
    );
    final data = _asMap(response.data);
    final items = data['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(BillingUsageEvent.fromJson)
        .toList();
  }
}

Map<String, dynamic> _asMap(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return <String, dynamic>{};
}
