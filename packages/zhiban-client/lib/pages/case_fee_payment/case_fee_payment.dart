/// 垂域工单服务费支付（F24 收款线上化，2026-07-24；代账 + 注册通用）。
///
/// 入口：聊天消息 action 块 ``action_id = open_payment:{fee_kind}:{case_id}``
/// （fee_kind ∈ bookkeeping_fee / registration_fee），容器层 onOpenPayment 调
/// [openCaseFeePayment] 本地打开（不走 respond 回灌）。
/// 金额由服务端按工单最终价定（POST /billing/orders/case-fee）；代账最终价
/// 为月费，新订单按 12 个月一次性年付；注册服务费仍为一次性金额。支付成功后
/// Bus 回调自动推进工单（代账签约 / 注册开始办理）并由助手推送，本页只负责收款闭环。
/// 桌面端 = 扫码 Dialog；移动端 = 全屏页拉起微信 App 支付（CLAUDE.md 分支约定）。
library;

import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/models/billing_models.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/billing_api.dart';
import 'package:zhiban_core/utils/error_utils.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

const _supportedFeeKinds = {
  'bookkeeping_fee': '代账服务费',
  'registration_fee': '注册服务费',
};

/// 解析支付 action_id（`open_payment:{fee_kind}:{case_id}`）；形态不符返回 null。
({String feeKind, String caseId})? caseFeeFromAction(String actionId) {
  final parts = actionId.split(':');
  if (parts.length != 3 || parts[0] != 'open_payment') return null;
  final feeKind = parts[1];
  final caseId = parts[2].trim();
  if (!_supportedFeeKinds.containsKey(feeKind) || caseId.isEmpty) return null;
  return (feeKind: feeKind, caseId: caseId);
}

({double monthlyPrice, int billingMonths})? _annualBookkeepingBilling(
  BillingPaymentOrder? order,
) {
  if (order == null || order.orderType != 'bookkeeping_fee') return null;
  final snapshot = order.productSnapshot;
  if (snapshot == null || snapshot['billing_cycle'] != 'yearly') return null;
  final monthsValue = snapshot['billing_months'];
  final months = monthsValue is num
      ? monthsValue.toInt()
      : int.tryParse(monthsValue?.toString() ?? '');
  final monthlyValue = snapshot['monthly_price'];
  final monthlyPrice = monthlyValue is num
      ? monthlyValue.toDouble()
      : double.tryParse(monthlyValue?.toString() ?? '');
  final annualValue = snapshot['annual_price'];
  final annualPrice = annualValue is num
      ? annualValue.toDouble()
      : double.tryParse(annualValue?.toString() ?? '');
  if (months == null ||
      months != 12 ||
      monthlyPrice == null ||
      monthlyPrice <= 0 ||
      annualPrice == null ||
      annualPrice <= 0) {
    return null;
  }
  return (monthlyPrice: monthlyPrice, billingMonths: months);
}

/// 工单服务费主金额：新代账年付单显示快照月费，历史代账单维持原显示。
String caseFeeAmountLabel(BillingPaymentOrder? order) {
  if (order == null) return '¥--';
  final annualBilling = _annualBookkeepingBilling(order);
  if (annualBilling != null) {
    return '¥${annualBilling.monthlyPrice.toStringAsFixed(2)} / 月';
  }
  final suffix = switch (order.orderType) {
    'bookkeeping_fee' => ' / 月',
    'registration_fee' => '（一次性）',
    _ => '',
  };
  return '¥${order.amountYuan}$suffix';
}

/// 新代账年付单的本次实付说明；历史单和注册单不伪造年付语义。
String? caseFeeBillingSummary(BillingPaymentOrder? order) {
  final annualBilling = _annualBookkeepingBilling(order);
  if (order == null || annualBilling == null) return null;
  return '按年支付 ¥${order.amountYuan}（${annualBilling.billingMonths}个月）';
}

/// 聊天内「去支付」统一入口：桌面弹扫码 Dialog，移动端进全屏支付页。
Future<void> openCaseFeePayment(BuildContext context, String actionId) async {
  final ref = caseFeeFromAction(actionId);
  if (ref == null) {
    BotToast.showText(text: '暂不支持该支付类型，请升级客户端后重试');
    return;
  }
  final title = '支付${_supportedFeeKinds[ref.feeKind]!}';
  if (PlatformUtils.isDesktop) {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CaseFeePaymentDialog(caseId: ref.caseId, title: title),
    );
  } else {
    await context.push(RoutePaths.caseFeePayment,
        extra: (caseId: ref.caseId, title: title));
  }
}

// ---------------------------------------------------------------- 桌面扫码

class _CaseFeePaymentDialog extends StatefulWidget {
  const _CaseFeePaymentDialog({required this.caseId, required this.title});
  final String caseId;
  final String title;

  @override
  State<_CaseFeePaymentDialog> createState() => _CaseFeePaymentDialogState();
}

class _CaseFeePaymentDialogState extends State<_CaseFeePaymentDialog> {
  final BillingService _service = BillingService();
  Timer? _pollTimer;
  BillingPaymentOrder? _order;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _createOrder();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _createOrder() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 桌面不传 trade_type，服务端默认微信 Native（扫码）。
      final order = await _service.createCaseFeeOrder(caseId: widget.caseId);
      if (!mounted) return;
      setState(() {
        _order = order;
        _loading = false;
      });
      _startPolling();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  Future<void> _poll() async {
    final order = _order;
    if (order == null || order.fulfilled) return;
    try {
      final latest = await _service.getOrder(order.outTradeNo);
      if (!mounted) return;
      setState(() => _order = latest);
      if (latest.fulfilled) {
        _pollTimer?.cancel();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final order = _order;
    final billingSummary = caseFeeBillingSummary(order);
    final fulfilled = order?.fulfilled ?? false;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UiSheetHeader(
                title: widget.title,
                onClose: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 12),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CupertinoActivityIndicator()),
                )
              else if (_error != null) ...[
                Text(
                  formatError(_error!),
                  style: TextStyle(fontSize: 13, color: scheme.error),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _createOrder,
                  child: const Text('重试')
                ),
              ] else if (fulfilled) ...[
                Icon(CupertinoIcons.checkmark_circle_fill,
                    size: 48, color: scheme.primary),
                const SizedBox(height: 12),
                const Text(
                  '支付成功',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  '回到会话即可查看最新进度通知。',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
              ] else if (order != null) ...[
                Text(
                  caseFeeAmountLabel(order),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w700),
                ),
                if (billingSummary != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    billingSummary,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 12),
                if (order.codeUrl.isNotEmpty)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.5),
                        ),
                      ),
                      child: QrImageView(data: order.codeUrl, size: 200),
                    ),
                  )
                else
                  Text(
                    '未获取到支付二维码，请关闭后重试',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: scheme.error),
                  ),
                const SizedBox(height: 12),
                Text(
                  '请使用微信扫码支付；支付完成后自动签约。',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: _poll,
                  child: const Text('我已完成支付')
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
