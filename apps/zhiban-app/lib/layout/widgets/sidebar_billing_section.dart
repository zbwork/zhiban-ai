import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/models/billing_models.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/billing_api.dart';
import 'package:zhiban_client/services/billing_refresh_notifier.dart';

import 'sidebar_billing_indicator.dart';

final _billingService = BillingService();

class SidebarBillingSection extends StatefulWidget {
  const SidebarBillingSection({super.key, this.collapsed = false});

  final bool collapsed;

  @override
  State<SidebarBillingSection> createState() => _SidebarBillingSectionState();
}

class _SidebarBillingSectionState extends State<SidebarBillingSection>
    with WidgetsBindingObserver {
  BillingWallet? _wallet;
  BillingSubscription? _subscription;
  int _planMonthlyCredits = 0;

  String get _planName {
    final sub = _subscription;
    if (sub == null || !sub.isActive) return '免费版';
    if (sub.planName.trim().isNotEmpty) return sub.planName.trim();
    if (sub.planCode.trim().isNotEmpty) return sub.planCode.trim();
    return '已订阅';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    billingSummaryRefreshNotifier.addListener(_loadBillingQuickInfo);
    unawaited(_loadBillingQuickInfo());
  }

  @override
  void dispose() {
    billingSummaryRefreshNotifier.removeListener(_loadBillingQuickInfo);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadBillingQuickInfo());
    }
  }

  Future<void> _loadBillingQuickInfo() async {
    try {
      final results = await Future.wait([
        _billingService.getMyWallet(),
        _billingService.getMySubscription(),
        _billingService.listPlans(),
      ]);
      if (!mounted) return;
      final wallet = results[0] as BillingWallet;
      final sub = results[1] as BillingSubscription?;
      final plans = results[2] as List<BillingPlan>;

      int monthly = 0;
      if (sub != null && sub.isActive) {
        final plan = plans.where((p) => p.id == sub.planId).firstOrNull;
        if (plan != null) monthly = plan.monthlyCredits;
      }
      if (monthly == 0) {
        final freePlan = plans.where((p) => p.isFree).firstOrNull;
        if (freePlan != null) monthly = freePlan.monthlyCredits;
      }

      setState(() {
        _wallet = wallet;
        _subscription = sub;
        _planMonthlyCredits = monthly;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return SidebarBillingIndicator(
      collapsed: widget.collapsed,
      planName: _planName,
      credits: _wallet?.balance ?? 0,
      totalCredits: _planMonthlyCredits,
      isLowCredit: _wallet?.isLowCredit ?? false,
      onTap: () {
        notifyBillingSummaryChanged();
        context.go(RoutePaths.billing);
        unawaited(_loadBillingQuickInfo());
      },
    );
  }
}
