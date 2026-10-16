// ignore_for_file: unused_element, unused_field

import 'dart:async';
import 'dart:math';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_client/models/billing_models.dart';
import 'package:zhiban_client/models/billing_plan_features.dart';
import 'package:zhiban_client/pages/settings/widgets/billing_usage_tooltip.dart';
import 'package:zhiban_client/pages/settings/widgets/billing_credit_detail_tabs.dart';
import 'package:nexwork/pages/settings/widgets/billing_cycle_switch.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/billing_api.dart';
import 'package:zhiban_client/services/billing_refresh_notifier.dart';
import 'package:zhiban_core/utils/error_utils.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:zhiban_ui/widgets/ui_underline_tabs.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

final _billingService = BillingService();

const _billingBrandBlue = Color(0xFF155EEF);
const _billingBrandBlueStrong = Color(0xFF0B5CFF);
const _billingPageTint = Color(0xFFFBFCFF);
const _billingCardSurface = Color(0xFFFFFFFF);
const _billingSoftSurface = Color(0xFFF8FAFD);
const _billingPanelSurface = Color(0xFFF7FAFF);
const _billingInk = Color(0xFF101828);
const _billingText = Color(0xFF344054);
const _billingMuted = Color(0xFF667085);
const _billingSubtle = Color(0xFF8B95A7);
const _billingBorder = Color(0xFFE8EDF5);
const _billingSoftBorder = Color(0xFFDDE7F5);
const _billingDivider = Color(0xFFE1E7F0);
const _billingPurple = Color(0xFF7C3AED);
const _billingDefaultPaymentProvider = 'wechat';

enum _BillingTab { subscription, usage }

enum _PurchaseRecordTab { subscription, creditPack }

enum BillingInitialTab { subscription, usage }

_BillingTab _toBillingTab(BillingInitialTab tab) {
  switch (tab) {
    case BillingInitialTab.subscription:
      return _BillingTab.subscription;
    case BillingInitialTab.usage:
      return _BillingTab.usage;
  }
}

String _formatCredits(num value) {
  final s = value.round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final remaining = s.length - i;
    buf.write(s[i]);
    if (remaining > 1 && remaining % 3 == 1) buf.write(',');
  }
  return buf.toString();
}

DateTime _billingUsageMonth() {
  final now = DateTime.now();
  return DateTime(now.year, now.month);
}

String _billingUsageMonthParamFor(DateTime month) {
  return '${month.year}-${month.month.toString().padLeft(2, '0')}-01';
}

String _billingUsageMonthLabelFor(DateTime month) {
  return '${month.year}年 / ${month.month}月';
}

DateTimeRange _billingUsageMonthRange(DateTime month) {
  final start = DateTime(month.year, month.month);
  final end =
      DateTime(month.year, month.month + 1).subtract(const Duration(days: 1));
  return DateTimeRange(start: start, end: end);
}

String _billingUsageDateLabel(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

String _billingUsageMonthFromParamFor(DateTime month) =>
    _billingUsageMonthParamFor(month);

String _billingUsageMonthToParamFor(DateTime month) {
  final nextMonth = DateTime(month.year, month.month + 1);
  return '${nextMonth.year}-${nextMonth.month.toString().padLeft(2, '0')}-01';
}

const _billingUsageAggregateFetchLimit = 500;

String _billingUsageDayParam(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

String _billingUsageDayToParam(DateTime value) {
  final local = value.toLocal();
  final nextDay = DateTime(local.year, local.month, local.day + 1);
  return _billingUsageDayParam(nextDay);
}

bool _isBillingUsageInCurrentMonth(BillingUsageAggregate item) {
  final periodStart = item.periodStart;
  if (periodStart == null) return false;
  final month = _billingUsageMonth();
  final local = periodStart.toLocal();
  return local.year == month.year && local.month == month.month;
}

List<BillingUsageAggregate> _currentMonthUsageAggregates(
  List<BillingUsageAggregate> items,
) {
  return items.where(_isBillingUsageInCurrentMonth).toList();
}

List<BillingUsageAggregate> _usageBreakdownByType(
  List<BillingUsageAggregate> items,
) {
  final grouped = <String, BillingUsageAggregate>{};
  for (final item in items) {
    final key = item.resourceType;
    final existing = grouped[key];
    grouped[key] = BillingUsageAggregate(
      id: existing?.id ?? item.id,
      tenantId: existing?.tenantId ?? item.tenantId,
      resourceType: item.resourceType,
      period: 'monthly',
      periodStart: _billingUsageMonth(),
      skillId: null,
      operationCode: '',
      totalAmount: (existing?.totalAmount ?? 0) + item.totalAmount,
      totalCredits: (existing?.totalCredits ?? 0) + item.totalCredits,
      eventCount: (existing?.eventCount ?? 0) + item.eventCount,
      unknownAmountCount:
          (existing?.unknownAmountCount ?? 0) + item.unknownAmountCount,
      updatedAt: item.updatedAt ?? existing?.updatedAt,
    );
  }
  return grouped.values.toList();
}

int _compareUsageAggregateRows(
  BillingUsageAggregate a,
  BillingUsageAggregate b,
) {
  final ad = a.periodStart;
  final bd = b.periodStart;
  if (ad != null && bd != null) {
    final byDate = bd.compareTo(ad);
    if (byDate != 0) return byDate;
  } else if (ad == null && bd != null) {
    return 1;
  } else if (ad != null && bd == null) {
    return -1;
  }
  final byLabel = a.resourceLabel.compareTo(b.resourceLabel);
  if (byLabel != 0) return byLabel;
  return b.totalCredits.compareTo(a.totalCredits);
}

String _formatUsageEventTime(DateTime? value) {
  if (value == null) return '-';
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}:'
      '${local.second.toString().padLeft(2, '0')}';
}

String _billingCycleLabel(String cycle) {
  return cycle == 'yearly' ? '按年付' : '按月付';
}

String _subscriptionBillingCycle(BillingSubscription? sub) {
  final start = sub?.currentPeriodStart;
  final end = sub?.currentPeriodEnd;
  if (start == null || end == null) return 'monthly';
  final days = end.difference(start).inDays;
  if (days >= 300) return 'yearly';
  return 'monthly';
}

String _shortBillingCycleLabel(String cycle) {
  return cycle == 'yearly' ? '按年付' : '按月付';
}

int _comparePlanTier(BillingPlan? currentPlan, BillingPlan targetPlan) {
  if (currentPlan == null) return targetPlan.isFree ? 0 : 1;
  final sortCompare = targetPlan.sortOrder.compareTo(currentPlan.sortOrder);
  if (sortCompare != 0) return sortCompare;
  final creditCompare =
      targetPlan.monthlyCredits.compareTo(currentPlan.monthlyCredits);
  if (creditCompare != 0) return creditCompare;
  final priceCompare = (targetPlan.priceForCycle('monthly') ?? 0)
      .compareTo(currentPlan.priceForCycle('monthly') ?? 0);
  return priceCompare;
}

String _planChangeActionLabel({
  required BillingPlan targetPlan,
  required BillingPlan? currentPlan,
  required String currentCycle,
  required String targetCycle,
}) {
  if (currentPlan == null) return targetPlan.isFree ? '当前使用' : '开通';
  if (targetPlan.isFree) return currentPlan.isFree ? '当前使用' : '';
  if (currentCycle == 'yearly' && targetCycle == 'monthly') return '';
  if (targetPlan.id == currentPlan.id) {
    if (targetCycle == currentCycle) return '当前使用';
    if (currentCycle == 'monthly' && targetCycle == 'yearly') {
      return '升级为${targetPlan.name}${_shortBillingCycleLabel(targetCycle)}';
    }
    return '';
  }

  if (currentPlan.isFree || _comparePlanTier(currentPlan, targetPlan) > 0) {
    return '升级为${targetPlan.name}${_shortBillingCycleLabel(targetCycle)}';
  }
  return '';
}

bool _isPaidPlanUpgrade({
  required BillingPlan? currentPlan,
  required BillingPlan targetPlan,
  required String currentCycle,
  required String targetCycle,
}) {
  if (currentPlan == null || targetPlan.isFree) return false;
  if (_comparePlanTier(currentPlan, targetPlan) > 0) return true;
  return currentPlan.id == targetPlan.id &&
      currentCycle == 'monthly' &&
      targetCycle == 'yearly';
}

@visibleForTesting
bool isBillingPlanCurrent({
  required BillingPlan plan,
  required int? activePlanId,
  required int? freePlanId,
  required String currentCycle,
  required String selectedCycle,
}) {
  if (activePlanId == null) return freePlanId == plan.id;
  if (activePlanId != plan.id) return false;
  return plan.isFree || selectedCycle == currentCycle;
}

Future<bool> _confirmPlanChangeDialog(
  BuildContext context, {
  required BillingPlan? currentPlan,
  required BillingPlan targetPlan,
  required String currentCycle,
  required String targetCycle,
  required String actionLabel,
  required DateTime? effectiveAt,
}) async {
  final currentName = currentPlan?.name ?? '免费版';
  final targetName = targetPlan.name;
  final currentCycleLabel = currentPlan == null || currentPlan.isFree
      ? '当前套餐'
      : _billingCycleLabel(currentCycle);
  final targetCycleLabel =
      targetPlan.isFree ? '免费套餐' : _billingCycleLabel(targetCycle);
  final currentPriceLabel = currentPlan == null || currentPlan.isFree
      ? null
      : currentPlan.priceLabelForCycle(currentCycle);
  final targetPriceLabel =
      targetPlan.isFree ? null : targetPlan.priceLabelForCycle(targetCycle);
  final isSubscribe = actionLabel == '开通';
  final title = isSubscribe ? '开通套餐' : '升级套餐';
  final confirmText = isSubscribe ? '确认开通' : '确认升级';
  final messagePrefix = targetPlan.isFree ? '确认后 ' : '确认后进入支付，支付完成后 ';
  final messageHighlight = targetName;
  final messageSuffix = targetPlan.isFree ? ' 将立即生效。' : ' 将立即生效。';
  final detailPrefix = '【$targetName-$targetCycleLabel】价格 ';
  final detailSuffix =
      targetPlan.isFree ? '，确认后立即生效，可后续升级套餐。' : '，支付完成后立即生效，补差价以订单为准。';

  final ok = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    builder: (ctx) => UiContentDialog(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 26, 32, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UiSheetHeader(
              title: title,
              onClose: () => Navigator.of(ctx).pop(false),
            ),
            const SizedBox(height: 16),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: RichText(
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 13.5,
                    height: 1.5,
                    fontWeight: FontWeight.w600,
                    color: _billingMuted,
                  ),
                  children: [
                    TextSpan(text: messagePrefix),
                    TextSpan(
                      text: messageHighlight,
                      style: const TextStyle(
                        color: _billingBrandBlue,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    TextSpan(text: messageSuffix),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _PlanChangeSummaryCard(
                    title: '原套餐',
                    name: currentName,
                    cycle: currentCycleLabel,
                    priceLabel: currentPriceLabel,
                    muted: true,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFF2C7DFF),
                          Color(0xFF0458F7),
                        ],
                      ),
                    ),
                    child: const Icon(
                      CupertinoIcons.arrow_right,
                      color: Colors.white,
                      size: 21,
                    ),
                  ),
                ),
                Expanded(
                  child: _PlanChangeSummaryCard(
                    title: isSubscribe ? '开通为' : '升级为',
                    name: targetName,
                    cycle: targetCycleLabel,
                    priceLabel: targetPriceLabel,
                    muted: false,
                  ),
                ),
              ],
            ),
            if (targetPriceLabel != null) ...[
              const SizedBox(height: 14),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: RichText(
                  maxLines: 1,
                  softWrap: false,
                  textAlign: TextAlign.center,
                  text: TextSpan(
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: _billingMuted,
                    ),
                    children: [
                      TextSpan(text: detailPrefix),
                      TextSpan(
                        text: targetPriceLabel,
                        style: const TextStyle(
                          color: _billingBrandBlue,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      TextSpan(text: detailSuffix),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _billingBrandBlue,
                      side: const BorderSide(
                        color: _billingBrandBlue,
                        width: 1.2,
                      ),
                      minimumSize: const Size.fromHeight(46),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: _billingBrandBlueStrong,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(46),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(confirmText),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return ok == true;
}

bool _canBuyCreditPack(
  List<BillingEntitlement> entitlements,
  List<BillingCreditPack> packs,
) {
  if (packs.isEmpty) return false;
  for (final item in entitlements) {
    if (item.featureCode == 'can_buy_credit_pack') {
      return (item.grantedValue ?? 0) > 0;
    }
  }
  return false;
}

class _PlanChangeSummaryCard extends StatelessWidget {
  const _PlanChangeSummaryCard({
    required this.title,
    required this.name,
    required this.cycle,
    required this.priceLabel,
    required this.muted,
  });

  final String title;
  final String name;
  final String cycle;
  final String? priceLabel;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 116),
      padding: const EdgeInsets.fromLTRB(20, 16, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: muted ? const Color(0xFFE3E8F1) : const Color(0xFFB7D0FF),
          width: muted ? 1.0 : 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF667085),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 20,
              height: 1.15,
              fontWeight: FontWeight.w800,
              color: _billingInk,
            ),
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: RichText(
              maxLines: 1,
              softWrap: false,
              text: TextSpan(
                children: [
                  TextSpan(
                    text: cycle,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _billingMuted,
                    ),
                  ),
                  if (priceLabel != null) ...[
                    const TextSpan(text: '  '),
                    TextSpan(
                      text: priceLabel!,
                      style: const TextStyle(
                        fontSize: 17,
                        height: 1,
                        fontWeight: FontWeight.w900,
                        color: _billingBrandBlue,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BillingOverviewPage extends ConsumerStatefulWidget {
  const BillingOverviewPage({super.key});

  @override
  ConsumerState<BillingOverviewPage> createState() =>
      _BillingOverviewPageState();
}

class _BillingOverviewPageState extends ConsumerState<BillingOverviewPage> {
  BillingWallet? _wallet;
  BillingSubscription? _subscription;
  List<BillingEntitlement> _entitlements = [];
  List<BillingCreditPack> _packs = [];
  List<BillingPlan> _plans = [];
  List<BillingPaymentOrder> _orders = [];
  List<BillingUsageAggregate> _usage = [];
  _BillingTab _tab = _BillingTab.subscription;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _billingService.getMyWallet(),
        _billingService.getMySubscription(),
        _billingService.getMyEntitlements(),
        _billingService.listCreditPacks(),
        _billingService.listPlans(),
        _billingService.listOrders(limit: 50),
        _billingService.listUsageAggregates(
          period: 'daily',
          limit: _billingUsageAggregateFetchLimit,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _wallet = results[0] as BillingWallet;
        _subscription = results[1] as BillingSubscription?;
        _entitlements = results[2] as List<BillingEntitlement>;
        _packs = results[3] as List<BillingCreditPack>;
        _plans = results[4] as List<BillingPlan>;
        _orders = results[5] as List<BillingPaymentOrder>;
        _usage = _currentMonthUsageAggregates(
          results[6] as List<BillingUsageAggregate>,
        );
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      BotToast.showText(text: '加载失败：$e');
    }
  }

  String _planActionLabel(BillingPlan plan) {
    if (_isPendingPlanChange(plan)) {
      return '已设置到期后变更';
    }
    final label = _planChangeActionLabel(
      targetPlan: plan,
      currentPlan: _currentPlan(),
      currentCycle: _subscriptionBillingCycle(_subscription),
      targetCycle: plan.billingCycle,
    );
    return label == '当前使用' ? '当前套餐' : label;
  }

  BillingPlan? _nextUpgradePlan() {
    final currentPlan = _currentPlan();
    final candidates =
        _plans.where((plan) => !plan.isFree && !_isCurrentPlan(plan)).toList()
          ..sort((a, b) {
            final sortCompare = a.sortOrder.compareTo(b.sortOrder);
            if (sortCompare != 0) return sortCompare;
            final creditCompare = a.monthlyCredits.compareTo(b.monthlyCredits);
            if (creditCompare != 0) return creditCompare;
            return (a.priceForCycle('monthly') ?? 0)
                .compareTo(b.priceForCycle('monthly') ?? 0);
          });

    for (final plan in candidates) {
      if (_comparePlanTier(currentPlan, plan) > 0) {
        return plan;
      }
    }
    return null;
  }

  Future<void> _handlePlanTap(BillingPlan plan) async {
    final sub = _subscription;
    if (_isCurrentPlan(plan)) {
      BotToast.showText(text: '当前已在使用此套餐');
      return;
    }
    if (sub == null || !sub.isActive) {
      return _subscribeToPlan(plan);
    }
    return _changePlan(plan);
  }

  Future<void> _reloadAfterBillingChange() async {
    notifyBillingSummaryChanged();
    await _loadAll();
  }

  Future<void> _subscribeToPlan(BillingPlan plan) async {
    try {
      final confirmed = await _confirmPlanChangeDialog(
        context,
        currentPlan: _currentPlan(),
        targetPlan: plan,
        currentCycle: _subscriptionBillingCycle(_subscription),
        targetCycle: plan.billingCycle,
        actionLabel: '开通',
        effectiveAt: null,
      );
      if (!mounted || !confirmed) return;
      final provider = plan.isFree ? '' : _billingDefaultPaymentProvider;
      final closeLoading = BotToast.showLoading();
      late final BillingPaymentOrder order;
      try {
        order = await _billingService.subscribe(
          planId: plan.id,
          provider: provider,
          billingCycle: plan.billingCycle,
        );
      } finally {
        closeLoading();
      }
      if (!mounted) return;
      if (order.fulfilled) {
        BotToast.showText(text: '订阅成功');
        unawaited(_reloadAfterBillingChange());
      } else if (order.isPending || order.isPaid) {
        _showPaymentPolling(order);
      }
    } catch (e) {
      if (!mounted) return;
      BotToast.showText(text: '订阅失败：$e');
    }
  }

  Future<void> _changePlan(BillingPlan plan) async {
    final action = _planActionLabel(plan);
    final isUpgrade = _isPaidPlanUpgrade(
      currentPlan: _currentPlan(),
      targetPlan: plan,
      currentCycle: _subscriptionBillingCycle(_subscription),
      targetCycle: plan.billingCycle,
    );
    if (action.isEmpty) return;
    try {
      final confirmed = await _confirmPlanChangeDialog(
        context,
        currentPlan: _currentPlan(),
        targetPlan: plan,
        currentCycle: _subscriptionBillingCycle(_subscription),
        targetCycle: plan.billingCycle,
        actionLabel: action,
        effectiveAt: null,
      );
      if (!mounted || !confirmed) return;
      final provider = isUpgrade ? _billingDefaultPaymentProvider : '';
      final closeLoading = BotToast.showLoading();
      late final ChangePlanResult result;
      try {
        result = await _billingService.changePlan(
          newPlanId: plan.id,
          provider: provider,
          billingCycle: plan.billingCycle,
        );
      } finally {
        closeLoading();
      }
      if (!mounted) return;
      switch (result.action) {
        case ChangePlanAction.upgrade:
          if (result.order != null) {
            if (result.order!.fulfilled) {
              BotToast.showText(text: '升级成功');
              unawaited(_reloadAfterBillingChange());
            } else if (result.order!.isPending || result.order!.isPaid) {
              _showPaymentPolling(result.order!);
            }
          } else {
            BotToast.showText(text: '升级成功');
            unawaited(_reloadAfterBillingChange());
          }
          break;
        case ChangePlanAction.scheduled:
        case ChangePlanAction.downgrade:
          BotToast.showText(text: '当前暂不支持该套餐变更');
          unawaited(_reloadAfterBillingChange());
          break;
        case ChangePlanAction.unknown:
          BotToast.showText(text: '操作完成');
          unawaited(_reloadAfterBillingChange());
          break;
      }
    } catch (e) {
      if (!mounted) return;
      BotToast.showText(text: '操作失败：$e');
    }
  }

  Future<void> _buyCreditPack(
    BillingCreditPack pack, {
    bool skipConfirm = false,
  }) async {
    if (!skipConfirm) {
      final confirmed = await showUiConfirmDialog(
        context,
        title: '购买积分包',
        description:
            '确认购买 ${pack.name}（${pack.priceLabel}，${pack.credits} 积分）？',
        confirmLabel: '确认',
      );
      if (confirmed != true || !mounted) return;
    }

    try {
      final closeLoading = BotToast.showLoading();
      late final BillingPaymentOrder order;
      try {
        order = await _billingService.buyCreditPack(
          packId: pack.id,
          provider: _billingDefaultPaymentProvider,
        );
      } finally {
        closeLoading();
      }
      if (!mounted) return;
      if (order.fulfilled) {
        BotToast.showText(text: '购买成功');
        unawaited(_reloadAfterBillingChange());
      } else if (order.isPending || order.isPaid) {
        _showPaymentPolling(order);
      }
    } catch (e) {
      if (!mounted) return;
      BotToast.showText(text: '购买失败：$e');
    }
  }

  void _showPaymentPolling(BillingPaymentOrder order) {
    showCupertinoDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PaymentPollingDialog(
        order: order,
        onDone: () {
          Navigator.of(ctx).pop();
          unawaited(_reloadAfterBillingChange());
        },
      ),
    );
  }

  void _showPurchaseRecordsDrawer() {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭购买记录',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        final size = MediaQuery.sizeOf(ctx);
        final drawerWidth = min(size.width * 0.72, 760.0);
        return Align(
          alignment: Alignment.centerRight,
          child: _PurchaseRecordsDrawer(
            width: drawerWidth,
            orders: _orders,
            plans: _plans,
            onClose: () => Navigator.of(ctx).pop(),
          ),
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  void _showCreditDetailDrawer() {
    final wallet = _wallet;
    final currentPlan = _currentPlan();
    final credits = BillingCreditDisplay.fromWallet(
      wallet,
      subscriptionTotal: currentPlan?.monthlyCredits ?? 0,
    );
    final subscriptionCredits = credits.subscriptionTotal;
    final totalCredits = credits.totalCredits;
    final addOnCredits = credits.addOnCredits;
    final subscriptionRemaining = credits.subscriptionRemaining;
    final subscriptionProgress = credits.subscriptionProgress;

    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭积分明细',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        final size = MediaQuery.sizeOf(ctx);
        final drawerWidth = min(size.width * 0.68, 700.0);
        return Align(
          alignment: Alignment.centerRight,
          child: _CreditDetailDrawer(
            width: drawerWidth,
            totalCredits: totalCredits,
            subscriptionRemaining: subscriptionRemaining,
            subscriptionTotal: subscriptionCredits,
            subscriptionProgress: subscriptionProgress,
            addOnCredits: addOnCredits,
            activeCredits: wallet?.activityCredits ?? 0,
            planName: currentPlan?.name ?? '免费版',
            planSubtitle: currentPlan?.isFree == true ? '默认免费套餐' : '可选择套餐开通',
            canBuyCredits: _canBuyCreditPack(_entitlements, _packs),
            onBuyCredits: _packs.isEmpty ? null : _showCreditPackDrawer,
            onClose: () => Navigator.of(ctx).pop(),
          ),
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  void _showEntitlementDrawer() {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭权益明细',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        final size = MediaQuery.sizeOf(ctx);
        final drawerWidth = min(size.width * 0.68, 700.0);
        return Align(
          alignment: Alignment.centerRight,
          child: _EntitlementDetailDrawer(
            width: drawerWidth,
            entitlements: _entitlements,
            walletBalance: _wallet?.balance,
            onClose: () => Navigator.of(ctx).pop(),
          ),
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  void _showCreditPackDrawer() {
    if (_packs.isEmpty) return;
    final wallet = _wallet;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭增购积分',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        final size = MediaQuery.sizeOf(ctx);
        final drawerWidth = min(size.width * 0.68, 700.0);
        return Align(
          alignment: Alignment.centerRight,
          child: _CreditPackDrawer(
            width: drawerWidth,
            packs: _packs,
            totalCredits: wallet?.balance ?? 0,
            planName: _subscription?.planName ?? _currentPlan()?.name ?? '免费版',
            periodEnd: _subscription?.currentPeriodEnd,
            onClose: () => Navigator.of(ctx).pop(),
            onBuy: (pack) {
              Navigator.of(ctx).pop();
              _buyCreditPack(pack, skipConfirm: true);
            },
          ),
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      body: SafeArea(
        child: const _BillingDialogContent(
          initialTab: _BillingTab.subscription,
        ),
      ),
    );
  }

  Widget _buildTabs() {
    return UiUnderlineTabs<_BillingTab>(
      tabs: const [
        UiUnderlineTab(value: _BillingTab.subscription, label: '订阅管理'),
        UiUnderlineTab(value: _BillingTab.usage, label: '积分消耗'),
      ],
      current: _tab,
      horizontalPadding: 0,
      topPadding: 0,
      spacing: 22,
      onChanged: (value) => setState(() => _tab = value),
    );
  }

  Widget _buildSubscriptionTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCurrentPlanSummary(),
        if (_plans.isNotEmpty) ...[
          const SizedBox(height: 18),
          _buildPlansSection(),
        ],
        if (_orders.isNotEmpty) ...[
          const SizedBox(height: 18),
          _buildOrderPreview(),
        ],
      ],
    );
  }

  Widget _buildCurrentPlanSummary() {
    final wallet = _wallet;
    final sub = _subscription;
    final currentPlan = _currentPlan();
    final planName = sub != null && sub.planName.isNotEmpty
        ? sub.planName
        : (currentPlan?.name ?? '免费版');
    final credits = BillingCreditDisplay.fromWallet(
      wallet,
      subscriptionTotal: currentPlan?.monthlyCredits ?? 0,
    );
    final subscriptionCredits = credits.subscriptionTotal;
    final totalCredits = credits.totalCredits;
    final addOnCredits = credits.addOnCredits;
    final subscriptionRemaining = credits.subscriptionRemaining;
    final subscriptionProgress = credits.subscriptionProgress;
    final canBuyCredits = _canBuyCreditPack(_entitlements, _packs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '当前套餐',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: Color(0xFF101828),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            color: const Color(0xFFFAFAF7),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFEDEFF3)),
          ),
          child: Row(
            children: [
              _CurrentPlanVisual(
                planName: planName,
                subtitle: _currentPlanSubtitle(sub, currentPlan),
                isFree: currentPlan?.isFree ?? true,
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text(
                                '总积分',
                                style: TextStyle(
                                  fontSize: 18,
                                  height: 1,
                                  color: Color(0xFF344054),
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _formatNumber(totalCredits),
                                style: const TextStyle(
                                  fontSize: 18,
                                  height: 1,
                                  color: Color(0xFF101828),
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          height: 40,
                          child: OutlinedButton(
                            onPressed: _showCreditDetailDrawer,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF344054),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              textStyle: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                              side: const BorderSide(color: Color(0xFFD0D5DD)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text('积分明细'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 40,
                          child: OutlinedButton(
                            onPressed: _showEntitlementDrawer,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF344054),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              textStyle: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                              side: const BorderSide(color: Color(0xFFD0D5DD)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text('权益明细'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 40,
                          child: FilledButton(
                            onPressed: () {
                              final target = _nextUpgradePlan();
                              if (target == null) {
                                BotToast.showText(text: '暂无可升级套餐');
                                return;
                              }
                              _handlePlanTap(target);
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF111827),
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              textStyle: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text('升级套餐'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: _SubscriptionCreditColumn(
                            remaining: _formatNumber(subscriptionRemaining),
                            total: _formatNumber(subscriptionCredits),
                            progress: subscriptionProgress,
                          ),
                        ),
                        const _VerticalSplit(),
                        Expanded(
                          child: _AddOnCreditColumn(
                            value: _formatNumber(addOnCredits),
                            canBuy: canBuyCredits,
                            onBuy: _showCreditPackDrawer,
                          ),
                        ),
                        const _VerticalSplit(),
                        Expanded(
                          child: _CreditColumn(
                            label: '活动积分',
                            value: _formatNumber(wallet?.activityCredits ?? 0),
                            helper: '',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlansSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            '可用套餐',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0xFF101828),
            ),
          ),
        ),
        ..._plans.map((plan) {
          final actionLabel = _planActionLabel(plan);
          final isCurrent = actionLabel == '当前套餐';
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _Card(
              onTap: () => _handlePlanTap(plan),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                plan.name,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF101828),
                                ),
                              ),
                            ),
                            if (isCurrent) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFECFDF5),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text(
                                  '当前',
                                  style: TextStyle(
                                      fontSize: 11, color: Color(0xFF059669)),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (plan.description.isNotEmpty ||
                            plan.monthlyCredits > 0) ...[
                          const SizedBox(height: 4),
                          Text(
                            [
                              if (plan.description.isNotEmpty) plan.description,
                              if (plan.monthlyCredits > 0)
                                '每月 ${plan.monthlyCredits} 积分',
                            ].join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xFF667085)),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (!isCurrent && actionLabel.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2563EB),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        actionLabel == '开通' ? plan.priceLabel : actionLabel,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildOrderPreview() {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '购买记录',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF101828),
            ),
          ),
          const SizedBox(height: 12),
          ..._orders.take(5).map((order) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF4FF),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        CupertinoIcons.doc_text,
                        size: 17,
                        color: Color(0xFF2563EB),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            order.orderTypeLabel,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF101828),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              order.statusLabel,
                              if (order.createdAt != null)
                                _formatDate(order.createdAt!),
                            ].join(' · '),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF667085),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '¥${order.amountYuan}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF101828),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildUsageTab() {
    final total = _usage.fold<int>(
      0,
      (sum, item) => sum + item.totalCredits,
    );
    final breakdown = _usageBreakdownByType(_usage)
      ..sort((a, b) => b.totalCredits.compareTo(a.totalCredits));
    final sorted = [..._usage]..sort(_compareUsageAggregateRows);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '本月用量汇总',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF101828),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _formatNumber(total),
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF101828),
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                '积分',
                style: TextStyle(fontSize: 13, color: Color(0xFF667085)),
              ),
              if (sorted.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: breakdown
                      .take(3)
                      .map((item) => _SmallStat(
                            label: item.resourceLabel,
                            value: _formatNumber(item.totalCredits),
                          ))
                      .toList(),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Padding(
          padding: EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            '全部用量',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF101828),
            ),
          ),
        ),
        if (sorted.isEmpty)
          const _EmptyBillingState(
            title: '暂无积分消耗',
            subtitle: '使用技能、LLM 对话或数据查询后，消耗会在这里展示。',
          )
        else
          _Card(
            child: Column(
              children: [
                for (var i = 0; i < sorted.length; i++) ...[
                  _UsageRow(item: sorted[i], formatDate: _formatDate),
                  if (i != sorted.length - 1)
                    const Divider(height: 18, color: Color(0xFFE5E7EB)),
                ],
              ],
            ),
          ),
        const SizedBox(height: 12),
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => context.push(RoutePaths.usageConsumption),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              child: Row(
                children: [
                  Text(
                    '查看消耗明细',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF2563EB),
                    ),
                  ),
                  Spacer(),
                  Icon(CupertinoIcons.chevron_right,
                      size: 16, color: Color(0xFF2563EB)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  BillingPlan? _currentPlan() {
    final sub = _subscription;
    if (sub == null || !sub.isActive) return _freePlan();
    for (final plan in _plans) {
      if (plan.id == sub.planId) return plan;
    }
    return _freePlan();
  }

  BillingPlan? _freePlan() {
    for (final p in _plans) {
      if (p.isFree) return p;
    }
    return null;
  }

  bool _isCurrentPlan(BillingPlan plan) {
    final sub = _subscription;
    return isBillingPlanCurrent(
      plan: plan,
      activePlanId: sub != null && sub.isActive ? sub.planId : null,
      freePlanId: _freePlan()?.id,
      currentCycle: _subscriptionBillingCycle(sub),
      selectedCycle: plan.billingCycle,
    );
  }

  bool _isPendingPlanChange(BillingPlan plan) {
    return false;
  }

  String _currentPlanSubtitle(BillingSubscription? sub, BillingPlan? plan) {
    if (sub != null && sub.currentPeriodEnd != null) {
      return '有效期至 ${_formatDate(sub.currentPeriodEnd!)}';
    }
    if (plan != null && plan.isFree) return '默认免费套餐';
    return sub?.statusLabel ?? '可选择套餐开通';
  }

  BillingPlan? _pendingPlan() {
    final pendingID = _subscription?.pendingPlanId;
    if (pendingID == null) return null;
    for (final plan in _plans) {
      if (plan.id == pendingID) return plan;
    }
    return null;
  }

  String _pendingEffectiveDateLabel() {
    final effectiveAt =
        _subscription?.pendingEffectiveAt ?? _subscription?.currentPeriodEnd;
    if (effectiveAt == null) return '当前套餐到期后';
    return _formatDate(effectiveAt);
  }

  String _formatNumber(num value) {
    final s = value.round().toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final remaining = s.length - i;
      buf.write(s[i]);
      if (remaining > 1 && remaining % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }

  String _formatDate(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.child,
    this.onTap,
  });

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _billingSoftBorder),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF155EEF).withValues(alpha: 0.035),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
    if (onTap == null) return card;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: card,
    );
  }
}

class _EntitlementDetailDrawer extends StatelessWidget {
  const _EntitlementDetailDrawer({
    required this.width,
    required this.entitlements,
    required this.onClose,
    this.walletBalance,
  });

  final double width;
  final List<BillingEntitlement> entitlements;
  final VoidCallback onClose;

  /// 钱包当前剩余积分。权益接口不返回积分用量(积分走钱包体系),
  /// 「每月积分额度」行用它展示剩余额度;null 时退回只展示上限。
  final int? walletBalance;

  @override
  Widget build(BuildContext context) {
    final metered = entitlements
        .where((e) => e.featureType != 'boolean')
        .toList()
      ..sort((a, b) =>
          _entitlementMeta(a).order.compareTo(_entitlementMeta(b).order));
    final booleans = entitlements
        .where((e) => e.featureType == 'boolean')
        .toList()
      ..sort((a, b) =>
          _entitlementMeta(a).order.compareTo(_entitlementMeta(b).order));
    final empty = metered.isEmpty && booleans.isEmpty;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: width,
        height: double.infinity,
        decoration: const BoxDecoration(
          color: _billingSoftSurface,
          borderRadius: BorderRadius.horizontal(left: Radius.circular(12)),
          boxShadow: [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 24,
              offset: Offset(-8, 0),
            ),
          ],
        ),
        child: SafeArea(
          left: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 18, 14),
                child: UiSheetHeader(
                  title: '权益明细',
                  subtitle: '查看当前套餐可用权益与配额',
                  onClose: onClose,
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (empty)
                        _sectionCard(const [
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(
                                '暂无权益数据',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: _billingMuted,
                                ),
                              ),
                            ),
                          ),
                        ]),
                      if (metered.isNotEmpty) ...[
                        _sectionTitle('容量与配额'),
                        const SizedBox(height: 12),
                        _sectionCard([
                          for (final e in metered) _meteredRow(e),
                        ]),
                      ],
                      if (booleans.isNotEmpty) ...[
                        if (metered.isNotEmpty) const SizedBox(height: 24),
                        _sectionTitle('已开通功能'),
                        const SizedBox(height: 12),
                        _sectionCard([
                          for (final e in booleans) _booleanRow(e),
                        ]),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: _billingInk,
      ),
    );
  }

  Widget _sectionCard(List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(
          const Divider(height: 1, thickness: 1, color: _billingDivider),
        );
      }
      children.add(rows[i]);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _billingSoftBorder),
        boxShadow: [
          BoxShadow(
            color: _billingBrandBlue.withValues(alpha: 0.035),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }

  Widget _iconTile(IconData icon) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFEEF4FF),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 20, color: _billingBrandBlue),
    );
  }

  Widget _meteredRow(BillingEntitlement e) {
    final meta = _entitlementMeta(e);
    final granted = e.grantedValue ?? 0;
    // 积分行:余额超出月度额度的部分属于加油包,clamp 后只算订阅内剩余
    final isCreditsWithWallet = e.featureCode == 'monthly_credits' &&
        walletBalance != null &&
        granted > 0;
    final creditsRemaining =
        isCreditsWithWallet ? (walletBalance ?? 0).clamp(0, granted) : 0;
    // 积分行进度是「剩余」占比(与积分明细抽屉一致),其余行是「已用」占比
    final progress = isCreditsWithWallet
        ? creditsRemaining / granted
        : _entitlementProgress(e);
    // over/near 预警只对「已用」语义的行生效
    final over = !isCreditsWithWallet && progress != null && progress >= 1;
    final near = !isCreditsWithWallet &&
        progress != null &&
        progress >= 0.8 &&
        progress < 1;
    final desc = over
        ? '超出当前套餐，新增会被拦截'
        : near
            ? '已接近当前套餐上限'
            : isCreditsWithWallet
                ? '当前剩余 / 每月积分上限'
                : meta.description;
    final valueText = isCreditsWithWallet
        ? '${_formatCredits(creditsRemaining)} / ${_formatCredits(granted)} 积分'
        : e.valueLabel;
    final descColor = over
        ? const Color(0xFFD92D20)
        : near
            ? const Color(0xFFDC6803)
            : _billingMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          _iconTile(meta.icon),
          const SizedBox(width: 12),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.displayLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _billingInk,
                  ),
                ),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    desc,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: descColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  valueText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: _billingInk,
                  ),
                ),
                if (progress != null) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      minHeight: 6,
                      value: progress.clamp(0.0, 1.0),
                      backgroundColor: _billingBorder,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        _billingBrandBlue,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _booleanRow(BillingEntitlement e) {
    final meta = _entitlementMeta(e);
    final on = (e.grantedValue ?? 0) > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          _iconTile(meta.icon),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              e.displayLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: _billingInk,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                on ? '已开通' : '未开通',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: on ? const Color(0xFF12B76A) : _billingMuted,
                ),
              ),
              const SizedBox(width: 5),
              Icon(
                on
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.circle,
                size: 18,
                color: on ? const Color(0xFF12B76A) : _billingSubtle,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EntitlementMeta {
  const _EntitlementMeta(this.icon, this.description, this.order);

  final IconData icon;
  final String description;
  final int order;
}

_EntitlementMeta _entitlementMeta(BillingEntitlement e) {
  switch (e.featureCode) {
    case 'drive_file_storage_limit':
      return const _EntitlementMeta(CupertinoIcons.cloud, '在线上传与管理文件的存储空间', 0);
    case 'member_limit':
      return const _EntitlementMeta(CupertinoIcons.person_2, '团队内可添加的成员数量', 1);
    case 'monthly_credits':
      return const _EntitlementMeta(CupertinoIcons.star, '每月可使用的积分上限', 2);
    case 'knowledge_file_storage_limit':
      return const _EntitlementMeta(CupertinoIcons.book, '知识库中文件的存储空间', 3);
    case 'digital_employee_limit':
      return const _EntitlementMeta(CupertinoIcons.person, '可创建的数字员工数量', 4);
    case 'automation_task_limit':
      return const _EntitlementMeta(
          CupertinoIcons.list_bullet, '可创建的自动任务数量', 5);
    case 'av_call_minutes_monthly':
      return const _EntitlementMeta(CupertinoIcons.phone, '每月音视频通话可用时长', 6);
    case 'premium_data_skills':
      return const _EntitlementMeta(CupertinoIcons.cube, '增值数据源与 API 技能', 7);
    case 'usage_report_level':
      return const _EntitlementMeta(CupertinoIcons.chart_bar, '用量统计报表能力', 8);
    case 'can_buy_credit_pack':
      return const _EntitlementMeta(CupertinoIcons.creditcard, '支持额外购买积分包', 20);
    case 'digital_employee_av_call':
      return const _EntitlementMeta(CupertinoIcons.videocam, '数字员工音视频通话功能', 22);
    default:
      if (e.featureName.contains('通讯')) {
        return const _EntitlementMeta(
            CupertinoIcons.chat_bubble_2, '实时消息通讯功能', 21);
      }
      return _EntitlementMeta(
        e.featureType == 'boolean'
            ? CupertinoIcons.checkmark_seal
            : CupertinoIcons.square_grid_2x2,
        '',
        99,
      );
  }
}

double? _entitlementProgress(BillingEntitlement entitlement) {
  if (entitlement.featureType == 'boolean') return null;
  final limit = entitlement.grantedValueBytes ?? entitlement.grantedValue;
  final used = entitlement.currentUsageBytes ?? entitlement.currentUsage;
  if (limit == null || limit <= 0 || used == null) return null;
  return used / limit;
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.helper,
  });

  final String label;
  final String value;
  final String helper;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 13),
      decoration: BoxDecoration(
        color: _billingPanelSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD7E4F5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF475467),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 26,
              height: 1.05,
              fontWeight: FontWeight.w800,
              color: Color(0xFF101828),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            helper,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF667085),
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallStat extends StatelessWidget {
  const _SmallStat({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 120),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF667085),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Color(0xFF101828),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyBillingState extends StatelessWidget {
  const _EmptyBillingState({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFFF2F4F7),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                CupertinoIcons.chart_bar,
                size: 20,
                color: Color(0xFF98A2B3),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Color(0xFF101828),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFF667085)),
            ),
          ],
        ),
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.item,
    required this.formatDate,
  });

  final BillingUsageAggregate item;
  final String Function(DateTime d) formatDate;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFFFFF7ED),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            CupertinoIcons.minus,
            size: 18,
            color: Color(0xFFF97316),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.resourceLabel,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF101828),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                [
                  '${item.eventCount} 次',
                  if (item.periodStart != null) formatDate(item.periodStart!),
                ].join(' · '),
                style: const TextStyle(fontSize: 12, color: Color(0xFF667085)),
              ),
            ],
          ),
        ),
        Text(
          '${billingCreditSign(item.totalCredits)}${item.totalCredits.abs()}',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: Color(0xFFF97316),
          ),
        ),
      ],
    );
  }
}

class _UsageBreakdownRow extends StatelessWidget {
  const _UsageBreakdownRow({
    required this.label,
    required this.credits,
    required this.percent,
    required this.color,
  });

  final String label;
  final int credits;
  final String percent;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF344054),
              ),
            ),
          ),
          Text(
            _formatCredits(credits),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Color(0xFF101828),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 38,
            child: Text(
              percent,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13, color: Color(0xFF667085)),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: const Color(0xFFFBFCFF),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _billingSoftBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF344054),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                CupertinoIcons.chevron_down,
                size: 12,
                color: Color(0xFF667085),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UsageTableHeader extends StatelessWidget {
  const _UsageTableHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
      child: const Column(
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text('时间', style: _tableHeaderStyle),
                ),
                Expanded(
                  flex: 2,
                  child: Text('类型', style: _tableHeaderStyle),
                ),
                Expanded(
                  flex: 2,
                  child: Text('消耗积分', style: _tableHeaderStyle),
                ),
                Expanded(
                  flex: 3,
                  child: Text('详情', style: _tableHeaderStyle),
                ),
                SizedBox(width: 20),
              ],
            ),
          ),
          Divider(height: 1, color: Color(0xFFE1E7F0)),
        ],
      ),
    );
  }
}

const _tableHeaderStyle = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w800,
  color: Color(0xFF475467),
);

class _UsageTableRow extends StatelessWidget {
  const _UsageTableRow({
    required this.item,
    required this.formatDate,
    required this.expanded,
    required this.loading,
    required this.onTap,
  });

  final BillingUsageAggregate item;
  final String Function(DateTime d) formatDate;
  final bool expanded;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final time = item.periodStart == null ? '-' : formatDate(item.periodStart!);
    final detail = item.operationCode.isEmpty
        ? '${item.eventCount} 条消费记录${item.unknownAmountCount > 0 ? " · Token 用量不完整" : ""}'
        : '${item.operationCode} · ${item.eventCount} 条';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(time, style: _tableCellStyle),
            ),
            Expanded(
              flex: 2,
              child: Text(item.resourceLabel, style: _tableCellStyle),
            ),
            Expanded(
              flex: 2,
              child: Text(
                '${billingCreditSign(item.totalCredits)}${_formatCredits(item.totalCredits.abs())}',
                style: _tableCellStyle.copyWith(
                  color: const Color(0xFFF97316),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _tableCellStyle,
              ),
            ),
            const SizedBox(width: 20),
            if (loading)
              const CupertinoActivityIndicator(radius: 7)
            else
              Icon(
                expanded
                    ? CupertinoIcons.chevron_up
                    : CupertinoIcons.chevron_down,
                size: 13,
                color: const Color(0xFF98A2B3),
              ),
          ],
        ),
      ),
    );
  }
}

const _tableCellStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w600,
  color: Color(0xFF344054),
);

class _UsageEventExpansion extends StatelessWidget {
  const _UsageEventExpansion({
    required this.events,
    required this.loading,
    required this.error,
  });

  final List<BillingUsageEvent>? events;
  final bool loading;
  final String error;

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (loading) {
      child = const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoActivityIndicator(radius: 7),
            SizedBox(width: 8),
            Text(
              '加载明细中…',
              style: TextStyle(fontSize: 11, color: Color(0xFF667085)),
            ),
          ],
        ),
      );
    } else if (error.isNotEmpty) {
      child = Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          '明细加载失败：$error',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Color(0xFFE5484D)),
        ),
      );
    } else if (events == null) {
      child = const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Text(
          '点击查看逐笔明细',
          style: TextStyle(fontSize: 11, color: Color(0xFF667085)),
        ),
      );
    } else if (events!.isEmpty) {
      child = const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Text(
          '暂无原始明细',
          style: TextStyle(fontSize: 11, color: Color(0xFF667085)),
        ),
      );
    } else {
      final sorted = [...events!]..sort((a, b) {
          final at = a.occurredAt;
          final bt = b.occurredAt;
          if (at == null && bt == null) return 0;
          if (at == null) return 1;
          if (bt == null) return -1;
          return bt.compareTo(at);
        });
      child = Column(
        children: [
          const _UsageEventHeader(),
          const Divider(height: 1, color: Color(0xFFE1E7F0)),
          for (var i = 0; i < sorted.length; i++) ...[
            _UsageEventRow(event: sorted[i]),
            if (i != sorted.length - 1)
              const Divider(height: 1, color: Color(0xFFE8EDF5)),
          ],
        ],
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: _billingPanelSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD7E4F5)),
      ),
      child: child,
    );
  }
}

class _UsageEventHeader extends StatelessWidget {
  const _UsageEventHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 9),
      child: Row(
        children: [
          Expanded(
            flex: 22,
            child: Text('发生时间', style: _usageEventHeaderStyle),
          ),
          SizedBox(width: 10),
          Expanded(
            flex: 13,
            child: Text('成员', style: _usageEventHeaderStyle),
          ),
          SizedBox(width: 10),
          Expanded(
            flex: 10,
            child: Text('来源场景', style: _usageEventHeaderStyle),
          ),
          SizedBox(width: 10),
          Expanded(
            flex: 18,
            child: Text('模型', style: _usageEventHeaderStyle),
          ),
          SizedBox(width: 10),
          Expanded(
            flex: 14,
            child: Text(
              '用量',
              style: _usageEventHeaderStyle,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            flex: 9,
            child: Text(
              '积分',
              style: _usageEventHeaderStyle,
            ),
          ),
        ],
      ),
    );
  }
}

const _usageEventHeaderStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w800,
  color: Color(0xFF475467),
);

class _UsageEventRow extends StatelessWidget {
  const _UsageEventRow({required this.event});

  final BillingUsageEvent event;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 22,
            child: Text(
              event.isBeeBridge
                  ? event.minuteLabel
                  : _formatUsageEventTime(event.occurredAt),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF667085),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 13,
            child: Text(
              event.accountLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF344054),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 10,
            child: Text(
              event.sceneLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF344054),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 18,
            child: Tooltip(
              message: event.usageModelLabel,
              child: Text(
                event.usageModelLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF344054),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 14,
            child: BillingUsageTooltip(
              event: event,
              child: Text(
                event.usageLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF667085),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 9,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${event.creditSign}${_formatCredits(event.displayCreditsCost.abs())}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFF97316),
                  ),
                ),
                if (event.chargeFailed)
                  const Text(
                    '待补扣',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFF97316),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PaymentPollingDialog extends StatefulWidget {
  const _PaymentPollingDialog({
    required this.order,
    required this.onDone,
  });

  final BillingPaymentOrder order;
  final VoidCallback onDone;

  @override
  State<_PaymentPollingDialog> createState() => _PaymentPollingDialogState();
}

class _PaymentPollingDialogState extends State<_PaymentPollingDialog> {
  Timer? _timer;
  late BillingPaymentOrder _order;
  late final DateTime _startedAt;
  int _elapsed = 0;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _order = widget.order;
    _startedAt = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll({bool syncProvider = false}) async {
    if (_checking) return;
    if (syncProvider && mounted) {
      setState(() => _checking = true);
    } else {
      _checking = true;
    }
    try {
      final order = syncProvider
          ? await _billingService.syncOrder(_order.outTradeNo)
          : await _billingService.getOrder(_order.outTradeNo);
      if (!mounted) return;
      setState(() {
        _checking = false;
        _order = order;
        _elapsed = DateTime.now().difference(_startedAt).inSeconds;
      });
      if (order.fulfilled) {
        _timer?.cancel();
      } else if (!order.isPending && !order.isPaid) {
        _timer?.cancel();
        BotToast.showText(text: '订单状态: ${order.statusLabel}');
        widget.onDone();
      } else if (_elapsed >= 300) {
        _timer?.cancel();
        BotToast.showText(
          text: order.isPaid ? '支付已完成，正在开通，请稍后查看' : '支付超时，请稍后查看订单状态',
        );
        widget.onDone();
      }
      if (syncProvider && !order.isPaid && order.isPending) {
        BotToast.showText(text: '暂未查询到支付结果，请确认微信支付已完成');
      }
    } catch (error) {
      if (syncProvider && mounted) {
        BotToast.showText(text: formatError(error, fallback: '查询支付结果失败，请稍后重试'));
      }
    } finally {
      if (_checking) {
        if (mounted) {
          setState(() => _checking = false);
        } else {
          _checking = false;
        }
      }
    }
  }

  Future<void> _openPayment() async {
    final url = _order.paymentUrl;
    if (url.isEmpty) {
      await Clipboard.setData(ClipboardData(text: _order.outTradeNo));
      BotToast.showText(text: '暂无可打开链接，订单号已复制');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      await Clipboard.setData(ClipboardData(text: url));
      BotToast.showText(text: '支付链接格式异常，已复制');
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      await Clipboard.setData(ClipboardData(text: url));
      BotToast.showText(text: '无法打开微信，支付链接已复制');
    }
  }

  Future<void> _copyOrderNo() async {
    await Clipboard.setData(ClipboardData(text: _order.outTradeNo));
    BotToast.showText(text: '订单号已复制');
  }

  @override
  Widget build(BuildContext context) {
    final codeUrl = _order.codeUrl;
    final success = _order.fulfilled;
    final opening = _order.isPaid && !_order.fulfilled;
    final statusText = success
        ? (_order.orderType == 'credit_pack' ? '积分已到账' : '套餐已开通')
        : opening
            ? '支付已完成，正在开通'
            : '微信支付未成功';
    return UiContentDialog(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UiSheetHeader(
              title: '微信扫码支付',
              subtitle: '支付 ¥${_order.amountYuan}，支付完成后会自动到账',
              onClose: () {
                _timer?.cancel();
                Navigator.of(context).pop();
              },
            ),
            const SizedBox(height: 22),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFE4E7EC)),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '¥ ${_order.amountYuan}',
                    style: const TextStyle(
                      fontSize: 40,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF155EEF),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: success
                              ? const Color(0xFF12B76A)
                              : opening
                                  ? const Color(0xFFF79009)
                                  : const Color(0xFF667085),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        statusText,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF667085),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Container(
                    width: 260,
                    height: 260,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE4E7EC)),
                    ),
                    child: success
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 78,
                                height: 78,
                                decoration: const BoxDecoration(
                                  color: Color(0xFFEAFBF2),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  CupertinoIcons.check_mark_circled_solid,
                                  size: 46,
                                  color: Color(0xFF12B76A),
                                ),
                              ),
                              const SizedBox(height: 18),
                              Text(
                                _order.orderType == 'credit_pack'
                                    ? '购买成功'
                                    : '开通成功',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF101828),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _order.orderType == 'credit_pack'
                                    ? '积分已发放到账'
                                    : '套餐权益已立即生效',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF667085),
                                ),
                              ),
                            ],
                          )
                        : codeUrl.isEmpty
                            ? const Text(
                                '暂无二维码\n请复制订单号联系管理员确认支付配置',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF667085),
                                ),
                              )
                            : QrImageView(
                                data: codeUrl,
                                size: 220,
                                backgroundColor: Colors.white,
                              ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    success
                        ? '页面将刷新当前套餐与购买记录'
                        : opening
                            ? '已收到微信支付结果，正在完成业务开通'
                            : '打开手机微信扫一扫，完成支付后页面会自动刷新到账状态',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF667085),
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (success)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: widget.onDone,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF155EEF),
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(46),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: const Text(
                          '完成',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    )
                  else
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: opening ? null : _openPayment,
                            icon: const Icon(
                                CupertinoIcons.arrow_up_right_square),
                            label: const Text('打开微信支付'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF155EEF),
                              side: const BorderSide(color: Color(0xFFB2CCFF)),
                              minimumSize: const Size.fromHeight(44),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _checking
                                ? null
                                : () => _poll(syncProvider: true),
                            icon: _checking
                                ? const CupertinoActivityIndicator(radius: 7)
                                : const Icon(CupertinoIcons.refresh),
                            label: Text(_checking ? '查询中' : '我已完成支付'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF344054),
                              side: const BorderSide(color: Color(0xFFE4E7EC)),
                              minimumSize: const Size.fromHeight(44),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          _order.outTradeNo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF98A2B3),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _copyOrderNo,
                        child: const Icon(
                          CupertinoIcons.doc_on_doc,
                          size: 16,
                          color: Color(0xFF98A2B3),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '已等待 $_elapsed 秒',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF98A2B3),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showBillingDialog(
  BuildContext context, {
  BillingInitialTab initialTab = BillingInitialTab.subscription,
}) async {
  if (PlatformUtils.isMobile) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => UiContentDialog(
      maxHeight: 790,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 790),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: UiSheetHeader(
                title: '套餐与积分',
                onClose: () => Navigator.of(ctx).pop(),
              ),
            ),
            Expanded(
              child: _BillingDialogContent(
                initialTab: _toBillingTab(initialTab),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _BillingDialogContent extends StatefulWidget {
  const _BillingDialogContent({required this.initialTab});

  final _BillingTab initialTab;

  @override
  State<_BillingDialogContent> createState() => _BillingDialogContentState();
}

class _BillingDialogContentState extends State<_BillingDialogContent> {
  BillingWallet? _wallet;
  BillingSubscription? _subscription;
  List<BillingEntitlement> _entitlements = [];
  List<BillingCreditPack> _packs = [];
  List<BillingPlan> _plans = [];
  List<BillingPaymentOrder> _orders = [];
  List<BillingUsageAggregate> _usage = [];
  List<BillingUsageAggregate> _usageSource = [];
  List<BillingUsageAggregate> _visibleUsage = [];
  final Map<String, List<BillingUsageEvent>> _usageEventCache = {};
  final Map<String, Future<List<BillingUsageEvent>>> _usageEventRequests = {};
  final Set<String> _expandedUsageKeys = {};
  final Set<String> _loadingUsageKeys = {};
  int _usageEventGeneration = 0;
  String _usageEventError = '';
  DateTime _usageMonth = _billingUsageMonth();
  String _usageResourceType = '';
  DateTimeRange? _usageDateRange;
  late _BillingTab _tab;
  String _billingCycle = 'monthly';
  bool _loading = true;
  bool _skipNextBillingRefresh = false;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    billingSummaryRefreshNotifier.addListener(_handleBillingRefresh);
    _load();
  }

  @override
  void dispose() {
    billingSummaryRefreshNotifier.removeListener(_handleBillingRefresh);
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _billingService.getMyWallet(),
        _billingService.getMySubscription(),
        _billingService.getMyEntitlements(),
        _billingService.listCreditPacks(),
        _billingService.listPlans(),
        _billingService.listOrders(limit: 50),
        _billingService.listUsageAggregates(
          period: 'daily',
          limit: _billingUsageAggregateFetchLimit,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _wallet = results[0] as BillingWallet;
        _subscription = results[1] as BillingSubscription?;
        _entitlements = results[2] as List<BillingEntitlement>;
        _packs = results[3] as List<BillingCreditPack>;
        _plans = results[4] as List<BillingPlan>;
        _orders = results[5] as List<BillingPaymentOrder>;
        _usageSource = results[6] as List<BillingUsageAggregate>;
        _applyUsageFilters();
        _expandedUsageKeys.clear();
        _loadingUsageKeys.clear();
        _usageEventError = '';
        _usageEventCache.clear();
        _usageEventRequests.clear();
        _usageEventGeneration++;
        _loading = false;
      });
      if (_tab == _BillingTab.usage) _prefetchUsageEvents();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _handleBillingRefresh() async {
    if (!mounted) return;
    if (_skipNextBillingRefresh) {
      _skipNextBillingRefresh = false;
      return;
    }
    if (_tab == _BillingTab.usage) {
      await _refreshUsage();
      return;
    }
    await _load();
  }

  Future<void> _refreshUsage() async {
    try {
      final results = await Future.wait([
        _billingService.getMyWallet(),
        _billingService.listUsageAggregates(
          period: 'daily',
          limit: _billingUsageAggregateFetchLimit,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _wallet = results[0] as BillingWallet;
        _usageSource = results[1] as List<BillingUsageAggregate>;
        _applyUsageFilters();
        _expandedUsageKeys.clear();
        _loadingUsageKeys.clear();
        _usageEventError = '';
        _usageEventCache.clear();
        _usageEventRequests.clear();
        _usageEventGeneration++;
      });
      _prefetchUsageEvents();
    } catch (_) {
      // 使用页刷新失败时保留旧数据，避免切 tab 时把页面打断。
    }
  }

  void _handleTabChanged(_BillingTab value) {
    if (_tab == value) {
      if (value == _BillingTab.usage) unawaited(_refreshUsage());
      return;
    }
    setState(() => _tab = value);
    if (value == _BillingTab.usage) {
      unawaited(_refreshUsage());
    }
  }

  void _applyUsageFilters() {
    final month = _usageMonth;
    _usage = _usageSource.where((item) {
      final periodStart = item.periodStart?.toLocal();
      return periodStart != null &&
          periodStart.year == month.year &&
          periodStart.month == month.month;
    }).toList();

    final range = _usageDateRange ?? _billingUsageMonthRange(month);
    _visibleUsage = _usage.where((item) {
      if (_usageResourceType.isNotEmpty &&
          item.resourceType != _usageResourceType) {
        return false;
      }
      final periodStart = item.periodStart?.toLocal();
      if (periodStart == null) return false;
      final day =
          DateTime(periodStart.year, periodStart.month, periodStart.day);
      final start =
          DateTime(range.start.year, range.start.month, range.start.day);
      final end = DateTime(range.end.year, range.end.month, range.end.day);
      return !day.isBefore(start) && !day.isAfter(end);
    }).toList();
  }

  void _clearUsageEventState() {
    _expandedUsageKeys.clear();
    _loadingUsageKeys.clear();
    _usageEventError = '';
    _usageEventCache.clear();
    _usageEventRequests.clear();
    _usageEventGeneration++;
  }

  Future<void> _pickUsageMonth() async {
    final now = _billingUsageMonth();
    final months = List<DateTime>.generate(
      24,
      (index) => DateTime(now.year, now.month - index),
    );
    final selected = await showDialog<DateTime>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择月份'),
        content: SizedBox(
          width: 360,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: months
                .map(
                  (month) => SizedBox(
                    width: 104,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(month),
                      child: Text(_billingUsageMonthLabelFor(month)),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() {
      _usageMonth = DateTime(selected.year, selected.month);
      _usageDateRange = _billingUsageMonthRange(_usageMonth);
      _applyUsageFilters();
      _clearUsageEventState();
    });
    _prefetchUsageEvents();
  }

  Future<void> _pickUsageType() async {
    const options = <String, String>{
      '': '全部类型',
      'llm': '模型消费',
      'rtc_minute': 'AI 通话',
      'data_query': '数据查询',
      'skill': '技能调用',
    };
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择类型'),
        children: options.entries
            .map(
              (entry) => SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(entry.key),
                child: Row(
                  children: [
                    Expanded(child: Text(entry.value)),
                    if (entry.key == _usageResourceType)
                      const Icon(CupertinoIcons.checkmark, size: 16),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() {
      _usageResourceType = selected;
      _applyUsageFilters();
      _clearUsageEventState();
    });
    _prefetchUsageEvents();
  }

  Future<void> _pickUsageDateRange() async {
    final current = _usageDateRange ?? _billingUsageMonthRange(_usageMonth);
    final month = _billingUsageMonthRange(_usageMonth);
    final selected = await showDateRangePicker(
      context: context,
      firstDate: month.start,
      lastDate: month.end,
      initialDateRange: current,
      helpText: '选择消耗明细时间范围',
      saveText: '确定',
    );
    if (!mounted || selected == null) return;
    setState(() {
      _usageDateRange = selected;
      _applyUsageFilters();
      _clearUsageEventState();
    });
    _prefetchUsageEvents();
  }

  String _usageDateRangeLabel() {
    final range = _usageDateRange ?? _billingUsageMonthRange(_usageMonth);
    return '${_billingUsageDateLabel(range.start)} ~ '
        '${_billingUsageDateLabel(range.end)}';
  }

  String _usageResourceTypeLabel() {
    switch (_usageResourceType) {
      case 'llm':
        return '模型消费';
      case 'rtc_minute':
        return 'AI 通话';
      case 'data_query':
        return '数据查询';
      case 'skill':
        return '技能调用';
      default:
        return '全部类型';
    }
  }

  Future<void> _toggleUsageEvents(BillingUsageAggregate item) async {
    final type = item.resourceType;
    if (type.isEmpty) return;
    final key = _usageAggregateKey(item);
    if (_expandedUsageKeys.contains(key)) {
      setState(() => _expandedUsageKeys.remove(key));
      return;
    }
    setState(() {
      _expandedUsageKeys.add(key);
      _usageEventError = '';
    });
    if (_usageEventCache.containsKey(key)) return;
    setState(() => _loadingUsageKeys.add(key));
    try {
      await _loadUsageEvents(item);
      if (!mounted) return;
      setState(() {
        _loadingUsageKeys.remove(key);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingUsageKeys.remove(key);
        _usageEventError = e.toString();
      });
    }
  }

  Future<List<BillingUsageEvent>> _loadUsageEvents(
    BillingUsageAggregate item,
  ) async {
    final key = _usageAggregateKey(item);
    final cached = _usageEventCache[key];
    if (cached != null) return cached;

    final inFlight = _usageEventRequests[key];
    if (inFlight != null) return inFlight;

    final periodStart = item.periodStart;
    final generation = _usageEventGeneration;
    final request = _billingService.listUsageEvents(
      type: item.resourceType,
      from: periodStart == null
          ? _billingUsageMonthFromParamFor(_usageMonth)
          : _billingUsageDayParam(periodStart),
      to: periodStart == null
          ? _billingUsageMonthToParamFor(_usageMonth)
          : _billingUsageDayToParam(periodStart),
      includeFree: true,
      limit: 100,
    );
    _usageEventRequests[key] = request;
    try {
      final events = await request;
      if (generation == _usageEventGeneration) {
        _usageEventCache[key] = events;
      }
      return events;
    } finally {
      if (identical(_usageEventRequests[key], request)) {
        _usageEventRequests.remove(key);
      }
    }
  }

  void _prefetchUsageEvents() {
    final sorted = [..._visibleUsage]..sort(_compareUsageAggregateRows);
    for (final item in sorted.take(3)) {
      unawaited(
        _loadUsageEvents(item).then<void>(
          (_) {},
          onError: (_, __) {},
        ),
      );
    }
  }

  String _usageAggregateKey(BillingUsageAggregate item) {
    final periodStart = item.periodStart == null
        ? ''
        : '${item.periodStart!.year}-${item.periodStart!.month.toString().padLeft(2, '0')}-${item.periodStart!.day.toString().padLeft(2, '0')}';
    return [
      item.resourceType,
      item.period,
      periodStart,
      item.skillId?.toString() ?? '',
      item.operationCode,
    ].join('|');
  }

  String _planActionLabel(BillingPlan plan) {
    if (_isPendingPlanChange(plan)) {
      return '已设置到期后变更';
    }
    return _planChangeActionLabel(
      targetPlan: plan,
      currentPlan: _currentPlan(),
      currentCycle: _currentBillingCycle(),
      targetCycle: _billingCycle,
    );
  }

  BillingPlan? _nextUpgradePlan() {
    final currentPlan = _currentPlan();
    final candidates =
        _plans.where((plan) => !plan.isFree && !_isCurrentPlan(plan)).toList()
          ..sort((a, b) {
            final sortCompare = a.sortOrder.compareTo(b.sortOrder);
            if (sortCompare != 0) return sortCompare;
            final creditCompare = a.monthlyCredits.compareTo(b.monthlyCredits);
            if (creditCompare != 0) return creditCompare;
            return (a.priceForCycle('monthly') ?? 0)
                .compareTo(b.priceForCycle('monthly') ?? 0);
          });

    for (final plan in candidates) {
      if (_comparePlanTier(currentPlan, plan) > 0) {
        return plan;
      }
    }
    return null;
  }

  Future<void> _handlePlanTap(BillingPlan plan) async {
    final sub = _subscription;
    if (_isCurrentPlan(plan)) {
      BotToast.showText(text: '当前已在使用此套餐');
      return;
    }
    if (sub == null || !sub.isActive) {
      return _subscribeToPlan(plan);
    }
    return _changePlan(plan);
  }

  Future<void> _reloadAfterBillingChange() async {
    _skipNextBillingRefresh = true;
    notifyBillingSummaryChanged();
    await _load();
  }

  Future<void> _subscribeToPlan(BillingPlan plan) async {
    try {
      final confirmed = await _confirmPlanChangeDialog(
        context,
        currentPlan: _currentPlan(),
        targetPlan: plan,
        currentCycle: _currentBillingCycle(),
        targetCycle: _billingCycle,
        actionLabel: '开通',
        effectiveAt: null,
      );
      if (!mounted || !confirmed) return;
      final provider = plan.isFree ? '' : _billingDefaultPaymentProvider;
      final closeLoading = BotToast.showLoading();
      late final BillingPaymentOrder order;
      try {
        order = await _billingService.subscribe(
          planId: plan.id,
          provider: provider,
          billingCycle: _billingCycle,
        );
      } finally {
        closeLoading();
      }
      if (!mounted) return;
      if (order.fulfilled) {
        BotToast.showText(text: '订阅成功');
        unawaited(_reloadAfterBillingChange());
      } else if (order.isPending || order.isPaid) {
        _showPaymentPolling(order);
      }
    } catch (e) {
      if (!mounted) return;
      BotToast.showText(text: '订阅失败：$e');
    }
  }

  Future<void> _changePlan(BillingPlan plan) async {
    final action = _planActionLabel(plan);
    final isUpgrade = _isPaidPlanUpgrade(
      currentPlan: _currentPlan(),
      targetPlan: plan,
      currentCycle: _currentBillingCycle(),
      targetCycle: _billingCycle,
    );
    if (action.isEmpty || action == '当前使用') return;
    try {
      final confirmed = await _confirmPlanChangeDialog(
        context,
        currentPlan: _currentPlan(),
        targetPlan: plan,
        currentCycle: _currentBillingCycle(),
        targetCycle: _billingCycle,
        actionLabel: action,
        effectiveAt: null,
      );
      if (!mounted || !confirmed) return;
      final provider = isUpgrade ? _billingDefaultPaymentProvider : '';
      final closeLoading = BotToast.showLoading();
      late final ChangePlanResult result;
      try {
        result = await _billingService.changePlan(
          newPlanId: plan.id,
          provider: provider,
          billingCycle: _billingCycle,
        );
      } finally {
        closeLoading();
      }
      if (!mounted) return;
      switch (result.action) {
        case ChangePlanAction.upgrade:
          if (result.order != null) {
            if (result.order!.fulfilled) {
              BotToast.showText(text: '升级成功');
              unawaited(_reloadAfterBillingChange());
            } else if (result.order!.isPending || result.order!.isPaid) {
              _showPaymentPolling(result.order!);
            }
          } else {
            BotToast.showText(text: '升级成功');
            unawaited(_reloadAfterBillingChange());
          }
          break;
        case ChangePlanAction.downgrade:
        case ChangePlanAction.scheduled:
          BotToast.showText(text: '当前暂不支持该套餐变更');
          unawaited(_reloadAfterBillingChange());
          break;
        case ChangePlanAction.unknown:
          BotToast.showText(text: '操作完成');
          unawaited(_reloadAfterBillingChange());
          break;
      }
    } catch (e) {
      if (!mounted) return;
      BotToast.showText(text: '操作失败：$e');
    }
  }

  Future<void> _buyCreditPack(
    BillingCreditPack pack, {
    bool skipConfirm = false,
  }) async {
    if (!skipConfirm) {
      final confirmed = await showUiConfirmDialog(
        context,
        title: '购买积分包',
        description:
            '确认购买 ${pack.name}（${pack.priceLabel}，${pack.credits} 积分）？',
        confirmLabel: '确认',
      );
      if (confirmed != true || !mounted) return;
    }

    try {
      final closeLoading = BotToast.showLoading();
      late final BillingPaymentOrder order;
      try {
        order = await _billingService.buyCreditPack(
          packId: pack.id,
          provider: _billingDefaultPaymentProvider,
        );
      } finally {
        closeLoading();
      }
      if (!mounted) return;
      if (order.fulfilled) {
        BotToast.showText(text: '购买成功');
        unawaited(_reloadAfterBillingChange());
      } else if (order.isPending || order.isPaid) {
        _showPaymentPolling(order);
      }
    } catch (e) {
      if (!mounted) return;
      BotToast.showText(text: '购买失败：$e');
    }
  }

  void _showPaymentPolling(BillingPaymentOrder order) {
    showCupertinoDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PaymentPollingDialog(
        order: order,
        onDone: () {
          Navigator.of(ctx).pop();
          unawaited(_reloadAfterBillingChange());
        },
      ),
    );
  }

  void _showPurchaseRecordsDrawer() {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭购买记录',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        final size = MediaQuery.sizeOf(ctx);
        final drawerWidth = min(size.width * 0.72, 760.0);
        return Align(
          alignment: Alignment.centerRight,
          child: _PurchaseRecordsDrawer(
            width: drawerWidth,
            orders: _orders,
            plans: _plans,
            onClose: () => Navigator.of(ctx).pop(),
          ),
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  void _showCreditDetailDrawer() {
    final wallet = _wallet;
    final currentPlan = _currentPlan();
    final credits = BillingCreditDisplay.fromWallet(
      wallet,
      subscriptionTotal: currentPlan?.monthlyCredits ?? 0,
    );
    final subscriptionCredits = credits.subscriptionTotal;
    final totalCredits = credits.totalCredits;
    final addOnCredits = credits.addOnCredits;
    final subscriptionRemaining = credits.subscriptionRemaining;
    final subscriptionProgress = credits.subscriptionProgress;

    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭积分明细',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        final size = MediaQuery.sizeOf(ctx);
        final drawerWidth = min(size.width * 0.68, 700.0);
        return Align(
          alignment: Alignment.centerRight,
          child: _CreditDetailDrawer(
            width: drawerWidth,
            totalCredits: totalCredits,
            subscriptionRemaining: subscriptionRemaining,
            subscriptionTotal: subscriptionCredits,
            subscriptionProgress: subscriptionProgress,
            addOnCredits: addOnCredits,
            activeCredits: wallet?.activityCredits ?? 0,
            planName: currentPlan?.name ?? '免费版',
            planSubtitle: _currentPlanSubtitle(_subscription, currentPlan),
            canBuyCredits: _canBuyCreditPack(_entitlements, _packs),
            onBuyCredits: _packs.isEmpty ? null : _showCreditPackDrawer,
            onClose: () => Navigator.of(ctx).pop(),
          ),
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  void _showEntitlementDrawer() {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭权益明细',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        final size = MediaQuery.sizeOf(ctx);
        final drawerWidth = min(size.width * 0.68, 700.0);
        return Align(
          alignment: Alignment.centerRight,
          child: _EntitlementDetailDrawer(
            width: drawerWidth,
            entitlements: _entitlements,
            walletBalance: _wallet?.balance,
            onClose: () => Navigator.of(ctx).pop(),
          ),
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  void _showCreditPackDrawer() {
    if (_packs.isEmpty) return;
    final wallet = _wallet;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭增购积分',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, animation, secondaryAnimation) {
        final size = MediaQuery.sizeOf(ctx);
        final drawerWidth = min(size.width * 0.68, 700.0);
        return Align(
          alignment: Alignment.centerRight,
          child: _CreditPackDrawer(
            width: drawerWidth,
            packs: _packs,
            totalCredits: wallet?.balance ?? 0,
            planName: _subscription?.planName ?? _currentPlan()?.name ?? '免费版',
            periodEnd: _subscription?.currentPeriodEnd,
            onClose: () => Navigator.of(ctx).pop(),
            onBuy: (pack) {
              Navigator.of(ctx).pop();
              _buyCreditPack(pack, skipConfirm: true);
            },
          ),
        );
      },
      transitionBuilder: (ctx, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CupertinoActivityIndicator());
    }
    return ColoredBox(
      color: _billingPageTint,
      child: Column(
        children: [
          SizedBox(
            height: 62,
            child: Stack(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: UiUnderlineTabs<_BillingTab>(
                    tabs: const [
                      UiUnderlineTab(
                        value: _BillingTab.subscription,
                        label: '订阅管理',
                      ),
                      UiUnderlineTab(value: _BillingTab.usage, label: '积分消耗'),
                    ],
                    current: _tab,
                    onChanged: _handleTabChanged,
                    horizontalPadding: 20,
                    topPadding: 6,
                    spacing: 28,
                    showBottomBorder: false,
                    activeColor: _billingBrandBlue,
                    inactiveColor: _billingMuted,
                    indicatorWidth: 30,
                  ),
                ),
                Positioned.fill(
                  right: 20,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _showPurchaseRecordsDrawer,
                      icon: const Icon(CupertinoIcons.doc_text, size: 18),
                      label: const Text('购买记录'),
                      style: TextButton.styleFrom(
                        foregroundColor: _billingText,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _billingDivider),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
              children: [
                if (_tab == _BillingTab.subscription)
                  _buildDialogSubscription()
                else
                  _buildDialogUsage(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDialogSubscription() {
    final sub = _subscription;
    final wallet = _wallet;
    final currentPlan = _currentPlan();
    final planName = sub != null && sub.planName.isNotEmpty
        ? sub.planName
        : (currentPlan?.name ?? '免费版');
    final credits = BillingCreditDisplay.fromWallet(
      wallet,
      subscriptionTotal: currentPlan?.monthlyCredits ?? 0,
    );
    final subscriptionCredits = credits.subscriptionTotal;
    final totalCredits = credits.totalCredits;
    final addOnCredits = credits.addOnCredits;
    final subscriptionRemaining = credits.subscriptionRemaining;
    final subscriptionProgress = credits.subscriptionProgress;
    final canBuyCredits = _canBuyCreditPack(_entitlements, _packs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '当前套餐',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: Color(0xFF101828),
          ),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              color: _billingCardSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _billingBorder),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF155EEF).withValues(alpha: 0.035),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CurrentPlanVisual(
                    planName: planName,
                    subtitle: _currentPlanSubtitle(sub, currentPlan),
                    isFree: currentPlan?.isFree ?? true,
                  ),
                  Container(
                    width: 1,
                    color: _billingDivider,
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 14, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    const Text(
                                      '总积分',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: _billingText,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      _formatNumber(totalCredits),
                                      style: const TextStyle(
                                        fontSize: 28,
                                        height: 1,
                                        color: _billingBrandBlue,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                height: 36,
                                child: OutlinedButton(
                                  onPressed: _showCreditDetailDrawer,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: _billingBrandBlue,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    textStyle: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    side: const BorderSide(
                                      color: _billingBrandBlue,
                                      width: 1.1,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: const Text('积分明细'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                height: 36,
                                child: OutlinedButton(
                                  onPressed: _showEntitlementDrawer,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: _billingBrandBlue,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    textStyle: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    side: const BorderSide(
                                      color: _billingBrandBlue,
                                      width: 1.1,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: const Text('权益明细'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                height: 36,
                                child: FilledButton(
                                  onPressed: () {
                                    final target = _nextUpgradePlan();
                                    if (target == null) {
                                      BotToast.showText(text: '暂无可升级套餐');
                                      return;
                                    }
                                    _handlePlanTap(target);
                                  },
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _billingBrandBlueStrong,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    textStyle: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: const Text('升级套餐'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          IntrinsicHeight(
                            child: Row(
                              children: [
                                Expanded(
                                  child: _SubscriptionCreditColumn(
                                    remaining:
                                        _formatNumber(subscriptionRemaining),
                                    total: _formatNumber(subscriptionCredits),
                                    progress: subscriptionProgress,
                                  ),
                                ),
                                const _VerticalSplit(),
                                Expanded(
                                  child: _AddOnCreditColumn(
                                    value: _formatNumber(addOnCredits),
                                    canBuy: canBuyCredits && _packs.isNotEmpty,
                                    onBuy: _showCreditPackDrawer,
                                  ),
                                ),
                                const _VerticalSplit(),
                                Expanded(
                                  child: _CreditColumn(
                                    label: '活动积分',
                                    value: _formatNumber(
                                      wallet?.activityCredits ?? 0,
                                    ),
                                    helper: '',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_plans.isNotEmpty) ...[
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '选择套餐',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF101828),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '支持按月付或按年付，可随时升级或到期变更',
                      style: TextStyle(fontSize: 13, color: Color(0xFF667085)),
                    ),
                  ],
                ),
              ),
              BillingCycleSwitch(
                value: _billingCycle,
                onChanged: (value) => setState(() => _billingCycle = value),
              ),
            ],
          ),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, plan) in _plans.take(3).indexed) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(
                    child: _DialogPlanCard(
                      plan: plan,
                      current: _isCurrentPlan(plan),
                      pending: _isPendingPlanChange(plan),
                      actionLabel: _planActionLabel(plan),
                      billingCycle: _billingCycle,
                      onTap: () => _handlePlanTap(plan),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDialogUsage() {
    final total = _usage.fold<int>(
      0,
      (sum, item) => sum + item.totalCredits,
    );
    final totalEvents = _usage.fold<int>(
      0,
      (sum, item) => sum + item.eventCount,
    );
    final breakdown = _usageBreakdownByType(_usage)
      ..sort((a, b) => b.totalCredits.compareTo(a.totalCredits));
    final sorted = [..._visibleUsage]..sort(_compareUsageAggregateRows);
    final top = breakdown.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '本月消耗',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF101828),
                      ),
                    ),
                  ),
                  _FilterPill(
                    label: _billingUsageMonthLabelFor(_usageMonth),
                    onTap: _pickUsageMonth,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _MetricTile(
                      label: '本月累计消耗（积分）',
                      value: _formatNumber(total),
                      helper: '消费记录 $totalEvents 条',
                    ),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 104,
                    height: 104,
                    child: CustomPaint(
                      painter: _DonutChartPainter(
                        segments: _buildDonutSegments(top, total),
                        consumedFraction: _consumedFraction(total),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${(_consumedFraction(total) * 100).round()}%',
                              style: const TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF101828),
                              ),
                            ),
                            const Text(
                              '已消耗',
                              style: TextStyle(
                                fontSize: 10,
                                color: Color(0xFF667085),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      children: top.isEmpty
                          ? const [
                              _UsageBreakdownRow(
                                label: '技能调用',
                                credits: 0,
                                percent: '0%',
                                color: Color(0xFF2563EB),
                              ),
                              _UsageBreakdownRow(
                                label: 'LLM 对话',
                                credits: 0,
                                percent: '0%',
                                color: Color(0xFFF59E0B),
                              ),
                              _UsageBreakdownRow(
                                label: '数据查询',
                                credits: 0,
                                percent: '0%',
                                color: Color(0xFF10B981),
                              ),
                            ]
                          : top.asMap().entries.map((entry) {
                              final colors = const [
                                Color(0xFF2563EB),
                                Color(0xFFF59E0B),
                                Color(0xFF10B981),
                              ];
                              final item = entry.value;
                              final percent = total == 0
                                  ? '0%'
                                  : '${((item.totalCredits / total) * 100).round()}%';
                              return _UsageBreakdownRow(
                                label: item.resourceLabel,
                                credits: item.totalCredits,
                                percent: percent,
                                color: colors[entry.key % colors.length],
                              );
                            }).toList(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(
                    '总积分：${_formatCredits((_wallet?.balance ?? 0) + total)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF475467),
                    ),
                  ),
                  const SizedBox(width: 24),
                  Text(
                    '剩余积分：${_formatCredits(_wallet?.balance ?? 0)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF475467),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    '消耗明细',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF101828),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '按类型汇总，模型消费明细按分钟、成员和模型合并。',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF475467),
                    ),
                  ),
                ],
              ),
            ),
            _FilterPill(
              label: _usageResourceTypeLabel(),
              onTap: _pickUsageType,
            ),
            const SizedBox(width: 8),
            _FilterPill(
              label: _usageDateRangeLabel(),
              onTap: _pickUsageDateRange,
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (sorted.isEmpty)
          const _EmptyBillingState(
            title: '暂无积分消耗',
            subtitle: '产生模型、技能或数据查询消耗后会显示在这里。',
          )
        else
          _Card(
            child: Column(
              children: [
                const _UsageTableHeader(),
                for (var i = 0; i < sorted.length; i++) ...[
                  Builder(
                    builder: (context) {
                      final item = sorted[i];
                      final key = _usageAggregateKey(item);
                      final expanded = _expandedUsageKeys.contains(key);
                      final loading = _loadingUsageKeys.contains(key);
                      return Column(
                        children: [
                          _UsageTableRow(
                            item: item,
                            formatDate: _formatDate,
                            expanded: expanded,
                            loading: loading,
                            onTap: () => _toggleUsageEvents(item),
                          ),
                          if (expanded)
                            _UsageEventExpansion(
                              events: _usageEventCache[key],
                              loading: loading,
                              error: _usageEventError,
                            ),
                        ],
                      );
                    },
                  ),
                  if (i != sorted.length - 1)
                    const Divider(height: 1, color: Color(0xFFE5EAF2)),
                ],
              ],
            ),
          ),
      ],
    );
  }

  BillingPlan? _currentPlan() {
    final sub = _subscription;
    if (sub == null || !sub.isActive) return _freePlan();
    for (final plan in _plans) {
      if (plan.id == sub.planId) return plan;
    }
    return _freePlan();
  }

  BillingPlan? _freePlan() {
    for (final plan in _plans) {
      if (plan.code == 'free' || plan.isFree) return plan;
    }
    return null;
  }

  bool _isCurrentPlan(BillingPlan plan) {
    final sub = _subscription;
    return isBillingPlanCurrent(
      plan: plan,
      activePlanId: sub != null && sub.isActive ? sub.planId : null,
      freePlanId: _freePlan()?.id,
      currentCycle: _currentBillingCycle(),
      selectedCycle: _billingCycle,
    );
  }

  bool _isPendingPlanChange(BillingPlan plan) {
    return false;
  }

  String _currentBillingCycle() {
    return _subscriptionBillingCycle(_subscription);
  }

  String _currentPlanSubtitle(BillingSubscription? sub, BillingPlan? plan) {
    if (sub != null && sub.currentPeriodEnd != null) {
      return '有效期至 ${_formatDate(sub.currentPeriodEnd!)}';
    }
    if (plan != null && plan.isFree) return '默认免费套餐';
    return sub?.statusLabel ?? '可选择套餐开通';
  }

  BillingPlan? _pendingPlan() {
    final pendingID = _subscription?.pendingPlanId;
    if (pendingID == null) return null;
    for (final plan in _plans) {
      if (plan.id == pendingID) return plan;
    }
    return null;
  }

  String _pendingEffectiveDateLabel() {
    final effectiveAt =
        _subscription?.pendingEffectiveAt ?? _subscription?.currentPeriodEnd;
    if (effectiveAt == null) return '当前套餐到期后';
    return _formatDate(effectiveAt);
  }

  double _consumedFraction(int consumed) {
    final remaining = _wallet?.balance ?? 0;
    final budget = consumed + remaining;
    if (budget <= 0) return 0;
    return consumed / budget;
  }

  List<_DonutSegment> _buildDonutSegments(
    List<BillingUsageAggregate> top,
    int total,
  ) {
    const colors = [Color(0xFF2563EB), Color(0xFFF59E0B), Color(0xFF10B981)];
    if (total <= 0) return [];
    return top.asMap().entries.map((e) {
      return _DonutSegment(
        colors[e.key % colors.length],
        e.value.totalCredits / total,
      );
    }).toList();
  }

  String _formatNumber(num value) {
    final s = value.round().toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final remaining = s.length - i;
      buf.write(s[i]);
      if (remaining > 1 && remaining % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }

  String _formatDate(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

class _PurchaseRecordsDrawer extends StatefulWidget {
  const _PurchaseRecordsDrawer({
    required this.width,
    required this.orders,
    required this.plans,
    required this.onClose,
  });

  final double width;
  final List<BillingPaymentOrder> orders;
  final List<BillingPlan> plans;
  final VoidCallback onClose;

  @override
  State<_PurchaseRecordsDrawer> createState() => _PurchaseRecordsDrawerState();
}

class _PurchaseRecordsDrawerState extends State<_PurchaseRecordsDrawer> {
  _PurchaseRecordTab _tab = _PurchaseRecordTab.subscription;

  @override
  Widget build(BuildContext context) {
    final orders = _filteredOrders();
    return Material(
      color: Colors.transparent,
      child: Container(
        width: widget.width,
        height: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.horizontal(left: Radius.circular(12)),
          boxShadow: [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 24,
              offset: Offset(-8, 0),
            ),
          ],
        ),
        child: SafeArea(
          left: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 18, 8),
                child: UiSheetHeader(
                  title: '购买记录',
                  onClose: widget.onClose,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Row(
                  children: [
                    _PurchaseRecordPill(
                      label: '套餐订阅',
                      active: _tab == _PurchaseRecordTab.subscription,
                      onTap: () => setState(
                        () => _tab = _PurchaseRecordTab.subscription,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _PurchaseRecordPill(
                      label: '增购积分',
                      active: _tab == _PurchaseRecordTab.creditPack,
                      onTap: () => setState(
                        () => _tab = _PurchaseRecordTab.creditPack,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: orders.isEmpty
                    ? const _DrawerEmptyPurchaseRecords()
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
                        child: _PurchaseRecordsTable(
                          orders: orders,
                          plans: widget.plans,
                          tab: _tab,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<BillingPaymentOrder> _filteredOrders() {
    final filtered = widget.orders.where((order) {
      if (_tab == _PurchaseRecordTab.creditPack) {
        return order.orderType == 'credit_pack';
      }
      return order.orderType != 'credit_pack';
    }).toList();
    filtered.sort((a, b) {
      final at = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    });
    return filtered;
  }
}

class _PurchaseRecordPill extends StatelessWidget {
  const _PurchaseRecordPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active ? Colors.white : const Color(0xFFF2F4F7),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFFE5EAF2)),
            boxShadow: active
                ? const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: active ? const Color(0xFF101828) : const Color(0xFF667085),
            ),
          ),
        ),
      ),
    );
  }
}

class _PurchaseRecordsTable extends StatelessWidget {
  const _PurchaseRecordsTable({
    required this.orders,
    required this.plans,
    required this.tab,
  });

  final List<BillingPaymentOrder> orders;
  final List<BillingPlan> plans;
  final _PurchaseRecordTab tab;

  @override
  Widget build(BuildContext context) {
    final headers = tab == _PurchaseRecordTab.creditPack
        ? const ['积分包', '订单状态', '价格（元）', '购买时间', '订单编号', '支付方式']
        : const ['订阅套餐', '订阅类型', '价格（元）', '购买时间', '订单编号', '支付方式'];
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5EAF2)),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _PurchaseTableRow(
            cells: headers,
            header: true,
          ),
          for (final order in orders)
            _PurchaseTableRow(
              cells: [
                tab == _PurchaseRecordTab.creditPack
                    ? order.orderTypeLabel
                    : _subscriptionPlanLabel(order),
                tab == _PurchaseRecordTab.creditPack
                    ? order.statusLabel
                    : _subscriptionCycleLabel(order),
                order.amountYuan,
                _formatDateTime(order.createdAt),
                order.outTradeNo.isEmpty ? '-' : order.outTradeNo,
                order.providerLabel,
              ],
            ),
        ],
      ),
    );
  }

  BillingPlan? _orderPlan(BillingPaymentOrder order) {
    final productId = order.productId;
    if (productId == null) return null;
    for (final plan in plans) {
      if (plan.id == productId) return plan;
    }
    return null;
  }

  String _subscriptionPlanLabel(BillingPaymentOrder order) {
    final plan = _orderPlan(order);
    if (plan != null) return plan.name;
    return order.subscriptionPlanLabel;
  }

  String _subscriptionCycleLabel(BillingPaymentOrder order) {
    final snapshotCycle = order.subscriptionCycleRaw;
    if (snapshotCycle.isNotEmpty) return _orderCycleLabel(snapshotCycle);
    final plan = _orderPlan(order);
    if (plan != null) return _orderCycleLabel(plan.billingCycle);
    return order.subscriptionCycleLabel;
  }

  String _orderCycleLabel(String cycle) {
    switch (cycle) {
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

  String _formatDateTime(DateTime? value) {
    if (value == null) return '-';
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }
}

class _PurchaseTableRow extends StatelessWidget {
  const _PurchaseTableRow({
    required this.cells,
    this.header = false,
  });

  final List<String> cells;
  final bool header;

  @override
  Widget build(BuildContext context) {
    const flexes = [15, 14, 12, 22, 25, 12];
    return Container(
      height: header ? 40 : 44,
      decoration: BoxDecoration(
        color: header ? const Color(0xFFF8FAFC) : Colors.white,
        border: const Border(
          bottom: BorderSide(color: Color(0xFFEFF1F5)),
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            Expanded(
              flex: flexes[i],
              child: Padding(
                padding: EdgeInsets.only(
                  left: i == 0 ? 12 : 8,
                  right: 8,
                ),
                child: Text(
                  cells[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: header ? FontWeight.w700 : FontWeight.w500,
                    color: header
                        ? const Color(0xFF344054)
                        : const Color(0xFF475467),
                    height: 1.2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DrawerEmptyPurchaseRecords extends StatelessWidget {
  const _DrawerEmptyPurchaseRecords();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4F7),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              CupertinoIcons.doc_text,
              size: 20,
              color: Color(0xFF667085),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '暂无购买记录',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF344054),
            ),
          ),
        ],
      ),
    );
  }
}

class _CreditPackDrawer extends StatefulWidget {
  const _CreditPackDrawer({
    required this.width,
    required this.packs,
    required this.totalCredits,
    required this.planName,
    required this.periodEnd,
    required this.onClose,
    required this.onBuy,
  });

  final double width;
  final List<BillingCreditPack> packs;
  final int totalCredits;
  final String planName;
  final DateTime? periodEnd;
  final VoidCallback onClose;
  final ValueChanged<BillingCreditPack> onBuy;

  @override
  State<_CreditPackDrawer> createState() => _CreditPackDrawerState();
}

class _CreditPackDrawerState extends State<_CreditPackDrawer> {
  late BillingCreditPack _selected = widget.packs.first;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: widget.width,
        height: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.horizontal(left: Radius.circular(12)),
          boxShadow: [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 24,
              offset: Offset(-8, 0),
            ),
          ],
        ),
        child: SafeArea(
          left: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 18, 10),
                child: UiSheetHeader(
                  title: '增购积分',
                  onClose: widget.onClose,
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildAccountBand(),
                      const SizedBox(height: 18),
                      _buildPackGrid(),
                      const SizedBox(height: 18),
                      const Text(
                        '积分说明：积分有效期为 1 年，可用于平台内消费使用，不支持退款、兑换套餐、转赠或提现。',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.55,
                          color: _billingSubtle,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 120),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
                child: Center(
                  child: Container(
                    width: 240,
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFE4E7EC)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '支付前请阅读\n《知办积分购买协议》',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.45,
                            color: _billingText,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: () => widget.onBuy(_selected),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF171312),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 22,
                              vertical: 12,
                            ),
                            textStyle: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: Text('同意并支付 ${_selected.priceLabel}'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAccountBand() {
    final periodText = widget.periodEnd == null
        ? '当前套餐生效中'
        : '套餐将于 ${_formatPeriodDate(widget.periodEnd!)} 到期';
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F3EF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              color: _billingBrandBlueStrong,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              CupertinoIcons.person_fill,
              color: Colors.white,
              size: 23,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.planName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: _billingInk,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  periodText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _billingSubtle,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                '我的积分',
                style: TextStyle(
                  fontSize: 13,
                  color: _billingSubtle,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      CupertinoIcons.sparkles,
                      size: 16,
                      color: _billingInk,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _formatCredits(widget.totalCredits),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: _billingInk,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPackGrid() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: widget.packs.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.72,
      ),
      itemBuilder: (context, index) {
        final pack = widget.packs[index];
        final selected = pack.id == _selected.id;
        return _CreditPackOptionCard(
          pack: pack,
          selected: selected,
          onTap: () => setState(() => _selected = pack),
        );
      },
    );
  }

  static String _formatPeriodDate(DateTime value) {
    return '${value.year}.${value.month.toString().padLeft(2, '0')}.${value.day.toString().padLeft(2, '0')}';
  }
}

class _CreditPackOptionCard extends StatelessWidget {
  const _CreditPackOptionCard({
    required this.pack,
    required this.selected,
    required this.onTap,
  });

  final BillingCreditPack pack;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? _billingInk : const Color(0xFFE4E7EC),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: selected ? 0.08 : 0.035),
              blurRadius: selected ? 14 : 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  CupertinoIcons.sparkles,
                  size: 20,
                  color: _billingInk,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    _formatCredits(pack.credits),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      color: _billingInk,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Text(
              pack.priceLabel,
              style: const TextStyle(
                fontSize: 14,
                height: 1,
                fontWeight: FontWeight.w700,
                color: _billingInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreditDetailDrawer extends StatefulWidget {
  const _CreditDetailDrawer({
    required this.width,
    required this.totalCredits,
    required this.subscriptionRemaining,
    required this.subscriptionTotal,
    required this.subscriptionProgress,
    required this.addOnCredits,
    required this.activeCredits,
    required this.planName,
    required this.planSubtitle,
    required this.canBuyCredits,
    required this.onBuyCredits,
    required this.onClose,
  });

  final double width;
  final int totalCredits;
  final num subscriptionRemaining;
  final int subscriptionTotal;
  final double subscriptionProgress;
  final int addOnCredits;
  final int activeCredits;
  final String planName;
  final String planSubtitle;
  final bool canBuyCredits;
  final VoidCallback? onBuyCredits;
  final VoidCallback onClose;

  @override
  State<_CreditDetailDrawer> createState() => _CreditDetailDrawerState();
}

class _CreditDetailDrawerState extends State<_CreditDetailDrawer> {
  BillingCreditDetailTab _tab = BillingCreditDetailTab.subscription;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: widget.width,
        height: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.horizontal(left: Radius.circular(12)),
          boxShadow: [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 24,
              offset: Offset(-8, 0),
            ),
          ],
        ),
        child: SafeArea(
          left: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 18, 10),
                child: UiSheetHeader(
                  title: '积分明细',
                  onClose: widget.onClose,
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSummaryCard(),
                      const SizedBox(height: 14),
                      _buildTabs(),
                      const SizedBox(height: 10),
                      _buildDetailBody(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5EAF2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                '总积分',
                style: TextStyle(
                  fontSize: 18,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF101828),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatCredits(widget.totalCredits),
                style: const TextStyle(
                  fontSize: 18,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF101828),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _CreditDetailMetric(
                  label: '订阅积分',
                  value: _formatCredits(widget.subscriptionRemaining),
                  helper: '/ ${_formatCredits(widget.subscriptionTotal)}',
                  progress: widget.subscriptionProgress,
                ),
              ),
              const _CreditDetailDivider(),
              Expanded(
                child: _CreditDetailMetric(
                  label: '增购积分',
                  value: _formatCredits(widget.addOnCredits),
                  actionLabel: widget.canBuyCredits ? '增购积分' : null,
                  onAction: widget.onBuyCredits,
                ),
              ),
              const _CreditDetailDivider(),
              Expanded(
                child: _CreditDetailMetric(
                  label: '活动积分',
                  value: _formatCredits(widget.activeCredits),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    return BillingCreditDetailTabs(
      value: _tab,
      onChanged: (value) => setState(() => _tab = value),
    );
  }

  Widget _buildDetailBody() {
    switch (_tab) {
      case BillingCreditDetailTab.subscription:
        return _CreditDetailEntry(
          title: widget.planName,
          subtitle: widget.planSubtitle,
          value:
              '${_formatCredits(widget.subscriptionRemaining)} / ${_formatCredits(widget.subscriptionTotal)}',
        );
      case BillingCreditDetailTab.addOn:
        if (widget.addOnCredits <= 0) {
          return const _CreditDetailEmpty(text: '暂无增购积分');
        }
        return _CreditDetailEntry(
          title: '增购积分',
          subtitle: '通过积分包购买获得',
          value: _formatCredits(widget.addOnCredits),
        );
      case BillingCreditDetailTab.activity:
        if (widget.activeCredits <= 0) {
          return const _CreditDetailEmpty(text: '暂无活动积分');
        }
        return _CreditDetailEntry(
          title: '活动积分',
          subtitle: '活动或运营赠送积分',
          value: _formatCredits(widget.activeCredits),
        );
    }
  }
}

class _CreditDetailMetric extends StatelessWidget {
  const _CreditDetailMetric({
    required this.label,
    required this.value,
    this.helper,
    this.progress,
    this.actionLabel,
    this.onAction,
  });

  final String label;
  final String value;
  final String? helper;
  final double? progress;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Color(0xFF344054),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF101828),
                ),
              ),
            ),
            if (helper != null) ...[
              const SizedBox(width: 4),
              Text(
                helper!,
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF98A2B3),
                ),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(width: 8),
              SizedBox(
                height: 28,
                child: OutlinedButton(
                  onPressed: onAction,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF344054),
                    backgroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                    side: const BorderSide(color: Color(0xFFD0D5DD)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  child: Text(actionLabel!),
                ),
              ),
            ],
          ],
        ),
        if (progress != null) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              color: const Color(0xFF111827),
              backgroundColor: const Color(0xFFE4DFD7),
            ),
          ),
        ],
      ],
    );
  }
}

class _CreditDetailDivider extends StatelessWidget {
  const _CreditDetailDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 58,
      margin: const EdgeInsets.symmetric(horizontal: 14),
      color: const Color(0xFFE5EAF2),
    );
  }
}

class _CreditDetailEntry extends StatelessWidget {
  const _CreditDetailEntry({
    required this.title,
    required this.subtitle,
    required this.value,
  });

  final String title;
  final String subtitle;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5EAF2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF344054),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF98A2B3),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF101828),
            ),
          ),
        ],
      ),
    );
  }
}

class _CreditDetailEmpty extends StatelessWidget {
  const _CreditDetailEmpty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 34),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5EAF2)),
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          color: Color(0xFF98A2B3),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _CurrentPlanVisual extends StatelessWidget {
  const _CurrentPlanVisual({
    required this.planName,
    required this.subtitle,
    required this.isFree,
  });

  final String planName;
  final String subtitle;
  final bool isFree;

  @override
  Widget build(BuildContext context) {
    if (isFree) {
      return Container(
        width: 240,
        padding: const EdgeInsets.fromLTRB(24, 22, 22, 22),
        decoration: const BoxDecoration(
          color: _billingSoftSurface,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              planName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 19,
                height: 1.1,
                fontWeight: FontWeight.w900,
                color: _billingInk,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                height: 1.4,
                fontWeight: FontWeight.w500,
                color: _billingSubtle,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: 244,
      padding: const EdgeInsets.fromLTRB(17, 14, 17, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF12101D),
            Color(0xFF2C1D3E),
            Color(0xFF8B78A8),
          ],
          stops: [0, 0.64, 1],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1D1028).withValues(alpha: 0.18),
            blurRadius: 16,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              '生效中',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
          const Spacer(),
          Text(
            planName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 20,
              height: 1.1,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.72),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _CreditColumn extends StatelessWidget {
  const _CreditColumn({
    required this.label,
    required this.value,
    required this.helper,
  });

  final String label;
  final String value;
  final String helper;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: _billingMuted,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 21,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  color: _billingInk,
                ),
              ),
            ),
            if (helper.isNotEmpty) ...[
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 1),
                child: Text(
                  helper,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: _billingSubtle,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _SubscriptionCreditColumn extends StatelessWidget {
  const _SubscriptionCreditColumn({
    required this.remaining,
    required this.total,
    required this.progress,
  });

  final String remaining;
  final String total;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '订阅积分',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: _billingMuted,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Text(
                remaining,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 21,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  color: _billingInk,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 1),
                child: Text(
                  '/ $total',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: _billingSubtle,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            color: _billingBrandBlueStrong,
            backgroundColor: const Color(0xFFE8F0FF),
          ),
        ),
      ],
    );
  }
}

class _AddOnCreditColumn extends StatelessWidget {
  const _AddOnCreditColumn({
    required this.value,
    required this.canBuy,
    required this.onBuy,
  });

  final String value;
  final bool canBuy;
  final VoidCallback onBuy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '增购积分',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: _billingMuted,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 21,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  color: _billingInk,
                ),
              ),
            ),
            if (canBuy) ...[
              const SizedBox(width: 8),
              SizedBox(
                height: 28,
                child: OutlinedButton(
                  onPressed: onBuy,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _billingBrandBlue,
                    backgroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                    side: const BorderSide(color: _billingBrandBlue),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  child: const Text('增购积分'),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _VerticalSplit extends StatelessWidget {
  const _VerticalSplit();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 52,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: _billingDivider,
    );
  }
}

class _DialogPlanCard extends StatelessWidget {
  const _DialogPlanCard({
    required this.plan,
    required this.current,
    required this.pending,
    required this.actionLabel,
    required this.billingCycle,
    required this.onTap,
  });

  final BillingPlan plan;
  final bool current;
  final bool pending;
  final String actionLabel;
  final String billingCycle;
  final VoidCallback onTap;

  IconData _planIcon() {
    switch (plan.code.toLowerCase()) {
      case 'free':
        return CupertinoIcons.person_fill;
      case 'basic':
        return Icons.diamond_outlined;
      case 'pro':
      case 'professional':
        return Icons.workspace_premium;
      default:
        return CupertinoIcons.star_fill;
    }
  }

  Color _planIconColor() {
    switch (plan.code.toLowerCase()) {
      case 'free':
        return const Color(0xFF2563EB);
      case 'basic':
        return const Color(0xFF2563EB);
      case 'pro':
      case 'professional':
        return const Color(0xFF7C3AED);
      default:
        return const Color(0xFF2563EB);
    }
  }

  @override
  Widget build(BuildContext context) {
    final features = planFeatureLines(plan);
    final availableModels = planAvailableModelsLine(plan);
    final isFreePrice = plan.isFree || plan.priceForCycle(billingCycle) == 0;
    final priceText = isFreePrice
        ? '¥0'
        : (billingCycle == 'yearly'
            ? plan.displayMonthlyPriceShortForCycle(billingCycle)
            : plan.priceShortForCycle(billingCycle));
    final priceUnit = billingCycle == 'yearly' ? '/月' : '/月';
    final promotionText = plan.promotionTextForCycle(billingCycle);
    final yearlyPaymentText = billingCycle == 'yearly' && !isFreePrice
        ? promotionText ?? '年付价 ${plan.priceLabelForCycle(billingCycle)}'
        : promotionText;
    final originalPriceText = plan.originalAmountShortForCycle(billingCycle);
    final showRecommend = plan.isRecommended && !current;
    final borderColor =
        showRecommend ? const Color(0xFF8B5CF6) : _billingBorder;
    final card = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: current ? null : onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
        decoration: BoxDecoration(
          gradient: showRecommend
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white,
                    Color(0xFFFFFBFF),
                    Color(0xFFF6F1FF),
                  ],
                  stops: [0, 0.52, 1],
                )
              : null,
          color: showRecommend ? null : _billingCardSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: borderColor,
            width: showRecommend ? 1.2 : 1.0,
          ),
          boxShadow: [
            if (showRecommend)
              BoxShadow(
                color: _billingPurple.withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 5),
              ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (!plan.isFree) ...[
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _planIconColor().withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      _planIcon(),
                      size: 15,
                      color: _planIconColor(),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    plan.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      color: _billingInk,
                    ),
                  ),
                ),
                if (showRecommend)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFFB53CFF),
                          Color(0xFF155EEF),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: _billingPurple.withValues(alpha: 0.22),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Text(
                      '推荐套餐',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  priceText,
                  style: const TextStyle(
                    fontSize: 28,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    color: _billingInk,
                  ),
                ),
                if (!isFreePrice) ...[
                  const SizedBox(width: 2),
                  Text(
                    priceUnit,
                    style: const TextStyle(
                      fontSize: 14,
                      color: _billingMuted,
                    ),
                  ),
                ],
                if (!isFreePrice && originalPriceText != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    '原价 $originalPriceText/月',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF98A2B3),
                      decoration: TextDecoration.lineThrough,
                      decorationColor: Color(0xFF98A2B3),
                      decorationThickness: 1.2,
                    ),
                  ),
                ],
              ],
            ),
            if (yearlyPaymentText != null && yearlyPaymentText.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                yearlyPaymentText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF9A6A2F),
                  height: 1.25,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              '每月 ${_formatCredits(plan.monthlyCredits)} 积分',
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: _billingInk,
              ),
            ),
            const SizedBox(height: 12),
            ...features.take(8).map(
                  (f) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Icon(
                            CupertinoIcons.checkmark_alt_circle_fill,
                            size: 14,
                            color: Color(0xFF2563EB),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            f,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 1.35,
                              fontWeight: FontWeight.w500,
                              color: _billingMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            if (availableModels != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        CupertinoIcons.checkmark_alt_circle_fill,
                        size: 14,
                        color: Color(0xFF2563EB),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        availableModels,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          fontWeight: FontWeight.w500,
                          color: _billingMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const Spacer(),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: actionLabel.isEmpty
                  ? const SizedBox.shrink()
                  : current || pending
                      ? OutlinedButton(
                          onPressed: null,
                          style: OutlinedButton.styleFrom(
                            disabledForegroundColor: _billingBrandBlue,
                            side: const BorderSide(color: _billingBrandBlue),
                            textStyle: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: Text(pending ? actionLabel : '当前使用'),
                        )
                      : showRecommend
                          ? Container(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFFB53CFF),
                                    Color(0xFF155EEF),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: FilledButton(
                                onPressed: onTap,
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  foregroundColor: Colors.white,
                                  textStyle: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                child: Text(actionLabel),
                              ),
                            )
                          : FilledButton(
                              onPressed: onTap,
                              style: FilledButton.styleFrom(
                                backgroundColor: _billingBrandBlueStrong,
                                foregroundColor: Colors.white,
                                textStyle: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: Text(actionLabel),
                            ),
            ),
          ],
        ),
      ),
    );
    return card;
  }
}

class _DialogOrderRow extends StatelessWidget {
  const _DialogOrderRow({required this.order, required this.formatDate});

  final BillingPaymentOrder order;
  final String Function(DateTime d) formatDate;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        children: [
          Expanded(
            child: Text(
              [
                order.orderTypeLabel,
                order.statusLabel,
                if (order.createdAt != null) formatDate(order.createdAt!),
              ].join(' · '),
              style: const TextStyle(fontSize: 13, color: Color(0xFF344054)),
            ),
          ),
          Text(
            '¥${order.amountYuan}',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF101828),
            ),
          ),
        ],
      ),
    );
  }
}

class _DonutSegment {
  final Color color;
  final double fraction;
  const _DonutSegment(this.color, this.fraction);
}

class _DonutChartPainter extends CustomPainter {
  final List<_DonutSegment> segments;
  final double consumedFraction;

  const _DonutChartPainter({
    required this.segments,
    required this.consumedFraction,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 12.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;

    paint.color = const Color(0xFFE5EAF2);
    canvas.drawCircle(center, radius, paint);

    final clampedFraction = consumedFraction.clamp(0.0, 1.0);
    if (clampedFraction <= 0 || segments.isEmpty) return;

    double startAngle = -pi / 2;
    for (final seg in segments) {
      if (seg.fraction <= 0) continue;
      final sweepAngle = seg.fraction * clampedFraction * 2 * pi;
      paint.color = seg.color;
      canvas.drawArc(rect, startAngle, sweepAngle, false, paint);
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutChartPainter old) =>
      consumedFraction != old.consumedFraction || segments != old.segments;
}
