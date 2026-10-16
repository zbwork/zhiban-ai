// doc-10 §8.5 登录预热任务模型 (zhiban-app S6)。
// 字段对齐后端脱敏 DTO (docs/contracts/agent-bus-client-contract.md §5b):
// 只含 uuid / 类型 / 状态 / 环境(uuid+name) / 数字员工(uuid+name) / last_error / 时间戳。
// 不含内部自增 id / 凭证 / pod IP。

/// 预热任务状态 (与后端 runtime_prewarm_tasks.status 一致)。
enum PrewarmTaskStatus {
  pending,
  waitingInstance,
  running,
  retrying,
  succeeded,
  failed,
  unknown;

  static PrewarmTaskStatus parse(String? raw) {
    switch (raw) {
      case 'pending':
        return PrewarmTaskStatus.pending;
      case 'waiting_instance':
        return PrewarmTaskStatus.waitingInstance;
      case 'running':
        return PrewarmTaskStatus.running;
      case 'retrying':
        return PrewarmTaskStatus.retrying;
      case 'succeeded':
        return PrewarmTaskStatus.succeeded;
      case 'failed':
        return PrewarmTaskStatus.failed;
      default:
        return PrewarmTaskStatus.unknown;
    }
  }

  /// 终态: 不再变化 (succeeded / failed)。
  bool get isTerminal =>
      this == PrewarmTaskStatus.succeeded || this == PrewarmTaskStatus.failed;
}

/// 预热任务类型 (与后端 runtime_prewarm_tasks.task_kind 一致)。
/// 后端现已包含 instance_init / agent_register / agent_unregister / skill_register / skill_unregister,
/// 浮层必须按 kind 正确分流 title / subtitle, 不能再"非 agent_register 一律当运行实例"。
enum PrewarmTaskKind {
  instanceInit,
  agentRegister,
  agentUnregister,
  skillRegister,
  skillUnregister,
  unknown;

  static PrewarmTaskKind parse(String? raw) {
    switch (raw) {
      case 'instance_init':
        return PrewarmTaskKind.instanceInit;
      case 'agent_register':
        return PrewarmTaskKind.agentRegister;
      case 'agent_unregister':
        return PrewarmTaskKind.agentUnregister;
      case 'skill_register':
        return PrewarmTaskKind.skillRegister;
      case 'skill_unregister':
        return PrewarmTaskKind.skillUnregister;
      default:
        return PrewarmTaskKind.unknown;
    }
  }
}

class PrewarmTask {
  const PrewarmTask({
    required this.uuid,
    required this.taskKind,
    required this.status,
    required this.runtimeEnvironmentUuid,
    required this.runtimeEnvironmentName,
    this.digitalEmployeeUuid,
    this.digitalEmployeeName,
    this.skillSlug,
    this.lastError,
  });

  final String uuid;
  final String
      taskKind; // instance_init | agent_register | agent_unregister | skill_register | skill_unregister
  final PrewarmTaskStatus status;
  final String runtimeEnvironmentUuid;
  final String runtimeEnvironmentName;
  final String? digitalEmployeeUuid; // agent_* / skill_*
  final String? digitalEmployeeName; // agent_* / skill_*
  final String? skillSlug; // 仅 skill_register / skill_unregister (后端 DTO 可选)
  final String? lastError;

  PrewarmTaskKind get kind => PrewarmTaskKind.parse(taskKind);

  bool get isAgentRegister => kind == PrewarmTaskKind.agentRegister;

  String get _deName => (digitalEmployeeName ?? '').trim();
  String get _envName => runtimeEnvironmentName.trim();

  /// 单条任务展示标题 (纯函数, 便于单测), 按 task_kind 分流:
  ///   - instance_init  → 运行环境名
  ///   - agent_register / agent_unregister → 数字员工名
  ///   - skill_*        → 数字员工名 (有 skill_slug 时附 " · slug")
  ///   - unknown        → 优先数字员工名, 其次运行环境名
  String get displayTitle {
    switch (kind) {
      case PrewarmTaskKind.instanceInit:
        return _envName.isNotEmpty ? _envName : '运行环境';
      case PrewarmTaskKind.agentRegister:
      case PrewarmTaskKind.agentUnregister:
        return _deName.isNotEmpty ? _deName : '数字员工';
      case PrewarmTaskKind.skillRegister:
      case PrewarmTaskKind.skillUnregister:
        final base = _deName.isNotEmpty ? _deName : '数字员工';
        final slug = (skillSlug ?? '').trim();
        return slug.isNotEmpty ? '$base · $slug' : base;
      case PrewarmTaskKind.unknown:
        if (_deName.isNotEmpty) return _deName;
        return _envName.isNotEmpty ? _envName : '准备任务';
    }
  }

  /// 单条任务副标题 (任务类型说明)。skill_register 绝不再显示成"运行实例"。
  String get displaySubtitle {
    switch (kind) {
      case PrewarmTaskKind.instanceInit:
        return '运行实例';
      case PrewarmTaskKind.agentRegister:
        return '数字员工';
      case PrewarmTaskKind.agentUnregister:
        return '数字员工删除';
      case PrewarmTaskKind.skillRegister:
        return '技能安装';
      case PrewarmTaskKind.skillUnregister:
        return '技能卸载';
      case PrewarmTaskKind.unknown:
        return '准备任务';
    }
  }

  factory PrewarmTask.fromJson(Map<String, dynamic> json) {
    String? s(dynamic v) {
      final str = v?.toString();
      return (str == null || str.isEmpty) ? null : str;
    }

    return PrewarmTask(
      uuid: (json['uuid'] ?? '').toString(),
      taskKind: (json['task_kind'] ?? '').toString(),
      status: PrewarmTaskStatus.parse(json['status']?.toString()),
      runtimeEnvironmentUuid:
          (json['runtime_environment_uuid'] ?? '').toString(),
      runtimeEnvironmentName:
          (json['runtime_environment_name'] ?? '').toString(),
      digitalEmployeeUuid: s(json['digital_employee_uuid']),
      digitalEmployeeName: s(json['digital_employee_name']),
      skillSlug: s(json['skill_slug']),
      lastError: s(json['last_error']),
    );
  }
}

/// POST /runtime/ensure 的返回 (含降级信息)。
class PrewarmEnsureResult {
  const PrewarmEnsureResult({
    required this.degraded,
    this.skippedReason,
    required this.created,
    required this.reused,
    required this.tasks,
  });

  final bool degraded;
  final String? skippedReason; // 'account_queue_full' | 'tenant_queue_full'
  final int created;
  final int reused;
  final List<PrewarmTask> tasks;

  factory PrewarmEnsureResult.fromJson(Map<String, dynamic> json) {
    final rawTasks = json['tasks'];
    final tasks = rawTasks is List
        ? rawTasks
            .whereType<Map<String, dynamic>>()
            .map(PrewarmTask.fromJson)
            .toList()
        : <PrewarmTask>[];
    return PrewarmEnsureResult(
      degraded: json['degraded'] == true,
      skippedReason: json['skipped_reason']?.toString(),
      created: (json['created'] as num?)?.toInt() ?? 0,
      reused: (json['reused'] as num?)?.toInt() ?? 0,
      tasks: tasks,
    );
  }
}
