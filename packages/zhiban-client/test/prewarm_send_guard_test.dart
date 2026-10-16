import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/runtime_prewarm/models/prewarm_send_guard.dart';
import 'package:zhiban_client/pages/runtime_prewarm/models/prewarm_task.dart';

PrewarmTask _task({
  required String kind,
  String status = 'running',
  String runtimeUuid = 'runtime-a',
  String? agentUuid,
}) {
  return PrewarmTask.fromJson({
    'uuid': '$kind-$status-${agentUuid ?? runtimeUuid}',
    'task_kind': kind,
    'status': status,
    'runtime_environment_uuid': runtimeUuid,
    'runtime_environment_name': runtimeUuid,
    if (agentUuid != null) 'digital_employee_uuid': agentUuid,
  });
}

void main() {
  group('prewarmSendBlockReason', () {
    test('当前数字员工加载或更新中时阻断', () {
      for (final kind in [
        'agent_register',
        'skill_register',
        'skill_unregister',
      ]) {
        expect(
          prewarmSendBlockReason(
            tasks: [_task(kind: kind, agentUuid: 'agent-a')],
            digitalEmployeeUuid: 'agent-a',
            runtimeEnvironmentUuid: 'runtime-a',
          ),
          PrewarmSendBlockReason.digitalEmployee,
          reason: kind,
        );
      }
    });

    test('当前数字员工绑定的运行环境初始化中时阻断', () {
      expect(
        prewarmSendBlockReason(
          tasks: [_task(kind: 'instance_init', runtimeUuid: 'runtime-a')],
          digitalEmployeeUuid: 'agent-a',
          runtimeEnvironmentUuid: 'runtime-a',
        ),
        PrewarmSendBlockReason.runtimeEnvironment,
      );
    });

    test('其他数字员工任务不阻断', () {
      expect(
        prewarmSendBlockReason(
          tasks: [_task(kind: 'agent_register', agentUuid: 'agent-b')],
          digitalEmployeeUuid: 'agent-a',
          runtimeEnvironmentUuid: 'runtime-a',
        ),
        isNull,
      );
    });

    test('其他运行环境任务不阻断', () {
      expect(
        prewarmSendBlockReason(
          tasks: [_task(kind: 'instance_init', runtimeUuid: 'runtime-b')],
          digitalEmployeeUuid: 'agent-a',
          runtimeEnvironmentUuid: 'runtime-a',
        ),
        isNull,
      );
    });

    test('终态任务不阻断', () {
      expect(
        prewarmSendBlockReason(
          tasks: [
            _task(
              kind: 'instance_init',
              status: 'failed',
              runtimeUuid: 'runtime-a',
            ),
            _task(
              kind: 'agent_register',
              status: 'succeeded',
              agentUuid: 'agent-a',
            ),
          ],
          digitalEmployeeUuid: 'agent-a',
          runtimeEnvironmentUuid: 'runtime-a',
        ),
        isNull,
      );
    });

    test('尚无任务明细时不因全局 ensure 状态阻断', () {
      expect(
        prewarmSendBlockReason(
          tasks: const [],
          digitalEmployeeUuid: 'agent-a',
          runtimeEnvironmentUuid: 'runtime-a',
        ),
        isNull,
      );
    });
  });
}
