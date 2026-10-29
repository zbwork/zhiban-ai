import 'dart:async';
import 'package:bot_toast/bot_toast.dart';
import 'package:zhiban_client/pages/model_service/widgets/add_provider_dialog.dart'
    show ProviderIcon;
import 'package:zhiban_client/pages/digital_employee/widgets/digital_employee_gallery.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:dio/dio.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/network.dart';
import 'dart:io';
import 'package:zhiban_client/pages/chat/widgets/file_preview/local_artifact_actions.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/local_artifact_source.dart';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/widgets/create_agent_dialog.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/providers/skills_providers.dart';
import 'package:zhiban_client/pages/skills/services/skills_service.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_picker_dialog.dart';
import 'package:zhiban_client/pages/chat/widgets/local_agent_controls.dart';
import 'package:zhiban_client/pages/chat/widgets/local_approval_card.dart';
import 'package:zhiban_client/pages/chat/widgets/local_approval_dialog.dart';
import 'package:zhiban_client/pages/chat/widgets/local_approval_sheet.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/prompt_input.dart';
import 'package:zhiban_client/pages/settings/local_runtime_panel.dart';
import 'package:zhiban_client/services/conversation_models.dart';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DesignChat extends OpenClawChatService {
  DesignChat({this.empty = false, this.fail = false});
  final bool empty;
  bool fail;
  @override
  Future<List<RuntimeEnvironmentOption>> listRuntimeEnvironments() async {
    if (fail) throw StateError('offline');
    if (empty) return [];
    return [
      for (final framework in ['openclaw', 'hermes', 'dsh'])
        RuntimeEnvironmentOption(
            uuid: framework,
            name: framework,
            framework: framework,
            hostingKind: 'external_endpoint',
            status: 'active',
            enabled: true),
    ];
  }
}

class EmptyDesignSkills extends OpenClawSkillsService {
  @override
  Future<List<SkillCategory>> listCategories() async => [];

  @override
  Future<Map<String, dynamic>> listSkills({
    String? keyword,
    String? source,
    int? categoryId,
    int page = 1,
    int pageSize = 20,
    String? sortBy,
    String? sortOrder,
  }) async =>
      {'list': <Skill>[]};
}

class ModelMenuAdapter implements HttpClientAdapter {
  List<String> models = ['第一模型', '第二模型'];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
          Future<void>? cancelFuture) async =>
      ResponseBody.fromString(
          jsonEncode({
            'success': true,
            'data': {
              'items': [
                for (final id in models)
                  {
                    'id': id,
                    'label': id,
                    'model_id':
                        id == '第一模型' ? 'Qwen/Qwen3-8B' : 'claude-opus-4-6'
                  }
              ]
            }
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json']
          });
  @override
  void close({bool force = false}) {}
}

final createdLocalFixture = {
  'UUID': 'local-created',
  'Name': 'Local QA',
  'execution_locus': 'local',
  'supports_model_selection': true,
  'model_source': 'byok',
  'model_service_config': {'model_id': 'bound-model'},
  'skills': <dynamic>[]
};

class CreationAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    final data = options.path == '/agents'
        ? (options.method == 'GET'
            ? {'items': <dynamic>[]}
            : createdLocalFixture)
        : options.path == '/agents/local-created'
            ? {'agent': createdLocalFixture}
            : {'items': <dynamic>[]};
    return ResponseBody.fromString(
        jsonEncode({'success': true, 'data': data}), 200,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}

class StaleContactService extends OpenClawDigitalEmployeeService {
  @override
  Future<DigitalEmployeeCatalog> listCatalog({String keyword = ''}) async =>
      DigitalEmployeeCatalog(personal: [
        DigitalEmployeeCatalogItem.personal(
            AgentItem.fromJson({'UUID': 'local-created', 'Name': 'Local QA'}))
      ], enterprise: const []);
}

Widget host(Widget child, {bool dark = false, DesignChat? chat}) =>
    ProviderScope(
        overrides: [
          skillsServiceProvider.overrideWithValue(EmptyDesignSkills()),
          chatServiceProvider.overrideWith((ref) => chat ?? DesignChat())
        ],
        child: MaterialApp(
            theme: (dark ? AppTheme.dark() : AppTheme.light()).copyWith(
                textTheme: (dark ? AppTheme.dark() : AppTheme.light())
                    .textTheme
                    .apply(fontFamily: 'DesignReviewFont')),
            home: Scaffold(body: Center(child: child))));
void main() {
  _localModelFallbackConsent();
  _localSupervisionBackoff();

  for (final action in ['允许本次', '本次任务允许', '拒绝']) {
    testWidgets(
        'approval action $action preserves decision and disables duplicates',
        (tester) async {
      final answers = <String>[];
      final pending = Completer<void>();
      await tester.pumpWidget(host(LocalApprovalDialog(
        request: const {
          'intent': {'operation': 'browser'}
        },
        onAnswer: (approved, scope) async {
          answers.add('$approved:$scope');
          await pending.future;
        },
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pump();
      expect(answers, [
        const {
          '允许本次': 'true:once',
          '本次任务允许': 'true:task',
          '拒绝': 'false:once',
        }[action]
      ]);
      for (final button in tester.widgetList<ButtonStyleButton>(
          find.byWidgetPredicate((widget) => widget is ButtonStyleButton))) {
        expect(button.onPressed, isNull);
      }
      await tester.tap(find.text(action));
      await tester.pump();
      expect(answers, hasLength(1));
      pending.completeError(StateError('expired'));
      await tester.pumpAndSettle();
      expect(find.text('审批已过期或任务已停止，请查看任务状态'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull);
      expect(tester.takeException(), isNull);
    });
  }
  for (final inSheet in [false, true]) {
    testWidgets('approval upload stays once-only ($inSheet)', (tester) async {
      const request = {
        'intent': {
          'operation': 'upload',
          'args': {'path': '报表/季度分析.xlsx'}
        },
      };
      String? answer;
      Future<void> decide(bool approved, String scope) async =>
          answer = '$approved:$scope';
      await tester.pumpWidget(host(inSheet
          ? LocalApprovalSheet(request: request, onAnswer: decide)
          : LocalApprovalDialog(request: request, onAnswer: decide)));
      await tester.pumpAndSettle();
      expect(find.text('本次任务允许'), findsNothing);
      expect(find.text('上传文件需逐次批准，仅允许本次操作'), findsOneWidget);
      expect(find.text('报表/季度分析.xlsx'), findsOneWidget);
      await tester.ensureVisible(find.text('允许本次'));
      await tester.tap(find.text('允许本次'));
      await tester.pump();
      expect(answer, 'true:once');
      expect(tester.takeException(), isNull);
    });
  }
  for (final operation in ['read', 'overwrite', 'delete', 'shell', 'browser']) {
    testWidgets('approval preserves long $operation target at large text size',
        (tester) async {
      tester.view.physicalSize = const Size(520, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final target = List.filled(10, '需要核对的完整操作对象').join('/');
      await tester.pumpWidget(host(Builder(
          builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(1.5)),
                child: LocalApprovalDialog(request: {
                  'employee_name': '需要保留的完整本地员工名称',
                  'intent': {
                    'operation': operation,
                    'args': {
                      if (operation == 'browser')
                        'url': target
                      else if (operation == 'shell')
                        'command': target
                      else
                        'path': target,
                    }
                  },
                }, onAnswer: (_, __) async {}),
              ))));
      await tester.pumpAndSettle();
      expect(find.text(target), findsOneWidget);
      expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).maxLines,
          isNull);
      if (operation == 'read') {
        expect(find.text('本次只读取文件，不会修改或删除原件。'), findsOneWidget);
      } else if (operation == 'overwrite' || operation == 'delete') {
        expect(find.text('此操作会修改或删除已有内容，请确认对象后批准。'), findsOneWidget);
      }
      await tester.ensureVisible(find.text('拒绝'));
      await tester.pumpAndSettle();
      expect(find.text('拒绝').hitTestable(), findsOneWidget);
      final once = tester.getRect(find.widgetWithText(FilledButton, '允许本次'));
      final task =
          tester.getRect(find.widgetWithText(OutlinedButton, '本次任务允许'));
      expect(once.bottom, lessThan(task.top));
      expect(tester.takeException(), isNull);
    });
  }
  for (final scale in [1.0, 1.5]) {
    testWidgets('mobile approval sheet fits narrow screen at text scale $scale',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final decision = Completer<void>();
      final answers = <String>[];
      await tester.pumpWidget(host(Builder(builder: (context) {
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              color: Theme.of(context).colorScheme.surface,
              child: LocalApprovalSheet(
                request: const {
                  'employee_name': '0910',
                  'intent': {
                    'operation': 'browser',
                    'args': {'name': '本次浏览器或网络操作（详细参数在电脑端查看）'},
                  },
                },
                onAnswer: (approved, scope) async {
                  answers.add('$approved:$scope');
                  await decision.future;
                },
              ),
            ),
          ),
        );
      })));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final once = tester.getRect(find.widgetWithText(FilledButton, '允许本次'));
      final task =
          tester.getRect(find.widgetWithText(OutlinedButton, '本次任务允许'));
      final deny = tester.getRect(find.widgetWithText(OutlinedButton, '拒绝'));
      expect(once.height, greaterThanOrEqualTo(48));
      expect(task.height, greaterThanOrEqualTo(48));
      expect(deny.height, greaterThanOrEqualTo(48));
      expect(once.width, task.width);
      expect(task.width, deny.width);
      expect(once.bottom, lessThan(task.top));
      expect(task.bottom, lessThan(deny.top));

      await tester.ensureVisible(find.text('本次任务允许'));
      await tester.tap(find.text('本次任务允许'));
      await tester.pump();
      expect(answers, ['true:task']);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      decision.complete();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  for (final locus
      in AppConfig.cloudAgentCreationEnabled ? ['cloud', 'local'] : ['cloud']) {
    testWidgets('editor submits selected runtime only for $locus',
        (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      CreateAgentDraft? result;
      await tester.pumpWidget(host(Builder(
          builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<CreateAgentDraft>(
                    context: context,
                    builder: (_) => const CreateAgentDialog(
                            initialDraft: CreateAgentDraft(
                          name: 'QA',
                          description: '负责测试',
                          avatarUrl: '',
                          runtimeEnvironmentUuid: 'openclaw',
                          internalDescription: '原备注',
                        )));
              },
              child: const Text('打开编辑')))));
      await tester.tap(find.text('打开编辑'));
      await tester.pumpAndSettle();
      if (!AppConfig.cloudAgentCreationEnabled) {
        await tester.ensureVisible(find.text('这台电脑'));
        await tester.tap(find.text('这台电脑'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('local-engine-select')), findsNothing);
      }
      await tester.ensureVisible(find.byType(UiSelect<String>));
      await tester.pumpAndSettle();
      expect(
          tester.widget<UiSelect<String>>(find.byType(UiSelect<String>)).value,
          'openclaw');
      await tester.tap(find.byType(UiSelect<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hermes'));
      await tester.pumpAndSettle();
      if (locus == 'local') {
        await tester.tap(find.text('这台电脑'));
        await tester.pumpAndSettle();
        await tester
            .ensureVisible(find.byKey(const ValueKey('local-engine-select')));
        await tester.tap(find.byKey(const ValueKey('local-engine-select')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Codex App Server'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('创建数字员工').last);
      await tester.pumpAndSettle();
      expect(result?.runtimeEnvironmentUuid, locus == 'cloud' ? 'hermes' : '');
      expect(result?.executionLocus, locus);
      if (locus == 'local') expect(result?.localEngine, 'codex_app_server');
      expect(result, isNotNull);
      expect(result!.skillSlugs, isEmpty);
      expect(result?.internalDescription, '原备注');
      expect(tester.takeException(), isNull);
    });
  }
  for (final scenario in ['empty', 'failed', 'removed']) {
    testWidgets(
        'cloud runtime $scenario blocks submission without replacing binding',
        (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service =
          DesignChat(empty: scenario == 'empty', fail: scenario == 'failed');
      await tester.pumpWidget(host(
          const SizedBox(
              width: 670,
              height: 950,
              child: CreateAgentEditor(
                  compact: false,
                  initialDraft: CreateAgentDraft(
                    name: 'QA',
                    description: '',
                    avatarUrl: '',
                    runtimeEnvironmentUuid: 'removed',
                  ))),
          chat: service));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('云端'));
      await tester.pumpAndSettle();
      expect(
          find.text(switch (scenario) {
            'empty' => '暂无可用的 Agent 类型',
            'failed' => 'Agent 类型加载失败，请重试',
            _ => '原 Agent 类型已不可用，请重新选择',
          }),
          findsOneWidget);
      await tester.tap(find.text('创建数字员工').last);
      await tester.pumpAndSettle();
      expect(find.text('请选择可用的 Agent 类型'), findsOneWidget);
      if (scenario == 'failed') {
        service.fail = false;
        await tester.ensureVisible(find.text('重试'));
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(find.text('原 Agent 类型已不可用，请重新选择'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('directory menu keeps actions visible while recent paths scroll',
      (tester) async {
    String? selected;
    await tester.pumpWidget(host(Builder(
        builder: (context) => TextButton(
            onPressed: () async {
              selected = await showMenu<String>(
                  context: context,
                  position: const RelativeRect.fromLTRB(30, 30, 30, 30),
                  constraints: const BoxConstraints.tightFor(width: 340),
                  items: [
                    LocalDirectoryMenuEntry(
                        height: 400,
                        header: const Text('工作目录'),
                        directories: [
                          for (var i = 0; i < 8; i++)
                            PopupMenuItem(
                                value: 'path-$i',
                                height: 68,
                                child: LocalDirectoryRow(
                                    path: '/Documents/employee/folder-$i',
                                    name: 'folder-$i'))
                        ],
                        actions: const [
                          PopupMenuItem(value: 'new', child: Text('新建工作目录…'))
                        ])
                  ]);
            },
            child: const Text('目录')))));
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    expect(find.text('新建工作目录…').hitTestable(), findsOneWidget);
    expect(find.text('切换后仅对新任务生效，原文件保留').hitTestable(), findsOneWidget);
    await tester.tap(find.text('folder-0'));
    await tester.pumpAndSettle();
    expect(selected, 'path-0');
    expect(find.text('工作目录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  setUpAll(() async {
    // Preload bundled catalog outside the widget test fake async zone.
    await rootBundle.loadString('assets/model_catalog/providers.json');
    await rootBundle.loadString('assets/model_catalog/models.json');
    final font = FontLoader('DesignReviewFont')
      ..addFont(
          rootBundle.load('packages/zhiban_ui/assets/fonts/harmonyos-sans/HarmonyOS_Sans_SC.ttf'));
    await font.load();
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in manifest) {
      final loader = FontLoader(entry['family'] as String);
      for (final asset in entry['fonts']) {
        loader.addFont(rootBundle.load(asset['asset'] as String));
      }
      await loader.load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  test(
      'local identity accepts real Bus tenant claims and isolates tenant switches',
      () {
    String token(String scope, [int? tenant]) =>
        'x.${base64Url.encode(utf8.encode(jsonEncode({
                'sub': 'account',
                'sid': 'session',
                'act_scope': scope,
                'act_tid': tenant
              })))}.x';
    expect(LocalAgentService.identity(token('tenant', 42))?['tenant'], 'id:42');
    expect(LocalAgentService.identity(token('tenant', 43))?['tenant'], 'id:43');
    expect(LocalAgentService.identity(token('tenant:legacy'))?['tenant'],
        'legacy');
    for (final bad in [
      token('platform', 42),
      token('workspace', 42),
      token('tenant'),
      token('tenant', 0)
    ]) {
      expect(LocalAgentService.identity(bad), isNull);
    }
  });
  testWidgets(
      'creation retains management runtime capabilities after stale contact readback',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prior = request.httpClientAdapter;
    request.httpClientAdapter = CreationAdapter();
    addTearDown(() => request.httpClientAdapter = prior);
    final container = ProviderContainer(overrides: [
      digitalEmployeeServiceProvider
          .overrideWith((ref) => StaleContactService())
    ]);
    addTearDown(container.dispose);
    final key = GlobalKey<OpenClawDigitalEmployeeGalleryState>();
    final notices = <String>[];
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            builder: BotToastInit(),
            home: Scaffold(
                body: OpenClawDigitalEmployeeGallery(
                    key: key,
                    requestCreateAgentDraft: (_) async =>
                        const CreateAgentDraft(
                            name: 'Local QA',
                            description: 'QA',
                            avatarUrl: '',
                            executionLocus: 'local'),
                    requestEditAgentDraft: (_, __) async => null,
                    showToast: notices.add,
                    onOpenConversation: (_, __) async {})))));
    await tester.pumpAndSettle();
    final loadingAgents = container.read(agentsProvider.future);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await loadingAgents;
    final creating = key.currentState!.createAgent();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await creating;
    final created = container.read(agentsProvider).requireValue.single;
    expect(created.executionLocus, 'local');
    expect(created.supportsModelSelection, true);
    expect(created.modelSource, 'byok');
    expect(created.modelServiceModelId, 'bound-model');
    expect(notices.last, contains('可在这台电脑使用'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'local file card exposes preview, reveal and explicit cancellable cloud sync',
      (tester) async {
    tester.view.physicalSize = const Size(800, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const source = LocalArtifactSource(
        artifactId: '11111111-1111-4111-8111-111111111111',
        deviceId: '22222222-2222-4222-8222-222222222222',
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        conversationId: '33333333-3333-4333-8333-333333333333');
    final previousDevice = LocalAgentService.instance.deviceId;
    LocalAgentService.instance.deviceId = source.deviceId;
    addTearDown(() => LocalAgentService.instance.deviceId = previousDevice);
    for (final dark in [false, true]) {
      await tester.pumpWidget(host(
          const SizedBox(
              width: 570,
              child: LocalArtifactActions(
                  source: source,
                  name: '项目交付清单.xlsx',
                  mime:
                      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')),
          dark: dark));
      await tester.pumpAndSettle();
      expect(find.textContaining('本机文件'), findsOneWidget);
      expect(find.byTooltip('预览'), findsOneWidget);
      expect(find.byTooltip('下载'), findsOneWidget);
      expect(find.byTooltip('在文件夹中显示'), findsOneWidget);

      expect(find.text('上传到我的云盘'), findsNothing);
      expect(find.text('确认上传'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
  testWidgets(
      'cloud model menu selects, persists and refuses a removed preference',
      (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final adapter = ModelMenuAdapter();
    final previous = sensitiveRequest.httpClientAdapter;
    sensitiveRequest.httpClientAdapter = adapter;
    addTearDown(() {
      sensitiveRequest.httpClientAdapter = previous;
      ConversationModels.instance.clear();
    });
    final claims = base64Url.encode(utf8.encode(jsonEncode({
      'sub': 'user',
      'aid': 1,
      'sid': 'session',
      'act_scope': 'tenant:tenant'
    })));
    SharedPreferences.setMockInitialValues(
        {AppConfig.storageTokenKey: 'x.$claims.x'});
    final agent = AgentItem.fromJson({
      'uuid': 'cloud-agent',
      'name': '云端助手',
      'supports_model_selection': true
    });
    await tester.pumpWidget(host(SizedBox(
        width: 500,
        child:
            LocalAgentControls(agent: agent, conversation: 'conversation'))));
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
        ConversationModels.instance
            .state(agent.agentId, 'conversation')
            .selected,
        '第一模型');
    expect(
        (tester
                .widget<AgentControlButton>(find.byType(AgentControlButton))
                .leading as ProviderIcon)
            .iconAssetPath,
        'assets/icons/providers/qwen.svg');
    await tester.tap(find.text('第一模型'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<AgentControlButton>(find.byType(AgentControlButton))
            .expanded,
        isTrue);
    expect(find.text('切换后从下一条消息生效'), findsOneWidget);

    await tester.tap(find.text('第二模型'));
    await tester.pumpAndSettle();
    expect(
        ConversationModels.instance
            .state(agent.agentId, 'conversation')
            .selected,
        '第二模型');
    expect(
        (tester
                .widget<AgentControlButton>(find.byType(AgentControlButton))
                .leading as ProviderIcon)
            .iconAssetPath,
        'assets/icons/providers/anthropic.svg');
    adapter.models = ['第一模型'];
    final loading = ConversationModels.instance.load(agent, 'conversation');
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await loading;
    expect(
        ConversationModels.instance.state(agent.agentId, 'conversation').ready,
        false);
    expect(find.text('当前模型「第二模型」已不可用，请切换模型后重试。'), findsNothing);
    await tester.tap(find.text('第二模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第一模型'));
    await tester.pumpAndSettle();
    expect(
        ConversationModels.instance.state(agent.agentId, 'conversation').ready,
        true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test(
      'model defaults preserve source order and require explicit reselection after removal',
      () {
    const models = [
      LlmModelOption(id: 'first', label: '第一模型'),
      LlmModelOption(id: 'second', label: '第二模型')
    ];
    expect(ConversationModels.resolve(models, '').selected, 'first');
    expect(ConversationModels.resolve(models, 'second').selected, 'second');
    expect(ConversationModels.resolve(models, 'removed').ready, false);
    expect(ConversationModels.resolve(models, 'removed').selected, 'removed');
    expect(ConversationModels.resolve([], '').ready, false);
    expect(const ConversationModelState(loading: true).ready, false);
  });
  testWidgets('creation respects cloud availability and shows remarks directly',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(const SizedBox(
        width: 670, height: 950, child: CreateAgentEditor(compact: false))));
    await tester.pumpAndSettle();
    expect(find.text('高级设置'), findsNothing);
    expect(find.text('备注（可选）'), findsOneWidget);
    expect(find.text('请选择模型'), findsNothing);
    await tester.ensureVisible(find.text('运行位置'));
    await tester.pumpAndSettle();
    final local = tester.getRect(find
        .ancestor(of: find.text('这台电脑'), matching: find.byType(InkWell))
        .first);
    final cloud = tester.getRect(find
        .ancestor(of: find.text('云端'), matching: find.byType(InkWell))
        .first);
    expect(local.width, closeTo(cloud.width, .1));
    expect(find.text('默认'), findsOneWidget);
    expect(find.text('运行方式'), findsNothing);
    expect(find.text('模型可在聊天时选择和切换。'), findsNothing);

    await tester.tap(find.text('云端'));
    await tester.pumpAndSettle();
    if (!AppConfig.cloudAgentCreationEnabled) {
      expect(find.text('暂未开放'), findsOneWidget);
      expect(find.byKey(const ValueKey('local-engine-select')), findsOneWidget);
      expect(find.text('DSH'), findsNothing);
      expect(tester.takeException(), isNull);
      return;
    }
    await tester.ensureVisible(find.byType(UiSelect<String>));
    await tester.pumpAndSettle();
    expect(find.text('DSH'), findsOneWidget);
    await tester.tap(find.byType(UiSelect<String>));
    await tester.pumpAndSettle();
    expect(find.text('OpenClaw'), findsOneWidget);
    expect(find.text('Hermes'), findsOneWidget);
    await tester.tap(find.text('Hermes'));
    await tester.pumpAndSettle();
    expect(tester.widget<UiSelect<String>>(find.byType(UiSelect<String>)).value,
        'hermes');
    await tester.tap(find.text('这台电脑'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('local-engine-select')), findsOneWidget);
    await tester.tap(find.text('云端'));
    await tester.pumpAndSettle();
    expect(tester.widget<UiSelect<String>>(find.byType(UiSelect<String>)).value,
        'hermes');

    expect(tester.takeException(), isNull);
  });
  for (final dark in [false, true]) {
    testWidgets('disabled cloud keeps local creation and keyboard safe ($dark)',
        (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      CreateAgentDraft? result;
      await tester.pumpWidget(host(
          Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    result = await showDialog<CreateAgentDraft>(
                        context: context,
                        builder: (_) => const CreateAgentDialog());
                  },
                  child: const Text('打开新建'))),
          dark: dark));
      await tester.tap(find.text('打开新建'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '本地测试员工');
      await tester.enterText(find.byType(TextField).at(1), '负责测试');
      await tester.ensureVisible(find.text('选择技能'));
      await tester.tap(find.text('选择技能'));
      await tester.pumpAndSettle();
      // 技能选择本身不属于本用例；模拟选择器返回的已选技能。
      Navigator.of(tester.element(find.byType(SkillPickerDialog)))
          .pop(<String, String>{'qa': '测试技能'});
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('云端'));
      await tester.pumpAndSettle();
      final cloud = find
          .ancestor(of: find.text('云端'), matching: find.byType(InkWell))
          .first;
      final ink = tester.widget<InkWell>(cloud);
      expect(ink.onTap, isNull);
      expect(ink.canRequestFocus, isFalse);
      final semantics = tester.widget<Semantics>(
          find.ancestor(of: cloud, matching: find.byType(Semantics)).first);
      expect(semantics.properties.enabled, isFalse);
      expect(semantics.properties.selected, isFalse);
      await tester.tap(cloud);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('local-engine-select')), findsOneWidget);
      expect(find.text('暂未开放'), findsOneWidget);

      await tester
          .ensureVisible(find.byKey(const ValueKey('local-engine-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local-engine-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Codex App Server'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建数字员工').last);
      await tester.pumpAndSettle();
      expect(result?.executionLocus, 'local');
      expect(result?.localEngine, 'codex_app_server');
      expect(result?.runtimeEnvironmentUuid, isEmpty);
      expect(tester.takeException(), isNull);
    }, skip: AppConfig.cloudAgentCreationEnabled);
  }
  for (final dark in [false, true]) {
    testWidgets(
        'composer bottom controls preserve toolbar and block button/keyboard without losing draft ($dark)',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TextEditingController(text: '请分析工作目录中的季度报表。');
      final focus = FocusNode();
      var sends = 0;
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      final controls = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: 7, children: [
              AgentControlButton(
                  label: '季度经营分析',
                  icon: CupertinoIcons.folder,
                  onPressed: () {}),
              AgentControlButton(
                  label: '帮我批准', icon: CupertinoIcons.shield, onPressed: () {}),
              AgentControlButton(
                  label: 'DeepSeek',
                  icon: CupertinoIcons.sparkles,
                  onPressed: () {},),
          ],
            ),
          ],
        );
      Widget composer(bool ready) => host(
          SizedBox(
              width: 600,
              child: PromptInput(
                  focusNode: focus,
                  controller: controller,
                  onPickAttachment: (_) {},
                  onPickFromDrive: () {},
                  onSend: (_) => sends++,
                  onStop: () {},
                  isSending: false,
                  sendReady: ready,
                  runtimeControls: controls)),
          dark: dark);
      await tester.pumpWidget(composer(false));
      await tester.pumpAndSettle();
      expect(find.text('本地任务将在这台电脑上执行。'), findsNothing);
      expect(tester.getTopLeft(find.byType(AgentControlButton).first).dy,
          greaterThan(tester.getBottomLeft(find.byType(TextField)).dy));
      final button = tester.widget<IconButton>(find
          .ancestor(
              of: find.byIcon(CupertinoIcons.paperplane_fill),
              matching: find.byType(IconButton))
          .first);
      expect(button.onPressed, isNull);
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sends, 0);
      expect(controller.text, contains('季度报表'));
      await tester.pumpWidget(composer(true));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(520, 720);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
    testWidgets(
        'permission confirmation, approval card and diagnostics states render at narrow desktop widths ($dark)',
        (tester) async {
      tester.view.physicalSize = const Size(760, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(const FullLocalAccessDialog(), dark: dark));
      await tester.pumpAndSettle();
      expect(find.byType(UiSheetHeader), findsOneWidget);
      expect(find.text('确认开启'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '确认开启'))
              .onPressed,
          isNull);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '确认开启'))
              .onPressed,
          isNotNull);

      String? answer;
      await tester.pumpWidget(host(
          SizedBox(
              width: 540,
              child: LocalApprovalCard(
                  request: const {
                    'intent': {
                      'operation': 'overwrite',
                      'tool': 'write_file',
                      'args': {'path': '报表/季度分析.xlsx'}
                    }
                  },
                  onAnswer: (approved, scope) async =>
                      answer = '$approved:$scope')),
          dark: dark));
      await tester.pumpAndSettle();

      await tester.tap(find.text('本次任务允许'));
      await tester.pump();
      expect(answer, 'true:task');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(host(
          const SizedBox(
              width: 520,
              child: LocalRuntimeStatusView(
                  online: false,
                  checking: false,
                  checks: {
                    'node': true,
                    'engine': true,
                    'office': true,
                    'browser': false,
                    'isolation': true
                  },
                  affected: '文档助手、经营分析',
                  activeTasks: 0,
                  pendingApprovals: 0)),
          dark: dark));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(host(
          const NewLocalDirectoryDialog(
              parent: '/Users/example/Documents/知办AI/文档助手'),
          dark: dark));
      await tester.pumpAndSettle();
      expect(find.text('创建并使用'), findsOneWidget);
      expect(find.text('更改…'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '创建并使用'))
              .onPressed,
          isNull);
      await tester.enterText(find.byType(TextField), '季度经营分析');
      await tester.pumpAndSettle();
      expect(find.text('将创建：文档助手 / 季度经营分析'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '创建并使用'))
              .onPressed,
          isNotNull);

      expect(tester.takeException(), isNull);
    });
  }
}

// I-08 / decision Q4: auto-recovery must escalate its retry delay and then hand back to the user
// instead of respawning a broken helper forever.
void _localSupervisionBackoff() {
  group('local agent supervision backoff', () {
    test('escalates 5s→300s and then caps', () {
      expect(LocalAgentService.supervisionBackoff(1).inSeconds, 5);
      expect(LocalAgentService.supervisionBackoff(2).inSeconds, 10);
      expect(LocalAgentService.supervisionBackoff(3).inSeconds, 20);
      expect(LocalAgentService.supervisionBackoff(4).inSeconds, 40);
      // Monotonic up to the ceiling; never longer than 5 minutes.
      expect(LocalAgentService.supervisionBackoff(9).inSeconds, 300);
      expect(LocalAgentService.supervisionBackoff(20).inSeconds, 300);
    });

    test('gives up after a bounded number of attempts', () {
      expect(LocalAgentService.supervisionAttemptLimit, greaterThan(0));
      expect(LocalAgentService.supervisionAttemptLimit, lessThanOrEqualTo(10));
    });

  });
}

// P0-5 req 5 / decision Q3. The client has no cross-model consent UI yet, so it
// must not send the consent flag at all. Bus defaults to "no fallback", which
// means a model switch simply cannot happen without a user acting — the safe
// direction. This test fails the moment someone wires the flag without a prompt.
void _localModelFallbackConsent() {
  group('cross-model fallback consent', () {
    test('client never implicitly grants model fallback', () {
      final sources = [
        File('lib/pages/chat/services/chat_service.dart'),
        File('lib/pages/chat/providers/chat_providers.dart'),
        File('lib/services/local_agent_service.dart'),
      ];
      for (final file in sources) {
        expect(file.existsSync(), isTrue, reason: '${file.path} missing');
        expect(
            file.readAsStringSync().contains('allow_model_fallback'), isFalse,
            reason:
                '${file.path} sends allow_model_fallback; a cross-model switch '
                'requires an explicit user confirmation first (Q3)');
      }
    });
  });
}
