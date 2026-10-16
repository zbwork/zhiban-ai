import 'billing_models.dart';

const _hiddenPlanCardFeatureCodes = {
  'monthly_credits',
  'realtime_communication',
};

/// 套餐权益展示文案的唯一来源：PC 端 billing_page.dart 与移动端
/// mobile_billing_page.dart 都从这里取值，避免两端各自维护一份、逐渐分叉。
List<String> planFeatureLines(BillingPlan plan) {
  if (plan.features.isNotEmpty) {
    final items = [...plan.features]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return items
        .where(
          (item) => !_hiddenPlanCardFeatureCodes.contains(item.featureCode),
        )
        .map(planFeatureLine)
        .where((v) => v.isNotEmpty)
        .take(8)
        .toList();
  }
  final creditLineRe = RegExp(r'每月\s*[\d,\.万]+\s*积分');
  final desc = plan.description;
  final lines = desc
      .split(RegExp(r'[\n;；]'))
      .map((l) => l.trim())
      .where(
        (l) => l.isNotEmpty && !creditLineRe.hasMatch(l) && l != '实时通讯功能'
      )
      .toList();
  if (lines.length > 1) return lines.take(6).toList();

  switch (plan.code.toLowerCase()) {
    case 'free':
      return [
        '团队成员：3 人',
        '自动任务：3 个',
        '自定义数字员工：1 个',
        '知识库文件：500MB',
        '云盘文件：1GB'
      ];
    case 'basic':
      return [
        '团队成员：10 人',
        '自动任务：5 个',
        '自定义数字员工：5 个',
        '知识库文件：1GB',
        '云盘文件：10GB',
        '可额外增购积分',
      ];
    case 'pro':
      return [
        '团队成员：50 人',
        '自动任务：10 个',
        '自定义数字员工：20 个',
        '知识库文件：10GB',
        '云盘文件：50GB',
        '可额外增购积分',
        '数字员工语音/视频通话',
      ];
    case 'enterprise':
      return [
        '团队成员：不限',
        '自动任务：不限',
        '专属服务支持'
      ];
    default:
      return lines;
  }
}

/// 套餐卡片底部的模型档位说明。
///
/// 这是一条套餐展示文案，不属于后端计量型权益；未知套餐不作模型承诺。
String? planAvailableModelsLine(BillingPlan plan) {
  switch (plan.code.toLowerCase()) {
    case 'free':
      return '可用模型：GPT-5.6系列等基础模型';
    case 'basic':
    case 'pro':
    case 'professional':
    case 'enterprise':
      return '可用模型：GPT-6 Astra、Claude Fable 5/5.1等高阶模型';
    default:
      return null;
  }
}

String planFeatureLine(BillingPlanFeature feature) {
  final name = feature.featureName.isNotEmpty
      ? feature.featureName
      : featureCodeLabel(feature.featureCode);
  if (feature.featureType == 'boolean') {
    return (feature.limitValue ?? 0) > 0 ? name : '';
  }
  // limit_bytes 是存储类权益的派生字段。旧版 Bus 曾给计数型权益也返回该字段，
  // 客户端必须结合 feature_code 判断，避免把「3 人」渲染成「3 B」。
  final bytes =
      isBillingStorageFeature(feature.featureCode) ? feature.limitBytes : null;
  if (bytes != null) return '$name：${formatBillingBytes(bytes)}';
  final value = feature.limitValue;
  if (value == null) return '$name：无限制';
  final unit = feature.limitUnit == null || feature.limitUnit!.isEmpty
      ? ''
      : ' ${feature.limitUnit!}';
  return '$name：$value$unit';
}

bool isBillingStorageFeature(String code) {
  switch (code) {
    case 'knowledge_file_storage_limit':
    case 'drive_file_storage_limit':
      return true;
    default:
      return false;
  }
}

/// 把套餐目录权益转换为只含「目标额度」的展示模型。
///
/// 目录权益没有当前租户用量，不能伪造成 0 用量或复用当前套餐的钱包余额。
List<BillingEntitlement> planEntitlementDetails(BillingPlan plan) {
  final features = [...plan.features]
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return [
    for (final (index, feature) in features.indexed)
      BillingEntitlement(
        id: index + 1,
        tenantId: 0,
        featureCode: feature.featureCode,
        featureName: feature.featureName,
        featureType: feature.featureType,
        grantedValue: feature.limitValue,
        grantedUnit: feature.limitUnit,
        grantedValueBytes: isBillingStorageFeature(feature.featureCode)
            ? feature.limitBytes
            : null,
        currentUsage: null,
        currentUsageBytes: null,
        isActive: true,
      ),
  ];
}

List<BillingEntitlement> billingEntitlementsForSelection({
  required BillingPlan? selectedPlan,
  required int? currentPlanId,
  required List<BillingEntitlement> currentEntitlements,
}) {
  if (selectedPlan == null || selectedPlan.id == currentPlanId) {
    return currentEntitlements;
  }
  return planEntitlementDetails(selectedPlan);
}

String featureCodeLabel(String code) {
  switch (code) {
    case 'member_limit':
      return '团队成员';
    case 'digital_employee_limit':
      return '数字员工';
    case 'automation_task_limit':
      return '自动任务';
    case 'knowledge_file_storage_limit':
      return '知识库文件';
    case 'drive_file_storage_limit':
      return '云盘文件';
    case 'digital_employee_av_call':
      return '数字员工音视频通话';
    default:
      return code;
  }
}

String formatBillingBytes(int value) {
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
