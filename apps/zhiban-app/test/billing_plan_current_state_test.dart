import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/models/billing_models.dart';
import 'package:nexwork/pages/settings/billing_page.dart';

void main() {
  group('isBillingPlanCurrent', () {
    final freePlan = _plan(id: 1, code: 'free', monthlyPrice: 0);
    final basicPlan = _plan(id: 2, code: 'basic', monthlyPrice: 99);

    test('free plan stays current when the selected cycle changes', () {
      expect(
        isBillingPlanCurrent(
          plan: freePlan,
          activePlanId: freePlan.id,
          freePlanId: freePlan.id,
          currentCycle: 'monthly',
          selectedCycle: 'yearly',
        ),
        isTrue,
      );
    });

    test('paid plan is current only for its active cycle', () {
      expect(
        isBillingPlanCurrent(
          plan: basicPlan,
          activePlanId: basicPlan.id,
          freePlanId: freePlan.id,
          currentCycle: 'monthly',
          selectedCycle: 'monthly',
        ),
        isTrue,
      );
      expect(
        isBillingPlanCurrent(
          plan: basicPlan,
          activePlanId: basicPlan.id,
          freePlanId: freePlan.id,
          currentCycle: 'monthly',
          selectedCycle: 'yearly',
        ),
        isFalse,
      );
    });

    test('falls back to the free plan without an active subscription', () {
      expect(
        isBillingPlanCurrent(
          plan: freePlan,
          activePlanId: null,
          freePlanId: freePlan.id,
          currentCycle: 'monthly',
          selectedCycle: 'yearly',
        ),
        isTrue,
      );
    });
  });
}

BillingPlan _plan({
  required int id,
  required String code,
  required double monthlyPrice,
}) {
  return BillingPlan.fromJson({
    'id': id,
    'code': code,
    'name': code,
    'price_monthly': monthlyPrice,
    'price_yearly': monthlyPrice * 10,
    'currency': 'CNY',
    'billing_cycle': 'monthly',
    'prices': const [],
    'features': const [],
    'trial_days': 0,
    'monthly_credits': 0,
    'sort_order': id,
    'is_active': true,
    'is_recommended': false,
  });
}
