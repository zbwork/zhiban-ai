import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/cron/models/prompt_template.dart';
import 'package:zhiban_client/cron/services/prompt_template_service.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/widgets/create_agent_dialog.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/providers/skills_providers.dart';
import 'package:zhiban_client/pages/skills/services/skills_service.dart';
import 'package:zhiban_client/pages/task/widgets/task_editor_content.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

class _Templates extends CronPromptTemplateService {
  @override
  Future<List<PromptTemplateSummary>> listVisibleTemplates() async => [];
}

class _Chat extends OpenClawChatService {
  @override
  Future<List<RuntimeEnvironmentOption>> listRuntimeEnvironments() async => [];
}

class _Skills extends OpenClawSkillsService {
  @override
  Future<List<SkillCategory>> listCategories() async => [];

  @override
  Future<Map<String, dynamic>> listSkills(
          {String? keyword,
          String? source,
          int? categoryId,
          int page = 1,
          int pageSize = 20,
          String? sortBy,
          String? sortOrder}) async =>
      {
        'list': [
          Skill.fromJson({
            'uuid': 'qa',
            'slug': 'qa',
            'display_name': '测试技能',
            'source': 'official',
          })
        ]
      };
}

Future<void> _mount(WidgetTester tester, Widget page, bool compact) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(compact ? 393 : 900, 852);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      chatServiceProvider.overrideWithValue(_Chat()),
      skillsServiceProvider.overrideWithValue(_Skills())
    ],
    child: MaterialApp(theme: AppTheme.light(), home: Scaffold(body: page)),
  ));
  await tester.pumpAndSettle();
}

Finder _input(String hint) => find.descendant(
    of: find.byWidgetPredicate((w) => w is UiInputField && w.hintText == hint),
    matching: find.byType(TextField));

Future<void> _enter(WidgetTester tester, String hint, String value) async {
  final field = _input(hint);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester, String label, String option) async {
  final select = find.byWidgetPredicate(
      (w) => w is UiSelect<String> && w.placeholder == label);
  await tester.ensureVisible(select);
  await tester.tap(select);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

void main() {
  for (final compact in [true, false]) {
    testWidgets('task required errors persist at fields ($compact)',
        (tester) async {
      var submits = 0;
      await _mount(
          tester,
          TaskEditorContent(
            compact: compact,
            showHeader: !compact,
            agents: [
              AgentItem.fromJson(
                  {'uuid': 'a', 'name': '员工', 'status': 'published'})
            ],
            promptTemplateService: _Templates(),
            onCancel: () {},
            onSubmit: (_) => submits++,
          ),
          compact);
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(submits, 0);
      expect(find.text('请输入任务名称'), findsOneWidget);
      expect(find.text('请输入执行内容'), findsOneWidget);
      await _enter(tester, '如：晨间简报', '   ');
      expect(find.text('请输入任务名称'), findsOneWidget);
      await _enter(tester, '如：晨间简报', '日报');
      await _enter(tester, '描述你希望代理定时执行的任务。', '汇总日报');
      expect(find.text('请输入任务名称'), findsNothing);
      expect(find.text('请输入执行内容'), findsNothing);
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(submits, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'agent requires description and skills before returning draft ($compact)',
        (tester) async {
      CreateAgentDraft? result;
      await _mount(
          tester,
          Builder(
              builder: (context) => TextButton(
                    onPressed: () async {
                      result = await Navigator.of(context)
                          .push<CreateAgentDraft>(MaterialPageRoute(
                        builder: (_) => Scaffold(
                            body: CreateAgentEditor(
                          compact: compact,
                          initialDraft: const CreateAgentDraft(
                              name: '测试员工',
                              description: '',
                              avatarUrl: '',
                              executionLocus: 'local'),
                        )),
                      ));
                    },
                    child: const Text('打开'),
                  )),
          compact);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建数字员工').last);
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.byType(CreateAgentEditor), findsOneWidget);
      expect(find.text('请输入主要职责'), findsOneWidget);
      expect(find.text('请至少选择一项核心技能'), findsOneWidget);
      await _enter(tester, '例如：帮助处理招聘流程与候选人答疑', '   ');
      expect(find.text('请输入主要职责'), findsOneWidget);
      await _enter(tester, '例如：帮助处理招聘流程与候选人答疑', '汇总日报');
      expect(find.text('请输入主要职责'), findsNothing);
      expect(find.text('请至少选择一项核心技能'), findsOneWidget);
      // Complete the real picker flow, then remove/reselect to revalidate.
      Future<void> pickSkill() async {
        await tester.ensureVisible(find.text('选择技能'));
        await tester.tap(find.text('选择技能'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('skill_picker_row_qa')));
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
      }

      await pickSkill();
      expect(find.text('请至少选择一项核心技能'), findsNothing);
      await tester.ensureVisible(find.byIcon(Icons.close_rounded));
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text('请至少选择一项核心技能'), findsOneWidget);
      await pickSkill();
      await tester.tap(find.text('创建数字员工').last);
      await tester.pumpAndSettle();
      expect(result?.name, '测试员工');
      expect(result?.description, '汇总日报');
      expect(result?.skillSlugs, ['qa']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('task validates only active schedule and scrolls to first error',
      (tester) async {
    var submits = 0;
    await _mount(
        tester,
        TaskEditorContent(
            compact: true,
            showHeader: false,
            agents: [
              AgentItem.fromJson(
                  {'uuid': 'a', 'name': '员工', 'status': 'published'})
            ],
            promptTemplateService: _Templates(),
            onCancel: () {},
            onSubmit: (_) => submits++),
        true);
    await tester.ensureVisible(find.text('投递会话 *'));
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_input('如：晨间简报')).dy, greaterThanOrEqualTo(0));
    expect(tester.getBottomRight(_input('如：晨间简报')).dy, lessThan(750));
    await _enter(tester, '如：晨间简报', '日报');
    await _enter(tester, '描述你希望代理定时执行的任务。', '汇总日报');
    for (final value in ['', '0', 'abc', '4', '60']) {
      await _enter(tester, '30', value);
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(submits, 0);
    }
    await _select(tester, '重复方式', 'Cron 表达式');
    await _enter(tester, '如：0 8 * * *', '   ');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(submits, 0);
    expect(find.text('请输入 Cron 表达式'), findsOneWidget);
    expect(find.text('分钟间隔最大 59，更长间隔请改用小时单位'), findsNothing);
    await _enter(tester, '如：0 8 * * *', '0 8 * * *');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(submits, 1);
    await _select(tester, '重复方式', '单次执行');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(submits, 1);
    expect(find.text('请选择执行时间'), findsOneWidget);
    await _select(tester, '重复方式', '固定频率');
    await _enter(tester, '30', '5');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(submits, 2);
    expect(find.text('请选择执行时间'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty agent directory blocks task at both selection fields',
      (tester) async {
    var submits = 0;
    await _mount(
        tester,
        TaskEditorContent(
            compact: true,
            showHeader: false,
            promptTemplateService: _Templates(),
            onCancel: () {},
            onSubmit: (_) => submits++),
        true);
    await _enter(tester, '如：晨间简报', '日报');
    await _enter(tester, '描述你希望代理定时执行的任务。', '汇总日报');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(submits, 0);
    expect(find.text('请选择数字员工'), findsOneWidget);
    expect(find.text('请选择投递会话'), findsOneWidget);
  });

  testWidgets('input validators follow programmatic controller changes',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final formKey = GlobalKey<FormState>();
    await _mount(
        tester,
        Form(
            key: formKey,
            autovalidateMode: AutovalidateMode.always,
            child: UiInputField(
                controller: controller,
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '必填内容' : null)),
        true);
    expect(formKey.currentState!.validate(), isFalse);
    controller.text = '模板自动填入的内容';
    await tester.pumpAndSettle();
    expect(find.text('必填内容'), findsNothing);
    expect(formKey.currentState!.validate(), isTrue);
    controller.clear();
    await tester.pumpAndSettle();
    expect(find.text('必填内容'), findsOneWidget);
  });
}
