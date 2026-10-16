import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_install_agent_dialog.dart';

/// F03 §1.5.4 技能广场闭环：「选择安装到哪个数字员工」弹框渲染态。
///
/// 覆盖：只列 can_manage_skills=true 的数字员工；已装行展示「使用」、
/// 未装行展示「添加」；无可管理数字员工时展示空态引导。
/// （绑定提交顺序语义由 agent_skill_binding_update_test 覆盖。）

class _FakeSvc extends OpenClawChatService {
  _FakeSvc(this.agents);
  final List<AgentItem> agents;

  @override
  Future<List<AgentItem>> listAgents() async => agents;
}

AgentItem _agent({
  required String id,
  required String name,
  bool canManage = true,
  List<Map<String, dynamic>> skills = const [],
}) {
  return AgentItem.fromJson({
    'uuid': id,
    'name': name,
    'can_manage_skills': canManage,
    'skills': skills,
  });
}

Skill _skill(String slug) {
  return Skill(
    uuid: 'skl_$slug',
    slug: slug,
    displayName: '演示技能',
    description: '',
    source: 'internal',
    status: 'active',
    installStatus: '',
    isInstalled: false,
    downloadCount: 0,
    versionCount: 0,
  );
}

Widget _host(List<AgentItem> agents, Skill skill) {
  return ProviderScope(
    overrides: [
      chatServiceProvider.overrideWith((ref) => _FakeSvc(agents))
    ],
    child: MaterialApp(
      home: Scaffold(body: SkillInstallAgentDialog(skill: skill)),
    ),
  );
}

void main() {
  testWidgets('只列可管理数字员工；已装行「使用」，未装行「添加」', (tester) async {
    final agents = [
      _agent(id: 'a1', name: '小张', skills: [
        {'slug': 'demo', 'name': '演示技能', 'isInstalled': true},
      ]),
      _agent(id: 'a2', name: '小李'),
      _agent(id: 'a3', name: '企业员工', canManage: false),
    ];
    await tester.pumpWidget(_host(agents, _skill('demo')));
    await tester.pumpAndSettle();

    expect(find.text('小张'), findsOneWidget);
    expect(find.text('小李'), findsOneWidget);
    // 非创建者 / ZAP（can_manage_skills=false）不出现在目标列表。
    expect(find.text('企业员工'), findsNothing);
    expect(find.text('使用'), findsOneWidget);
    expect(find.text('添加'), findsOneWidget);
    expect(find.text('选择安装到哪个数字员工'), findsOneWidget);
  });

  testWidgets('无可管理数字员工时展示空态引导', (tester) async {
    final agents = [
      _agent(id: 'a3', name: '企业员工', canManage: false)
    ];
    await tester.pumpWidget(_host(agents, _skill('demo')));
    await tester.pumpAndSettle();

    expect(find.text('暂无可添加技能的数字员工'), findsOneWidget);
    expect(find.text('添加'), findsNothing);
  });
}
