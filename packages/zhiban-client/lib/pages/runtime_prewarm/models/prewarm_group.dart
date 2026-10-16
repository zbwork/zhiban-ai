// 预热浮层「聚合准备视图」模型 (docs/contracts/agent-bus-client-contract.md §5b)。
//
// 后端 runtime_prewarm_tasks 仍是 instance_init / agent_register / agent_unregister /
// skill_register / skill_unregister 原子任务,**逐条**下发。客户端**不得平铺**,必须聚合成两层一级视图:
//   1. 初始化运行环境        —— 聚合全部 instance_init,展开后每个 runtime environment 一行。
//   2. 加载/更新/删除数字员工 - 名 —— 按 digital_employee_uuid 聚合该员工的 agent_register +
//      agent_unregister + skill_register + skill_unregister,展开后含「注册/更新/删除数字员工」+ 各技能安装/卸载。
//
// 纯前端聚合,仅依赖现有 DTO 字段 (task_kind / digital_employee_uuid /
// runtime_environment_uuid / runtime_environment_name / skill_slug)。后端不变。
//
// 本文件全是纯函数 / 纯数据,便于单测。

import 'prewarm_task.dart';

/// 一级分组类型。
enum PrewarmGroupKind { runtimeInit, digitalEmployee }

/// 展开后的子项 (label + 原子任务状态)。状态 chip 复用 PrewarmTaskStatus。
class PrewarmChildRow {
  const PrewarmChildRow({
    required this.uuid,
    required this.label,
    required this.status,
  });

  final String uuid;
  final String label;
  final PrewarmTaskStatus status;
}

/// 一级聚合行。
class PrewarmGroup {
  const PrewarmGroup({
    required this.kind,
    required this.key,
    required this.title,
    required this.children,
  });

  final PrewarmGroupKind kind;

  /// 稳定 key (展开态记忆用): 运行环境组固定 'runtime'; 数字员工组 `de:<uuid>`。
  final String key;

  /// 一级标题: 「初始化运行环境」/「加载数字员工 - 名」/「更新数字员工 - 名」/「删除数字员工 - 名」。
  final String title;

  /// 展开后的子项 (有序: 运行环境组按 instance_init 顺序; 员工组 agent_register 在前、技能在后)。
  final List<PrewarmChildRow> children;

  int get total => children.length;

  int get succeededCount =>
      children.where((c) => c.status == PrewarmTaskStatus.succeeded).length;

  int get failedCount =>
      children.where((c) => c.status == PrewarmTaskStatus.failed).length;

  int get terminalCount => children.where((c) => c.status.isTerminal).length;

  bool get hasActive => children.any((c) => !c.status.isTerminal);

  bool get hasFailed => failedCount > 0;

  bool get hasRetrying =>
      children.any((c) => c.status == PrewarmTaskStatus.retrying);

  /// 总数未知 / 无子项 → 不确定进度态 (UI 用不确定进度条, 不崩)。
  bool get indeterminate => total == 0;

  /// 进度 0..1: 终态(succeeded+failed)/总数。failed 也算终态计入。
  /// total==0 时返回 null (不确定 / 不除零)。
  double? get progress => total == 0 ? null : terminalCount / total;

  /// 一级行简短状态: 准备中 / 已就绪 / 部分失败 / 初始化中。
  /// 优先级: 任一 failed → 部分失败; 否则任一 retrying → 初始化中;
  /// 否则仍有 active → 准备中; 全 succeeded → 已就绪。
  ///
  /// retrying 不叫"重试中"——后端这个状态同时覆盖"真失败重试"和"实例启动
  /// 中/让位这种正常等待"（见 runtimeprewarm repo.go MarkDeferred 注释），
  /// 客户端拿不到 attempts 区分两者。新建数字员工首次进这个状态是完全正常
  /// 的编排过程，"重试中"这个词会让用户误以为一创建就出错了。
  String get statusLabel {
    if (hasFailed) return '部分失败';
    if (hasRetrying) return '初始化中';
    if (hasActive) return '准备中';
    return '已就绪';
  }
}

/// 把后端平铺的原子任务聚合成两层一级视图。纯函数。
///
/// 路由规则:
///   - 有 digital_employee_uuid 的任务 (agent_register / skill_register /
///     agent_unregister / skill_unregister, 以及未识别但带员工的任务) → 该员工组。
///   - 其余 (instance_init, 以及未识别且无员工的任务) → 运行环境组。
/// 运行环境组恒在最前; 员工组按首次出现顺序。
List<PrewarmGroup> aggregatePrewarmTasks(List<PrewarmTask> tasks) {
  final runtimeTasks = <PrewarmTask>[];
  // 保持首次出现顺序的员工分组。
  final deOrder = <String>[];
  final deTasks = <String, List<PrewarmTask>>{};

  for (final t in tasks) {
    final de = (t.digitalEmployeeUuid ?? '').trim();
    if (de.isNotEmpty) {
      if (!deTasks.containsKey(de)) {
        deOrder.add(de);
        deTasks[de] = <PrewarmTask>[];
      }
      deTasks[de]!.add(t);
    } else {
      runtimeTasks.add(t);
    }
  }

  final groups = <PrewarmGroup>[];

  if (runtimeTasks.isNotEmpty) {
    groups.add(PrewarmGroup(
      kind: PrewarmGroupKind.runtimeInit,
      key: 'runtime',
      title: '初始化运行环境',
      children: [
        for (final t in runtimeTasks)
          PrewarmChildRow(
            uuid: t.uuid,
            label: _runtimeChildLabel(t),
            status: t.status,
          ),
      ],
    ));
  }

  for (final de in deOrder) {
    final ts = deTasks[de]!;
    final isDelete = _isDeleteOperation(ts);
    final isUpdate = _isUpdateOperation(ts);
    final name = _deName(ts);
    groups.add(PrewarmGroup(
      kind: PrewarmGroupKind.digitalEmployee,
      key: 'de:$de',
      title:
          '${isDelete ? '删除数字员工' : (isUpdate ? '更新数字员工' : '加载数字员工')} - $name',
      children: _deChildren(ts, isUpdate: isUpdate, isDelete: isDelete),
    ));
  }

  return groups;
}

/// 运行环境组子项 label: 取 runtime_environment_name (如「OpenClaw 工作负载服务」)。
String _runtimeChildLabel(PrewarmTask t) {
  final env = t.runtimeEnvironmentName.trim();
  if (env.isNotEmpty) return env;
  // 未识别且无员工无环境名 → 回退副标题 (不崩, 不平铺技能)。
  return t.kind == PrewarmTaskKind.instanceInit ? '运行环境' : t.displaySubtitle;
}

/// 「删除」: 含 agent_unregister → 删除数字员工。
bool _isDeleteOperation(List<PrewarmTask> ts) {
  return ts.any((t) => t.kind == PrewarmTaskKind.agentUnregister);
}

/// 「加载」vs「更新」: 含 skill_unregister、或无 agent_register (纯技能变更) → 更新; 否则加载。
bool _isUpdateOperation(List<PrewarmTask> ts) {
  final hasUnregister =
      ts.any((t) => t.kind == PrewarmTaskKind.skillUnregister);
  final hasAgentRegister =
      ts.any((t) => t.kind == PrewarmTaskKind.agentRegister);
  return hasUnregister || !hasAgentRegister;
}

String _deName(List<PrewarmTask> ts) {
  for (final t in ts) {
    final n = (t.digitalEmployeeName ?? '').trim();
    if (n.isNotEmpty) return n;
  }
  return '数字员工';
}

/// 员工组子项: agent 任务在前 (注册/更新/删除数字员工), 技能任务在后 (安装/卸载 · slug)。
/// 用分桶拼接而非 List.sort —— Dart 的 List.sort **不保证稳定**, 同类任务顺序可能乱;
/// 分桶按 (agent_register → skill_* → 其它) 拼接, 每桶内保持输入原始顺序。
List<PrewarmChildRow> _deChildren(
  List<PrewarmTask> ts, {
  required bool isUpdate,
  required bool isDelete,
}) {
  final agents = <PrewarmTask>[];
  final skills = <PrewarmTask>[];
  final others = <PrewarmTask>[];
  for (final t in ts) {
    if (t.kind == PrewarmTaskKind.agentRegister ||
        t.kind == PrewarmTaskKind.agentUnregister) {
      agents.add(t);
    } else if (t.kind == PrewarmTaskKind.skillRegister ||
        t.kind == PrewarmTaskKind.skillUnregister) {
      skills.add(t);
    } else {
      others.add(t);
    }
  }
  final ordered = [...agents, ...skills, ...others];
  return [
    for (final t in ordered)
      PrewarmChildRow(
        uuid: t.uuid,
        label: _deChildLabel(t, isUpdate: isUpdate, isDelete: isDelete),
        status: t.status,
      ),
  ];
}

String _deChildLabel(
  PrewarmTask t, {
  required bool isUpdate,
  required bool isDelete,
}) {
  switch (t.kind) {
    case PrewarmTaskKind.agentRegister:
      return isUpdate ? '更新数字员工' : '注册数字员工';
    case PrewarmTaskKind.agentUnregister:
      return '删除数字员工';
    case PrewarmTaskKind.skillRegister:
      return _withSlug('安装技能', t.skillSlug);
    case PrewarmTaskKind.skillUnregister:
      return _withSlug('卸载技能', t.skillSlug);
    default:
      // 未识别 task_kind → 通用展示, 不报错。
      return t.displaySubtitle;
  }
}

String _withSlug(String base, String? slug) {
  final s = (slug ?? '').trim();
  return s.isNotEmpty ? '$base · $s' : base;
}
