import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/models/billing_models.dart';

void main() {
  group('BillingPlan price comparison', () {
    BillingPlan planWithPrice({
      required String cycle,
      required double amount,
      double? displayMonthlyAmount,
      double? originalAmount,
      double? legacyOriginalPriceMonthly,
    }) {
      return BillingPlan.fromJson({
        'id': 1,
        'code': 'basic',
        'name': '基础版',
        'price_monthly': 99,
        'price_yearly': 998,
        'original_price_monthly': legacyOriginalPriceMonthly,
        'currency': 'CNY',
        'billing_cycle': cycle,
        'prices': [
          {
            'id': 11,
            'code': 'basic_$cycle',
            'billing_cycle': cycle,
            'amount': amount,
            'currency': 'CNY',
            'interval_count': 1,
            'display_monthly_amount': displayMonthlyAmount,
            'original_amount': originalAmount,
            'promotion_text': '',
            'is_active': true,
          },
        ],
        'features': const [],
        'trial_days': 0,
        'monthly_credits': 120000,
        'sort_order': 20,
        'is_active': true,
        'is_recommended': false,
      });
    }

    test('monthly card reads original amount from the active price point', () {
      final plan = planWithPrice(
        cycle: 'monthly',
        amount: 99,
        originalAmount: 128,
      );

      expect(plan.originalAmountShortForCycle('monthly'), '¥128');
    });

    test('yearly card compares prices using monthly equivalents', () {
      final plan = planWithPrice(
        cycle: 'yearly',
        amount: 998,
        displayMonthlyAmount: 83,
        originalAmount: 1536,
      );

      expect(plan.originalAmountShortForCycle('yearly'), '¥128');
    });

    test('does not show a non-discount comparison price', () {
      final plan = planWithPrice(
        cycle: 'monthly',
        amount: 99,
        originalAmount: 99,
      );

      expect(plan.originalAmountShortForCycle('monthly'), isNull);
    });

    test('does not reuse a legacy original price for an active price point',
        () {
      final plan = planWithPrice(
        cycle: 'monthly',
        amount: 99,
        legacyOriginalPriceMonthly: 128,
      );

      expect(plan.originalAmountShortForCycle('monthly'), isNull);
    });

    test('keeps legacy monthly original price as a fallback', () {
      final plan = BillingPlan.fromJson({
        'id': 1,
        'code': 'basic',
        'name': '基础版',
        'price_monthly': 99,
        'original_price_monthly': 128,
        'currency': 'CNY',
        'billing_cycle': 'monthly',
        'prices': const [],
        'features': const [],
        'trial_days': 0,
        'monthly_credits': 120000,
        'sort_order': 20,
        'is_active': true,
        'is_recommended': false,
      });

      expect(plan.originalAmountShortForCycle('monthly'), '¥128');
    });
  });

  group('ChangePlanResult.fromJson', () {
    test('parses upgrade with order', () {
      final result = ChangePlanResult.fromJson({
        'action': 'upgrade',
        'order': {
          'id': 42,
          'out_trade_no': 'AB123',
          'order_type': 'upgrade',
          'amount_cents': 1500,
          'currency': 'CNY',
          'status': 'created',
          'provider': 'wechat',
          'fulfilled': false,
        },
        'prorated_days': 15,
      });
      expect(result.action, ChangePlanAction.upgrade);
      expect(result.order, isNotNull);
      expect(result.order!.amountCents, 1500);
      expect(result.order!.amountYuan, '15.00');
      expect(result.order!.orderType, 'upgrade');
      expect(result.order!.isPending, isTrue);
      expect(result.proratedDays, 15);
      expect(result.effectiveAt, isNull);
    });

    test('parses downgrade with effective_at', () {
      final result = ChangePlanResult.fromJson({
        'action': 'downgrade',
        'effective_at': '2026-07-15T00:00:00Z',
        'prorated_days': 0,
      });
      expect(result.action, ChangePlanAction.downgrade);
      expect(result.order, isNull);
      expect(result.effectiveAt, isNotNull);
      expect(result.effectiveAt!.month, 7);
      expect(result.effectiveAt!.day, 15);
    });

    test('parses unknown action gracefully', () {
      final result = ChangePlanResult.fromJson({
        'action': 'noop'
      });
      expect(result.action, ChangePlanAction.unknown);
      expect(result.order, isNull);
    });
  });

  group('BillingPaymentOrder.fromJson', () {
    test('upgrade order type label', () {
      final order = BillingPaymentOrder.fromJson({
        'id': 1,
        'out_trade_no': 'X1',
        'order_type': 'upgrade',
        'amount_cents': 0,
        'currency': 'CNY',
        'status': 'paid',
        'provider': 'manual',
        'fulfilled': true,
      });
      expect(order.isPaid, isTrue);
      expect(order.orderType, 'upgrade');
    });
  });

  group('BillingWallet.fromJson', () {
    test('parses server-side credit source breakdown', () {
      final wallet = BillingWallet.fromJson({
        'tenant_id': 877,
        'balance': 799470,
        'subscription_credits': 799470,
        'add_on_credits': 0,
        'activity_credits': 0,
        'overdraft_used': 0,
        'overdraft_limit': 80000,
        'frozen': false,
        'available_credits': 879470,
        'expiring_credits_total': 799470,
        'low_credit_warning_threshold': 100,
      });

      expect(wallet.balance, 799470);
      expect(wallet.subscriptionCredits, 799470);
      expect(wallet.addOnCredits, 0);
      expect(wallet.activityCredits, 0);
    });

    test('credit display keeps a purchased pack separate from subscription',
        () {
      const wallet = BillingWallet(
        tenantId: 877,
        balance: 125867,
        subscriptionCredits: 115867,
        addOnCredits: 10000,
        activityCredits: 0,
        overdraftUsed: 0,
        overdraftLimit: 12000,
        frozen: false,
        availableCredits: 137867,
        expiringCreditsTotal: 115867,
        nearestExpiringAt: null,
        lowCreditWarningThreshold: 100,
      );

      final display = BillingCreditDisplay.fromWallet(
        wallet,
        subscriptionTotal: 120000,
      );

      expect(display.totalCredits, 125867);
      expect(display.subscriptionRemaining, 115867);
      expect(display.subscriptionTotal, 120000);
      expect(display.addOnCredits, 10000);
      expect(display.activityCredits, 0);
      expect(display.subscriptionProgress, closeTo(115867 / 120000, 0.000001));
    });

    test('credit display excludes unused overdraft from the visible balance',
        () {
      const wallet = BillingWallet(
        tenantId: 1,
        balance: 19745,
        subscriptionCredits: 19745,
        addOnCredits: 0,
        activityCredits: 0,
        overdraftUsed: 0,
        overdraftLimit: 2000,
        frozen: false,
        availableCredits: 21745,
        expiringCreditsTotal: 19745,
        nearestExpiringAt: null,
        lowCreditWarningThreshold: 100,
      );

      final display = BillingCreditDisplay.fromWallet(
        wallet,
        subscriptionTotal: 20000,
      );

      expect(display.totalCredits, 19745);
      expect(display.subscriptionRemaining, 19745);
      expect(display.subscriptionProgress, closeTo(19745 / 20000, 0.000001));
    });

    test('credit display keeps negative balance while wallet is frozen', () {
      const wallet = BillingWallet(
        tenantId: 60,
        balance: -30787,
        subscriptionCredits: 0,
        addOnCredits: 0,
        activityCredits: 0,
        overdraftUsed: 30787,
        overdraftLimit: 59900,
        frozen: true,
        availableCredits: 0,
        expiringCreditsTotal: 0,
        nearestExpiringAt: null,
        lowCreditWarningThreshold: 100,
      );

      final display = BillingCreditDisplay.fromWallet(
        wallet,
        subscriptionTotal: 599000,
      );

      expect(display.totalCredits, -30787);
      expect(display.subscriptionRemaining, 0);
      expect(display.addOnCredits, 0);
      expect(display.subscriptionProgress, 0);
    });

    test('credit display preserves credited balance while recovery is pending',
        () {
      final wallet = BillingWallet.fromJson({
        'tenant_id': 60,
        'balance': 1200,
        'subscription_credits': 700,
        'add_on_credits': 400,
        'activity_credits': 100,
        'overdraft_limit': 2000,
        'frozen': true,
        'available_credits': 3200,
      });
      final display = BillingCreditDisplay.fromWallet(
        wallet,
        subscriptionTotal: 20000,
      );

      expect(display.totalCredits, 1200);
      expect(display.subscriptionRemaining, 700);
      expect(display.addOnCredits, 400);
      expect(display.activityCredits, 100);
      expect(display.subscriptionProgress, closeTo(700 / 20000, 0.000001));
    });
  });

  group('BillingCreditPack.fromJson', () {
    test('parses client snake_case contract', () {
      final pack = BillingCreditPack.fromJson({
        'id': 1,
        'name': '积分小包',
        'credits': 1000,
        'price': 9.9,
        'currency': 'CNY',
        'sort_order': 10,
        'is_active': true,
      });

      expect(pack.id, 1);
      expect(pack.name, '积分小包');
      expect(pack.credits, 1000);
      expect(pack.priceLabel, '¥9.90');
      expect(pack.sortOrder, 10);
      expect(pack.isActive, isTrue);
    });

    test('accepts legacy PascalCase backend fields', () {
      final pack = BillingCreditPack.fromJson({
        'ID': 2,
        'Name': '积分中包',
        'Credits': 5000,
        'Price': 39.9,
        'Currency': 'CNY',
        'SortOrder': 20,
        'IsActive': true,
      });

      expect(pack.id, 2);
      expect(pack.name, '积分中包');
      expect(pack.credits, 5000);
      expect(pack.priceLabel, '¥39.90');
      expect(pack.sortOrder, 20);
      expect(pack.isActive, isTrue);
    });
  });

  group('BillingEntitlement.valueLabel', () {
    test('untracked monthly credits shows limit only without /月', () {
      final ent = BillingEntitlement.fromJson({
        'id': 1,
        'tenant_id': 3,
        'feature_code': 'monthly_credits',
        'feature_name': '每月积分额度',
        'feature_type': 'metered',
        'granted_value': 20000,
        'granted_unit': '积分/月',
        'is_active': true,
      });

      expect(ent.valueLabel, '20000 积分');
    });

    test('tracked quota shows usage over limit', () {
      final ent = BillingEntitlement.fromJson({
        'id': 2,
        'tenant_id': 3,
        'feature_code': 'member_limit',
        'feature_name': '团队成员数',
        'feature_type': 'metered',
        'granted_value': 500,
        'granted_unit': '人',
        'current_usage': 19,
        'is_active': true,
      });

      expect(ent.valueLabel, '19 / 500 人');
    });

    test('explicit zero usage still shows as usage', () {
      final ent = BillingEntitlement.fromJson({
        'id': 3,
        'tenant_id': 3,
        'feature_code': 'automation_task_limit',
        'feature_name': '自动任务数量',
        'feature_type': 'metered',
        'granted_value': 100,
        'granted_unit': '个',
        'current_usage': 0,
        'is_active': true,
      });

      expect(ent.valueLabel, '0 / 100 个');
    });

    test('null granted value means unlimited', () {
      final ent = BillingEntitlement.fromJson({
        'id': 4,
        'tenant_id': 3,
        'feature_code': 'monthly_credits',
        'feature_name': '每月积分额度',
        'feature_type': 'metered',
        'granted_value': null,
        'is_active': true,
      });

      expect(ent.valueLabel, '无限制');
    });

    test('catalog storage quota without usage shows limit only', () {
      final ent = BillingEntitlement.fromJson({
        'id': 5,
        'tenant_id': 0,
        'feature_code': 'drive_file_storage_limit',
        'feature_name': '云盘文件容量',
        'feature_type': 'metered',
        'granted_value': 1,
        'granted_unit': 'GB',
        'granted_value_bytes': 1073741824,
        'is_active': true,
      });

      expect(ent.valueLabel, '1 GB');
    });
  });

  group('BillingUsageAggregate.fromJson', () {
    test('parses monthly skill usage aggregate', () {
      final usage = BillingUsageAggregate.fromJson({
        'id': 9,
        'tenant_id': 3,
        'resource_type': 'skill',
        'period': 'monthly',
        'period_start': '2026-06-01T00:00:00Z',
        'skill_id': 88,
        'operation_code': 'search',
        'total_amount': 12,
        'total_credits': 120,
        'event_count': 6,
        'updated_at': '2026-06-20T12:00:00Z',
      });

      expect(usage.resourceLabel, '技能调用');
      expect(usage.totalCredits, 120);
      expect(usage.eventCount, 6);
      expect(usage.operationCode, 'search');
      expect(usage.periodStart, isNotNull);
      expect(usage.periodStart!.month, 6);
    });
  });
}
