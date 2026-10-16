import 'package:zhiban_core/utils/error_utils.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_providers.dart';
import 'package:zhiban_client/pages/task/models/task_models.dart';
import 'package:zhiban_client/pages/task/services/task_service.dart';
import 'package:zhiban_client/pages/task/utils/task_utils.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final taskServiceProvider = Provider<BusTaskService>(
  (ref) => BusTaskService()
);

/// 自动任务需要的是“当前用户可对话的数字员工”，不是仅供管理场景使用的
/// `/agents?mine=1`。这里直接读取空关键词联系人快照，避免继承数字员工页面
/// 残留的搜索词；个人员工排在组织员工前，并按 UUID 去重。
final taskSelectableAgentsProvider =
    FutureProvider<List<AgentItem>>((ref) async {
  final snapshot = await ref.read(contactsServiceProvider).agents();
  return taskSelectableAgentsFromSnapshot(snapshot);
});

List<AgentItem> taskSelectableAgentsFromSnapshot(
  ContactAgentsSnapshot snapshot, {
  bool cloudEnabled = AppConfig.cloudAgentCreationEnabled,
}) {
  final agentsById = <String, AgentItem>{};
  for (final contact in snapshot.all) {
    final agentId = contact.id.trim();
    if (agentId.isEmpty || !contact.canChat) continue;
    if (!cloudEnabled && contact.executionLocus != 'local') continue;
    agentsById.putIfAbsent(agentId, contact.toAgentItem);
  }
  return List<AgentItem>.unmodifiable(agentsById.values);
}

final taskPageProvider = NotifierProvider<TaskPageNotifier, TaskPageState>(
  TaskPageNotifier.new,
);

class TaskPageState {
  const TaskPageState({
    required this.jobs,
    required this.recentRuns,
    required this.runsByJob,
    required this.historyJobs,
    required this.expandedJobIds,
    required this.busyJobIds,
    required this.loadingRunJobIds,
    required this.isRefreshing,
    required this.isLoading,
    required this.hasLoadedOnce,
    this.errorMessage,
  });

  final List<CronJob> jobs;
  final List<CronRunEntry> recentRuns;
  final Map<String, List<CronRunEntry>> runsByJob;

  /// 历史 tab 下拉用：账号下所有出现过的任务（含 OpenClaw 已删除的）。
  /// 由 GET /cron/jobs/distinct 返回，跟 [jobs]（活跃任务）相补，
  /// 删除的任务带 deleted=true 标识。
  final List<CronJobDistinctEntry> historyJobs;

  final Set<String> expandedJobIds;
  final Set<String> busyJobIds;
  final Set<String> loadingRunJobIds;
  final bool isRefreshing;
  final bool isLoading;
  final bool hasLoadedOnce;
  final String? errorMessage;

  factory TaskPageState.initial() {
    return const TaskPageState(
      jobs: [],
      recentRuns: [],
      runsByJob: {},
      historyJobs: [],
      expandedJobIds: <String>{},
      busyJobIds: <String>{},
      loadingRunJobIds: <String>{},
      isRefreshing: false,
      isLoading: false,
      hasLoadedOnce: false,
      errorMessage: null,
    );
  }

  TaskPageState copyWith({
    List<CronJob>? jobs,
    List<CronRunEntry>? recentRuns,
    Map<String, List<CronRunEntry>>? runsByJob,
    List<CronJobDistinctEntry>? historyJobs,
    Set<String>? expandedJobIds,
    Set<String>? busyJobIds,
    Set<String>? loadingRunJobIds,
    bool? isRefreshing,
    bool? isLoading,
    bool? hasLoadedOnce,
    String? errorMessage,
    bool clearError = false,
  }) {
    return TaskPageState(
      jobs: jobs ?? this.jobs,
      recentRuns: recentRuns ?? this.recentRuns,
      runsByJob: runsByJob ?? this.runsByJob,
      historyJobs: historyJobs ?? this.historyJobs,
      expandedJobIds: expandedJobIds ?? this.expandedJobIds,
      busyJobIds: busyJobIds ?? this.busyJobIds,
      loadingRunJobIds: loadingRunJobIds ?? this.loadingRunJobIds,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      isLoading: isLoading ?? this.isLoading,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  CronJobsOverview get overview {
    final enabledCount = jobs.where((e) => e.enabled).length;
    final healthy = jobs
        .where((e) => (e.state.lastRunStatus ?? '') == 'ok' && e.enabled)
        .length;
    final errors = jobs
        .where(
          (e) =>
              (e.state.lastRunStatus ?? '') == 'error' ||
              e.state.consecutiveErrors > 0,
        )
        .length;
    return CronJobsOverview(
      total: jobs.length,
      enabled: enabledCount,
      runningHealthy: healthy,
      withErrors: errors,
    );
  }
}

class TaskPageNotifier extends Notifier<TaskPageState> {
  @override
  TaskPageState build() => TaskPageState.initial();

  Future<void> loadIfNeeded() async {
    if (state.isLoading || state.hasLoadedOnce) {
      return;
    }
    await load();
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    final service = ref.read(taskServiceProvider);
    try {
      // jobs 与 recent runs 互相独立，并行拉取（此前串行等待）；
      // runs 的 jobName 回填依赖 jobs，放在两者都返回后做。
      final (jobs, rawRuns) = await _loadJobsAndRecentRuns(service);
      final recentRuns = _withJobNames(rawRuns, jobs);
      // 历史 tab 下拉直接从已拉取的 jobs 派生（Bus F08 暂无 distinct endpoint，
      // 之前调 listJobsDistinct 会把同一份 /cron/jobs 再打一次）。
      final historyJobs =
          jobs.map(CronJobDistinctEntry.fromJob).toList(growable: false);
      state = state.copyWith(
        jobs: jobs,
        recentRuns: recentRuns,
        historyJobs: historyJobs,
        isLoading: false,
        hasLoadedOnce: true,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        hasLoadedOnce: true,
        errorMessage: isTransientNetworkError(e) ? null : taskUserMessage(e),
        clearError: isTransientNetworkError(e),
      );
    }
  }

  Future<void> refresh() async {
    state = state.copyWith(isRefreshing: true, clearError: true);
    final service = ref.read(taskServiceProvider);
    try {
      final (jobs, rawRuns) = await _loadJobsAndRecentRuns(service);
      final recentRuns = _withJobNames(rawRuns, jobs);
      final historyJobs =
          jobs.map(CronJobDistinctEntry.fromJob).toList(growable: false);
      final nextRunsByJob = <String, List<CronRunEntry>>{};
      for (final jobId in state.expandedJobIds) {
        nextRunsByJob[jobId] = await service.listJobRuns(jobId, limit: 10);
      }
      state = state.copyWith(
        jobs: jobs,
        recentRuns: recentRuns,
        runsByJob: nextRunsByJob,
        historyJobs: historyJobs,
        isRefreshing: false,
        hasLoadedOnce: true,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        isRefreshing: false,
        errorMessage: isTransientNetworkError(e) ? null : taskUserMessage(e),
        clearError: isTransientNetworkError(e),
        hasLoadedOnce: true,
      );
    }
  }

  Future<void> retry() async {
    state = state.copyWith(hasLoadedOnce: false, clearError: true);
    await load();
  }

  Future<void> saveDraft(CronJobDraft draft, {String? jobId}) async {
    final busy = {...state.busyJobIds, jobId ?? '__create__'};
    state = state.copyWith(busyJobIds: busy);
    final service = ref.read(taskServiceProvider);
    try {
      if (jobId == null) {
        await service.createJob(draft);
        BotToast.showText(text: '任务已创建');
      } else {
        await service.updateJob(jobId, draft);
        BotToast.showText(text: '任务已更新');
      }
      await refresh();
    } catch (error) {
      BotToast.showText(text: taskUserMessage(error));
    } finally {
      final reduced = {...state.busyJobIds}..remove(jobId ?? '__create__');
      state = state.copyWith(busyJobIds: reduced);
    }
  }

  Future<void> toggleEnabled(CronJob job, bool enabled) async {
    // 乐观更新：CupertinoSwitch 是受控组件，onChanged 后必须立刻喂入新 value，
    // 否则动画结束会回弹到旧值（用户感觉"点了没反应、要点两次"）。这里先把
    // state.jobs 里这条 job 的 enabled 翻成目标值，UI 立刻翻；HTTP 失败再回滚
    // 并以服务端最新状态为准（refresh）。
    //
    // 同时联动 state.nextRunAtMs：禁用任务时把"下次执行"立刻清空，否则开关
    // OFF 但右侧时间停留在旧值，得等 refresh 才变 "—"，看起来像 bug。启用时
    // 不直接乐观算（避免本地时间/时区漂移），等服务端 refresh 算回来。
    final optimisticState = enabled ? job.state : const CronState();
    final patched = state.jobs
        .map((j) => j.id == job.id
            ? j.copyWith(
                enabled: enabled,
                state: optimisticState,
                status: enabled ? 'active' : 'paused')
            : j)
        .toList(growable: false);
    state = state.copyWith(jobs: patched);
    try {
      await _withBusy(job.id, () async {
        await ref.read(taskServiceProvider).updateJobEnabled(job.id, enabled);
        BotToast.showText(text: enabled ? '任务已启用' : '任务已停用');
        await refresh();
      });
    } catch (_) {
      await refresh();
      rethrow;
    }
  }

  Future<void> runNow(String jobId) async {
    await _withBusy(jobId, () async {
      await ref.read(taskServiceProvider).runJobNow(jobId);
      BotToast.showText(text: '已触发执行');
      await refresh();
      await loadRuns(jobId, force: true);
    });
  }

  Future<void> deleteJob(String jobId) async {
    await _withBusy(jobId, () async {
      await ref.read(taskServiceProvider).deleteJob(jobId);
      BotToast.showText(text: '任务已删除');
      await refresh();
    });
  }

  Future<void> toggleExpanded(String jobId) async {
    final expanded = {...state.expandedJobIds};
    if (expanded.contains(jobId)) {
      expanded.remove(jobId);
      state = state.copyWith(expandedJobIds: expanded);
      return;
    }
    expanded.add(jobId);
    state = state.copyWith(expandedJobIds: expanded);
    await loadRuns(jobId);
  }

  Future<void> loadRuns(String jobId, {bool force = false}) async {
    if (!force && state.runsByJob.containsKey(jobId)) return;
    final loading = {...state.loadingRunJobIds, jobId};
    state = state.copyWith(loadingRunJobIds: loading);
    try {
      final entries = await ref.read(taskServiceProvider).listJobRuns(jobId);
      // 后端按 jobId 单独查 runs 时往往不再回填 jobName（前端已经知道 jobId）。
      // 这里用 state.jobs 里的 name 兜底，避免详情列表里全是「未命名任务」。
      String? fallbackName;
      for (final j in state.jobs) {
        if (j.id == jobId) {
          fallbackName = j.name.trim();
          break;
        }
      }
      // 也接受从 recentRuns 里捞历史 jobName（job 已删除场景）。
      if (fallbackName == null || fallbackName.isEmpty) {
        for (final r in state.recentRuns) {
          if (r.jobId == jobId && r.jobName.trim().isNotEmpty) {
            fallbackName = r.jobName.trim();
            break;
          }
        }
      }
      final patched = (fallbackName == null || fallbackName.isEmpty)
          ? entries
          : entries
              .map((e) => e.jobName.trim().isEmpty
                  ? e.copyWith(jobName: fallbackName!)
                  : e)
              .toList();
      final nextRuns = {...state.runsByJob, jobId: patched};
      final nextLoading = {...state.loadingRunJobIds}..remove(jobId);
      state =
          state.copyWith(runsByJob: nextRuns, loadingRunJobIds: nextLoading);
    } catch (_) {
      final nextLoading = {...state.loadingRunJobIds}..remove(jobId);
      state = state.copyWith(loadingRunJobIds: nextLoading);
      rethrow;
    }
  }

  Future<CronRunOpenChatResponse> openRunChat(CronRunEntry entry) async {
    return ref.read(taskServiceProvider).openRunChat(entry: entry);
  }

  /// jobs 与 recent runs 并行拉取；Future.wait 保证任一失败时两个 future 都被消费，
  /// 不产生 unawaited 错误。
  Future<(List<CronJob>, List<CronRunEntry>)> _loadJobsAndRecentRuns(
    BusTaskService service,
  ) async {
    final results = await Future.wait<Object?>([
      service.listJobs(),
      service.listRecentRuns(limit: 100),
    ]);
    return (
      results[0]! as List<CronJob>,
      results[1]! as List<CronRunEntry>
    );
  }

  List<CronRunEntry> _withJobNames(
    List<CronRunEntry> entries,
    List<CronJob> jobs,
  ) {
    final byID = {for (final j in jobs) j.id: j.name};
    return entries.map((e) {
      if (e.jobName.trim().isNotEmpty) return e;
      final name = byID[e.jobId]?.trim();
      return name == null || name.isEmpty ? e : e.copyWith(jobName: name);
    }).toList(growable: false);
  }

  Future<void> _withBusy(String jobId, Future<void> Function() action) async {
    final busy = {...state.busyJobIds, jobId};
    state = state.copyWith(busyJobIds: busy);
    try {
      await action();
    } finally {
      final reduced = {...state.busyJobIds}..remove(jobId);
      state = state.copyWith(busyJobIds: reduced);
    }
  }
}
