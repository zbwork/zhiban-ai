import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

import '../models/prewarm_task.dart';
import '../services/prewarm_service.dart';

final prewarmServiceProvider = Provider<PrewarmService>((ref) {
  return const PrewarmService();
});

/// 云端 runtime 预热阶段开关。默认关闭，但保留 provider 以便测试和未来恢复。
final cloudRuntimePrewarmEnabledProvider = Provider<bool>((ref) {
  return AppConfig.cloudRuntimePrewarmEnabled;
});

/// 预热浮层状态。
class PrewarmState {
  const PrewarmState({
    this.tasks = const [],
    this.ensuring = false,
    this.degraded = false,
    this.skippedReason,
    this.dismissed = false,
    this.collapsed = false,
    this.errorText,
  });

  final List<PrewarmTask> tasks;
  // POST /runtime/ensure in-flight: show feedback before task DTOs arrive.
  final bool ensuring;
  final bool degraded;
  final String? skippedReason;
  final bool dismissed; // 用户/自动收起后不再展示
  final bool collapsed; // 用户手动缩小为右下角轻量入口，任务轮询继续
  final String? errorText; // ensure 失败提示 (只在浮层内显示)

  bool get hasActive => tasks.any((t) => !t.status.isTerminal);
  bool get hasFailed => tasks.any((t) => t.status == PrewarmTaskStatus.failed);

  /// 浮层是否可见：未收起 且 (有任务 或 有降级/错误提示)。
  bool get visible =>
      !dismissed &&
      (ensuring ||
          tasks.isNotEmpty ||
          degraded ||
          (errorText != null && errorText!.isNotEmpty));

  PrewarmState copyWith({
    List<PrewarmTask>? tasks,
    bool? ensuring,
    bool? degraded,
    String? skippedReason,
    bool? dismissed,
    bool? collapsed,
    String? errorText,
    bool clearError = false,
  }) {
    return PrewarmState(
      tasks: tasks ?? this.tasks,
      ensuring: ensuring ?? this.ensuring,
      degraded: degraded ?? this.degraded,
      skippedReason: skippedReason ?? this.skippedReason,
      dismissed: dismissed ?? this.dismissed,
      collapsed: collapsed ?? this.collapsed,
      errorText: clearError ? null : (errorText ?? this.errorText),
    );
  }
}

/// 登录预热控制器：once-per-session 触发 ensure + 轮询 tasks + 成功终态自动收起。
/// Riverpod 3 Notifier；随 sessionScope 重建即复位 once-guard。
class PrewarmController extends Notifier<PrewarmState> {
  Timer? _pollTimer;
  Timer? _autoHideTimer;
  bool _started =
      false; // once-per-session guard (provider 随 sessionScope 重建即复位)

  // 快启动 + 指数退避: dsh 运行时的员工注册是亚秒级完成(NOTIFY 唤醒), 固定 3s 首查
  // 会让浮层白等一轮; 300ms 起查、逐次翻倍、封顶 3s——快环境秒级变绿, 慢环境不打爆后端。
  static const Duration _pollInitialInterval = Duration(milliseconds: 300);
  static const Duration _pollMaxInterval = Duration(seconds: 3);
  static const Duration _autoHideDelay = Duration(seconds: 4);
  Duration _pollDelay = _pollInitialInterval;
  bool _pollFailureLogged = false;

  // 移动端屏幕小，浮层默认折叠成右下角胶囊条；桌面端默认展开。
  bool get _defaultCollapsed => PlatformUtils.isMobile;

  @override
  PrewarmState build() {
    ref.onDispose(_stopTimers);
    return PrewarmState(collapsed: _defaultCollapsed);
  }

  PrewarmService get _service => ref.read(prewarmServiceProvider);

  /// 登录后调一次；重复调用被 guard 拦掉，避免触发风暴。
  Future<void> startOnce() async {
    if (_started) return;
    _started = true;
    if (!ref.read(cloudRuntimePrewarmEnabledProvider)) return;
    await ensureNow();
  }

  /// 用户在浮层点"重新预热"：再次 ensure（幂等复用 active、重建失败项）。
  Future<void> retry() => ensureNow();

  /// 配置变更后立即触发一次 runtime ensure，并让右下角浮层重新可见。
  Future<void> ensureNow() async {
    _started = true;
    if (!ref.read(cloudRuntimePrewarmEnabledProvider)) {
      _stopTimers();
      state = PrewarmState(
        dismissed: true,
        collapsed: _defaultCollapsed
      );
      return;
    }
    state = state.copyWith(
      dismissed: false,
      collapsed: _defaultCollapsed,
      clearError: true,
    );
    if (!await _ensure()) return;
    if (!ref.mounted) return;
    _startPolling();
  }

  void dismiss() {
    _stopTimers();
    state = state.copyWith(dismissed: true, collapsed: false);
  }

  void collapse() {
    state = state.copyWith(collapsed: true, dismissed: false);
  }

  void expand() {
    state = state.copyWith(collapsed: false, dismissed: false);
  }

  /// 仅重新展示浮层，不重新触发 ensure。用于「发送被预热守卫拦截」等场景，
  /// 让用户能看到当前准备进度。浮层被收起过但任务仍在进行时，轮询可能已停
  /// （dismiss 会停 timer），这里顺带补一次轮询启动。
  void reveal() {
    state = state.copyWith(dismissed: false, collapsed: false);
    if (state.hasActive && _pollTimer == null) {
      _startPolling();
    }
  }

  Future<bool> _ensure() async {
    try {
      debugPrint('[RuntimePrewarm] operation=runtime.ensure phase=start');
      state = state.copyWith(
        ensuring: true,
        dismissed: false,
        collapsed: _defaultCollapsed,
        clearError: true,
      );
      final res = await _service.ensure();
      if (!ref.mounted) {
        return false;
      }
      final tasks = res.tasks.isNotEmpty
          ? res.tasks
          : await _loadVisibleTasksOrKeepFailed();
      if (!ref.mounted) {
        return false;
      }
      state = state.copyWith(
        tasks: tasks,
        ensuring: false,
        degraded: res.degraded,
        skippedReason: res.skippedReason,
        clearError: true,
      );
      debugPrint('[RuntimePrewarm] operation=runtime.ensure phase=success '
          'created=${res.created} reused=${res.reused} tasks=${tasks.length} '
          'degraded=${res.degraded}');
      _maybeScheduleAutoHide();
      return true;
    } catch (e) {
      // ResponseInterceptor has already logged status/code/trace when this is
      // an HTTP failure. Keep this semantic log free of upstream text.
      debugPrint('[RuntimePrewarm] operation=runtime.ensure phase=failed '
          'type=${e.runtimeType}');
      // ensure 失败只在浮层提示，不阻断主界面。
      if (!ref.mounted) {
        return false;
      }
      state = state.copyWith(
        ensuring: false,
        errorText: '预热初始化失败，可点击重试'
      );
      return true;
    }
  }

  Future<List<PrewarmTask>> _loadVisibleTasksOrKeepFailed() async {
    try {
      return await _service.listTasks();
    } catch (_) {
      // Snapshot restore is best-effort; keep local failed entries only when
      // the service cannot confirm the current displayable task list.
      if (state.hasFailed) {
        return state.tasks;
      }
      return const <PrewarmTask>[];
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    // 无 active 任务则不轮询（degraded / 全终态）。
    if (!state.hasActive) {
      _maybeScheduleAutoHide();
      return;
    }
    _pollDelay = _pollInitialInterval;
    _scheduleNextPoll();
  }

  void _scheduleNextPoll() {
    _pollTimer = Timer(_pollDelay, () async {
      final keepPolling = await _pollOnce();
      if (!ref.mounted || !keepPolling) return;
      final doubled = _pollDelay * 2;
      _pollDelay = doubled > _pollMaxInterval ? _pollMaxInterval : doubled;
      _scheduleNextPoll();
    });
  }

  /// 返回是否继续轮询。
  Future<bool> _pollOnce() async {
    try {
      final tasks = await _service.listTasks();
      _pollFailureLogged = false;
      if (!ref.mounted) {
        return false;
      }
      state = state.copyWith(tasks: tasks, clearError: true);
    } catch (e) {
      if (!_pollFailureLogged) {
        _pollFailureLogged = true;
        debugPrint('[RuntimePrewarm] operation=runtime.tasks phase=failed '
            'type=${e.runtimeType}');
      }
      return true; // 轮询失败忽略，下一轮再试
    }
    if (!state.hasActive) {
      _pollTimer?.cancel();
      _pollTimer = null;
      _maybeScheduleAutoHide();
      return false;
    }
    return true;
  }

  /// 全部终态且无失败 → 延时自动收起；有失败则保留浮层（带重试入口）。
  void _maybeScheduleAutoHide() {
    _autoHideTimer?.cancel();
    if (state.ensuring) return;
    if (state.hasActive) return;
    if (state.hasFailed) return; // 有 failed 不自动收起
    // 无任务且未降级也直接收起；否则展示一会儿"已就绪"再收。
    _autoHideTimer = Timer(_autoHideDelay, () {
      if (!ref.mounted) return;
      if (!state.hasActive && !state.hasFailed) {
        state = state.copyWith(dismissed: true);
      }
    });
  }

  void _stopTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
  }
}

final prewarmControllerProvider =
    NotifierProvider<PrewarmController, PrewarmState>(PrewarmController.new);
