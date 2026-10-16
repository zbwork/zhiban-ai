import 'package:zhiban_client/network/user_refresh.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_client/models/billing_models.dart';
import 'package:zhiban_client/pages/settings/widgets/billing_usage_tooltip.dart';
import 'package:zhiban_client/services/billing_api.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';

/// 积分消耗页：本月消耗汇总（分类）+ 消耗明细。
///
/// 数据来源：
///   - 汇总 GET /billing/usage/summary（仅 credits_cost>0 的成功事件）。
///   - 明细 GET /billing/usage/events。
/// 仅读当前租户范围；不调用 admin 接口。
class UsageConsumptionPage extends StatefulWidget {
  const UsageConsumptionPage({super.key});

  @override
  State<UsageConsumptionPage> createState() => _UsageConsumptionPageState();
}

class _UsageConsumptionPageState extends State<UsageConsumptionPage> {
  final BillingService _service = BillingService();

  // 客户端展示分类（技能调用本版本未启用，显示 0 + 未启用标注，避免误解）。
  static const _categories = <String>[
    'llm',
    'rtc_minute',
    'data_query',
    'skill'
  ];
  static const _enabledCategories = <String>{'llm', 'rtc_minute'};

  // 明细类型过滤：'' = 全部。
  static const _filters = <_UsageFilter>[
    _UsageFilter('', '全部'),
    _UsageFilter('llm', 'LLM 对话'),
    _UsageFilter('rtc_minute', 'AI 通话'),
  ];

  BillingUsageSummary? _summary;
  List<BillingUsageEvent> _events = const [];
  String _typeFilter = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await _service.getUsageSummary();
      final events =
          await _service.listUsageEvents(type: _typeFilter, limit: 100);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _events = events;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _reloadEvents(String type) async {
    setState(() => _typeFilter = type);
    try {
      final events = await _service.listUsageEvents(type: type, limit: 100);
      if (!mounted) return;
      setState(() => _events = events);
    } catch (_) {
      // 过滤失败保持原列表，不打断页面。
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: UiPageBar(
        title: '积分消耗',
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.refresh, size: 20),
            tooltip: '刷新',
            onPressed: _loading ? null : () => UserRefresh.run(_load),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CupertinoActivityIndicator(radius: 13));
    }
    if (_error != null && _summary == null) {
      return _StateMessage(
        icon: CupertinoIcons.exclamationmark_triangle,
        title: '加载失败',
        subtitle: _error!,
        actionLabel: '重新加载',
        onAction: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: () => UserRefresh.run(_load),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _buildSummaryCard(context),
          const SizedBox(height: 20),
          _buildFilterRow(context),
          const SizedBox(height: 12),
          ..._buildEventList(context),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final summary = _summary;
    final totalCredits = summary?.totalCredits ?? 0;
    final balance = summary?.walletBalance ?? 0;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _metric(context, '本月消耗（积分）', '$totalCredits')),
              Expanded(child: _metric(context, '剩余积分', '$balance')),
            ],
          ),
          const SizedBox(height: 16),
          Divider(
              height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          ..._categories.map((c) => _categoryRow(context, c, summary)),
        ],
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        Text(value,
            style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface)),
      ],
    );
  }

  Widget _categoryRow(
      BuildContext context, String resourceType, BillingUsageSummary? summary) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = _enabledCategories.contains(resourceType);
    final credits = summary?.creditsFor(resourceType) ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(billingResourceLabel(resourceType),
              style: TextStyle(fontSize: 14, color: scheme.onSurface)),
          if (!enabled) ...[
            const SizedBox(width: 6),
            Text('（未启用）',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
          const Spacer(),
          // 未启用分类（数据查询/技能调用）显示 0 积分而非占位，避免用户误以为缺数据。
          Text('$credits 积分',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: enabled ? scheme.onSurface : scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildFilterRow(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: _filters.map((f) {
        final selected = f.type == _typeFilter;
        return ChoiceChip(
          label: Text(f.label),
          selected: selected,
          onSelected: (_) {
            if (!selected) _reloadEvents(f.type);
          },
        );
      }).toList(),
    );
  }

  List<Widget> _buildEventList(BuildContext context) {
    if (_events.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.only(top: 48),
          child: _StateMessage(
            icon: CupertinoIcons.doc_text,
            title: '暂无消耗记录',
            subtitle: '产生 AI 对话或通话消费后，明细会在这里展示',
          ),
        ),
      ];
    }
    return _events.map((e) => _UsageEventTile(event: e)).toList();
  }
}

class _UsageFilter {
  const _UsageFilter(this.type, this.label);
  final String type;
  final String label;
}

class _UsageEventTile extends StatelessWidget {
  const _UsageEventTile({required this.event});
  final BillingUsageEvent event;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title =
        event.displayTitle.isNotEmpty ? event.displayTitle : event.typeLabel;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _typeBadge(context, event.typeLabel),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '来源场景：${event.sceneLabel} · 模型：${event.usageModelLabel}',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                BillingUsageTooltip(
                  event: event,
                  child: Text(
                    '${_formatTime(event.occurredAt)} · ${event.accountLabel} · ${event.usageLabel}',
                    style:
                        TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text('${event.creditSign}${event.displayCreditsCost.abs()}',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface)),
        ],
      ),
    );
  }

  Widget _typeBadge(BuildContext context, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: scheme.primary)),
    );
  }
}

String _formatTime(DateTime? dt) {
  if (dt == null) return '';
  final local = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
