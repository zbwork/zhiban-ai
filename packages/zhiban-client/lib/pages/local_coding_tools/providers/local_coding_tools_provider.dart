import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;

import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_bridge_client.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_tools_service.dart';

final localCodingToolsServiceProvider = Provider<LocalCodingToolsOperations>(
  (_) => LocalCodingToolsService(),
);

/// 复合流程:多段串行、每段可独立失败并停在该段。这里只承载 UI 需要的最小语义。
/// - installAndEnable:下载安装 → 接入知办隔离配置 → 启动验证(v1.7 保留)。
/// - switchToZhiban / repairSwitch:备份并改写全局配置 → 真实请求验证(CC Switch 式)。
enum LocalCodingCompoundPhase { install, enable, switchWrite, verify }

enum LocalCodingCompoundKind { installAndEnable, switchToZhiban, repairSwitch }

class LocalCodingCompound {
  const LocalCodingCompound({
    required this.phase,
    this.kind = LocalCodingCompoundKind.installAndEnable,
    this.failed = false,
    this.errorCode = '',
  });

  final LocalCodingCompoundKind kind;
  final LocalCodingCompoundPhase phase;
  final bool failed;
  final String errorCode;

  LocalCodingCompound copyWith({
    LocalCodingCompoundPhase? phase,
    bool? failed,
    String? errorCode,
  }) {
    return LocalCodingCompound(
      kind: kind,
      phase: phase ?? this.phase,
      failed: failed ?? this.failed,
      errorCode: errorCode ?? this.errorCode,
    );
  }
}

/// 行级(target)名字:横幅、弹框、Toast 里用。
String localCodingTargetName(LocalCodingTarget target) => switch (target) {
      LocalCodingTarget.codexCli => 'Codex CLI',
      LocalCodingTarget.claudeCli => 'Claude Code',
      LocalCodingTarget.codexDesktop => 'Codex 桌面端',
      LocalCodingTarget.claudeDesktop => 'Claude 桌面端',
    };

/// 卡级(厂商)名字。
String localCodingVendorName(LocalCodingVendor vendor) => vendor.displayName;

/// M3 · 卡级批处理(F31 §3.2):一次动作按顺序作用于该厂商的多个 target
/// (下载安装 / 切换 / 重新检测 / 修复),每项独立成败;进度弹框按项显示。
enum LocalCodingBatchKind {
  install,

  /// F31 §3.2.1(2026-09-17)· 「一键配置工具 / 修复并重试」:每个形态
  /// ①程序到位 → ②写配置 → ③验证,每步按 [LocalCodingConnectPlan] 决定做不做。
  connect,
  switchToZhiban,
  repairSwitch,
  verify,

  /// 契约 §2.7.4 · 版本目录:升级到目录 current;已切换态随后再做一次全局验证。
  /// App 不提供回退(2026-09-15 拍板)。版本行末尾的文字链走这里,不进页脚。
  upgrade,

  /// 「恢复官方配置」:对每个已切换形态依次 restore_global,同样走进度弹框
  /// (2026-09-11 用户反馈:点完没有任何进度反馈)。
  restore,
}

/// 接入链第①步要对程序做什么(F31 §3.2.1)。
enum LocalCodingProgramAction {
  none,
  install,

  /// 安装损坏:按锁定版本原位重装。
  repair,

  /// npm / Homebrew 副本:在标准位置装目录版本并让命令指向它,原副本保留。
  adopt,

  /// 标准位置低于目录版本。
  upgrade;

  LocalCodingInstallMode get installMode => switch (this) {
        LocalCodingProgramAction.repair => LocalCodingInstallMode.repair,
        LocalCodingProgramAction.adopt => LocalCodingInstallMode.adopt,
        LocalCodingProgramAction.upgrade => LocalCodingInstallMode.upgrade,
        _ => LocalCodingInstallMode.install,
      };
}

/// 接入链对某个形态的计划:第①步做什么、第②步写不写配置;第③步验证永远做。
/// 页面用它列"这次会做什么",进度弹框用它决定显示哪些步。
class LocalCodingConnectPlan {
  const LocalCodingConnectPlan({
    this.action = LocalCodingProgramAction.none,
    this.writeConfig = true,
    this.fromVersion = '',
    this.toVersion = '',
  });

  final LocalCodingProgramAction action;
  final bool writeConfig;

  /// 升级 / 接管时的版本变化;安装时 [toVersion] 为空(目录版本由 Bridge 决定)。
  final String fromVersion;
  final String toVersion;

  bool get changesProgram => action != LocalCodingProgramAction.none;
}

enum LocalCodingBatchItemStatus {
  pending,
  running,
  succeeded,
  failed,
  cancelled
}

class LocalCodingBatchItem {
  const LocalCodingBatchItem({
    this.status = LocalCodingBatchItemStatus.pending,
    this.errorCode = '',
    this.errorMessage = '',
    this.errorDetail = '',
    this.modelWarning,
  });

  final LocalCodingBatchItemStatus status;
  final String errorCode;

  /// 检测通过、但靠的是备用模型(契约 §2.7 L3 备用模型)。成功后 operation 会从
  /// state 里清掉,卡片上的提示只能从这里取。
  final LocalCodingModelWarning? modelWarning;

  /// 检测失败时中转站返回的原话(operation.error_detail)。
  final String errorDetail;

  /// 失败时给用户看的一句话(来自 LocalCodingToolsException.userMessage);
  /// Bridge 侧 operation 失败时为空,只有错误码。
  final String errorMessage;

  bool get isTerminal =>
      status == LocalCodingBatchItemStatus.succeeded ||
      status == LocalCodingBatchItemStatus.failed ||
      status == LocalCodingBatchItemStatus.cancelled;
}

class LocalCodingBatch {
  const LocalCodingBatch({
    required this.vendor,
    required this.kind,
    required this.targets,
    this.items = const {},
    this.components = const {},
    this.componentOnly = false,
    this.done = false,
    this.plans = const {},
  });

  final LocalCodingVendor vendor;
  final LocalCodingBatchKind kind;

  /// [LocalCodingBatchKind.connect] · 每个形态的接入计划(其余种类为空)。
  final Map<LocalCodingTarget, LocalCodingConnectPlan> plans;

  /// 执行顺序:CLI 在前、桌面端在后(与卡内两行一致)。
  final List<LocalCodingTarget> targets;
  final Map<LocalCodingTarget, LocalCodingBatchItem> items;

  /// M3 Task 8 · 运行组件预置步(按 target):Claude 桌面端安装后 / 切换前要把
  /// Claude Code 宿主包放好,只在批处理计划了该步时出现。
  final Map<LocalCodingTarget, LocalCodingBatchItem> components;

  /// 只做组件预置(行级"一键修复 · 缺少运行组件"),弹框只显示组件块。
  final bool componentOnly;

  /// 全部项都到终态后置 true;弹框据此决定自动关闭 / 停留。
  final bool done;

  LocalCodingBatchItem itemFor(LocalCodingTarget target) =>
      items[target] ?? const LocalCodingBatchItem();

  LocalCodingBatchItem? componentFor(LocalCodingTarget target) =>
      components[target];

  bool get anyFailed =>
      items.values.any((i) => i.status == LocalCodingBatchItemStatus.failed) ||
      components.values
          .any((i) => i.status == LocalCodingBatchItemStatus.failed);

  bool get allSucceeded =>
      done &&
      targets.every(
          (t) => items[t]?.status == LocalCodingBatchItemStatus.succeeded) &&
      components.values
          .every((i) => i.status == LocalCodingBatchItemStatus.succeeded);

  LocalCodingBatch copyWith({
    Map<LocalCodingTarget, LocalCodingBatchItem>? items,
    Map<LocalCodingTarget, LocalCodingBatchItem>? components,
    bool? done,
  }) {
    return LocalCodingBatch(
      vendor: vendor,
      kind: kind,
      targets: targets,
      items: items ?? this.items,
      components: components ?? this.components,
      componentOnly: componentOnly,
      done: done ?? this.done,
      plans: plans,
    );
  }

  LocalCodingBatch withItem(
    LocalCodingTarget target,
    LocalCodingBatchItem item,
  ) {
    final next = Map<LocalCodingTarget, LocalCodingBatchItem>.from(items)
      ..[target] = item;
    return copyWith(items: next);
  }

  LocalCodingBatch withComponent(
    LocalCodingTarget target,
    LocalCodingBatchItem item,
  ) {
    final next = Map<LocalCodingTarget, LocalCodingBatchItem>.from(components)
      ..[target] = item;
    return copyWith(components: next);
  }
}

/// 展示给页面消费的完整状态。快照 + 运行中操作(按 target)+ 顶部横幅
/// + 最近检测时间 + 「一键安装并启用」的复合流程状态 + 卡级批处理(按厂商)。
class LocalCodingToolsPageData {
  const LocalCodingToolsPageData({
    required this.snapshot,
    this.operations = const {},
    this.compounds = const {},
    this.batches = const {},
    this.banner,
    this.lastDetectedAt,
  });

  final LocalCodingToolsSnapshot snapshot;
  final Map<LocalCodingTarget, LocalCodingOperation> operations;
  final Map<LocalCodingTarget, LocalCodingCompound> compounds;
  final Map<LocalCodingVendor, LocalCodingBatch> batches;
  final LocalCodingPageBanner? banner;
  final DateTime? lastDetectedAt;

  LocalCodingOperation? operationFor(LocalCodingTarget target) =>
      operations[target];

  LocalCodingCompound? compoundFor(LocalCodingTarget target) =>
      compounds[target];

  LocalCodingBatch? batchFor(LocalCodingVendor vendor) => batches[vendor];

  bool hasRunningOperation(LocalCodingTarget target) {
    final op = operations[target];
    return op != null && !op.isTerminal;
  }

  bool hasRunningBatch(LocalCodingVendor vendor) {
    final batch = batches[vendor];
    return batch != null && !batch.done;
  }

  LocalCodingToolsPageData copyWith({
    LocalCodingToolsSnapshot? snapshot,
    Map<LocalCodingTarget, LocalCodingOperation>? operations,
    Map<LocalCodingTarget, LocalCodingCompound>? compounds,
    Map<LocalCodingVendor, LocalCodingBatch>? batches,
    LocalCodingPageBanner? banner,
    bool clearBanner = false,
    DateTime? lastDetectedAt,
  }) {
    return LocalCodingToolsPageData(
      snapshot: snapshot ?? this.snapshot,
      operations: operations ?? this.operations,
      compounds: compounds ?? this.compounds,
      batches: batches ?? this.batches,
      banner: clearBanner ? null : (banner ?? this.banner),
      lastDetectedAt: lastDetectedAt ?? this.lastDetectedAt,
    );
  }
}

enum LocalCodingPageBannerKind {
  needsAttention,
  installComplete,
  repairComplete,
}

class LocalCodingPageBanner {
  const LocalCodingPageBanner({
    required this.kind,
    required this.text,
    this.title = '',
  });

  final LocalCodingPageBannerKind kind;
  final String text;

  /// 有标题时浮动通知分两行:标题 + [text]。重新检测的结果统一用"检测完成"做标题,
  /// 因为检测的是整台机器,不只是被点的那张卡(2026-09-15 用户反馈)。
  final String title;
}

/// 全量检测结束时浮动通知的标题(页面没有别的结果要报时单独显示)。
const String localCodingInspectDoneTitle = '检测完成';

/// 接入 / 恢复完成提示的第二行:配置文件只在进程启动时读,已打开的会话不会跟着变。
const String localCodingRelaunchHint = '已打开的终端和桌面端要重新打开才生效';

/// 全量检测进度(2026-09-15 检测过程可视化):进页面、回到页面、重新检测时逐项上报,
/// 页面据此保留卡片并逐行填充;检测结束(成功或失败)置 null。
final localCodingInspectProgressProvider =
    StateProvider<LocalCodingInspectProgress?>((ref) => null);

// keepAlive:离开设置页也不释放,好让长操作在后台继续轮询到终态,
// 而且再进页面时可以显示上次快照 + 后台 refresh(见 refreshQuiet)。
// App 退出即会关掉 Bridge 会话(service 的 _activeSessions 兜底关闭)。
final localCodingToolsProvider =
    AsyncNotifierProvider<LocalCodingToolsNotifier, LocalCodingToolsPageData>(
  LocalCodingToolsNotifier.new,
  retry: (retryCount, error) => null,
);

class LocalCodingToolsNotifier extends AsyncNotifier<LocalCodingToolsPageData> {
  LocalCodingToolsOperations get _service =>
      ref.read(localCodingToolsServiceProvider);

  // 同 target 只允许一个写操作(install / verify)排队。
  final Map<LocalCodingTarget, Completer<void>> _mutex = {};
  final Map<LocalCodingTarget, Timer> _pollTimers = {};

  @override
  Future<LocalCodingToolsPageData> build() async {
    ref.onDispose(() {
      for (final timer in _pollTimers.values) {
        timer.cancel();
      }
      _pollTimers.clear();
    });
    // 登录后立刻进页面时后台那次自动重新接入可能还没跑:先接入再检测,卡片不会先闪
    // 一下「需要处理 · 授权已失效」(并发由服务合并为一次)。
    await _service.reconnectIfSameIdentity();
    final snapshot = await _inspectWithProgress();
    return LocalCodingToolsPageData(
      snapshot: snapshot,
      lastDetectedAt: DateTime.now(),
    );
  }

  /// 带进度的全量检测(进页面 / 回到页面 / 重新检测):逐项上报给页面,结束时清掉。
  /// [announce]:开始前先报"准备中",让页面立刻进入检测态(build 期间不能改别的
  /// provider,首次进入由页面自己显示骨架)。
  Future<LocalCodingToolsSnapshot> _inspectWithProgress(
      {bool announce = false}) async {
    void report(LocalCodingInspectProgress? progress) {
      if (!ref.mounted) return;
      ref.read(localCodingInspectProgressProvider.notifier).state = progress;
    }

    if (announce) report(LocalCodingInspectProgress.starting());
    try {
      return await _service.inspect(onProgress: report);
    } finally {
      report(null);
    }
  }

  bool get _inspecting => ref.read(localCodingInspectProgressProvider) != null;

  bool _quietRefreshing = false;

  /// 后台静默刷新:不进入 loading、保留 operations / compounds / banner,也不上报
  /// 检测进度。用于页面 re-mount(keepAlive 生效)时用旧快照占位再后台同步——
  /// 再次进入页面不应看起来"又检测了一遍"(2026-09-15 用户反馈);检测进度只在
  /// 首次进入与「重新检测」时显示。
  Future<void> refreshQuiet() async {
    final data = state.value;
    if (data == null) return; // 首次挂载,交给 build()。
    if (_inspecting || _quietRefreshing) return;
    _quietRefreshing = true;
    try {
      final snap = await _service.inspect();
      final current = state.value ?? data;
      state = AsyncData(current.copyWith(
        snapshot: snap,
        lastDetectedAt: DateTime.now(),
        compounds: _withoutStaleWriteFailures(current.compounds),
        batches: _withoutFinishedWriteBatches(current.batches),
      ));
    } catch (_) {
      // 静默刷新失败保留旧快照,不打扰用户;下一次交互会再试。
    } finally {
      _quietRefreshing = false;
    }
  }

  /// 显式重新检测:不影响正在跑的操作。卡片不消失,按检测进度逐行刷新
  /// (2026-09-15;此前是整页转圈)。
  Future<void> reload() async {
    if (state.isLoading || _inspecting) return;
    final progress = _inspectWithProgress(announce: true);
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final snap = await progress;
      return LocalCodingToolsPageData(
        snapshot: snap,
        operations: state.value?.operations ?? const {},
        compounds:
            _withoutStaleWriteFailures(state.value?.compounds ?? const {}),
        batches:
            _withoutFinishedWriteBatches(state.value?.batches ?? const {}),
        lastDetectedAt: DateTime.now(),
        banner: state.value?.banner,
      );
    });
  }

  /// 重新检测 / 重新进入页面以最新检测为准:清掉写入阶段(安装 / 启用 / 切换)
  /// 留下的失败,否则"切换未完成，原有配置已保留"会压过已经指向知办的新快照
  /// (2026-09-14 用户反馈)。验证失败保留:检测读不出服务是否连得上。
  static Map<LocalCodingTarget, LocalCodingCompound> _withoutStaleWriteFailures(
    Map<LocalCodingTarget, LocalCodingCompound> compounds,
  ) =>
      {
        for (final entry in compounds.entries)
          if (!entry.value.failed ||
              entry.value.phase == LocalCodingCompoundPhase.verify)
            entry.key: entry.value,
      };

  /// 同上:已结束的写入类批处理(失败项会让已切换的行显示"需要处理")。
  static Map<LocalCodingVendor, LocalCodingBatch> _withoutFinishedWriteBatches(
    Map<LocalCodingVendor, LocalCodingBatch> batches,
  ) =>
      {
        for (final entry in batches.entries)
          if (!entry.value.done ||
              entry.value.kind == LocalCodingBatchKind.verify)
            entry.key: entry.value,
      };

  Future<bool> registerOrRotate() async {
    if (state.isLoading) return false;
    state = const AsyncLoading();
    final next = await AsyncValue.guard(() async {
      final snap = await _service.registerOrRotate();
      return LocalCodingToolsPageData(
        snapshot: snap,
        lastDetectedAt: DateTime.now(),
      );
    });
    state = next;
    return !next.hasError;
  }

  Future<bool> enable(LocalCodingTarget target) async {
    if (state.isLoading) return false;
    state = const AsyncLoading();
    final next = await AsyncValue.guard(() async {
      final snap = await _service.enable(target);
      return LocalCodingToolsPageData(
        snapshot: snap,
        lastDetectedAt: DateTime.now(),
      );
    });
    state = next;
    return !next.hasError;
  }

  Future<LocalCodingLaunchResult?> launch(
    LocalCodingTarget target, {
    LocalCodingLaunchMode mode = LocalCodingLaunchMode.managed,
  }) async {
    if (state.isLoading) return null;
    final previous = state.value;
    state = const AsyncLoading();
    try {
      final result = await _service.launch(target, mode: mode);
      final snap = await _service.inspect();
      state = AsyncData(
        (previous ?? await _initial()).copyWith(
          snapshot: snap,
          lastDetectedAt: DateTime.now(),
        ),
      );
      return result;
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      return null;
    }
  }

  Future<Object?> removeAuthorization() async {
    if (state.isLoading) return null;
    state = const AsyncLoading();
    Object? operationError;
    try {
      await _service.removeAuthorization();
    } catch (error) {
      operationError = error;
    }
    final next = await AsyncValue.guard(() async {
      final snap = await _service.inspect();
      return LocalCodingToolsPageData(
        snapshot: snap,
        lastDetectedAt: DateTime.now(),
      );
    });
    state = next;
    return operationError ?? next.error;
  }

  /// 移除该 target 的知办隔离配置(config.restore)。service 内部会在两卡都
  /// not_configured 时顺带撤销本机设备授权。
  Future<Object?> removeConfiguration(LocalCodingTarget target) async {
    if (state.isLoading || _isBusy(target)) return null;
    final data = state.value;
    if (data == null) return null;
    try {
      final snap = await _service.removeConfiguration(target);
      state = AsyncData(data.copyWith(
        snapshot: snap,
        lastDetectedAt: DateTime.now(),
        clearBanner: true,
      ));
      return null;
    } catch (error) {
      return error;
    }
  }

  /// 冲突态修复:config.plan(type=repair) → config.execute → 刷新快照。
  Future<Object?> repairConfiguration(LocalCodingTarget target) async {
    if (state.isLoading || _isBusy(target)) return null;
    final data = state.value;
    if (data == null) return null;
    state = const AsyncLoading();
    try {
      final snap = await _service.repairConfiguration(target);
      state = AsyncData(data.copyWith(
        snapshot: snap,
        lastDetectedAt: DateTime.now(),
        banner: const LocalCodingPageBanner(
          kind: LocalCodingPageBannerKind.repairComplete,
          text: '修复完成，知办线路配置已就绪',
        ),
      ));
      return null;
    } catch (error) {
      state = AsyncData(data);
      return error;
    }
  }

  /// 启动一次安装。返回时已经开始轮询;UI 只需要观察 state.operations[target]。
  /// 传 component 时预置运行组件(M3 Task 8),不装工具本身。
  Future<Object?> startInstall(
    LocalCodingTarget target, {
    LocalCodingInstallMode mode = LocalCodingInstallMode.install,
    String? component,
  }) async {
    if (_isBusy(target)) return null;
    final data = state.value;
    if (data == null) return null;
    _mutex[target] = Completer<void>();
    _pollFailures.remove(target);
    _lastTerminal.remove(target);
    try {
      final op = await _service.startInstall(
        target,
        mode: mode,
        component: component,
      );
      _updateOperation(target, op);
      _schedulePoll(target, op.operationId);
      return null;
    } catch (error) {
      _mutex.remove(target)?.complete();
      return error;
    }
  }

  Future<Object?> startVerify(
    LocalCodingTarget target, {
    LocalCodingVerifyScope scope = LocalCodingVerifyScope.overlay,
  }) async {
    if (_isBusy(target)) return null;
    final data = state.value;
    if (data == null) return null;
    _mutex[target] = Completer<void>();
    _pollFailures.remove(target);
    _lastTerminal.remove(target);
    try {
      final op = await _service.startVerify(target, scope: scope);
      _updateOperation(target, op);
      _schedulePoll(target, op.operationId);
      return null;
    } catch (error) {
      _mutex.remove(target)?.complete();
      return error;
    }
  }

  /// v1.7 · 「一键安装并启用」:install → (可能的 register) → config.plan/execute → verify。
  /// 每段成功后 provider 自动推进下一段;失败停在该段并把错误码放入 compound。
  Future<Object?> startInstallAndEnable(LocalCodingTarget target) async {
    if (_isBusy(target)) return null;
    final data = state.value;
    if (data == null) return null;
    _setCompound(target,
        const LocalCodingCompound(phase: LocalCodingCompoundPhase.install));
    return startInstall(target);
  }

  /// 「切换为自定义模型 API」/「一键修复」(已切换态):备份并改写用户全局配置
  /// (Bridge 内部先备份、写入失败自动回滚)→ 真实请求验证。失败停在该段。
  Future<Object?> switchToZhiban(
    LocalCodingTarget target, {
    bool repair = false,
  }) async {
    if (_isBusy(target)) return null;
    final data = state.value;
    if (data == null) return null;
    final kind = repair
        ? LocalCodingCompoundKind.repairSwitch
        : LocalCodingCompoundKind.switchToZhiban;
    _setCompound(
      target,
      LocalCodingCompound(
          kind: kind, phase: LocalCodingCompoundPhase.switchWrite),
    );
    try {
      final snap = await _service.switchToZhiban(target);
      final current = state.value;
      if (current != null) {
        state = AsyncData(current.copyWith(
          snapshot: snap,
          lastDetectedAt: DateTime.now()),
        );
      }
    } catch (error) {
      _setCompound(
        target,
        LocalCodingCompound(
          kind: kind,
          phase: LocalCodingCompoundPhase.switchWrite,
          failed: true,
          errorCode: _errorCode(error),
        ),
      );
      await _refreshSnapshot();
      return error;
    }
    _setCompound(
      target,
      LocalCodingCompound(kind: kind, phase: LocalCodingCompoundPhase.verify),
    );
    final verifyError =
        await startVerify(target, scope: LocalCodingVerifyScope.global);
    if (verifyError != null) {
      _setCompound(
        target,
        LocalCodingCompound(
          kind: kind,
          phase: LocalCodingCompoundPhase.verify,
          failed: true,
          errorCode: _errorCode(verifyError),
        ),
      );
      return verifyError;
    }
    return null;
  }

  /// 「恢复官方配置」:按切换时的备份恢复用户全局配置。
  Future<Object?> restoreOfficial(LocalCodingTarget target) async {
    if (state.isLoading || _isBusy(target)) return null;
    final data = state.value;
    if (data == null) return null;
    try {
      final snap = await _service.restoreOfficial(target);
      state = AsyncData(data.copyWith(
        snapshot: snap,
        lastDetectedAt: DateTime.now(),
        banner: LocalCodingPageBanner(
          kind: LocalCodingPageBannerKind.repairComplete,
          text: '已恢复 ${localCodingTargetName(target)} 官方配置',
        ),
      ));
      return null;
    } catch (error) {
      return error;
    }
  }

  // ─── M3 · 卡级批处理(F31 §3.2)────────────────────────────────────────
  //
  // 同一厂商的多个 target 按给定顺序串行执行;每项独立成败,失败不回滚已成功
  // 的另一形态,只让该行进入"需要处理"。进度弹框观察 batches[vendor]。

  /// F31 §3.2.1(2026-09-17)· 接入链对某个形态的计划,按当前快照算出来:
  /// ① 程序到位:未安装 → 安装;安装损坏 → 重装;npm / Homebrew 副本 → 接管;
  ///    标准位置低于目录 → 升级。桌面端只在"它是切不了的原因"时才升(Claude
  ///    桌面端不支持第三方推理),其余桌面端版本留给后台维护与发行方自己的更新,
  ///    免得 ChatGPT 开着就把整条链卡在"正在运行"上。不降级由 Bridge 保证:目录
  ///    不高于已装版本时给不出 available_version / adopt_version。
  /// ② 写配置:还没切到知办、或受管区域被改动时才写。
  /// ③ 验证永远做。
  LocalCodingConnectPlan connectPlanFor(LocalCodingTarget target) {
    final snap = state.value?.snapshot;
    final tool = snap?.tools[target];
    if (snap == null || tool == null) return const LocalCodingConnectPlan();
    var action = LocalCodingProgramAction.none;
    var to = '';
    if (tool.uiState == LocalCodingToolUiState.notInstalled) {
      action = LocalCodingProgramAction.install;
    } else if (tool.uiState == LocalCodingToolUiState.repairable) {
      action = LocalCodingProgramAction.repair;
    } else if (tool.uiState == LocalCodingToolUiState.installedUnmanaged) {
      if (tool.canAdopt) {
        action = LocalCodingProgramAction.adopt;
        to = tool.adoptVersion;
      } else if (tool.canUpgrade &&
          (!target.isDesktop || !tool.supportsEnable)) {
        action = LocalCodingProgramAction.upgrade;
        to = tool.availableVersion;
      }
    }
    return LocalCodingConnectPlan(
      action: action,
      writeConfig: _configWriteNeeded(target),
      fromVersion: tool.installedVersion,
      toVersion: to,
    );
  }

  /// 「一键配置工具」/「修复并重试」(F31 §3.2.1):一条幂等链,对该厂商的每个
  /// 形态依次 ①程序到位 → ②写配置 → ③验证,每步按 [connectPlanFor] 决定做不做;
  /// 某一形态失败只让该形态进入"需要处理",不回滚另一形态;①失败时配置未动,
  /// 官方服务照常可用。取代此前的 下载安装(落位即切换)/ 切换为自定义模型 API /
  /// 一键修复 / 页脚升级与接管 四个入口,页脚不再按功能开关堆 if。
  Future<Object?> connectTargets(List<LocalCodingTarget> targets) {
    final plans = {
      for (final target in targets) target: connectPlanFor(target),
    };
    // 这个包没带知办接入参数(开发 / 测试包常见):只做第①步,装完就停。
    final connectAllowed = state.value?.snapshot.registrationAvailable ?? false;
    return _runBatch(
      LocalCodingBatchKind.connect,
      targets,
      (target) async {
        final plan = plans[target]!;
        // ① 程序到位。
        if (plan.changesProgram) {
          final error =
              await startInstall(target, mode: plan.action.installMode);
          if (error != null) return _failure(error);
          final outcome = await _awaitOperationOutcome(target);
          if (outcome.status != LocalCodingBatchItemStatus.succeeded) {
            return outcome;
          }
          // M3 Task 8 · Claude 桌面端装好后立刻预置 Claude Code 宿主包,否则国内
          // 无代理的用户一条消息都发不出;组件没就绪就不往下切(Bridge 报"已安装"
          // 视为成功)。
          if (plan.action == LocalCodingProgramAction.install &&
              _needsHostComponent(target)) {
            final component = await _provisionComponent(target);
            if (component.status != LocalCodingBatchItemStatus.succeeded) {
              return outcome;
            }
          }
          if (!connectAllowed) return outcome;
          // 换了程序,后面两步要看新快照(版本门槛、运行组件、是否已切换)。
          await _refreshSnapshot();
        } else if (!connectAllowed) {
          return _failure(const LocalCodingToolsException(
            'profiles_unavailable',
            '当前环境暂未开放自定义模型 API，可先使用官方服务',
          ));
        }
        // Codex 桌面端与命令行共用配置:命令行仍低于最低版本时不能替它写配置,
        // 否则终端里的旧 CLI 会直接起不来(契约 §2.7 最低可切换版本)。
        if (target == LocalCodingTarget.codexDesktop && _codexCliTooOld) {
          return _failure(const LocalCodingToolsException(
            'shared_config_too_old',
            'Codex 命令行版本过旧，桌面端与它共用配置，请先升级命令行',
          ));
        }
        // ② 写配置 + ③ 验证:还没切换 / 受管区域被改动才写;缺运行组件的桌面端
        // 由 _switchOne 先补组件。
        if (_configWriteNeeded(target)) {
          return _switchOne(target, repair: _switchedToZhiban(target));
        }
        // ③ 只验证:已切换且未漂移,重新确认能连上(缺组件先补)。
        if (_needsHostComponent(target) && _componentNeedsProvisioning(target)) {
          final component = await _provisionComponent(target);
          if (component.status != LocalCodingBatchItemStatus.succeeded) {
            return component;
          }
        }
        final verifyError =
            await startVerify(target, scope: LocalCodingVerifyScope.global);
        if (verifyError != null) return _failure(verifyError);
        return _awaitOperationOutcome(target);
      },
      plans: plans,
      // 配置文件只在进程启动时读:开着的终端 / 桌面端会话仍走原来的线路,
      // 提示里说清楚,免得用户以为没切成(2026-09-17 真机验收反馈)。
      onAllSucceeded: (vendor) => connectAllowed
          ? LocalCodingPageBanner(
              kind: LocalCodingPageBannerKind.installComplete,
              title: '接入完成，${localCodingVendorName(vendor)} 已可以使用自定义模型 API',
              text: localCodingRelaunchHint,
            )
          : LocalCodingPageBanner(
              kind: LocalCodingPageBannerKind.installComplete,
              text: '安装完成，${localCodingVendorName(vendor)} 已可以在本机使用',
            ),
    );
  }

  /// 接入链第②步要不要写配置:还没切到知办,或受管区域被改动。
  bool _configWriteNeeded(LocalCodingTarget target) {
    final config = state.value?.snapshot.configurations[target];
    // global_upgrade_available:已接入、未漂移,但缺当前 Bridge 会写的内容(契约
    // §2.7.2)。不算进来的话「修复并重试」会直接跳去验证——缺的正是让验证通过的
    // 那一项时,每点一次都是同一个错误(2026-09-17 Claude 根证书补充,1.2.7 真机)。
    return config == null ||
        !config.switchedToZhiban ||
        config.globalDrifted ||
        config.globalUpgradeAvailable;
  }

  bool get _codexCliTooOld =>
      state.value?.snapshot.tools[LocalCodingTarget.codexCli]?.versionTooOld ??
      false;

  /// 契约 §2.7.4 · 卡级「升级」:对每个形态依次 换版本 →(Claude 桌面端补运行
  /// 组件)→ 已切换态再做一次全局验证。弹框复用安装四步 + 检测服务连接。
  Future<Object?> upgradeTargets(List<LocalCodingTarget> targets) =>
      _changeVersion(
        targets,
        kind: LocalCodingBatchKind.upgrade,
        mode: LocalCodingInstallMode.upgrade,
        versionOf: (tool) => tool?.availableVersion ?? '',
        banner: (names) => '升级完成，$names 已可以使用',
      );

  Future<Object?> _changeVersion(
    List<LocalCodingTarget> targets, {
    required LocalCodingBatchKind kind,
    required LocalCodingInstallMode mode,
    required String Function(LocalCodingToolState? tool) versionOf,
    required String Function(String names) banner,
  }) {
    final snap = state.value?.snapshot;
    String versionFor(LocalCodingTarget target) => versionOf(snap?.tools[target]);

    final ordered = List<LocalCodingTarget>.from(targets)
      ..sort((a, b) => a.formFactor.index.compareTo(b.formFactor.index));
    final names = ordered.map((target) {
      final version = versionFor(target);
      final name = localCodingTargetName(target);
      return version.isEmpty ? name : '$name $version';
    }).join('、');
    return _runBatch(
      kind,
      targets,
      (target) async {
        final error = await startInstall(target, mode: mode);
        if (error != null) return _failure(error);
        final outcome = await _awaitOperationOutcome(target);
        if (outcome.status != LocalCodingBatchItemStatus.succeeded) {
          return outcome;
        }
        // 新版 Claude 桌面端可能钉住新的宿主包版本:缺了就顺手补上。
        if (_needsHostComponent(target)) {
          await _refreshSnapshot();
          if (_componentNeedsProvisioning(target)) {
            final component = await _provisionComponent(target);
            if (component.status != LocalCodingBatchItemStatus.succeeded) {
              return outcome;
            }
          }
        }
        // 已切换为自定义模型 API 的形态:换了版本要重新确认能连上。
        if (!_switchedToZhiban(target)) return outcome;
        final verifyError =
            await startVerify(target, scope: LocalCodingVerifyScope.global);
        if (verifyError != null) return _failure(verifyError);
        return _awaitOperationOutcome(target);
      },
      onAllSucceeded: (_) => LocalCodingPageBanner(
        kind: LocalCodingPageBannerKind.installComplete,
        text: banner(names),
      ),
    );
  }

  /// 快照里该 target 当前是否已切换为自定义模型 API。
  bool _switchedToZhiban(LocalCodingTarget target) =>
      state.value?.snapshot.configurations[target]?.switchedToZhiban ?? false;

  /// 行级「一键修复 · 缺少运行组件」:只预置 Claude 桌面端的运行组件。
  Future<Object?> installComponent(LocalCodingTarget target) {
    return _runBatch(
      LocalCodingBatchKind.install,
      [target],
      (target) => _provisionComponent(target),
      componentOnly: true,
      onAllSucceeded: (_) => LocalCodingPageBanner(
        kind: LocalCodingPageBannerKind.repairComplete,
        text: '修复完成，${localCodingTargetName(target)} 的运行组件已就绪',
      ),
    );
  }

  /// 该 target 安装后是否要跟一步运行组件预置(目前只有 Claude 桌面端)。
  bool _needsHostComponent(LocalCodingTarget target) =>
      target == LocalCodingTarget.claudeDesktop;

  /// 快照里该 target 的运行组件是否缺失 / 过期。
  bool _componentNeedsProvisioning(LocalCodingTarget target) {
    final tool = state.value?.snapshot.tools[target];
    return tool != null && tool.componentNeedsProvisioning;
  }

  /// 预置运行组件:install.plan component=claude_code_host → execute → 轮询。
  /// Bridge 报"已安装"视为成功(安装完成后组件已在位的情形)。
  Future<LocalCodingBatchItem> _provisionComponent(
      LocalCodingTarget target) async {
    final vendor = target.vendor;
    _updateBatchComponent(vendor, target,
        const LocalCodingBatchItem(status: LocalCodingBatchItemStatus.running));
    _lastTerminal.remove(target);
    LocalCodingBatchItem outcome;
    final error = await startInstall(
      target,
      component: LocalCodingComponent.claudeCodeHost,
    );
    if (error != null) {
      outcome = _isAlreadyInstalled(error)
          ? const LocalCodingBatchItem(
              status: LocalCodingBatchItemStatus.succeeded)
          : _failure(error);
    } else {
      outcome = await _awaitOperationOutcome(target);
    }
    _updateBatchComponent(vendor, target, outcome);
    return outcome;
  }

  static bool _isAlreadyInstalled(Object error) =>
      error is LocalCodingToolsException &&
      error.code.endsWith('-INSTALL-ALREADY_INSTALLED');

  /// 单个形态的切换 + 验证(接入链第②③步)。
  Future<LocalCodingBatchItem> _switchOne(
    LocalCodingTarget target, {
    required bool repair,
  }) async {
    // M3 Task 8 · Claude 桌面端切换前先把缺失的运行组件补上,否则切换后
    // 仍然一条消息都发不出;组件失败则不再切换。
    if (_needsHostComponent(target) && _componentNeedsProvisioning(target)) {
      final component = await _provisionComponent(target);
      if (component.status != LocalCodingBatchItemStatus.succeeded) {
        return component;
      }
    }
    final error = await switchToZhiban(target, repair: repair);
    if (error != null) return _failure(error);
    await _awaitOperation(target);
    final compound = state.value?.compoundFor(target);
    if (compound != null && compound.failed) {
      final code =
          compound.errorCode.isEmpty ? 'UNKNOWN' : compound.errorCode;
      return LocalCodingBatchItem(
        status: LocalCodingBatchItemStatus.failed,
        errorCode: code,
        errorMessage:
            code.startsWith('LCT-') ? localCodingErrorMessage(code) : '',
      );
    }
    return const LocalCodingBatchItem(
        status: LocalCodingBatchItemStatus.succeeded);
  }

  /// 卡片「重新检测」(2026-09-15):先带进度读本机状态,再对该厂商已切换的形态做
  /// 全局验证(命令行真实请求 / 桌面端配置与凭证)。验证作为追加步骤接在同一份检测
  /// 进度后面,显示在卡片里,不弹进度弹框;成功 / 失败都用顶部浮动通知。
  Future<Object?> recheckVendor(LocalCodingVendor vendor) async {
    if (state.isLoading || _inspecting) return null;
    final data = state.value;
    if (data == null) return null;
    if (data.hasRunningBatch(vendor) || vendor.targets.any(_isBusy)) {
      return null;
    }
    LocalCodingInspectProgress? last;
    void report(LocalCodingInspectProgress? progress) {
      if (!ref.mounted) return;
      last = progress ?? last;
      ref.read(localCodingInspectProgressProvider.notifier).state = progress;
    }

    report(LocalCodingInspectProgress.starting());
    try {
      final LocalCodingToolsSnapshot snap;
      try {
        snap = await _service.inspect(onProgress: report);
      } catch (error) {
        final current = state.value ?? data;
        state = AsyncData(current.copyWith(
          banner: LocalCodingPageBanner(
            kind: LocalCodingPageBannerKind.needsAttention,
            text: _userFacingError(error, '检测失败，请重试'),
          ),
        ));
        return error;
      }
      final current = state.value ?? data;
      state = AsyncData(current.copyWith(
        snapshot: snap,
        lastDetectedAt: DateTime.now(),
        compounds: _withoutStaleWriteFailures(current.compounds),
        batches: _withoutFinishedWriteBatches(current.batches),
      ));
      final targets = [
        for (final target in vendor.targets)
          if (snap.hasTarget(target) &&
              snap.configurationFor(target).switchedToZhiban &&
              snap.stateFor(target).uiState !=
                  LocalCodingToolUiState.notInstalled)
            target,
      ];
      if (targets.isEmpty || !snap.canVerify) return null;
      final base = last?.steps ?? LocalCodingInspectStep.plan(network: true);
      final steps = [
        ...base,
        for (final target in targets)
          LocalCodingInspectStep(
              LocalCodingInspectStepKind.verify, vendor, target),
      ];
      var completed = base.length;
      report(LocalCodingInspectProgress(
          steps: steps, completed: completed, snapshot: snap));
      final error = await _runBatch(
        LocalCodingBatchKind.verify,
        targets,
        (target) async {
          try {
            final startError =
                await startVerify(target, scope: LocalCodingVerifyScope.global);
            if (startError != null) return _failure(startError);
            return await _awaitOperationOutcome(target);
          } finally {
            completed++;
            report(LocalCodingInspectProgress(
              steps: steps,
              completed: completed,
              snapshot: state.value?.snapshot ?? snap,
            ));
          }
        },
        onAllSucceeded: (vendor) {
          // 靠备用模型通过的要说一声,否则用户打开工具第一句就撞上 502。
          LocalCodingModelWarning? warning;
          for (final target in vendor.targets) {
            warning ??= _lastTerminal[target]?.modelWarning;
          }
          return LocalCodingPageBanner(
            kind: LocalCodingPageBannerKind.repairComplete,
            title: localCodingInspectDoneTitle,
            text: warning == null
                ? '${localCodingVendorName(vendor)} 服务连接正常'
                : '${localCodingVendorName(vendor)} 服务连接正常；${localCodingModelWarningText(warning)}',
          );
        },
      );
      if (error != null) {
        final latest = state.value;
        if (latest != null) {
          // 中转站自己拒绝的(503 过载、429 等)直接说清,别让人以为是本机连不上。
          String? relayText;
          for (final item in latest.batchFor(vendor)?.items.values ??
              const <LocalCodingBatchItem>[]) {
            if (item.status != LocalCodingBatchItemStatus.failed) continue;
            final relay =
                localCodingRelayFailure(item.errorCode, item.errorDetail);
            if (relay != null) {
              relayText = localCodingRelayFailureSummary(relay, item.errorDetail);
              break;
            }
          }
          state = AsyncData(latest.copyWith(
            banner: LocalCodingPageBanner(
              kind: LocalCodingPageBannerKind.needsAttention,
              title: localCodingInspectDoneTitle,
              text: relayText == null
                  ? '${localCodingVendorName(vendor)} 暂时连不上自定义模型 API，可在卡片上查看原因'
                  : '${localCodingVendorName(vendor)}：$relayText',
            ),
          ));
        }
      }
      return error;
    } finally {
      report(null);
    }
  }

  static String _userFacingError(Object error, String fallback) =>
      switch (error) {
        LocalCodingToolsException(:final userMessage) => userMessage,
        // Bridge 自己的原因直接给用户看,不再统一成兜底文案(2026-09-15)。
        LocalCodingBridgeException(:final userMessage) => userMessage,
        _ => fallback,
      };

  /// 契约 §2.7 network.* · 一键为你配置的模型服务设置代理例外(NO_PROXY + 系统代理的绕过
  /// 名单),成功后刷新快照。检测 / 修复由调用方接着做;返回 null 表示成功。
  /// [vendor] 只决定提示里让用户重开哪个应用。
  Future<Object?> applyProxyFix(
      {LocalCodingVendor vendor = LocalCodingVendor.codex}) async {
    final data = state.value;
    if (data == null) return null;
    try {
      final snap = await _service.applyProxyFix();
      final current = state.value ?? data;
      state = AsyncData(current.copyWith(
        snapshot: snap,
        lastDetectedAt: DateTime.now(),
        banner: LocalCodingPageBanner(
          kind: LocalCodingPageBannerKind.repairComplete,
          text:
              '已为你配置的模型服务设置代理例外。请重开 ${localCodingVendorName(vendor)} 桌面端；终端请新开窗口后使用',
        ),
      ));
      return null;
    } catch (error) {
      return error;
    }
  }

  /// 卡级「恢复官方配置」:对每个已切换 target 依次恢复,走卡级批处理,
  /// 进度弹框按形态显示"恢复原有配置 / 检测软件状态";全部成功后横幅提示。
  Future<Object?> restoreTargets(List<LocalCodingTarget> targets) async {
    if (state.isLoading || targets.isEmpty) return null;
    final restored = <LocalCodingTarget>[];
    final error = await _runBatch(
      LocalCodingBatchKind.restore,
      targets,
      (target) async {
        final snap = await _service.restoreOfficial(target);
        restored.add(target);
        // 与切换一致:Bridge 返回的恢复后快照立刻上屏。此前丢掉它、收尾再全量
        // 检测一遍,弹框关闭后卡片先闪回知办状态卡几秒才变成官方(12008 真机)。
        final current = state.value;
        if (current != null) {
          state = AsyncData(current.copyWith(
            snapshot: snap,
            lastDetectedAt: DateTime.now()),
          );
        }
        return const LocalCodingBatchItem(
            status: LocalCodingBatchItemStatus.succeeded);
      },
      onAllSucceeded: (vendor) => LocalCodingPageBanner(
        kind: LocalCodingPageBannerKind.repairComplete,
        title: '已恢复 ${localCodingVendorName(vendor)} 官方配置',
        text: localCodingRelaunchHint,
      ),
      refreshOnSuccess: false,
    );
    if (error != null && restored.isNotEmpty) await _refreshSnapshot();
    return error;
  }

  /// 清除已结束的批处理(用户关闭进度弹框时调用)。
  void dismissBatch(LocalCodingVendor vendor) {
    final data = state.value;
    if (data == null || !data.batches.containsKey(vendor)) return;
    final batch = data.batches[vendor]!;
    if (!batch.done) return;
    final next = Map<LocalCodingVendor, LocalCodingBatch>.from(data.batches)
      ..remove(vendor);
    // 同时清掉各项遗留的失败 compound / operation,让卡片回到快照状态。
    final compounds =
        Map<LocalCodingTarget, LocalCodingCompound>.from(data.compounds);
    final operations =
        Map<LocalCodingTarget, LocalCodingOperation>.from(data.operations);
    for (final target in batch.targets) {
      compounds.remove(target);
      final op = operations[target];
      if (op != null && op.isTerminal) operations.remove(target);
    }
    state = AsyncData(data.copyWith(
        batches: next, compounds: compounds, operations: operations));
  }

  Future<Object?> _runBatch(
    LocalCodingBatchKind kind,
    List<LocalCodingTarget> targets,
    Future<LocalCodingBatchItem> Function(LocalCodingTarget target) runOne, {
    LocalCodingPageBanner Function(LocalCodingVendor vendor)? onAllSucceeded,
    bool componentOnly = false,
    // 每项已把最新快照上屏的批处理(恢复)成功收尾不再全量检测,横幅立即出现。
    bool refreshOnSuccess = true,
    Map<LocalCodingTarget, LocalCodingConnectPlan> plans = const {},
  }) async {
    if (targets.isEmpty) return null;
    final vendor = targets.first.vendor;
    if (targets.any((t) => t.vendor != vendor)) {
      return const LocalCodingToolsException(
          'batch_mixed_vendors', '一次只能处理同一厂商的工具');
    }
    final data = state.value;
    if (data == null) return null;
    if (data.hasRunningBatch(vendor) || targets.any(_isBusy)) return null;
    // 处理顺序固定:CLI 在前、桌面端在后。
    final ordered = List<LocalCodingTarget>.from(targets)
      ..sort((a, b) => a.formFactor.index.compareTo(b.formFactor.index));
    _setBatch(
        vendor,
        LocalCodingBatch(
            vendor: vendor,
            kind: kind,
            targets: ordered,
            componentOnly: componentOnly,
            plans: plans));
    Object? firstError;
    for (final target in ordered) {
      _lastTerminal.remove(target);
      _updateBatchItem(
          vendor,
          target,
          const LocalCodingBatchItem(
              status: LocalCodingBatchItemStatus.running));
      LocalCodingBatchItem outcome;
      try {
        outcome = await runOne(target);
      } catch (error) {
        outcome = _failure(error);
      }
      _recordAppFailure(kind, target, outcome);
      final component = state.value?.batchFor(vendor)?.componentFor(target);
      final componentFailed = component != null &&
          component.status != LocalCodingBatchItemStatus.succeeded;
      if (outcome.status != LocalCodingBatchItemStatus.succeeded) {
        firstError ??= LocalCodingToolsException(
          outcome.errorCode.isEmpty ? 'UNKNOWN' : outcome.errorCode,
          outcome.status == LocalCodingBatchItemStatus.cancelled
              ? '${localCodingTargetName(target)} 已取消'
              : '${localCodingTargetName(target)} 未完成：${outcome.errorCode}',
        );
      } else if (componentFailed) {
        firstError ??= LocalCodingToolsException(
          component.errorCode.isEmpty ? 'UNKNOWN' : component.errorCode,
          '${localCodingTargetName(target)} 的运行组件未就绪：${component.errorCode}',
        );
      }
      _updateBatchItem(vendor, target, outcome);
    }
    final batch = state.value?.batchFor(vendor);
    if (batch != null) {
      _setBatch(vendor, batch.copyWith(done: true));
      if (batch.copyWith(done: true).allSucceeded && onAllSucceeded != null) {
        if (refreshOnSuccess) {
          await _refreshSnapshot(banner: onAllSucceeded(vendor));
        } else {
          final current = state.value;
          if (current != null) {
            state = AsyncData(current.copyWith(banner: onAllSucceeded(vendor)));
          }
        }
      }
    }
    return firstError;
  }

  static LocalCodingBatchItem _failure(Object error) => LocalCodingBatchItem(
        status: LocalCodingBatchItemStatus.failed,
        errorCode: _errorCode(error),
        errorMessage:
            error is LocalCodingToolsException ? error.userMessage : '',
      );

  /// App 侧(service / provider 校验)失败的最近一条记录,按 target 保存。
  /// Bridge 的 diagnostics.get_latest 只记 Bridge 自己的失败(operation /
  /// detect / config conflict / launch),App 在调用 Bridge 之前或之后自己判出的
  /// 错误(如 configuration_plan_invalid)那边没有,"诊断详情"就会是空的——
  /// 2026-09-09 11911 真机踩到,故在这里补一份。
  final Map<LocalCodingTarget, LocalCodingDiagnostics> _appFailures = {};

  void _recordAppFailure(
    LocalCodingBatchKind kind,
    LocalCodingTarget target,
    LocalCodingBatchItem outcome,
  ) {
    if (outcome.status != LocalCodingBatchItemStatus.failed) {
      _appFailures.remove(target);
      return;
    }
    if (outcome.errorCode.startsWith('LCT-')) {
      // Bridge 域错误,Bridge 自己会记;不覆盖成 App 视角。
      return;
    }
    _appFailures[target] = LocalCodingDiagnostics(
      target: target,
      bridgeVersion: '',
      kind: 'app.${kind.name}',
      stage: 'app',
      errorCode: outcome.errorCode,
      occurredAt: DateTime.now().toUtc().toIso8601String(),
      suggestions: [
        if (outcome.errorMessage.isNotEmpty) outcome.errorMessage,
        ..._appFailureSuggestions(outcome.errorCode),
      ],
    );
  }

  static List<String> _appFailureSuggestions(String code) {
    switch (code) {
      case 'configuration_plan_invalid':
        return const ['点击「重新检测」刷新状态后再试;仍失败请更新知办'];
      case 'switch_validation_failed':
        return const ['原有配置已恢复;确认本机未同时运行其它改写该配置的工具后再试'];
      case 'tool_unsupported':
        return const ['当前安装来源或版本不受支持;可点「查看原因」了解详情'];
      case 'profiles_unavailable':
        return const ['当前环境未开放自定义模型 API 切换,请联系管理员'];
      default:
        return const [];
    }
  }

  /// 等待该 target 当前 operation 到终态(轮询在 _tickPoll 里推进)。
  Future<void> _awaitOperation(LocalCodingTarget target) async {
    final completer = _mutex[target];
    if (completer == null) return;
    await completer.future;
  }

  Future<LocalCodingBatchItem> _awaitOperationOutcome(
      LocalCodingTarget target) async {
    await _awaitOperation(target);
    final pollFailure = _pollFailures[target];
    if (pollFailure != null) return pollFailure;
    final op = _lastTerminal[target];
    if (op == null) {
      return const LocalCodingBatchItem(
          status: LocalCodingBatchItemStatus.failed, errorCode: 'UNKNOWN');
    }
    if (op.isSucceeded) {
      return LocalCodingBatchItem(
          status: LocalCodingBatchItemStatus.succeeded,
          modelWarning: op.modelWarning);
    }
    if (op.isCancelled) {
      return const LocalCodingBatchItem(
          status: LocalCodingBatchItemStatus.cancelled, errorCode: 'CANCELLED');
    }
    // 文案必须在这里补:进度弹框的失败块只显示 errorMessage + 错误码,而
    // Bridge 的异步 operation 失败不会抛 LocalCodingToolsException,不补就只剩
    // 一行 LCT-… 码,用户不知道下一步(2026-09-16:升级桌面端报 TARGET_IN_USE,
    // 页面没告诉用户要先退出应用)。
    final code = op.errorCode.isEmpty ? 'UNKNOWN' : op.errorCode;
    return LocalCodingBatchItem(
      status: LocalCodingBatchItemStatus.failed,
      errorCode: code,
      errorMessage: code.startsWith('LCT-') ? localCodingErrorMessage(code) : '',
      errorDetail: op.errorDetail,
    );
  }

  // 每个 target 最近一次到终态的 operation;批处理据此判定该项成败
  // (provider 成功后会把 operation 从 state 里清掉)。
  final Map<LocalCodingTarget, LocalCodingOperation> _lastTerminal = {};
  final Map<LocalCodingTarget, LocalCodingBatchItem> _pollFailures = {};

  void _setBatch(LocalCodingVendor vendor, LocalCodingBatch batch) {
    final data = state.value;
    if (data == null) return;
    final next = Map<LocalCodingVendor, LocalCodingBatch>.from(data.batches)
      ..[vendor] = batch;
    state = AsyncData(data.copyWith(batches: next));
  }

  void _updateBatchItem(
    LocalCodingVendor vendor,
    LocalCodingTarget target,
    LocalCodingBatchItem item,
  ) {
    final batch = state.value?.batchFor(vendor);
    if (batch == null) return;
    _setBatch(vendor, batch.withItem(target, item));
  }

  void _updateBatchComponent(
    LocalCodingVendor vendor,
    LocalCodingTarget target,
    LocalCodingBatchItem item,
  ) {
    final batch = state.value?.batchFor(vendor);
    if (batch == null) return;
    _setBatch(vendor, batch.withComponent(target, item));
  }

  /// 「打开应用」:CLI 在系统终端于用户主目录按其全局配置启动;桌面端由 Bridge
  /// 以 open -a 打开。不选项目、不改配置。
  Future<Object?> openApp(LocalCodingTarget target) async {
    try {
      await _service.openApp(target);
      return null;
    } catch (error) {
      return error;
    }
  }

  static String _errorCode(Object error) =>
      error is LocalCodingToolsException ? error.code : 'UNKNOWN';

  Future<void> cancelRunning(LocalCodingTarget target) async {
    final op = state.value?.operationFor(target);
    if (op == null || op.isTerminal) return;
    try {
      final updated = await _service.cancelOperation(op.operationId);
      _updateOperation(target, updated);
      if (updated.isTerminal) {
        await _onTerminal(target, updated);
      }
    } catch (_) {
      // 取消失败保留原状态,继续轮询下一次。
    }
  }

  /// 清除已完成/失败的复合流程状态(用户关闭进度弹框时调用)。
  void dismissCompound(LocalCodingTarget target) {
    final data = state.value;
    if (data == null) return;
    if (!data.compounds.containsKey(target)) return;
    final next = Map<LocalCodingTarget, LocalCodingCompound>.from(
      data.compounds,
    )..remove(target);
    state = AsyncData(data.copyWith(compounds: next));
  }

  bool _isBusy(LocalCodingTarget target) {
    final op = state.value?.operationFor(target);
    return op != null && !op.isTerminal;
  }

  void _updateOperation(LocalCodingTarget target, LocalCodingOperation op) {
    final data = state.value;
    if (data == null) return;
    final next = Map<LocalCodingTarget, LocalCodingOperation>.from(
      data.operations,
    )..[target] = op;
    state = AsyncData(data.copyWith(operations: next));
  }

  void _clearOperation(LocalCodingTarget target) {
    final data = state.value;
    if (data == null) return;
    final next = Map<LocalCodingTarget, LocalCodingOperation>.from(
      data.operations,
    )..remove(target);
    state = AsyncData(data.copyWith(operations: next));
  }

  void _setCompound(LocalCodingTarget target, LocalCodingCompound? compound) {
    final data = state.value;
    if (data == null) return;
    final next = Map<LocalCodingTarget, LocalCodingCompound>.from(
      data.compounds,
    );
    if (compound == null) {
      next.remove(target);
    } else {
      next[target] = compound;
    }
    state = AsyncData(data.copyWith(compounds: next));
  }

  void _schedulePoll(LocalCodingTarget target, String operationId) {
    _pollTimers[target]?.cancel();
    // A slow stdio response must finish before another read starts.
    _pollTimers[target] = Timer(const Duration(milliseconds: 500),
        () => _tickPoll(target, operationId));
  }

  bool _isCurrentOperation(LocalCodingTarget target, String operationId) =>
      ref.mounted &&
      state.value?.operationFor(target)?.operationId == operationId &&
      (state.value?.operationFor(target)?.isRunning ?? false);

  Future<void> _tickPoll(LocalCodingTarget target, String operationId) async {
    if (!_isCurrentOperation(target, operationId)) return;
    try {
      final op = await _service.pollOperation(operationId);
      if (!_isCurrentOperation(target, operationId)) return;
      _updateOperation(target, op);
      if (op.isTerminal) {
        await _onTerminal(target, op);
      }
    } catch (error) {
      if (!_isCurrentOperation(target, operationId)) return;
      _pollTimers.remove(target)?.cancel();
      _lastTerminal.remove(target);
      _pollFailures[target] = _failure(error);
      _mutex.remove(target)?.complete();
      final data = state.value;
      if (data != null) {
        final next = Map<LocalCodingTarget, LocalCodingOperation>.from(
          data.operations,
        )..remove(target);
        state = AsyncData(data.copyWith(
          operations: next,
          banner: LocalCodingPageBanner(
            kind: LocalCodingPageBannerKind.needsAttention,
            text: error is LocalCodingToolsException
                ? error.userMessage
                : '操作失败，请重新检测',
          ),
        ));
      }
      await _refreshSnapshot();
    } finally {
      if (_isCurrentOperation(target, operationId)) {
        _schedulePoll(target, operationId);
      }
    }
  }

  Future<void> _onTerminal(
      LocalCodingTarget target, LocalCodingOperation op) async {
    _pollTimers.remove(target)?.cancel();
    _lastTerminal[target] = op;
    // 先摘下本次 operation 的 completer,等状态推进完再放行等待方
    // (_advanceCompound 可能为下一段 verify 挂上新的 completer)。
    final completer = _mutex.remove(target);

    final data = state.value;
    final compound = data?.compoundFor(target);
    final inBatch = data?.hasRunningBatch(target.vendor) ?? false;

    if (compound != null &&
        !compound.failed &&
        op.isSucceeded &&
        _matchesCompoundPhase(op, compound)) {
      // 推进复合流程;成功阶段清掉 operation,进入下一段。
      _clearOperation(target);
      await _advanceCompound(target, compound);
      completer?.complete();
      return;
    }

    if (compound != null && (op.isFailed || op.isCancelled)) {
      _setCompound(
          target,
          compound.copyWith(
            failed: true,
            errorCode: op.errorCode.isEmpty
                ? (op.isCancelled ? 'CANCELLED' : 'UNKNOWN')
                : op.errorCode,
          ));
      // 复合流程失败时不清 operation(弹框里还要显示 stage 与错误码);
      // 刷新一次快照让卡片状态跟着回落。
      await _refreshSnapshot();
      completer?.complete();
      return;
    }

    LocalCodingPageBanner? banner;
    if (op.isSucceeded && op.kind == LocalCodingOperationKind.install) {
      banner = LocalCodingPageBanner(
        kind: LocalCodingPageBannerKind.installComplete,
        text: '安装完成，${localCodingTargetName(target)} 已可以在本机使用',
      );
    } else if (op.isSucceeded && op.kind == LocalCodingOperationKind.verify) {
      final warning = op.modelWarning;
      banner = LocalCodingPageBanner(
        kind: LocalCodingPageBannerKind.repairComplete,
        text: warning == null
            ? '检测完成，${localCodingTargetName(target)} 服务连接正常'
            : '检测完成，${localCodingTargetName(target)} 服务连接正常；${localCodingModelWarningText(warning)}',
      );
    } else if (op.isFailed) {
      banner = LocalCodingPageBanner(
        kind: LocalCodingPageBannerKind.needsAttention,
        text: _bannerForFailure(op),
      );
    }
    // 批处理里的单项不各自弹横幅(由批处理统一收尾),失败的 operation 留给
    // 进度弹框显示 stage 与错误码。
    await _refreshSnapshot(banner: inBatch ? null : banner);
    if (!inBatch || op.isSucceeded) _clearOperation(target);
    completer?.complete();
  }

  bool _matchesCompoundPhase(
      LocalCodingOperation op, LocalCodingCompound compound) {
    return (compound.phase == LocalCodingCompoundPhase.install &&
            op.kind == LocalCodingOperationKind.install) ||
        (compound.phase == LocalCodingCompoundPhase.verify &&
            op.kind == LocalCodingOperationKind.verify);
  }

  Future<void> _advanceCompound(
      LocalCodingTarget target, LocalCodingCompound compound) async {
    switch (compound.phase) {
      case LocalCodingCompoundPhase.install:
        _setCompound(
            target, compound.copyWith(phase: LocalCodingCompoundPhase.enable));
        await _refreshSnapshot();
        try {
          final snap = await _service.enable(target);
          final data = state.value;
          if (data != null) {
            state = AsyncData(data.copyWith(
              snapshot: snap,
              lastDetectedAt: DateTime.now()),
            );
          }
        } catch (error) {
          _setCompound(
              target,
              compound.copyWith(
                phase: LocalCodingCompoundPhase.enable,
                failed: true,
                errorCode:
                    error is LocalCodingToolsException ? error.code : 'UNKNOWN',
              ));
          return;
        }
        // enable 完成 → 进入 verify 段。
        _setCompound(
            target, compound.copyWith(phase: LocalCodingCompoundPhase.verify));
        final verifyError = await startVerify(target);
        if (verifyError != null) {
          _setCompound(
              target,
              compound.copyWith(
                phase: LocalCodingCompoundPhase.verify,
                failed: true,
                errorCode: verifyError is LocalCodingToolsException
                    ? verifyError.code
                    : 'UNKNOWN',
              ));
        }
        return;
      case LocalCodingCompoundPhase.verify:
        // 全部成功:清掉复合状态,横幅提示。
        _setCompound(target, null);
        final name = localCodingTargetName(target);
        await _refreshSnapshot(
          banner: LocalCodingPageBanner(
            kind: LocalCodingPageBannerKind.repairComplete,
            text: switch (compound.kind) {
              LocalCodingCompoundKind.installAndEnable => '安装、接入、验证已全部完成',
              LocalCodingCompoundKind.switchToZhiban =>
                '切换完成，$name 已可以使用自定义模型 API',
              LocalCodingCompoundKind.repairSwitch => '修复完成，$name 已可以正常使用',
            },
          ),
        );
        return;
      case LocalCodingCompoundPhase.enable:
      case LocalCodingCompoundPhase.switchWrite:
        // 这两段没有 operation,不会走到这里。
        return;
    }
  }

  String _bannerForFailure(LocalCodingOperation op) {
    if (op.errorCode.isEmpty) return '操作失败，请查看诊断详情';
    final relay = op.kind == LocalCodingOperationKind.verify
        ? localCodingRelayFailure(op.errorCode, op.errorDetail)
        : null;
    if (relay != null) {
      return '${localCodingTargetName(op.target)} 检测未通过：${localCodingRelayFailureSummary(relay, op.errorDetail)}';
    }
    return '${op.kind == LocalCodingOperationKind.install ? '安装' : '验证'}失败：${op.errorCode}';
  }

  Future<void> _refreshSnapshot({LocalCodingPageBanner? banner}) async {
    try {
      final snap = await _service.inspect();
      final data = state.value;
      if (data == null) return;
      state = AsyncData(data.copyWith(
        snapshot: snap,
        lastDetectedAt: DateTime.now(),
        banner: banner,
        clearBanner: banner == null,
      ));
    } catch (_) {
      // inspect 失败保留旧快照;下次交互会再次尝试。
    }
  }

  Future<LocalCodingToolsPageData> _initial() async {
    final snap = await _service.inspect();
    return LocalCodingToolsPageData(
      snapshot: snap,
      lastDetectedAt: DateTime.now(),
    );
  }

  Future<LocalCodingDiagnostics?> diagnostics(LocalCodingTarget target) async {
    LocalCodingDiagnostics? fromBridge;
    try {
      fromBridge = await _service.diagnostics(target);
    } catch (_) {
      fromBridge = null;
    }
    final local = _appFailures[target];
    if (local == null) return fromBridge;
    if (fromBridge == null || fromBridge.isEmpty) return local;
    // 两边都有记录:给更晚发生的那条。
    return local.occurredAt.compareTo(fromBridge.occurredAt) >= 0
        ? local
        : fromBridge;
  }

  /// 一键上报诊断(2026-09-16):把这一次失败的现场打包发给支持,返回反馈编号。
  ///
  /// 本地环境千差万别——工具版本、安装来源、残留进程、缓存、代理——失败往往发生在
  /// 我们控制不到的第三方 CLI 里,只看一个错误码定位不了。用户点一下就能把现场交
  /// 出来,不必截图、跑命令或描述现象。内容只有本机状态与我们自己的错误信息,不含
  /// 配置内容、令牌与用户文件。
  Future<String?> reportDiagnostics(LocalCodingTarget target) async {
    final data = state.value;
    if (data == null) return null;
    final diag = await diagnostics(target);
    final snap = data.snapshot;
    Map<String, dynamic> describe(LocalCodingTarget item) {
      final tool = snap.tools[item];
      final config = snap.configurations[item];
      return {
        'target': item.id,
        if (tool != null) ...{
          'ui_state': tool.uiState.name,
          'installed_version': tool.installedVersion,
          'install_source': tool.installSource,
          'available_version': tool.availableVersion,
          'minimum_version': tool.minimumVersion,
          'supports_enable': tool.supportsEnable,
          'detect_error_code': tool.errorCode,
        },
        if (config != null) ...{
          'current_service': config.currentService.name,
          'config_state': config.state.name,
          'switched': config.switchedToZhiban,
          'drifted': config.globalDrifted,
          'verification_level': config.globalVerificationLevel,
          'last_verified_at': config.globalLastVerifiedAt,
          'upgrade_available': config.globalUpgradeAvailable,
          'config_error_code': config.errorCode,
        },
      };
    }

    final payload = <String, dynamic>{
      'kind': 'local_coding_tools',
      'vendor': target.vendor.name,
      'reported_target': target.id,
      'bridge_version': diag?.bridgeVersion ?? '',
      'proxy_needs_fix': snap.proxyNeedsFix,
      'authorization_connected': snap.authorizationConnected,
      'targets': [for (final item in target.vendor.targets) describe(item)],
      if (diag != null && !diag.isEmpty)
        'failure': {
          'stage': diag.stage,
          'kind': diag.kind,
          'error_code': diag.errorCode,
          'error_detail': diag.errorDetail,
          'occurred_at': diag.occurredAt,
          'suggestions': diag.suggestions,
        },
    };
    final code = diag == null || diag.isEmpty ? '无失败记录' : diag.errorCode;
    return _service.reportDiagnostics(
      title: '本地开发工具 · ${localCodingVendorName(target.vendor)} · $code',
      description: '用户在「本地开发工具」页面上报诊断。'
          '${localCodingTargetName(target)}：$code',
      clientInfo: payload,
    );
  }

  Future<LocalCodingRequirements?> requirements(
      LocalCodingTarget target) async {
    try {
      return await _service.requirements(target);
    } catch (_) {
      return null;
    }
  }

  void dismissBanner() {
    final data = state.value;
    if (data == null || data.banner == null) return;
    state = AsyncData(data.copyWith(clearBanner: true));
  }
}
