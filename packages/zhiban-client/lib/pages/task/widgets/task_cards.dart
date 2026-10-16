import 'package:zhiban_client/pages/task/models/task_models.dart';
import 'package:zhiban_client/pages/task/utils/task_utils.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

String taskAgentDisplayLabel(String? agentName) {
  final normalized = (agentName ?? '').trim();
  return normalized.isEmpty ? '数字员工信息暂不可用' : normalized;
}

class TaskOverviewCard extends StatelessWidget {
  const TaskOverviewCard({
    required this.label,
    required this.value,
    required this.accent,
    super.key,
  });

  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE7ECF5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Color(0xFF162033),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF667085)),
          ),
        ],
      ),
    );
  }
}

class TaskJobCard extends StatelessWidget {
  const TaskJobCard({
    required this.job,
    required this.expanded,
    required this.runs,
    required this.busy,
    required this.loadingRuns,
    required this.onToggleEnabled,
    required this.onRunNow,
    this.onEdit,
    required this.onDelete,
    required this.onToggleExpanded,
    this.agentName,
    super.key,
  });

  final CronJob job;
  final bool expanded;
  final List<CronRunEntry> runs;
  final bool busy;
  final bool loadingRuns;
  final ValueChanged<bool> onToggleEnabled;
  final VoidCallback onRunNow;

  /// 编辑回调；为空时菜单里不显示「编辑」项。
  /// 当前 ai-office 只支持在对话框里创建/调整任务，列表页不暴露编辑入口。
  final VoidCallback? onEdit;
  final VoidCallback onDelete;
  final VoidCallback onToggleExpanded;
  final String? agentName;

  String _nextRunLabelText() {
    if (!job.enabled) return '最近执行';
    final last = job.state.lastRunAtMs ?? 0;
    final next = job.state.nextRunAtMs ?? 0;
    if (next > 0) return '下次执行';
    if (last > 0) return '最近执行';
    return '下次执行';
  }

  DateTime? _nextRunDateTime() {
    final next = job.state.nextRunAtMs ?? 0;
    final last = job.state.lastRunAtMs ?? 0;
    final ms = job.enabled && next > 0 ? next : last;
    if (ms <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  // 跨天加日期语义, 避免「明天 09:00」被看成今天的过期时间 (2026-06-12 反馈)。
  // 前缀单独一行小字展示, 不并入大号时间——右栏只有 100 宽, 并排会溢出。
  String _nextRunDayPrefix() {
    final dt = _nextRunDateTime();
    if (dt == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = DateTime(dt.year, dt.month, dt.day).difference(today).inDays;
    if (diff == 0) return '';
    if (diff == 1) return '明天';
    if (diff == -1) return '昨天';
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  String _nextRunTimeText() {
    final dt = _nextRunDateTime();
    if (dt == null) return '—';
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// 单次任务状态：图标 + 文案一行展示，紧凑，不占额外一行。
  Widget _runOnceStatusRow() {
    final executed = !job.enabled && (job.state.lastRunAtMs ?? 0) > 0;
    final color = executed ? const Color(0xFF12B76A) : const Color(0xFF98A2B3);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          executed ? Icons.check_circle : CupertinoIcons.clock,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 4),
        // 默认字体行高比字形本身高一截，跟 14px 图标用 CrossAxisAlignment.center
        // 对齐时视觉上文字会偏低；height:1.0 把行高收紧到贴合字形，两者才是真的
        // 视觉居中。
        Text(
          executed ? '已执行' : '单次执行',
          style: TextStyle(fontSize: 12, color: color, height: 1.0),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final lastOk = (job.state.lastRunStatus ?? '') == 'ok' &&
        (job.state.lastRunAtMs ?? 0) > 0 &&
        (job.state.nextRunAtMs ?? 0) <= 0;

    final agentLabel = taskAgentDisplayLabel(agentName);
    final scheduleLabel = taskScheduleLabel(job);

    return Stack(
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 148),
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14152647),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    job.name.isEmpty ? '未命名任务' : job.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF1D2939),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    job.payload.displayText.isEmpty
                                        ? (job.description.isEmpty
                                            ? '未填写执行内容'
                                            : job.description)
                                        : job.payload.displayText,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      height: 1.55,
                                      color: Color(0xFF667085),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _TaskMetaChip(
                            icon: CupertinoIcons.person,
                            label: agentLabel,
                          ),
                          _TaskMetaChip(
                            icon: CupertinoIcons.clock,
                            label: scheduleLabel,
                            // 单次执行标签比「每天 HH:MM」这类固定频率文案长
                            // （形如「8月25日 14:46 执行一次」），沿用 110 的默
                            // 认宽度会被省略号截断到看不出日期，故单独放宽。
                            maxWidth: 180,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  color: const Color(0xFFEFF1F5),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 100,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 32),
                      // 占满开关区和按钮区之间剩下的高度，并在这块空间里垂直居中——
                      // 之前直接把内容摆在固定 40px 间距下面，卡片变高（比如两行
                      // 描述换成一行）时内容会贴在顶部，跟按钮之间空出一大截。
                      Expanded(
                        child: Center(
                          child: !job.enabled &&
                                  (job.requiresResume ||
                                      !job.canToggle ||
                                      !job.runOnce)
                              ? Text(job.schedulingStatusLabel,
                                  textAlign: TextAlign.center)
                              : job.runOnce
                                  ? _runOnceStatusRow()
                                  : Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Text(
                                          _nextRunLabelText(),
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF98A2B3),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        if (_nextRunDayPrefix().isNotEmpty) ...[
                                          Text(
                                            _nextRunDayPrefix(),
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF475467),
                                              height: 1.1,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                        ],
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              _nextRunTimeText(),
                                              style: const TextStyle(
                                                fontSize: 26,
                                                fontWeight: FontWeight.w700,
                                                color: Color(0xFF1D2939),
                                                letterSpacing: 0.2,
                                                height: 1.1,
                                              ),
                                            ),
                                            if (lastOk) ...[
                                              const SizedBox(width: 4),
                                              const Icon(
                                                Icons.check_circle,
                                                size: 14,
                                                color: Color(0xFF12B76A),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ],
                                    ),
                        ),
                      ),
                      Visibility(
                        visible: job.canRunNow,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: _RunNowButton(
                          busy: busy,
                          onPressed: busy ? null : onRunNow,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 启用/禁用开关：禁用 = 暂停调度但保留任务记录，与「删除」（软删 + 移出
              // 任务列表）不同。busy 期间禁掉开关避免乐观切换打架。
              _TaskEnabledSwitch(
                enabled: job.enabled,
                onChanged: busy || !job.canToggle ? null : onToggleEnabled,
              ),
              const SizedBox(width: 4),
              _TaskMoreMenu(
                onEdit: onEdit,
                onDelete: busy ? null : onDelete,
                onHistory: onToggleExpanded,
                historyLabel: expanded ? '收起历史' : '查看历史',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TaskEnabledSwitch extends StatelessWidget {
  const _TaskEnabledSwitch({
    required this.enabled,
    required this.onChanged
  });

  final bool enabled;
  // null 时 Switch 自身置灰且不可交互（busy 中）。
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: enabled ? '已启用，点击暂停' : '已暂停，点击启用',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Transform.scale(
          // CupertinoSwitch 默认偏大（51x31），列表卡片右上角空间紧凑，缩到 0.7
          // 视觉对得上「更多」按钮的高度，且不抢主标题视觉。
          scale: 0.7,
          child: CupertinoSwitch(
            value: enabled,
            activeTrackColor: const Color(0xFF3361F0),
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}

class _TaskMetaChip extends StatelessWidget {
  const _TaskMetaChip({
    required this.icon,
    required this.label,
    this.maxWidth = 110,
  });
  final IconData icon;
  final String label;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFEAEEF7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: const Color(0xFF7A8499)),
          const SizedBox(width: 2),
          // maxWidth 只是上限，实际可用宽度由外层 Wrap/父容器给的约束决定；
          // 用 Flexible 兜底真正可用空间不足 maxWidth 的场景，避免几像素级溢出
          // （2026-08-25 实测：单次执行长文案在个别卡片宽度下溢出 0.69px）。
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF54607A),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskMoreMenu extends StatelessWidget {
  const _TaskMoreMenu({
    this.onEdit,
    required this.onDelete,
    required this.onHistory,
    required this.historyLabel,
  });

  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback onHistory;
  final String historyLabel;

  @override
  Widget build(BuildContext context) {
    return UiDropdownMenu<String>(
      menuWidth: 140,
      hoverRadius: 8,
      items: [
        if (onEdit != null)
          const UiDropdownMenuItem(
            value: 'edit',
            label: '编辑',
            icon: CupertinoIcons.pencil,
          ),
        UiDropdownMenuItem(
          value: 'history',
          label: historyLabel,
          icon: CupertinoIcons.clock,
        ),
        if (onDelete != null)
          const UiDropdownMenuItem(
            value: 'delete',
            label: '删除',
            icon: CupertinoIcons.delete,
            danger: true,
          ),
      ],
      onSelected: (value) {
        switch (value) {
          case 'edit':
            onEdit?.call();
          case 'history':
            onHistory();
          case 'delete':
            onDelete?.call();
        }
      },
      child: const SizedBox(
        width: 32,
        height: 32,
        child: Icon(
          Icons.more_vert_rounded,
          size: 18,
          color: Color(0xFF98A2B3),
        ),
      ),
    );
  }
}

class _RunNowButton extends StatelessWidget {
  const _RunNowButton({required this.busy, required this.onPressed});
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 100,
      height: 34,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF3361F0),
          foregroundColor: Colors.white,
          // FilledButton 在 onPressed=null 时默认会把背景渲染成 Material 自带
          // disabled 灰，跟 loading 状态语义不一致（视觉上像"任务被禁用了"）。
          // 显式声明 disabled 时仍保持品牌蓝，spinner 在白底蓝上 → 蓝底白上：
          //   • backgroundColor 加点透明度（0.85）暗示「点了，正在做」；
          //   • foregroundColor 同样保持白，让 CupertinoActivityIndicator 看清。
          disabledBackgroundColor:
              const Color(0xFF3361F0).withValues(alpha: 0.85),
          disabledForegroundColor: Colors.white,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8)
          ),
          textStyle: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        onPressed: onPressed,
        child: busy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CupertinoActivityIndicator(
                  radius: 7,
                  color: Colors.white,
                ),
              )
            : const Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.play_arrow_rounded, size: 16),
                  SizedBox(width: 4),
                  Text('立即执行'),
                ],
              ),
      ),
    );
  }
}

class TaskRecentRunsPanel extends StatelessWidget {
  const TaskRecentRunsPanel({required this.entries, super.key});

  final List<CronRunEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE4E7EC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (entries.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Text(
                '还没有运行记录，创建并执行一个任务后就会出现在这里。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: Color(0xFF667085),
                ),
              ),
            )
          else
            ...entries.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TaskRunEntryTile(
                  entry: entry,
                  backgroundColor: const Color(0xFFF8FAFC),
                  darkStyle: false,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class TaskRunEntryTile extends StatelessWidget {
  const TaskRunEntryTile({
    required this.entry,
    this.backgroundColor = Colors.white,
    this.darkStyle = false,
    this.onOpenInChat,
    super.key,
  });

  final CronRunEntry entry;
  final Color backgroundColor;
  final bool darkStyle;
  final VoidCallback? onOpenInChat;

  String _timeText() {
    final ms = entry.runAtMs;
    if (ms <= 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$h:$min';
  }

  ({String label, Color background, Color foreground, IconData icon})
      _statusVisual(BuildContext context) {
    switch (entry.status) {
      case 'cancelled':
        final scheme = Theme.of(context).colorScheme;
        return (
          label: '已停止',
          background: scheme.surfaceContainerHighest,
          foreground: scheme.onSurfaceVariant,
          icon: CupertinoIcons.stop_circle,
        );
      case 'ok':
      case 'success':
      case 'succeeded':
      case 'completed':
        return (
          label: '执行成功',
          background: const Color(0xFFE8F8F2),
          foreground: const Color(0xFF12B76A),
          icon: Icons.check_circle_rounded,
        );
      // 2026-06-12 run 终态语义: run 在 agent 回复终态前保持 running/queued → 执行中。
      case 'running':
      case 'queued':
      case 'pending':
        return (
          label: '执行中',
          background: const Color(0xFFFFF4E1),
          foreground: const Color(0xFFE08A1F),
          icon: Icons.sync_rounded,
        );
      default:
        return (
          label: '执行失败',
          background: const Color(0xFFFFF1EF),
          foreground: const Color(0xFFB42318),
          icon: Icons.cancel_rounded,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final visual = _statusVisual(context);
    final bodyText = entry.displaySummary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: backgroundColor == Colors.white
            ? const [
                BoxShadow(
                  color: Color(0x0A1B2A4E),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: visual.background,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(visual.icon, size: 18, color: visual.foreground),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        entry.jobName.trim().isEmpty
                            ? '未命名任务'
                            : entry.jobName.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1D2939),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: visual.background,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        visual.label,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: visual.foreground,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _timeText(),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF98A2B3),
                      ),
                    ),
                  ],
                ),
                if (bodyText.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    bodyText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.55,
                      // 只有真出错（带错误信息）才红色; 执行中/成功的提示词正文统一灰色
                      // (2026-06-12 反馈: 执行中条目的提示词被误染红)。
                      color: entry.isCancelled
                          ? visual.foreground
                          : entry.hasDisplayError
                              ? const Color(0xFFB42318)
                              : const Color(0xFF667085),
                    ),
                  ),
                ],
                if (onOpenInChat != null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: onOpenInChat,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Text(
                            '在对话中查看',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF3361F0),
                            ),
                          ),
                          SizedBox(width: 2),
                          Icon(
                            Icons.arrow_forward_rounded,
                            size: 12,
                            color: Color(0xFF3361F0),
                          ),
                        ],
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
}

class TaskStatusBadge extends StatelessWidget {
  const TaskStatusBadge({
    required this.label,
    required this.background,
    required this.foreground,
    super.key,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }
}

class TaskTasksEmptyState extends StatelessWidget {
  const TaskTasksEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 56, 28, 56),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A1B2A4E),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: const Column(
        children: [
          Icon(CupertinoIcons.sparkles, size: 32, color: Color(0xFF3361F0)),
          SizedBox(height: 14),
          Text(
            '还没有任务',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1D2939),
            ),
          ),
          SizedBox(height: 8),
          Text(
            '创建一个定时任务，让数字员工按你的节奏自动执行提醒、摘要或巡检工作。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: Color(0xFF667085),
            ),
          ),
        ],
      ),
    );
  }
}
