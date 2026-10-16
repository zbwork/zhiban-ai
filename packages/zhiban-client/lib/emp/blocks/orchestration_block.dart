// F09 Phase B PR7 (B3-08): 协作编排 EMP block 渲染器.
//
// 由 IM payload 中 emp_block_registry.code='orchestration' 的 block 解码后传入:
//   - 默认折叠: "💼 幕后协作 (N 步) ▶"
//   - 展开后步骤时序: role + agent_name + status + tokens
//   - 末行汇总: 总 tokens_in/out + 总 latency
//
// 输入是 Map<String, dynamic>(已经 jsonDecode), 字段定义见 migration 000127:
//   plan_summary: String
//   steps: List<{step_index, role, agent_name?, agent_uuid?, status,
//                input_summary?, output_summary?, tokens_in?, tokens_out?,
//                started_at?, completed_at?, error_message?}>
//   default_collapsed: bool (默认 true)
//   total_tokens_in/out/latency_ms: 可选
//
// 不在 PR7 范围 (留 follow-up):
//   - 完整的 EMP block dispatcher (本 widget 是独立可挂接的; IM 消息解码层未来再接).
//   - 国际化 (l10n); 当前文案硬编码中文, 与产品口径一致.

import 'package:flutter/material.dart';

/// 协作编排 block 渲染器.
class OrchestrationBlock extends StatefulWidget {
  /// 解码后的 EMP block data 字段 (不含外层 type/code).
  ///
  /// 期望 schema:
  /// ```json
  /// {
  ///   "plan_summary": "...",
  ///   "steps": [{...}],
  ///   "default_collapsed": true,
  ///   "total_tokens_in": 0,
  ///   "total_tokens_out": 0,
  ///   "total_latency_ms": 0
  /// }
  /// ```
  final Map<String, dynamic> data;

  const OrchestrationBlock({super.key, required this.data});

  @override
  State<OrchestrationBlock> createState() => _OrchestrationBlockState();
}

class _OrchestrationBlockState extends State<OrchestrationBlock> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    // default_collapsed=true → 折叠; false → 展开. schema 未传时默认折叠.
    final collapsed = widget.data['default_collapsed'] as bool? ?? true;
    _expanded = !collapsed;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = (widget.data['steps'] as List?) ?? const [];
    final planSummary = (widget.data['plan_summary'] as String?) ?? '';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(theme, steps.length),
          if (_expanded) ...[
            const Divider(height: 1),
            if (planSummary.isNotEmpty) _planSummaryRow(theme, planSummary),
            ...steps.map((s) => _stepRow(theme, s as Map<String, dynamic>)),
            _totalsRow(theme),
          ],
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, int stepCount) {
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const Text('💼 '),
            Text(
              '幕后协作 ($stepCount 步)',
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: theme.iconTheme.color?.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }

  Widget _planSummaryRow(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  Widget _stepRow(ThemeData theme, Map<String, dynamic> step) {
    final idx = step['step_index'];
    final role = (step['role'] as String?) ?? '?';
    final agentName = (step['agent_name'] as String?) ?? '?';
    final status = (step['status'] as String?) ?? 'pending';
    final tokensIn = step['tokens_in'] as int?;
    final tokensOut = step['tokens_out'] as int?;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          // index
          SizedBox(
            width: 24,
            child: Text(
              '#$idx',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          // role chip
          _roleChip(theme, role),
          const SizedBox(width: 8),
          // agent name
          Expanded(
            child: Text(
              agentName,
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // status badge
          _statusBadge(theme, status),
          const SizedBox(width: 8),
          // tokens (只在两者皆有时显示)
          if (tokensIn != null && tokensOut != null)
            Text(
              '${tokensIn + tokensOut} tk',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
        ],
      ),
    );
  }

  Widget _roleChip(ThemeData theme, String role) {
    // 简短中文化, 不引入 l10n.
    const labels = {
      'planner': '规划',
      'worker': '执行',
      'reducer': '汇总',
      'validator': '校验',
    };
    final label = labels[role] ?? role;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.primary,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _statusBadge(ThemeData theme, String status) {
    Color color;
    String text;
    switch (status) {
      case 'done':
        color = Colors.green.shade600;
        text = '✓';
        break;
      case 'failed':
        color = Colors.red.shade600;
        text = '✗';
        break;
      case 'running':
        color = Colors.blue.shade600;
        text = '…';
        break;
      case 'skipped':
        color = Colors.grey.shade500;
        text = '⊘';
        break;
      case 'pending':
      default:
        color = Colors.grey.shade400;
        text = '○';
    }
    return Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold));
  }

  Widget _totalsRow(ThemeData theme) {
    final tokIn = widget.data['total_tokens_in'] as int?;
    final tokOut = widget.data['total_tokens_out'] as int?;
    final latency = widget.data['total_latency_ms'] as int?;
    final parts = <String>[];
    if (latency != null && latency > 0) {
      parts.add(_formatLatency(latency));
    }
    if (tokIn != null || tokOut != null) {
      final inV = tokIn ?? 0;
      final outV = tokOut ?? 0;
      parts.add('${inV + outV} tokens');
    }
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Row(
        children: [
          const Spacer(),
          Text(
            parts.join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  String _formatLatency(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }
}
