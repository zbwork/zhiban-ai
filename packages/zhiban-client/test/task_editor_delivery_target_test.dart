import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/cron/models/prompt_template.dart';
import 'package:zhiban_client/cron/services/prompt_template_service.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/task/models/task_models.dart';
import 'package:zhiban_client/pages/task/widgets/task_editor_content.dart';

class _EmptyPromptTemplateService extends CronPromptTemplateService {
  @override
  Future<List<PromptTemplateSummary>> listVisibleTemplates() async => const [];

  @override
  Future<PromptTemplateDetail> getVariables(String uuid) =>
      throw UnsupportedError('not used');
}

void main() {
  AgentItem agent({
    String id = 'agent-new',
    String name = '新建数字员工'
  }) =>
      AgentItem.fromJson({
        'uuid': id,
        'name': name,
        'status': 'published'
      });

  ConversationItem groupConversation({
    required String id,
    required String title,
    required String agentUuid,
    String conversationAgentId = '',
  }) =>
      ConversationItem(
        conversationId: id,
        title: title,
        agentId: conversationAgentId,
        agentName: '',
        kind: 'group',
        participants: [
          ConversationParticipant(
            kind: 'agent',
            accountUuid: '',
            agentUuid: agentUuid,
            displayName: '群内数字员工',
            avatar: '',
          ),
        ],
      );

  testWidgets(
      'local agent hides group delivery and explains online requirement',
      (tester) async {
    final local = AgentItem.fromJson(
        {'uuid': 'local-agent', 'name': '本地员工', 'execution_locus': 'local'});
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 900,
                height: 1200,
                child: TaskEditorContent(
                    agents: [
                      local
                    ],
                    conversations: [
                      groupConversation(
                          id: 'group-local',
                          title: '本地所在群',
                          agentUuid: 'local-agent'),
                      const ConversationItem(
                          conversationId: 'cloud-room-conv',
                          title: '云端会话',
                          agentId: 'local-agent',
                          agentName: '本地员工',
                          kind: 'agent_direct',
                          roomUuid: 'cloud-room'),
                    ],
                    promptTemplateService: _EmptyPromptTemplateService(),
                    onCancel: () {},
                    onSubmit: (_) {})))));
    await tester.pump();
    expect(find.textContaining('电脑需保持登录和在线'), findsOneWidget);
    final direct = find.text('单聊 · 本地员工');
    await tester.ensureVisible(direct);
    await tester.pump();
    await tester.tap(direct);
    await tester.pump();
    expect(find.text('群聊 · 本地所在群'), findsNothing);
    await tester.tap(find.text('单聊 · 本地员工').last);
    await tester.pump();
  });

  testWidgets('new agent without conversations still shows direct delivery',
      (tester) async {
    final newAgent = agent();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 1200,
            child: TaskEditorContent(
              agents: [newAgent],
              conversations: const [],
              promptTemplateService: _EmptyPromptTemplateService(),
              onCancel: () {},
              onSubmit: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('单聊 · 新建数字员工'), findsOneWidget);
    expect(find.text('暂无可用会话'), findsNothing);
  });

  testWidgets(
      'default delivery follows selectable agent instead of unrelated conversation',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 1200,
            child: TaskEditorContent(
              agents: [agent(id: 'agent-test-001', name: '测试001')],
              conversations: const [
                ConversationItem(
                  conversationId: 'direct-admin',
                  title: '行政专员',
                  agentId: 'agent-admin',
                  agentName: '行政专员',
                  kind: 'agent-direct',
                ),
              ],
              promptTemplateService: _EmptyPromptTemplateService(),
              onCancel: () {},
              onSubmit: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('测试001'), findsOneWidget);
    expect(find.text('单聊 · 测试001'), findsOneWidget);
    expect(find.text('单聊 · 行政专员'), findsNothing);
  });

  testWidgets('editing mismatched legacy delivery falls back to agent direct',
      (tester) async {
    final legacyJob = CronJob.fromJson({
      'uuid': 'job-1',
      'name': '旧任务',
      'agent_uuid': 'agent-test-001',
      'enabled': true,
      'schedule_cron': '*/30 * * * *',
      'payload': {'prompt': '执行任务'},
      'delivery': {'conversation_uuid': 'direct-admin'},
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 1200,
            child: TaskEditorContent(
              job: legacyJob,
              agents: [agent(id: 'agent-test-001', name: '测试001')],
              conversations: const [
                ConversationItem(
                  conversationId: 'direct-admin',
                  title: '行政专员',
                  agentId: 'agent-admin',
                  agentName: '行政专员',
                  kind: 'agent-direct',
                ),
              ],
              promptTemplateService: _EmptyPromptTemplateService(),
              onCancel: () {},
              onSubmit: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('单聊 · 测试001'), findsOneWidget);
    expect(find.text('单聊 · 行政专员'), findsNothing);
  });

  testWidgets('switching agent resets and filters delivery targets',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 1200,
            child: TaskEditorContent(
              agents: [
                agent(id: 'agent-a', name: '员工A'),
                agent(id: 'agent-b', name: '员工B'),
              ],
              conversations: [
                const ConversationItem(
                  conversationId: 'direct-a',
                  title: '员工A',
                  agentId: 'agent-a',
                  agentName: '员工A',
                  kind: 'agent-direct',
                ),
                const ConversationItem(
                  conversationId: 'direct-b',
                  title: '员工B',
                  agentId: 'agent-b',
                  agentName: '员工B',
                  kind: 'agent-direct',
                ),
                groupConversation(
                  id: 'group-a',
                  title: 'A所在群',
                  agentUuid: 'agent-a',
                ),
                groupConversation(
                  id: 'group-b',
                  title: 'B所在群',
                  agentUuid: 'agent-b',
                ),
              ],
              promptTemplateService: _EmptyPromptTemplateService(),
              onCancel: () {},
              onSubmit: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final executingAgentA = find.text('员工A');
    await tester.ensureVisible(executingAgentA);
    await tester.pump();
    await tester.tap(executingAgentA);
    await tester.pump();
    await tester.tap(find.text('员工B'));
    await tester.pump();

    final directB = find.text('单聊 · 员工B');
    expect(directB, findsOneWidget);
    await tester.ensureVisible(directB);
    await tester.tap(directB);
    await tester.pump();

    expect(find.text('群聊 · B所在群'), findsOneWidget);
    expect(find.text('群聊 · A所在群'), findsNothing);

    await tester.tap(find.text('群聊 · B所在群'));
    await tester.pump();
  });

  testWidgets('group options only include groups containing selected agent',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 1200,
            child: TaskEditorContent(
              agents: [agent()],
              conversations: [
                groupConversation(
                  id: 'group-ok',
                  title: '已加入群聊',
                  agentUuid: 'agent-new',
                ),
                groupConversation(
                  id: 'group-other',
                  title: '未加入群聊',
                  agentUuid: 'agent-other',
                ),
              ],
              promptTemplateService: _EmptyPromptTemplateService(),
              onCancel: () {},
              onSubmit: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final directTarget = find.text('单聊 · 新建数字员工');
    await tester.ensureVisible(directTarget);
    await tester.pump();
    await tester.tap(directTarget);
    await tester.pump();

    expect(find.text('群聊 · 已加入群聊'), findsOneWidget);
    expect(find.text('群聊 · 未加入群聊'), findsNothing);

    // 选择候选项关闭 overlay，避免测试卸载仍展开的 UiSelect。
    await tester.tap(find.text('群聊 · 已加入群聊'));
    await tester.pump();
  });

  testWidgets('group without participant evidence is not a delivery option',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 1200,
            child: TaskEditorContent(
              agents: [agent()],
              conversations: const [
                ConversationItem(
                  conversationId: 'group-unknown',
                  title: '成员不明群聊',
                  agentId: '',
                  agentName: '',
                  kind: 'group',
                ),
              ],
              promptTemplateService: _EmptyPromptTemplateService(),
              onCancel: () {},
              onSubmit: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final directTarget = find.text('单聊 · 新建数字员工');
    await tester.ensureVisible(directTarget);
    await tester.tap(directTarget);
    await tester.pump();

    expect(find.text('群聊 · 成员不明群聊'), findsNothing);

    // 重新选中单聊收起 overlay。
    await tester.tap(find.text('单聊 · 新建数字员工').last);
    await tester.pump();
  });

  testWidgets('selecting a delivery group does not change executing agent',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 1200,
            child: TaskEditorContent(
              agents: [
                agent(),
                agent(id: 'agent-other', name: '另一数字员工'),
              ],
              conversations: [
                const ConversationItem(
                  conversationId: 'direct-new',
                  title: '新建数字员工',
                  agentId: 'agent-new',
                  agentName: '新建数字员工',
                  kind: 'agent-direct',
                ),
                groupConversation(
                  id: 'group-target',
                  title: '目标群聊',
                  agentUuid: 'agent-new',
                  // 群会话数据可能带有 agentId，但它不是执行者选择的权威来源。
                  conversationAgentId: 'agent-other',
                ),
              ],
              promptTemplateService: _EmptyPromptTemplateService(),
              onCancel: () {},
              onSubmit: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final directTarget = find.text('单聊 · 新建数字员工');
    await tester.ensureVisible(directTarget);
    await tester.pump();
    await tester.tap(directTarget);
    await tester.pump();
    await tester.tap(find.text('群聊 · 目标群聊'));
    await tester.pump();

    expect(find.text('新建数字员工'), findsOneWidget);
    expect(find.text('另一数字员工'), findsNothing);
    expect(find.text('群聊 · 目标群聊'), findsOneWidget);
  });
}
