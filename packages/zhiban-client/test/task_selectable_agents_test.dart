import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/task/providers/task_provider.dart';

void main() {
  test('task agents include personal and chat-capable organization agents', () {
    final agents = taskSelectableAgentsFromSnapshot(
      ContactAgentsSnapshot(
        personal: [_contact('personal-1', '测试001')],
        enterprise: [
          _contact('enterprise-1', '行政专员'),
          _contact('disabled-1', '已停用员工', canChat: false),
        ],
        platform: [_contact('platform-1', '平台副本')],
      ),
    );

    expect(
      agents.map((agent) => agent.agentId),
      ['personal-1', 'enterprise-1', 'platform-1']
    );
    expect(
      agents.map((agent) => agent.name),
      ['测试001', '行政专员', '平台副本']
    );
  });

  test(
      'cloud-disabled candidates contain only local, including platform agents',
      () {
    final snapshot = ContactAgentsSnapshot(
      personal: [_contact('cloud', '云端', executionLocus: 'cloud')],
      enterprise: [_contact('local', '本地')],
      platform: [_contact('platform', '平台本地')],
    );
    expect(
        taskSelectableAgentsFromSnapshot(snapshot, cloudEnabled: false)
            .map((a) => a.agentId),
        ['local', 'platform']);
    expect(taskSelectableAgentsFromSnapshot(snapshot, cloudEnabled: true),
        hasLength(3));
  });

  test('task agents discard empty IDs and deduplicate by agent UUID', () {
    final agents = taskSelectableAgentsFromSnapshot(
      ContactAgentsSnapshot(
        personal: [
          _contact('same-agent', '个人名称'),
          _contact('  ', '无效员工')
        ],
        enterprise: [_contact('same-agent', '组织名称')],
        platform: const [],
      ),
    );

    expect(agents, hasLength(1));
    expect(agents.single.agentId, 'same-agent');
    expect(agents.single.name, '个人名称');
  });
}

ContactAgent _contact(
  String id,
  String name, {
  bool canChat = true,
  String executionLocus = 'local',
}) {
  return ContactAgent(
    id: id,
    displayName: name,
    avatarUrl: '',
    subtitle: '',
    positionLabel: '',
    departmentName: '',
    source: 'enterprise',
    skills: const [],
    apps: const [],
    lifecycleStatus: canChat ? 'active' : 'disabled',
    canChat: canChat,
    executionLocus: executionLocus,
  );
}
