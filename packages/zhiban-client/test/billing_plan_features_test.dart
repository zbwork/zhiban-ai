import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/models/billing_models.dart';
import 'package:zhiban_client/models/billing_plan_features.dart';

void main() {
  BillingPlan plan({
    required int id,
    required String code,
    required String name,
    required List<BillingPlanFeature> features,
  }) {
    return BillingPlan(
      id: id,
      code: code,
      name: name,
      description: '',
      priceMonthly: 0,
      priceYearly: 0,
      originalPriceMonthly: null,
      currency: 'CNY',
      billingCycle: 'none',
      prices: const [],
      features: features,
      trialDays: 0,
      monthlyCredits: 0,
      sortOrder: 0,
      isActive: true,
      isRecommended: false,
    );
  }

  test('non-storage entitlements ignore legacy limit_bytes', () {
    const cases = [
      (
        BillingPlanFeature(
          featureCode: 'monthly_credits',
          featureName: '每月积分额度',
          featureType: 'metered',
          limitValue: 500,
          limitUnit: '积分/月',
          limitBytes: 500,
          sortOrder: 1,
        ),
        '每月积分额度：500 积分/月',
      ),
      (
        BillingPlanFeature(
          featureCode: 'member_limit',
          featureName: '团队成员数',
          featureType: 'metered',
          limitValue: 10,
          limitUnit: '人',
          limitBytes: 10,
          sortOrder: 2,
        ),
        '团队成员数：10 人',
      ),
      (
        BillingPlanFeature(
          featureCode: 'automation_task_limit',
          featureName: '自动任务数量',
          featureType: 'metered',
          limitValue: 5,
          limitUnit: '个',
          limitBytes: 5,
          sortOrder: 3,
        ),
        '自动任务数量：5 个',
      ),
      (
        BillingPlanFeature(
          featureCode: 'digital_employee_limit',
          featureName: '自定义数字员工数量',
          featureType: 'metered',
          limitValue: 5,
          limitUnit: '个',
          limitBytes: 5,
          sortOrder: 4,
        ),
        '自定义数字员工数量：5 个',
      ),
    ];

    for (final (feature, expected) in cases) {
      expect(planFeatureLine(feature), expected);
    }
  });

  test('storage entitlement still formats normalized bytes', () {
    const feature = BillingPlanFeature(
      featureCode: 'drive_file_storage_limit',
      featureName: '云盘文件容量',
      featureType: 'metered',
      limitValue: 1,
      limitUnit: 'GB',
      limitBytes: 1073741824,
      sortOrder: 1,
    );

    expect(planFeatureLine(feature), '云盘文件容量：1 GB');
  });

  test('plan cards hide duplicate credits and realtime communication', () {
    final target = plan(
      id: 1,
      code: 'free',
      name: '免费版',
      features: const [
        BillingPlanFeature(
          featureCode: 'monthly_credits',
          featureName: '每月积分额度',
          featureType: 'metered',
          limitValue: 14400,
          limitUnit: '积分/月',
          limitBytes: null,
          sortOrder: 1,
        ),
        BillingPlanFeature(
          featureCode: 'member_limit',
          featureName: '团队成员数',
          featureType: 'metered',
          limitValue: 3,
          limitUnit: '人',
          limitBytes: null,
          sortOrder: 2,
        ),
        BillingPlanFeature(
          featureCode: 'realtime_communication',
          featureName: '实时通讯功能',
          featureType: 'boolean',
          limitValue: 1,
          limitUnit: null,
          limitBytes: null,
          sortOrder: 3,
        ),
      ],
    );

    expect(planFeatureLines(target), ['团队成员数：3 人']);
  });

  test('package model access copy follows the documented tier mapping', () {
    expect(
      planAvailableModelsLine(
        plan(id: 1, code: 'free', name: '免费版', features: const []),
      ),
      '可用模型：GPT-5.6系列等基础模型',
    );
    for (final code in ['basic', 'pro', 'professional', 'enterprise']) {
      expect(
        planAvailableModelsLine(
          plan(id: 2, code: code, name: code, features: const []),
        ),
        '可用模型：GPT-6 Astra、Claude Fable 5/5.1等高阶模型',
      );
    }
    expect(
      planAvailableModelsLine(
        plan(id: 3, code: 'custom', name: '自定义套餐', features: const []),
      ),
      isNull,
    );
  });

  test('selected non-current plan uses catalog entitlements without usage', () {
    final selected = plan(
      id: 2,
      code: 'pro',
      name: '专业版',
      features: const [
        BillingPlanFeature(
          featureCode: 'member_limit',
          featureName: '团队成员数',
          featureType: 'metered',
          limitValue: 50,
          limitUnit: '人',
          limitBytes: 50,
          sortOrder: 1,
        ),
      ],
    );
    final current = [
      BillingEntitlement.fromJson({
        'feature_code': 'member_limit',
        'feature_name': '团队成员数',
        'feature_type': 'metered',
        'granted_value': 3,
        'granted_unit': '人',
        'current_usage': 1,
        'is_active': true,
      }),
    ];

    final details = billingEntitlementsForSelection(
      selectedPlan: selected,
      currentPlanId: 1,
      currentEntitlements: current,
    );

    expect(details.single.valueLabel, '50 人');
    expect(details.single.currentUsage, isNull);
    expect(details.single.grantedValueBytes, isNull);
  });

  test('selected current plan keeps runtime entitlements and usage', () {
    final selected = plan(id: 1, code: 'free', name: '免费版', features: const []);
    final current = [
      BillingEntitlement.fromJson({
        'feature_code': 'member_limit',
        'feature_name': '团队成员数',
        'feature_type': 'metered',
        'granted_value': 3,
        'granted_unit': '人',
        'current_usage': 1,
        'is_active': true,
      }),
    ];

    final details = billingEntitlementsForSelection(
      selectedPlan: selected,
      currentPlanId: 1,
      currentEntitlements: current,
    );

    expect(identical(details, current), isTrue);
    expect(details.single.valueLabel, '1 / 3 人');
  });
}
