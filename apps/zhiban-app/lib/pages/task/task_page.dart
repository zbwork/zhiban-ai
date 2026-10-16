import 'package:zhiban_client/network/user_refresh.dart';

import 'package:zhiban_client/pages/task/services/task_navigation.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_client/pages/task/providers/task_provider.dart';
import 'package:zhiban_client/pages/task/widgets/task_feedback.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/task/models/task_models.dart';
import 'package:zhiban_client/pages/task/utils/task_utils.dart';
import 'package:zhiban_client/pages/task/widgets/task_cards.dart';
import 'widgets/task_editor_dialog.dart';
import 'package:zhiban_client/pages/task/task_editor_page.dart';
import 'package:zhiban_client/pages/task/widgets/task_skeleton.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class TaskPage extends ConsumerStatefulWidget {
  const TaskPage({super.key});

  @override
  ConsumerState<TaskPage> createState() => _TaskPageState();
}

class _TaskPageState extends ConsumerState<TaskPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(taskPageProvider.notifier);
      final loaded = ref.read(taskPageProvider).hasLoadedOnce;
      if (loaded) {
        // 进入任务页时静默拉最新数据，确保对话里通过 agent 新建/改动的任务能即时呈现。
        notifier.refresh();
      } else {
        notifier.loadIfNeeded();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final taskState = ref.watch(taskPageProvider);
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: AppBar(
        toolbarHeight: 0,
        backgroundColor: Colors.white,
        shape: const Border(bottom: BorderSide.none),
      ),
      body: SafeArea(
        child: taskState.errorMessage != null
            ? TaskLoadError(
                message: taskUserMessage(taskState.errorMessage!),
                onRetry: () => ref.read(taskPageProvider.notifier).retry(),
              )
            : (taskState.isLoading && !taskState.hasLoadedOnce)
                ? const TaskPageSkeleton()
                : TaskPageBody(
                    state: taskState,
                    compact: false,
                    openEditorAsPage: false,
                    openConversationAsPage: false,
                  ),
      ),
    );
  }
}

class TaskPageBody extends ConsumerWidget {
  const TaskPageBody({
    super.key,
    required this.state,
    required this.compact,
    required this.openEditorAsPage,
    required this.openConversationAsPage,
  });

  final TaskPageState state;
  final bool compact;
  final bool openEditorAsPage;
  final bool openConversationAsPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(taskPageProvider.notifier);
    return _TaskPageBodyContent(
      state: state,
      notifier: notifier,
      compact: compact,
      openEditorAsPage: openEditorAsPage,
      openConversationAsPage: openConversationAsPage,
    );
  }
}

class _TaskPageBodyContent extends ConsumerStatefulWidget {
  const _TaskPageBodyContent({
    required this.state,
    required this.notifier,
    required this.compact,
    required this.openEditorAsPage,
    required this.openConversationAsPage,
  });

  final TaskPageState state;
  final TaskPageNotifier notifier;
  final bool compact;
  final bool openEditorAsPage;
  final bool openConversationAsPage;

  @override
  ConsumerState<_TaskPageBodyContent> createState() =>
      _TaskPageBodyContentState();
}

class _TaskPageBodyContentState extends ConsumerState<_TaskPageBodyContent> {
  static const String _allJobsSelectValue = '__all_jobs__';
  _TaskTab _activeTab = _TaskTab.jobs;
  String? _historyJobId;

  Future<void> _openHistoryByJobId(String jobId) async {
    setState(() {
      _historyJobId = jobId;
      _activeTab = _TaskTab.history;
    });
    try {
      await ref.read(taskPageProvider.notifier).loadRuns(jobId, force: true);
    } catch (e) {
      if (!mounted) return;
      BotToast.showText(text: taskUserMessage(e));
    }
  }

  Future<void> _openRunInChat(CronRunEntry entry) =>
      openTaskRunInChat(context, ref, entry,
          asPage: widget.openConversationAsPage);

  String _historyGroupLabel(int runAtMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(runAtMs);
    final y = dt.year.toString();
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  List<Widget> _buildHistoryGroupedItems(List<CronRunEntry> entries) {
    final grouped = <String, List<CronRunEntry>>{};
    for (final entry in entries) {
      final key = _historyGroupLabel(entry.runAtMs);
      grouped.putIfAbsent(key, () => <CronRunEntry>[]).add(entry);
    }

    final widgets = <Widget>[];
    final keys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final key in keys) {
      final list = grouped[key]!;
      widgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 8),
          child: Text(
            key,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF475467),
            ),
          ),
        ),
      );
      widgets.addAll(
        list.map(
          (entry) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TaskRunEntryTile(
              entry: entry,
              backgroundColor: Colors.white,
              onOpenInChat: () => _openRunInChat(entry),
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final notifier = widget.notifier;

    final screenWidth = MediaQuery.sizeOf(context).width;
    // 520px 以下切单列窄屏布局。
    final isNarrow = screenWidth < 520;
    final hPad = isNarrow ? 16.0 : 24.0;

    final managedAgents =
        ref.watch(agentsProvider).asData?.value ?? const <AgentItem>[];
    final selectableAgents = ref.watch(taskSelectableAgentsProvider);
    // 联系人目录是完整业务候选；只有目录失败时才降级保留“我创建的”列表。
    // value 会在 refresh 期间保留上一份快照，避免下拉闪空。
    final agents = selectableAgents.value ?? managedAgents;
    final conversations = ref.watch(conversationsProvider).asData?.value ??
        const <ConversationItem>[];
    final agentNameById = <String, String>{
      for (final a in agents) a.agentId: a.name,
    };

    Future<void> openEditor([CronJob? job]) async {
      if (selectableAgents.isLoading && selectableAgents.value == null) {
        BotToast.showText(text: '正在加载数字员工，请稍后再试');
        return;
      }
      if (selectableAgents.hasError && selectableAgents.value == null) {
        BotToast.showText(text: '数字员工目录加载失败，当前仅显示我创建的员工，请刷新后重试');
      }
      final CronJobDraft? draft;
      if (widget.openEditorAsPage) {
        draft = await context.push<CronJobDraft>(
          RoutePaths.taskEditor,
          extra: TaskEditorPageArgs(
            job: job,
            agents: agents,
            conversations: conversations,
          ),
        );
      } else {
        draft = await showDialog<CronJobDraft>(
          context: context,
          builder: (context) => TaskEditorDialog(
            job: job,
            agents: agents,
            conversations: conversations,
          ),
        );
      }
      if (draft == null) return;
      await notifier.saveDraft(draft, jobId: job?.id);
    }

    return Column(
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(
            hPad,
            widget.compact ? 0 : 16,
            hPad,
            widget.compact ? 4 : 12,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            border: widget.compact
                ? null
                : const Border(
                    bottom: BorderSide(color: Color(0xFFEFF1F5)),
                  ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _TaskTabs(
                  activeTab: _activeTab,
                  onChanged: (next) => setState(() {
                    _activeTab = next;
                    if (next != _TaskTab.history) {
                      _historyJobId = null;
                    }
                  }),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (state.isRefreshing)
                    const Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: CupertinoActivityIndicator(radius: 8),
                    ),
                  _GhostButton(
                    compact: widget.compact,
                    icon: CupertinoIcons.refresh,
                    label: '刷新',
                    onPressed: () => UserRefresh.run(() async {
                      ref.invalidate(taskSelectableAgentsProvider);
                      await Future.wait([
                        ref.read(taskSelectableAgentsProvider.future),
                        ref.read(taskPageProvider.notifier).refresh(),
                      ]);
                    }),
                  ),
                  const SizedBox(width: 8),
                  _GhostButton(
                    compact: widget.compact,
                    icon: CupertinoIcons.add,
                    label: '新建',
                    onPressed: () => openEditor(),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (_activeTab == _TaskTab.history) {
                final historyEntries = _historyJobId == null
                    ? state.recentRuns
                    : (state.runsByJob[_historyJobId!] ??
                        const <CronRunEntry>[]);
                final isLoadingRuns = _historyJobId != null &&
                    state.loadingRunJobIds.contains(_historyJobId);

                Future<void> handleJobChange(String value) async {
                  final nextId = value == _allJobsSelectValue ? null : value;
                  setState(() => _historyJobId = nextId);
                  if (nextId != null) {
                    await ref
                        .read(taskPageProvider.notifier)
                        .loadRuns(nextId, force: true);
                  }
                }

                return ListView(
                  padding: EdgeInsets.fromLTRB(hPad, 0, hPad, hPad),
                  children: [
                    _HistoryJobSelect(
                      value: _historyJobId ?? _allJobsSelectValue,
                      historyJobs: state.historyJobs,
                      onChanged: handleJobChange,
                    ),
                    const SizedBox(height: 12),
                    if (isLoadingRuns)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: CupertinoActivityIndicator(radius: 12),
                        ),
                      )
                    else if (historyEntries.isEmpty)
                      const TaskTasksEmptyState()
                    else
                      ..._buildHistoryGroupedItems(historyEntries),
                  ],
                );
              }

              if (state.jobs.isEmpty) {
                return ListView(
                  padding: EdgeInsets.fromLTRB(hPad, 0, hPad, hPad),
                  children: const [TaskTasksEmptyState()],
                );
              }

              // 任务与数字员工目录并行加载。任务先回来时不能把尚未解析到的
              // 组织员工 UUID 当成“默认数字员工”；首轮等权威目录再画任务卡。
              if (selectableAgents.isLoading &&
                  selectableAgents.value == null) {
                return const Center(
                  child: CupertinoActivityIndicator(radius: 12),
                );
              }

              // 窄屏（< 520px）：单列全宽卡片；宽屏：双列带间距。
              final spacing = isNarrow ? 0.0 : 16.0;
              final cardWidth = isNarrow
                  ? constraints.maxWidth - hPad * 2
                  : (constraints.maxWidth - hPad * 2 - spacing) / 2;
              final contentWidth = constraints.maxWidth - hPad * 2;
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(hPad, 0, hPad, hPad),
                child: SizedBox(
                  width: contentWidth,
                  child: Wrap(
                    spacing: spacing,
                    runSpacing: isNarrow ? 12.0 : spacing,
                    children: state.jobs.map((job) {
                      // ValueKey 是关键：列表按 updated_at DESC 排序，每次
                      // toggle 都会把当前任务推到首位，没 key 时 Flutter 按
                      // 位置 diff 复用上一个位置的 widget element——CupertinoSwitch
                      // 内部的 AnimationController 状态会错位继承，造成
                      // "点 A 的开关 B 也跟着动 / 描述显示成另一个任务的"。
                      // 用 jobId 当 key 后 Flutter 能正确把同一 widget element
                      // 跟着 job 移动，子树状态一直绑定在正确的 job 上。
                      return SizedBox(
                        key: ValueKey<String>('task-job-${job.id}'),
                        width: cardWidth,
                        child: TaskJobCard(
                          job: job,
                          expanded: false,
                          runs: const <CronRunEntry>[],
                          busy: state.busyJobIds.contains(job.id),
                          loadingRuns: false,
                          agentName: agentNameById[job.agentId],
                          onToggleEnabled: (value) =>
                              notifier.toggleEnabled(job, value),
                          onRunNow: () => notifier.runNow(job.id),
                          onEdit: () => openEditor(job),
                          onDelete: () => _confirmDelete(context, () {
                            ref
                                .read(taskPageProvider.notifier)
                                .deleteJob(job.id);
                          }),
                          onToggleExpanded: () => _openHistoryByJobId(job.id),
                        ),
                      );
                    }).toList(growable: false),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

enum _TaskTab { jobs, history }

class _TaskTabs extends StatelessWidget {
  const _TaskTabs({required this.activeTab, required this.onChanged});

  final _TaskTab activeTab;
  final ValueChanged<_TaskTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return UiUnderlineTabs<_TaskTab>(
      current: activeTab,
      onChanged: onChanged,
      spacing: 24,
      horizontalPadding: 0,
      topPadding: 0,
      // 页头容器已画全宽底边线; 组件默认的桌面底边线会叠成两根 (2026-06-12 反馈)。
      showBottomBorder: false,
      activeColor: const Color(0xFF3361F0),
      inactiveColor: const Color(0xFF98A2B3),
      fontSize: 15,
      tabs: const [
        UiUnderlineTab(value: _TaskTab.jobs, label: '任务列表'),
        UiUnderlineTab(value: _TaskTab.history, label: '历史任务'),
      ],
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.compact,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final bool compact;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF475467),
        side: compact
            ? BorderSide.none
            : const BorderSide(color: Color(0xFFE4E7EC)),
        backgroundColor: compact ? Colors.transparent : Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}

class _HistoryJobSelect extends StatelessWidget {
  const _HistoryJobSelect({
    required this.value,
    required this.historyJobs,
    required this.onChanged,
  });

  final String value;

  /// 历史 tab 下拉的任务列表，从当前可见 jobs 派生（Bus F08 暂无 distinct
  /// endpoint，已删除任务暂不出现在下拉；其运行记录仍可在「全部任务」里看到）。
  final List<CronJobDistinctEntry> historyJobs;

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = <UiSelectOption<String>>[
      const UiSelectOption<String>(value: '__all_jobs__', label: '全部任务'),
      ...historyJobs.map((j) {
        final base = j.name.trim().isEmpty ? j.jobId : j.name.trim();
        return UiSelectOption<String>(value: j.jobId, label: base);
      }),
    ];

    final hasValue = options.any((item) => item.value == value);
    return SizedBox(
      width: 280,
      child: UiSelect<String>(
        value: hasValue ? value : '__all_jobs__',
        onChanged: (next) {
          if (next == null) return;
          onChanged(next);
        },
        placeholder: '选择任务',
        options: options,
      ),
    );
  }
}

Future<void> _confirmDelete(
  BuildContext context,
  VoidCallback onConfirm,
) async {
  final ok = await showUiConfirmDialog(
    context,
    title: '删除任务',
    description: '删除后将无法恢复，确认继续吗？',
    confirmLabel: '删除',
    danger: true,
  );
  if (ok) onConfirm();
}
