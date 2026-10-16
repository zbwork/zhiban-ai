class BillingPlan {
  const BillingPlan({
    required this.id,
    required this.code,
    required this.name,
    required this.description,
    required this.priceMonthly,
    required this.priceYearly,
    required this.originalPriceMonthly,
    required this.currency,
    required this.billingCycle,
    required this.prices,
    required this.features,
    required this.trialDays,
    required this.monthlyCredits,
    required this.sortOrder,
    required this.isActive,
    required this.isRecommended,
  });

  final int id;
  final String code;
  final String name;
  final String description;
  final double? priceMonthly;
  final double? priceYearly;
  final double? originalPriceMonthly;
  final String currency;
  final String billingCycle;
  final List<BillingPlanPrice> prices;
  final List<BillingPlanFeature> features;
  final int trialDays;
  final int monthlyCredits;
  final int sortOrder;
  final bool isActive;
  final bool isRecommended;

  factory BillingPlan.fromJson(Map<String, dynamic> json) {
    return BillingPlan(
      id: _readInt(json['id']) ?? 0,
      code: (json['code'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      priceMonthly: _readDouble(json['price_monthly']),
      priceYearly: _readDouble(json['price_yearly']),
      originalPriceMonthly: _readDouble(json['original_price_monthly']),
      currency: (json['currency'] ?? 'CNY').toString(),
      billingCycle: (json['billing_cycle'] ?? '').toString(),
      prices: (json['prices'] is List)
          ? (json['prices'] as List)
              .whereType<Map<String, dynamic>>()
              .map(BillingPlanPrice.fromJson)
              .toList()
          : const [],
      features: (json['features'] is List)
          ? (json['features'] as List)
              .whereType<Map<String, dynamic>>()
              .map(BillingPlanFeature.fromJson)
              .toList()
          : const [],
      trialDays: _readInt(json['trial_days']) ?? 0,
      monthlyCredits: _readInt(json['monthly_credits']) ?? 0,
      sortOrder: _readInt(json['sort_order']) ?? 0,
      isActive: json['is_active'] == true,
      isRecommended: json['is_recommended'] == true,
    );
  }

  bool get isFree {
    final activePrices = prices.where((price) => price.isActive).toList();
    if (activePrices.isNotEmpty) {
      return activePrices.every((price) => price.amount <= 0);
    }
    return (priceMonthly ?? 0) <= 0 && (priceYearly ?? 0) <= 0;
  }

  bool get hasDiscount =>
      originalPriceMonthly != null &&
      priceMonthly != null &&
      originalPriceMonthly! > priceMonthly!;

  String get priceLabel {
    if (isFree) return '免费';
    final price = priceForCycle(billingCycle);
    if (price == null) return '免费';
    final unit = billingCycle == 'yearly' ? '年' : '月';
    return '¥${price.toStringAsFixed(2)}/$unit';
  }

  String get priceShort {
    if (isFree) return '免费';
    final price = priceMonthly;
    if (price == null) return '免费';
    final v = price == price.roundToDouble()
        ? price.round().toString()
        : price.toStringAsFixed(2);
    return '¥$v';
  }

  double? priceForCycle(String cycle) {
    if (isFree) return 0;
    final price = pricePointForCycle(cycle);
    if (price != null) return price.amount;
    if (cycle == 'yearly') return priceYearly ?? priceMonthly;
    return priceMonthly ?? priceYearly;
  }

  BillingPlanPrice? pricePointForCycle(String cycle) {
    for (final price in prices) {
      if (price.isActive && price.billingCycle == cycle) return price;
    }
    return null;
  }

  double? displayMonthlyPriceForCycle(String cycle) {
    if (isFree) return 0;
    final price = pricePointForCycle(cycle);
    if (price != null) {
      if (cycle == 'yearly') {
        return price.displayMonthlyAmount ?? price.amount / 12;
      }
      return price.displayMonthlyAmount ?? price.amount;
    }
    final actual = priceForCycle(cycle);
    if (actual == null) return null;
    return cycle == 'yearly' ? actual / 12 : actual;
  }

  String displayMonthlyPriceShortForCycle(String cycle) {
    if (isFree) return '免费';
    final price = displayMonthlyPriceForCycle(cycle);
    if (price == null) return '免费';
    final value = price == price.roundToDouble()
        ? price.round().toString()
        : price.toStringAsFixed(2);
    return '¥$value';
  }

  String? promotionTextForCycle(String cycle) {
    final text = pricePointForCycle(cycle)?.promotionText.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  String? originalAmountShortForCycle(String cycle) {
    final pricePoint = pricePointForCycle(cycle);
    final original = pricePoint != null
        ? pricePoint.originalAmount
        : (cycle == 'monthly' ? originalPriceMonthly : null);
    if (original == null || original <= 0) return null;

    final comparableOriginal = cycle == 'yearly' ? original / 12 : original;
    final comparableCurrent = cycle == 'yearly'
        ? displayMonthlyPriceForCycle(cycle)
        : priceForCycle(cycle);
    if (comparableCurrent == null || comparableOriginal <= comparableCurrent) {
      return null;
    }

    final value = comparableOriginal == comparableOriginal.roundToDouble()
        ? comparableOriginal.round().toString()
        : comparableOriginal.toStringAsFixed(2);
    return '¥$value';
  }

  String priceLabelForCycle(String cycle) {
    if (isFree) return '免费';
    final price = priceForCycle(cycle);
    if (price == null) return '免费';
    final unit = cycle == 'yearly' ? '年' : '月';
    final value = price == price.roundToDouble()
        ? price.round().toString()
        : price.toStringAsFixed(2);
    return '¥$value/$unit';
  }

  String priceShortForCycle(String cycle) {
    if (isFree) return '免费';
    final price = priceForCycle(cycle);
    if (price == null) return '免费';
    final value = price == price.roundToDouble()
        ? price.round().toString()
        : price.toStringAsFixed(2);
    return '¥$value';
  }

  String? get originalPriceShort {
    if (!hasDiscount) return null;
    final v = originalPriceMonthly!;
    final s =
        v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);
    return '¥$s';
  }
}

class BillingPlanFeature {
  const BillingPlanFeature({
    required this.featureCode,
    required this.featureName,
    required this.featureType,
    required this.limitValue,
    required this.limitUnit,
    required this.limitBytes,
    required this.sortOrder,
  });

  final String featureCode;
  final String featureName;
  final String featureType;
  final int? limitValue;
  final String? limitUnit;
  final int? limitBytes;
  final int sortOrder;

  factory BillingPlanFeature.fromJson(Map<String, dynamic> json) {
    return BillingPlanFeature(
      featureCode: (json['feature_code'] ?? '').toString(),
      featureName: (json['feature_name'] ?? '').toString(),
      featureType: (json['feature_type'] ?? '').toString(),
      limitValue: _readInt(json['limit_value']),
      limitUnit: json['limit_unit']?.toString(),
      limitBytes: _readInt(json['limit_bytes']),
      sortOrder: _readInt(json['sort_order']) ?? 0,
    );
  }
}

class BillingPlanPrice {
  const BillingPlanPrice({
    required this.id,
    required this.code,
    required this.billingCycle,
    required this.amount,
    required this.currency,
    required this.intervalCount,
    required this.displayMonthlyAmount,
    required this.originalAmount,
    required this.promotionText,
    required this.isActive,
  });

  final int id;
  final String code;
  final String billingCycle;
  final double amount;
  final String currency;
  final int intervalCount;
  final double? displayMonthlyAmount;
  final double? originalAmount;
  final String promotionText;
  final bool isActive;

  factory BillingPlanPrice.fromJson(Map<String, dynamic> json) {
    return BillingPlanPrice(
      id: _readInt(json['id']) ?? 0,
      code: (json['code'] ?? '').toString(),
      billingCycle: (json['billing_cycle'] ?? '').toString(),
      amount: _readDouble(json['amount']) ?? 0,
      currency: (json['currency'] ?? 'CNY').toString(),
      intervalCount: _readInt(json['interval_count']) ?? 1,
      displayMonthlyAmount: _readDouble(json['display_monthly_amount']),
      originalAmount: _readDouble(json['original_amount']),
      promotionText: (json['promotion_text'] ?? '').toString(),
      isActive: json['is_active'] != false,
    );
  }
}

class BillingSubscription {
  const BillingSubscription({
    required this.id,
    required this.tenantId,
    required this.planId,
    required this.planName,
    required this.planCode,
    required this.pendingPlanId,
    required this.pendingPlanName,
    required this.pendingPlanCode,
    required this.pendingBillingCycle,
    required this.pendingEffectiveAt,
    required this.status,
    required this.currentPeriodStart,
    required this.currentPeriodEnd,
    required this.trialEnd,
    required this.canceledAt,
    required this.cancelReason,
    required this.autoRenew,
    required this.inGracePeriod,
    required this.gracePeriodEnd,
    required this.createdAt,
  });

  final int id;
  final int tenantId;
  final int planId;
  final String planName;
  final String planCode;
  final int? pendingPlanId;
  final String pendingPlanName;
  final String pendingPlanCode;
  final String pendingBillingCycle;
  final DateTime? pendingEffectiveAt;
  final String status;
  final DateTime? currentPeriodStart;
  final DateTime? currentPeriodEnd;
  final DateTime? trialEnd;
  final DateTime? canceledAt;
  final String cancelReason;
  final bool autoRenew;
  final bool inGracePeriod;
  final DateTime? gracePeriodEnd;
  final DateTime? createdAt;

  factory BillingSubscription.fromJson(Map<String, dynamic> json) {
    return BillingSubscription(
      id: _readInt(json['id']) ?? 0,
      tenantId: _readInt(json['tenant_id']) ?? 0,
      planId: _readInt(json['plan_id']) ?? 0,
      planName: (json['plan_name'] ?? '').toString(),
      planCode: (json['plan_code'] ?? '').toString(),
      pendingPlanId: _readInt(json['pending_plan_id']),
      pendingPlanName: (json['pending_plan_name'] ?? '').toString(),
      pendingPlanCode: (json['pending_plan_code'] ?? '').toString(),
      pendingBillingCycle: (json['pending_billing_cycle'] ?? '').toString(),
      pendingEffectiveAt: _parseDateTime(json['pending_effective_at']),
      status: (json['status'] ?? '').toString(),
      currentPeriodStart: _parseDateTime(json['current_period_start']),
      currentPeriodEnd: _parseDateTime(json['current_period_end']),
      trialEnd: _parseDateTime(json['trial_end']),
      canceledAt: _parseDateTime(json['canceled_at']),
      cancelReason: (json['cancel_reason'] ?? '').toString(),
      autoRenew: json['auto_renew'] == true,
      inGracePeriod: json['in_grace_period'] == true,
      gracePeriodEnd: _parseDateTime(json['grace_period_end']),
      createdAt: _parseDateTime(json['created_at']),
    );
  }

  bool get hasPendingPlanChange =>
      pendingPlanId != null &&
      pendingPlanId! > 0 &&
      pendingBillingCycle.isNotEmpty;

  bool get isActive => status == 'active' || status == 'trialing';

  String get statusLabel {
    switch (status) {
      case 'active':
        return '使用中';
      case 'trialing':
        return '试用中';
      case 'past_due':
        return '已逾期';
      case 'canceled':
        return '已取消';
      case 'expired':
        return '已过期';
      default:
        return status;
    }
  }
}

class BillingWallet {
  const BillingWallet({
    required this.tenantId,
    required this.balance,
    required this.subscriptionCredits,
    required this.addOnCredits,
    required this.activityCredits,
    required this.overdraftUsed,
    required this.overdraftLimit,
    required this.frozen,
    required this.availableCredits,
    required this.expiringCreditsTotal,
    required this.nearestExpiringAt,
    required this.lowCreditWarningThreshold,
  });

  final int tenantId;
  final int balance;
  final int subscriptionCredits;
  final int addOnCredits;
  final int activityCredits;
  final int overdraftUsed;
  final int overdraftLimit;
  final bool frozen;
  final int availableCredits;
  final int expiringCreditsTotal;
  final DateTime? nearestExpiringAt;
  final int lowCreditWarningThreshold;

  factory BillingWallet.fromJson(Map<String, dynamic> json) {
    return BillingWallet(
      tenantId: _readInt(json['tenant_id']) ?? 0,
      balance: _readInt(json['balance']) ?? 0,
      subscriptionCredits: _readInt(json['subscription_credits']) ?? 0,
      addOnCredits: _readInt(json['add_on_credits']) ?? 0,
      activityCredits: _readInt(json['activity_credits']) ?? 0,
      overdraftUsed: _readInt(json['overdraft_used']) ?? 0,
      overdraftLimit: _readInt(json['overdraft_limit']) ?? 0,
      frozen: json['frozen'] == true,
      availableCredits: _readInt(json['available_credits']) ?? 0,
      expiringCreditsTotal: _readInt(json['expiring_credits_total']) ?? 0,
      nearestExpiringAt: _parseDateTime(json['nearest_expiring_at']),
      lowCreditWarningThreshold:
          _readInt(json['low_credit_warning_threshold']) ?? 0,
    );
  }

  String get balanceLabel => balance.toString();

  bool get isLowCredit =>
      lowCreditWarningThreshold > 0 && balance <= lowCreditWarningThreshold;
}

/// 客户端积分展示口径。
///
/// 订阅、增购和活动积分必须直接使用服务端按有效 grant 来源汇总的字段，
/// 不能再通过“总余额 - 套餐额度”反推，否则增购积分会先被错误补到订阅积分。
/// 冻结仅限制使用，不改变余额或来源明细；欠费保留负余额。
class BillingCreditDisplay {
  const BillingCreditDisplay({
    required this.totalCredits,
    required this.subscriptionRemaining,
    required this.subscriptionTotal,
    required this.addOnCredits,
    required this.activityCredits,
  });

  factory BillingCreditDisplay.fromWallet(
    BillingWallet? wallet, {
    required int subscriptionTotal,
  }) {
    return BillingCreditDisplay(
      totalCredits: wallet?.balance ?? 0,
      subscriptionRemaining: wallet?.subscriptionCredits ?? 0,
      subscriptionTotal: subscriptionTotal,
      addOnCredits: wallet?.addOnCredits ?? 0,
      activityCredits: wallet?.activityCredits ?? 0,
    );
  }

  final int totalCredits;
  final int subscriptionRemaining;
  final int subscriptionTotal;
  final int addOnCredits;
  final int activityCredits;

  double get subscriptionProgress => subscriptionTotal > 0
      ? (subscriptionRemaining / subscriptionTotal).clamp(0.0, 1.0)
      : 0.0;
}

class BillingEntitlement {
  const BillingEntitlement({
    required this.id,
    required this.tenantId,
    required this.featureCode,
    required this.featureName,
    required this.featureType,
    required this.grantedValue,
    required this.grantedUnit,
    required this.grantedValueBytes,
    required this.currentUsage,
    required this.currentUsageBytes,
    required this.isActive,
  });

  final int id;
  final int tenantId;
  final String featureCode;
  final String featureName;
  final String featureType;
  final int? grantedValue;
  final String? grantedUnit;
  final int? grantedValueBytes;
  final int? currentUsage;
  final int? currentUsageBytes;
  final bool isActive;

  factory BillingEntitlement.fromJson(Map<String, dynamic> json) {
    return BillingEntitlement(
      id: _readInt(json['id']) ?? 0,
      tenantId: _readInt(json['tenant_id']) ?? 0,
      featureCode: (json['feature_code'] ?? '').toString(),
      featureName: (json['feature_name'] ?? '').toString(),
      featureType: (json['feature_type'] ?? json['type'] ?? '').toString(),
      grantedValue: _readInt(json['granted_value']),
      grantedUnit: json['granted_unit']?.toString(),
      grantedValueBytes: _readInt(json['granted_value_bytes']),
      currentUsage: _readInt(json['current_usage']),
      currentUsageBytes: _readInt(json['current_usage_bytes']),
      isActive: json['is_active'] == true,
    );
  }

  String get displayLabel {
    switch (featureCode) {
      case 'monthly_credits':
        return '每月积分额度';
      case 'can_buy_credit_pack':
        return '可额外购买积分包';
      case 'digital_employee_limit':
        return '数字员工数量';
      case 'member_limit':
        return '团队成员数';
      case 'automation_task_limit':
        return '自动任务数量';
      case 'digital_employee_av_call':
        return '数字员工音视频通话';
      case 'av_call_minutes_monthly':
        return '音视频通话时长';
      case 'premium_data_skills':
        return '增值数据源/API 技能';
      case 'usage_report_level':
        return '用量统计报表';
      case 'knowledge_file_storage_limit':
        return '知识库文件容量';
      case 'drive_file_storage_limit':
        return '云盘文件容量';
      default:
        return featureName.isNotEmpty ? featureName : featureCode;
    }
  }

  String get valueLabel {
    if (featureType == 'boolean') {
      return (grantedValue ?? 0) > 0 ? '已开通' : '未开通';
    }
    if (grantedValueBytes != null || currentUsageBytes != null) {
      if (grantedValueBytes == null) return '无限制';
      if (currentUsageBytes == null) {
        return _formatBytes(grantedValueBytes!);
      }
      final used = currentUsageBytes!;
      return '${_formatBytes(used)} / ${_formatBytes(grantedValueBytes!)}';
    }
    if (grantedValue == null) return '无限制';
    // 周期性配额单位形如「积分/月」,周期已由「每月×××」标签表达,展示时去掉「/月」
    final unit = (grantedUnit ?? '').replaceFirst(RegExp(r'/月$'), '');
    final suffix = unit.isEmpty ? '' : ' $unit';
    // 后端仅对注册了用量计数器的配额返回 current_usage(如成员数/数字员工数);
    // 未跟踪用量的配额(如每月积分额度)只展示额度上限,不伪造 0 用量
    if (currentUsage == null) return '$grantedValue$suffix';
    return '$currentUsage / $grantedValue$suffix';
  }
}

class BillingCreditPack {
  const BillingCreditPack({
    required this.id,
    required this.name,
    required this.credits,
    required this.price,
    required this.currency,
    required this.sortOrder,
    required this.isActive,
  });

  final int id;
  final String name;
  final int credits;
  final double price;
  final String currency;
  final int sortOrder;
  final bool isActive;

  factory BillingCreditPack.fromJson(Map<String, dynamic> json) {
    return BillingCreditPack(
      id: _readInt(json['id'] ?? json['ID']) ?? 0,
      name: (json['name'] ?? json['Name'] ?? '').toString(),
      credits: _readInt(json['credits'] ?? json['Credits']) ?? 0,
      price: _readDouble(json['price'] ?? json['Price']) ?? 0,
      currency: (json['currency'] ?? json['Currency'] ?? 'CNY').toString(),
      sortOrder: _readInt(
              json['sort_order'] ?? json['sortOrder'] ?? json['SortOrder']) ??
          0,
      isActive:
          (json['is_active'] ?? json['isActive'] ?? json['IsActive']) == true,
    );
  }

  String get priceLabel => '¥${price.toStringAsFixed(2)}';
}

class BillingPaymentOrder {
  const BillingPaymentOrder({
    required this.id,
    required this.outTradeNo,
    required this.orderType,
    required this.productId,
    required this.productSnapshot,
    required this.amountCents,
    required this.currency,
    required this.status,
    required this.provider,
    required this.providerTradeNo,
    required this.providerPrepay,
    required this.fulfilled,
    required this.paidAt,
    required this.createdAt,
  });

  final int id;
  final String outTradeNo;
  final String orderType;
  final int? productId;
  final Map<String, dynamic>? productSnapshot;
  final int amountCents;
  final String currency;
  final String status;
  final String provider;
  final String providerTradeNo;
  final Map<String, dynamic>? providerPrepay;
  final bool fulfilled;
  final DateTime? paidAt;
  final DateTime? createdAt;

  factory BillingPaymentOrder.fromJson(Map<String, dynamic> json) {
    return BillingPaymentOrder(
      id: _readInt(json['id']) ?? 0,
      outTradeNo: (json['out_trade_no'] ?? '').toString(),
      orderType: (json['order_type'] ?? '').toString(),
      productId: _readInt(json['product_id']),
      productSnapshot: json['product_snapshot'] is Map
          ? Map<String, dynamic>.from(json['product_snapshot'] as Map)
          : null,
      amountCents: _readInt(json['amount_cents']) ?? 0,
      currency: (json['currency'] ?? 'CNY').toString(),
      status: (json['status'] ?? '').toString(),
      provider: (json['provider'] ?? '').toString(),
      providerTradeNo: (json['provider_trade_no'] ?? '').toString(),
      providerPrepay: json['provider_prepay'] is Map
          ? Map<String, dynamic>.from(json['provider_prepay'] as Map)
          : null,
      fulfilled: json['fulfilled'] == true,
      paidAt: _parseDateTime(json['paid_at'])?.toLocal(),
      createdAt: _parseDateTime(json['created_at'])?.toLocal(),
    );
  }

  bool get isPending => status == 'created' || status == 'paying';

  bool get isPaid => status == 'paid';

  String get amountYuan => (amountCents / 100).toStringAsFixed(2);

  String get codeUrl {
    final prepay = providerPrepay;
    if (prepay == null) return '';
    final direct = prepay['code_url']?.toString() ?? '';
    if (direct.isNotEmpty) return direct;
    final nested = prepay['prepay'];
    if (nested is Map) {
      return (nested['code_url'] ?? nested['codeUrl'] ?? '').toString();
    }
    return '';
  }

  String get paymentUrl {
    final prepay = providerPrepay;
    if (prepay == null) return codeUrl;
    final direct = (prepay['payment_url'] ??
            prepay['paymentUrl'] ??
            prepay['mweb_url'] ??
            prepay['mwebUrl'] ??
            prepay['deeplink'] ??
            prepay['deep_link'] ??
            '')
        .toString();
    return direct.isNotEmpty ? direct : codeUrl;
  }

  BillingWechatAppPayParams? get wechatAppPayParams {
    final root = providerPrepay;
    if (root == null) return null;
    final nested = root['prepay'];
    final source = nested is Map
        ? <String, dynamic>{...root, ...Map<String, dynamic>.from(nested)}
        : root;
    return BillingWechatAppPayParams.fromJson(source);
  }

  String get statusLabel {
    if (isAdminCreditPurchase && status == 'paid') {
      return fulfilled ? '已到账' : '入账中';
    }
    switch (status) {
      case 'created':
        return '待支付';
      case 'paying':
        return '支付中';
      case 'paid':
        return '已支付';
      case 'closed':
        return '已关闭';
      case 'refunding':
        return '退款中';
      case 'refunded':
        return '已退款';
      default:
        return status;
    }
  }

  String get orderTypeLabel {
    if (isAdminCreditPurchase) {
      final name = productSnapshot?['name']?.toString().trim() ?? '';
      return name.isEmpty ? '后台增购积分' : name;
    }
    switch (orderType) {
      case 'subscription':
        return '套餐订阅';
      case 'upgrade':
        return '套餐升级';
      case 'credit_pack':
        return '积分包';
      default:
        return orderType;
    }
  }

  String get subscriptionPlanLabel {
    final snap = productSnapshot;
    final value = snap == null
        ? ''
        : (snap['name'] ??
                snap['Name'] ??
                snap['plan_name'] ??
                snap['to_plan_name'] ??
                '')
            .toString();
    if (value.trim().isNotEmpty) return value.trim();
    return orderTypeLabel;
  }

  bool get isAdminCreditPurchase =>
      orderType == 'credit_pack' &&
      provider == 'manual' &&
      productSnapshot?['source'] == 'admin_credit_purchase';

  String get providerLabel {
    if (isAdminCreditPurchase) return '后台增购';
    switch (provider) {
      case 'wechat':
        return '微信支付';
      case 'alipay':
        return '支付宝';
      case 'manual':
        return '人工处理';
      case '':
        return '-';
      default:
        return provider;
    }
  }

  String get subscriptionCycleRaw {
    final snap = productSnapshot;
    return snap == null
        ? ''
        : (snap['billing_cycle'] ??
                snap['billingCycle'] ??
                snap['BillingCycle'] ??
                '')
            .toString();
  }

  String get subscriptionCycleLabel {
    final value = subscriptionCycleRaw;
    switch (value) {
      case 'monthly':
        return '按月付';
      case 'yearly':
        return '按年付';
      case 'none':
        return '无周期';
      default:
        return '-';
    }
  }
}

class BillingWechatAppPayParams {
  const BillingWechatAppPayParams({
    required this.appId,
    required this.partnerId,
    required this.prepayId,
    required this.packageValue,
    required this.nonceStr,
    required this.timestamp,
    required this.sign,
  });

  final String appId;
  final String partnerId;
  final String prepayId;
  final String packageValue;
  final String nonceStr;
  final int timestamp;
  final String sign;

  bool get isValid =>
      appId.isNotEmpty &&
      partnerId.isNotEmpty &&
      prepayId.isNotEmpty &&
      packageValue.isNotEmpty &&
      nonceStr.isNotEmpty &&
      timestamp > 0 &&
      sign.isNotEmpty;

  factory BillingWechatAppPayParams.fromJson(Map<String, dynamic> json) {
    String value(List<String> keys) {
      for (final key in keys) {
        final raw = json[key];
        if (raw != null && raw.toString().isNotEmpty) return raw.toString();
      }
      return '';
    }

    return BillingWechatAppPayParams(
      appId: value(const ['appid', 'appId', 'Appid']),
      partnerId: value(const ['partnerid', 'partnerId', 'Partnerid', 'mchid']),
      prepayId: value(const ['prepayid', 'prepayId', 'Prepayid']),
      packageValue: value(const ['package', 'packageValue', 'Package']),
      nonceStr: value(const ['noncestr', 'nonceStr', 'Noncestr']),
      timestamp: _readInt(json['timestamp'] ?? json['timeStamp']) ?? 0,
      sign: value(const ['sign', 'Sign']),
    );
  }
}

class BillingUsageAggregate {
  const BillingUsageAggregate({
    this.unknownAmountCount = 0,
    required this.id,
    required this.tenantId,
    required this.resourceType,
    required this.period,
    required this.periodStart,
    required this.skillId,
    required this.operationCode,
    required this.totalAmount,
    required this.totalCredits,
    required this.eventCount,
    required this.updatedAt,
  });

  final int id;
  final int tenantId;
  final String resourceType;
  final String period;
  final DateTime? periodStart;
  final int? skillId;
  final String operationCode;
  final int totalAmount;
  final int totalCredits;
  final int eventCount;
  final int unknownAmountCount;
  final DateTime? updatedAt;

  factory BillingUsageAggregate.fromJson(Map<String, dynamic> json) {
    return BillingUsageAggregate(
      unknownAmountCount: _readInt(json['unknown_amount_count']) ?? 0,
      id: _readInt(_field(json, 'id', 'ID')) ?? 0,
      tenantId: _readInt(_field(json, 'tenant_id', 'TenantID')) ?? 0,
      resourceType:
          _field(json, 'resource_type', 'ResourceType')?.toString() ?? '',
      period: _field(json, 'period', 'Period')?.toString() ?? '',
      periodStart: _parseDateTime(_field(json, 'period_start', 'PeriodStart')),
      skillId: _readInt(_field(json, 'skill_id', 'SkillID')),
      operationCode:
          _field(json, 'operation_code', 'OperationCode')?.toString() ?? '',
      totalAmount: _readInt(_field(json, 'total_amount', 'TotalAmount')) ?? 0,
      totalCredits:
          _readInt(_field(json, 'total_credits', 'TotalCredits')) ?? 0,
      eventCount: _readInt(_field(json, 'event_count', 'EventCount')) ?? 0,
      updatedAt: _parseDateTime(_field(json, 'updated_at', 'UpdatedAt')),
    );
  }

  String get resourceLabel {
    switch (resourceType) {
      case 'skill':
        return '技能调用';
      case 'llm':
        return '模型消费';
      case 'rtc_minute':
        return 'AI 通话';
      case 'runtime':
        return '运行时';
      default:
        return resourceType.isEmpty ? '其他用量' : resourceType;
    }
  }
}

enum ChangePlanAction { upgrade, downgrade, scheduled, unknown }

class ChangePlanResult {
  const ChangePlanResult({
    required this.action,
    this.order,
    this.effectiveAt,
    required this.proratedDays,
  });

  final ChangePlanAction action;
  final BillingPaymentOrder? order;
  final DateTime? effectiveAt;
  final int proratedDays;

  factory ChangePlanResult.fromJson(Map<String, dynamic> json) {
    final actionStr = (json['action'] ?? '').toString();
    ChangePlanAction action;
    switch (actionStr) {
      case 'upgrade':
        action = ChangePlanAction.upgrade;
        break;
      case 'downgrade':
        action = ChangePlanAction.downgrade;
        break;
      case 'scheduled':
        action = ChangePlanAction.scheduled;
        break;
      default:
        action = ChangePlanAction.unknown;
    }
    return ChangePlanResult(
      action: action,
      order: json['order'] is Map<String, dynamic>
          ? BillingPaymentOrder.fromJson(json['order'] as Map<String, dynamic>)
          : null,
      effectiveAt: _parseDateTime(json['effective_at']),
      proratedDays: _readInt(json['prorated_days']) ?? 0,
    );
  }
}

/// 单个 resource_type 的消耗汇总（积分消耗页「本月消耗」分类）。
class BillingUsageResourceSum {
  const BillingUsageResourceSum({
    this.unknownAmountCount = 0,
    required this.resourceType,
    required this.totalCredits,
    required this.totalAmount,
    required this.eventCount,
  });

  final String resourceType;
  final int totalCredits;
  final int totalAmount;
  final int eventCount;
  final int unknownAmountCount;

  factory BillingUsageResourceSum.fromJson(Map<String, dynamic> json) {
    return BillingUsageResourceSum(
      unknownAmountCount: _readInt(json['unknown_amount_count']) ?? 0,
      resourceType: (json['resource_type'] ?? '').toString(),
      totalCredits: _readInt(json['total_credits']) ?? 0,
      totalAmount: _readInt(json['total_amount']) ?? 0,
      eventCount: _readInt(json['event_count']) ?? 0,
    );
  }

  String get label => billingResourceLabel(resourceType);
}

/// 积分消耗汇总（GET /billing/usage/summary）。
class BillingUsageSummary {
  const BillingUsageSummary({
    required this.totalCredits,
    required this.totalEvents,
    required this.walletBalance,
    required this.byResource,
  });

  final int totalCredits;
  final int totalEvents;
  final int walletBalance;
  final List<BillingUsageResourceSum> byResource;

  factory BillingUsageSummary.fromJson(Map<String, dynamic> json) {
    final raw = json['by_resource'];
    final list = raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(BillingUsageResourceSum.fromJson)
            .toList()
        : <BillingUsageResourceSum>[];
    return BillingUsageSummary(
      totalCredits: _readInt(json['total_credits']) ?? 0,
      totalEvents: _readInt(json['total_events']) ?? 0,
      walletBalance: _readInt(json['wallet_balance']) ?? 0,
      byResource: list,
    );
  }

  int creditsFor(String resourceType) {
    for (final r in byResource) {
      if (r.resourceType == resourceType) return r.totalCredits;
    }
    return 0;
  }
}

/// 单条消耗明细（GET /billing/usage/events）。
class BillingUsageEvent {
  const BillingUsageEvent({
    this.meteringSource = '',
    this.model,
    this.inputTokens,
    this.outputTokens,
    this.cacheCreationInputTokens,
    this.cacheReadInputTokens,
    this.amountKnown = true,
    this.chargeCount = 0,
    this.refundCount = 0,
    this.netUsd = '',
    required this.id,
    required this.resourceType,
    required this.sourceScene,
    required this.sourceObjectType,
    required this.sourceObjectId,
    required this.displayTitle,
    required this.accountId,
    required this.accountName,
    required this.agentId,
    required this.agentUuid,
    required this.amount,
    required this.creditsCost,
    required this.chargeFailed,
    required this.intendedCredits,
    required this.status,
    required this.occurredAt,
  });

  final String meteringSource;
  final String? model;
  final int? inputTokens;
  final int? outputTokens;
  final int? cacheCreationInputTokens;
  final int? cacheReadInputTokens;
  final bool amountKnown;
  final int chargeCount;
  final int refundCount;
  final String netUsd;
  bool get isBeeBridge => meteringSource == 'beebridge';
  // Product grouping includes all clients sharing a BeeBridge member key.
  // Keep sourceScene unchanged: the provider does not identify the caller.
  String get sceneLabel {
    if (isBeeBridge) return '对话';
    switch (sourceScene.trim()) {
      case 'chat':
        return '对话';
      case 'cron':
        return '定时任务';
      case 'rtc':
        return '通话';
      case 'api':
        return 'API';
      case '':
        return '未提供';
      default:
        return sourceScene.trim();
    }
  }

  String get usageModelLabel =>
      resourceType == 'llm' || isBeeBridge ? modelLabel : '—';
  String get modelLabel => model?.trim().isNotEmpty == true ? model! : '未知模型';
  // Cache fields are reserved until BeeBridge confirms the webhook contract.
  String get tokenDetailLabel =>
      '输入 ${inputTokens ?? "未知"}\n输出 ${outputTokens ?? "未知"}';
  String get creditSign => displayCreditsCost < 0
      ? '+'
      : displayCreditsCost > 0
          ? '-'
          : '';
  String get minuteLabel {
    final local = occurredAt?.toLocal();
    if (local == null) return '-';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  final int id;
  final String resourceType;
  final String sourceScene;
  final String sourceObjectType;
  final String sourceObjectId;
  final String displayTitle;
  final int? accountId;
  final String accountName;
  final int? agentId;
  final String agentUuid;
  final int amount;
  final int creditsCost;
  final bool chargeFailed;
  final int intendedCredits;
  final String status;
  final DateTime? occurredAt;

  factory BillingUsageEvent.fromJson(Map<String, dynamic> json) {
    return BillingUsageEvent(
      meteringSource: (json['metering_source'] ?? '').toString(),
      model: json['model']?.toString(),
      inputTokens: _readInt(json['input_tokens']),
      outputTokens: _readInt(json['output_tokens']),
      cacheCreationInputTokens: _readInt(json['cache_creation_input_tokens']),
      cacheReadInputTokens: _readInt(json['cache_read_input_tokens']),
      amountKnown: json['amount_known'] != false,
      chargeCount: _readInt(json['charge_count']) ?? 0,
      refundCount: _readInt(json['refund_count']) ?? 0,
      netUsd: (json['net_usd'] ?? '').toString(),
      id: _readInt(json['id']) ?? 0,
      resourceType: (json['resource_type'] ?? '').toString(),
      sourceScene: (json['source_scene'] ?? '').toString(),
      sourceObjectType: (json['source_object_type'] ?? '').toString(),
      sourceObjectId: (json['source_object_id'] ?? '').toString(),
      displayTitle: (json['display_title'] ?? '').toString(),
      accountId: _readInt(json['account_id']),
      accountName: (json['account_name'] ?? '').toString(),
      agentId: _readInt(json['agent_id']),
      agentUuid: (json['agent_uuid'] ?? '').toString(),
      amount: _readInt(json['amount']) ?? 0,
      creditsCost: _readInt(json['credits_cost']) ?? 0,
      chargeFailed: json['charge_failed'] == true,
      intendedCredits: _readInt(json['intended_credits']) ?? 0,
      status: (json['status'] ?? '').toString(),
      occurredAt: _parseDateTime(json['occurred_at']),
    );
  }

  String get typeLabel => billingResourceLabel(resourceType);

  String get accountLabel {
    final name = accountName.trim();
    if (name.isNotEmpty) return name;
    final id = accountId;
    if (id != null && id > 0) return '用户 #$id';
    return isBeeBridge ? '未归属成员' : '系统';
  }

  int get displayCreditsCost =>
      chargeFailed && intendedCredits > 0 ? intendedCredits : creditsCost;

  /// 用量展示：LLM 按 token，RTC 按分钟，其余按次。
  String get usageLabel {
    switch (resourceType) {
      case 'llm':
        return amountKnown ? '$amount tokens' : 'Token 未知';
      case 'rtc_minute':
        return '$amount 分钟';
      default:
        return '$amount 次';
    }
  }
}

/// 按 source_scene 的消耗汇总。
class BillingUsageSceneSum {
  const BillingUsageSceneSum({
    required this.sourceScene,
    required this.totalCredits,
    required this.eventCount,
  });

  final String sourceScene;
  final int totalCredits;
  final int eventCount;

  factory BillingUsageSceneSum.fromJson(Map<String, dynamic> json) {
    return BillingUsageSceneSum(
      sourceScene: (json['source_scene'] ?? '').toString(),
      totalCredits: _readInt(json['total_credits']) ?? 0,
      eventCount: _readInt(json['event_count']) ?? 0,
    );
  }
}

/// 月度积分消耗对账单（预付费积分，非后付费 invoice）。
class BillingMonthlyStatement {
  const BillingMonthlyStatement({
    required this.month,
    required this.openingBalance,
    required this.grantedCredits,
    required this.consumedCredits,
    required this.closingBalance,
    required this.eventCount,
    required this.byResource,
    required this.byScene,
  });

  final String month;
  final int? openingBalance;
  final int grantedCredits;
  final int consumedCredits;
  final int? closingBalance;
  final int eventCount;
  final List<BillingUsageResourceSum> byResource;
  final List<BillingUsageSceneSum> byScene;

  factory BillingMonthlyStatement.fromJson(Map<String, dynamic> json) {
    List<T> list<T>(Object? raw, T Function(Map<String, dynamic>) f) {
      if (raw is! List) return <T>[];
      return raw.whereType<Map<String, dynamic>>().map(f).toList();
    }

    return BillingMonthlyStatement(
      month: (json['month'] ?? '').toString(),
      openingBalance: _readInt(json['opening_balance']),
      grantedCredits: _readInt(json['granted_credits']) ?? 0,
      consumedCredits: _readInt(json['consumed_credits']) ?? 0,
      closingBalance: _readInt(json['closing_balance']),
      eventCount: _readInt(json['event_count']) ?? 0,
      byResource: list(json['by_resource'], BillingUsageResourceSum.fromJson),
      byScene: list(json['by_scene'], BillingUsageSceneSum.fromJson),
    );
  }
}

/// resource_type → 客户端业务分类中文名（积分消耗页统一口径）。
String billingResourceLabel(String resourceType) {
  switch (resourceType) {
    case 'llm':
      return '模型消费';
    case 'rtc_minute':
      return 'AI 通话';
    case 'data_query':
      return '数据查询';
    case 'skill':
      return '技能调用';
    default:
      return resourceType.isEmpty ? '其他用量' : resourceType;
  }
}

int? _readInt(dynamic value) {
  if (value is int) return value;
  if (value == null) return null;
  return int.tryParse(value.toString());
}

Object? _field(Map<String, dynamic> json, String snake, String pascal) {
  if (json.containsKey(snake)) return json[snake];
  return json[pascal];
}

double? _readDouble(dynamic value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value == null) return null;
  return double.tryParse(value.toString());
}

String _formatBytes(int value) {
  if (value < 0) return '无限制';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = value.toDouble();
  var index = 0;
  while (size >= 1024 && index < units.length - 1) {
    size /= 1024;
    index++;
  }
  final text = size >= 10 || size == size.roundToDouble()
      ? size.toStringAsFixed(0)
      : size.toStringAsFixed(1);
  return '$text ${units[index]}';
}

DateTime? _parseDateTime(Object? value) {
  final raw = value?.toString() ?? '';
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

String billingCreditSign(int credits) => credits < 0 ? '+' : credits > 0 ? '-' : '';
