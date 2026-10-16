import 'prewarm_task.dart';

enum PrewarmSendBlockReason { runtimeEnvironment, digitalEmployee }

/// 发送守卫只看当前数字员工及其运行环境关联的 active 预热任务。
///
/// 右下角任务列表是账号级全局视图；其他数字员工或其他运行环境的任务
/// 不应阻断当前会话。全局 ensuring 状态没有任务归属信息，不在这里判断。
PrewarmSendBlockReason? prewarmSendBlockReason({
  required Iterable<PrewarmTask> tasks,
  required String digitalEmployeeUuid,
  required String runtimeEnvironmentUuid,
}) {
  final agentUuid = digitalEmployeeUuid.trim();
  final runtimeUuid = runtimeEnvironmentUuid.trim();
  var agentPreparing = false;
  var runtimePreparing = false;

  for (final task in tasks) {
    if (task.status.isTerminal) continue;

    if (task.kind == PrewarmTaskKind.instanceInit &&
        runtimeUuid.isNotEmpty &&
        task.runtimeEnvironmentUuid.trim() == runtimeUuid) {
      runtimePreparing = true;
      continue;
    }

    final isAgentLoadOrUpdate = task.kind == PrewarmTaskKind.agentRegister ||
        task.kind == PrewarmTaskKind.skillRegister ||
        task.kind == PrewarmTaskKind.skillUnregister;
    if (isAgentLoadOrUpdate &&
        agentUuid.isNotEmpty &&
        (task.digitalEmployeeUuid ?? '').trim() == agentUuid) {
      agentPreparing = true;
    }
  }

  if (runtimePreparing) return PrewarmSendBlockReason.runtimeEnvironment;
  if (agentPreparing) return PrewarmSendBlockReason.digitalEmployee;
  return null;
}
