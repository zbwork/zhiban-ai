import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/layout/main_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:window_manager/window_manager.dart';
import 'package:zhiban_client/layout/widgets/sidebar_nav_item.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_roundtable_chat.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_roundtable_page.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_expert_workflow.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/douyin_creator_service.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_app.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_controller.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_model_client.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';
import 'package:zhiban_client/window/window_controller.dart';
import 'package:zhiban_ui/widgets/ui_select.dart';

const _model = {'provider_id': 'fixture', 'model_id': 'gpt-fixture'};
const _question = '企业 AI 工具怎么验证客户愿不愿意付费？';
const _names = [
  '林岚的产品笔记',
  '周远商业拆解',
  '许宁创业手记',
  '陈舟增长实战',
  '乔一的试点观察',
  '沈然增长笔记',
  '刘安的商业复盘',
  '梁乐产品观察',
];

class _VisualModels extends ModelProvidersNotifier {
  @override
  Future<List<AiProviderConfig>> build() async => const [
        AiProviderConfig(
          id: 'fixture',
          enabled: true,
          name: 'GPT',
          models: [
            AiModelConfig(
                id: 'gpt', modelId: 'gpt-fixture', displayName: 'GPT 测试模型'),
          ],
        ),
        AiProviderConfig(
          id: 'claude-fixture',
          enabled: true,
          name: 'Claude',
          models: [
            AiModelConfig(
                id: 'claude',
                modelId: 'claude-fixture',
                displayName: 'Claude 测试模型'),
          ],
        ),
      ];
}

class _VisualModelStore extends ModelServiceStore {
  @override
  Future<String?> getApiKey(String providerId) async => 'visual-test-key';
}

class _VisualModelClient extends LocalModelClient {
  final requested = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String> complete({
    required AiProviderConfig provider,
    required AiEndpointType protocol,
    required String model,
    required String apiKey,
    required String system,
    required List<Map<String, String>> messages,
    required CancelToken cancelToken,
  }) async {
    if (!requested.isCompleted) requested.complete();
    await release.future;
    throw const LocalModelException('模型服务暂时不可用，请稍后重试。');
  }
}

class _VisualImportModel extends _VisualModelClient {
  @override
  Future<String> complete({
    required AiProviderConfig provider,
    required AiEndpointType protocol,
    required String model,
    required String apiKey,
    required String system,
    required List<Map<String, String>> messages,
    required CancelToken cancelToken,
  }) async {
    final input = jsonDecode(messages.single['content']!);
    if (input is List) {
      requested.complete();
      await release.future;
      return jsonEncode({
        'methods': [
          {
            'problem': '付费试点如何确认实际支出',
            'applies_when': '试点开始前已取得交易记录',
            'limits': '缺少凭证则停止判断',
            'steps': [
              {
                'action': '核对预算和已发生的支出',
                'evidence_ids': [(input.first as Map)['id']],
              },
            ],
          }
        ]
      });
    }
    if (system.startsWith('独立审查')) return '{"supported":[0]}';
    if (system.startsWith('你负责知识图谱归类')) {
      final rows = (input as Map)['methods'] as List;
      final first = rows.single as Map;
      return jsonEncode({
        'memberships': [
          {
            'method_id': (first['method'] as Map)['id'],
            'topic_id': '',
            'title': '核对试点支出',
            'meaning': '按实际凭证确认试点投入',
            'evidence_ids': [((first['evidence'] as List).single as Map)['id']],
          },
        ]
      });
    }
    throw StateError('出现未配置的导入验收模型请求');
  }
}

class _VisualDouyin extends DouyinCreatorService {
  _VisualDouyin(this.readPage, {required this.importVisual});

  final bool importVisual;

  final Future<Map<String, dynamic>> Function(String authorId) readPage;

  @override
  Future<Map<String, dynamic>> read({
    required String cookie,
    required String link,
    required void Function(String) onStatus,
  }) async {
    if (!importVisual) {
      throw const DouyinCreatorException('暂时无法读取该作品，请修改链接或重试。');
    }
    final uri = Uri.parse(link);
    final isNote = uri.pathSegments.first == 'note';
    return {
      'author': {
        'id': isNote ? 'import-note-author' : 'import-video-author',
        'name': isNote ? '付费试点验收博主' : '单条视频验收博主',
      },
      'work': {
        'id': uri.pathSegments.last,
        'title': isNote ? '基于凭证核对付费试点' : '单条视频验收作品',
        if (isNote) 'article_body': '试点开始前核对预算和已发生的支出，缺少凭证则停止判断。',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> readAuthorPage({
    required String cookie,
    required String authorId,
    required int cursor,
    int count = 20,
    required void Function(String) onStatus,
  }) {
    onStatus('正在读取作品列表…');
    return readPage(authorId);
  }
}

Future<List<String>> _seed(LocalWorkspaceStore store) async {
  final ids = <String>[];
  final replies = <Map<String, Object>>[];
  for (final (index, name) in _names.indexed) {
    final action = index.isEven ? '核实现有支出' : '确认预算负责人';
    final transcript = '先$action，再约定一个付费试点。记录验收标准和结束日期。';
    final added = await store.importCreatorWorks(
      {'id': 'visual-author-$index', 'name': name, 'works': 1},
      [
        {
          'id': '${1234567890123456700 + index}',
          'title': index == 0 ? '先验证付费，再验证功能' : '$name · 公开作品样例',
          'published_at': 1795478400 - index * 120,
        },
      ],
    );
    ids.add(added.creatorId);
    final work = (await store.creatorWorks(added.creatorId)).single;
    await store.saveCreatorTranscript(
      workId: work['id'] as String,
      sourceVersion: work['source_version'] as int,
      source: 'visual-fixture',
      transcript: transcript,
      cues: [
        {'start_ms': 0, 'end_ms': 4400, 'text': transcript},
      ],
    );
    final evidence = creatorEvidence(await store.creatorWorks(added.creatorId));
    if (evidence.isEmpty) throw StateError('图册样本缺少证据');
    final job =
        await store.beginCreatorExpertJob(added.creatorId, _model, evidence);
    await store.publishCreatorExpert(
      creatorId: added.creatorId,
      jobId: job,
      methods: [
        {
          'id': 'method-$index',
          'problem': action,
          'applies_when': '试点尚未获得正式预算',
          'limits': '已有付费合同则按合同执行',
          'steps': [
            {
              'action': action,
              'evidence_ids': [evidence.single['id']]
            },
          ],
        },
      ],
      evidence: evidence,
      graphTopics: [
        {
          'id': 'visual-paid-pilot',
          'title': '付费验证',
          'meaning': '用预算与付费试点验证需求',
          'method_id': 'method-$index',
          'fingerprint': 'fixture-$index',
          'evidence_ids': [evidence.single['id']!],
        }
      ],
    );
    if (index < 2) {
      replies.add({
        'text': transcript,
        'expert': {'name': name, 'version': 1},
        'evidence': evidence,
      });
    }
  }
  for (final question in ['怎么访谈第一批企业客户？', '如何设计一周付费试点？', _question]) {
    await store.saveRoundtableExchange(
        question: question, model: _model, replies: replies);
  }
  return ids;
}

Future<void> main() async {
  try {
    await _captureBatch();
    exit(0);
  } catch (error, stack) {
    stderr.writeln('ROUNDTABLE_VISUAL_BATCH_FAILED $error');
    stderr.writeln(stack);
    exit(1);
  }
}

Future<void> _captureBatch() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  await WindowController.instance.init(hasToken: true);
  final output = await Directory.systemTemp.createTemp('roundtable-v20-batch-');
  debugPrint('ROUNDTABLE_VISUAL_DIR ${output.path}');
  final database =
      await LocalWorkspaceStore.open(path: '${output.path}/roundtable.db');
  final sandbox = LocalWorkspaceController(database);
  final controller = LiveWidgetController(binding);
  var boundary = GlobalKey();
  var connected = false;
  final syncGate = Completer<void>();
  const importVisual = bool.fromEnvironment('ROUNDTABLE_IMPORT_VISUAL');
  final modelClient =
      importVisual ? _VisualImportModel() : _VisualModelClient();
  var syncAttempts = 0;

  Future<Map<String, dynamic>> readPage(String authorId) async {
    switch (++syncAttempts) {
      case 1:
        await syncGate.future;
        return {
          'author': {'id': authorId, 'name': _names.first, 'works': 1},
          'posts': [
            {
              'id': '1234567890123456700',
              'title': '先验证付费，再验证功能',
              'published_at': 1795478400,
            },
          ],
          'next_cursor': null,
        };
      case 2:
        throw const DouyinCreatorException('抖音暂未返回作品列表，请重试。');
      default:
        throw const DouyinCreatorException('抖音授权已失效，请重新连接。',
            code: 'auth_expired');
    }
  }

  Future<void> mount(
      {required bool seeded, List<String> seats = const []}) async {
    SharedPreferences.setMockInitialValues({
      'creator_roundtable.model.v1': jsonEncode(['fixture', 'gpt-fixture']),
      if (seeded) 'creator_roundtable.guide_dismissed.v1': true,
      'creator_roundtable.display_seats.v1': seats,
    });
    boundary = GlobalKey();
    runApp(ProviderScope(
      key: ValueKey(seeded),
      overrides: [
        localWorkspaceProvider.overrideWith((ref) async => sandbox),
        creatorDouyinSessionProvider
            .overrideWithValue(() async => connected ? 'fixture' : ''),
        modelProvidersProvider.overrideWith(_VisualModels.new),
        modelServiceStoreProvider.overrideWithValue(_VisualModelStore()),
        creatorRoundtableModelClientProvider.overrideWithValue(modelClient),
        creatorDouyinAdapterProvider.overrideWithValue(
            () => _VisualDouyin(readPage, importVisual: importVisual)),
      ],
      child: RepaintBoundary(
        key: boundary,
        child: LocalWorkspaceApp(
          shellBuilder: (child) =>
              MainLayout(localWorkspace: true, child: child),
        ),
      ),
    ));
    await controller.pump(const Duration(milliseconds: 120));
  }

  Future<void> wait(Finder finder) async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (binding.rootElement == null || finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) throw StateError('未找到控件 $finder');
      await controller.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tap(Finder finder) async {
    final target = finder.hitTestable();
    await wait(target);
    await controller.tap(target.first);
    await controller.pump(const Duration(milliseconds: 280));
  }

  Future<void> openCreatorDrawer() async {
    if (find
        .byKey(const ValueKey('roundtable-creators-drawer'))
        .evaluate()
        .isEmpty) {
      await tap(find.byKey(const ValueKey('roundtable-open-creators')));
    }
  }

  Future<void> capture(String figure, Finder state) async {
    await wait(state);
    await controller.pump(const Duration(milliseconds: 320));
    await binding.endOfFrame;
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${output.path}/$figure.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
    debugPrint('ROUNDTABLE_VISUAL_CAPTURED $figure');
  }

  Future<void> openRoundtable() => tap(find.ancestor(
        of: find.text('博主圆桌'),
        matching: find.byType(SidebarNavItem),
      ));

  if (importVisual) {
    connected = true;
    await mount(seeded: true);
    await openRoundtable();
    await windowManager.setSize(const Size(1512, 859));
    Future<void> importWork(String link) async {
      await openCreatorDrawer();
      await tap(find.text('+ 添加博主'));
      final field = find.descendant(
        of: find.byKey(const ValueKey('roundtable-add-link')),
        matching: find.byType(EditableText),
      );
      await wait(field);
      controller.widget<EditableText>(field).controller.text = link;
      await tap(find.text('读取作品'));
      await tap(find.text('开始蒸馏'));
    }

    await importWork('https://www.douyin.com/note/7198765432109876541');
    await modelClient.requested.future.timeout(const Duration(seconds: 12));
    await capture('11', find.text('正在分析作品'));
    modelClient.release.complete();
    await capture('12', find.text('已发布博主专家'));
    await tap(find.text('完成'));

    await importWork('https://www.douyin.com/video/7198765432109876542');
    await capture('51', find.text('作品资料已保存'));
    await tap(find.text('完成'));
    final profiles = await database.creatorProfiles();
    final note = profiles
        .singleWhere((row) => row['source_account_id'] == 'import-note-author');
    final video = profiles.singleWhere(
        (row) => row['source_account_id'] == 'import-video-author');
    if ((await database.creatorWorks(note['id'] as String)).length != 1 ||
        (await database.creatorWorks(video['id'] as String)).length != 1 ||
        (await database
                .latestCreatorExpert(note['id'] as String))?['version'] !=
            1) {
      throw StateError('导入样本未按预期落盘或发布');
    }
    debugPrint('ROUNDTABLE_IMPORT_VISUAL_PASSED ${output.path}');
    return;
  }

  await mount(seeded: false);
  await openRoundtable();
  await windowManager.setSize(const Size(1512, 859));
  await openCreatorDrawer();
  await capture('02', find.text('快速开始 · 1 / 2'));
  await tap(find.byTooltip('收起博主列表'));
  await tap(find.text('知识资产'));
  await capture('24', find.text('暂无知识图谱'));
  await tap(find.text('圆桌专家团'));
  await openCreatorDrawer();
  await tap(find.text('配置渠道'));
  await tap(find.text('去授权'));
  await capture('53', find.text('抖音授权说明'));
  await tap(find.text('取消'));
  connected = true;
  await tap(find.text('完成'));
  await openCreatorDrawer();
  await capture('41', find.text('快速开始 · 2 / 2'));
  await tap(find.text('跳过引导'));
  await capture('42', find.text('+ 添加博主'));

  connected = false;
  final ids = await _seed(database);
  await mount(seeded: true, seats: ids.take(4).toList());
  await openRoundtable();
  final stage = find.byKey(const ValueKey('roundtable-scene'));
  await wait(find.descendant(
    of: stage,
    matching: find.byWidgetPredicate((w) => w is RawImage && w.image != null),
  ));
  await capture('01', find.text('展示席位  4 / 8'));
  await capture('03', find.byKey(const ValueKey('roundtable-open-creators')));
  await openCreatorDrawer();
  await tap(find.text('配置渠道'));
  await capture('07', find.text('未授权'));
  await tap(find.byTooltip('关闭').last);
  connected = true;
  await openCreatorDrawer();
  await tap(find.text('配置渠道'));
  await capture('08', find.text('已授权'));
  await tap(find.byTooltip('关闭').last);
  await openCreatorDrawer();
  await tap(find.text('+ 添加博主'));
  await capture('09', find.text('粘贴链接或分享文案 *'));
  final link = find.descendant(
    of: find.byKey(const ValueKey('roundtable-add-link')),
    matching: find.byType(EditableText),
  );
  await wait(link);
  final linkText = controller.widget<EditableText>(link).controller;
  linkText.text = '不是抖音链接';
  await tap(find.text('读取作品'));
  await capture('10', find.text('请粘贴一条抖音作品链接或分享文本。'));
  if (linkText.text != '不是抖音链接') {
    throw StateError('解析失败后清空了用户输入');
  }
  linkText.text = 'https://www.douyin.com/video/1234567890123456700';
  await tap(find.text('读取作品'));
  await capture('13', find.text('修改链接'));
  await tap(find.text('修改链接'));
  await tap(find.text('取消'));

  await tap(find.byKey(const ValueKey('roundtable-seat-settings')));
  await capture('04', find.textContaining('已展示 4 / 8'));
  for (final name in _names.skip(4)) {
    await tap(find.descendant(
      of: find.widgetWithText(ListTile, name).last,
      matching: find.widgetWithText(OutlinedButton, '在圆桌展示'),
    ));
  }
  await capture('05', find.textContaining('已展示 8 / 8'));
  await tap(find.text('完成'));
  await capture('38', find.text('展示席位  8 / 8'));
  final modelPicker = find.byType(UiSelect<String>).first;
  await tap(modelPicker);
  await tap(find.text('Claude'));
  await capture('58', find.text('Claude 测试模型'));
  await tap(find.text('Claude 测试模型'));
  final preferences = await SharedPreferences.getInstance();
  if (preferences.getString('creator_roundtable.model.v1') !=
      jsonEncode(['claude-fixture', 'claude-fixture'])) {
    throw StateError('模型切换没有保存 Claude');
  }
  await tap(find.text('知识资产'));
  await wait(find.text('Claude 测试模型'));
  await tap(find.text('圆桌专家团'));
  await tap(modelPicker);
  await tap(find.text('GPT'));
  await tap(find.text('GPT 测试模型').hitTestable());

  await tap(find.byKey(const ValueKey('roundtable-stage-experts')));
  final chat = find.byType(CreatorRoundtableChat);
  Finder chatControl(Finder control) =>
      find.descendant(of: chat, matching: control);
  await capture('06', chatControl(find.text('修改只影响下一条消息。')));
  await tap(find.byKey(const ValueKey('roundtable-chat-experts')));
  await tap(chatControl(find.byTooltip('放大对话')));
  await capture('36', chatControl(find.text('你好，今天想和圆桌专家聊些什么？')));
  await tap(chatControl(find.byTooltip('退出全屏对话')));
  await tap(chatControl(find.widgetWithText(OutlinedButton, '新对话')));
  await tap(chatControl(find.text(_question)));
  await capture('18', chatControl(find.text(_question)));
  await tap(chatControl(find.widgetWithText(OutlinedButton, _question)));
  await capture('39', chatControl(find.text('最近对话')));
  await tap(chatControl(find.byTooltip('关闭最近对话')));
  await tap(find.byKey(const ValueKey('roundtable-chat-experts')));
  await capture('40', chatControl(find.text('修改只影响下一条消息。')));
  await tap(find.byKey(const ValueKey('roundtable-chat-experts')));
  await tap(chatControl(find.byTooltip('放大对话')));
  await capture('19', chatControl(find.text('对话列表')));
  await tap(chatControl(find.byTooltip('删除对话')));
  await capture('54', find.text('删除此会话及其中的消息？'));
  await tap(find.text('取消'));
  await tap(chatControl(find.byTooltip('收起对话列表')));
  await wait(chatControl(find.byTooltip('展开对话列表')));
  await tap(chatControl(find.byTooltip('收起对话')));
  await capture('20', find.byTooltip('全屏展开对话').hitTestable());

  await openCreatorDrawer();
  await tap(find.widgetWithText(ListTile, _names.first));
  await capture('14', find.text('先验证付费，再验证功能'));
  await capture('43', find.text('作品同步'));
  await tap(find.widgetWithText(OutlinedButton, '立即同步'));
  await capture('50', find.text('同步范围'));
  await tap(find.text('最新作品'));
  await capture('52', find.text('同步作品数量'));
  await tap(find.text('开始同步'));
  await capture('45', find.textContaining('第 1 页 ·'));
  await tap(find.text('后台继续'));
  await tap(find.text('返回博主列表'));
  await openCreatorDrawer();
  await tap(find.widgetWithText(ListTile, _names.first));
  await tap(find.text('查看进度'));
  await wait(find.text('取消同步'));
  syncGate.complete();
  await capture('46', find.textContaining('暂无新作品').hitTestable());
  await tap(find.widgetWithText(FilledButton, '完成').hitTestable());
  await tap(find.widgetWithText(OutlinedButton, '立即同步'));
  await tap(find.text('开始同步'));
  await capture('48', find.text('抖音暂未返回作品列表，请重试。').hitTestable());
  await tap(find.widgetWithText(FilledButton, '关闭').hitTestable());
  await tap(find.widgetWithText(OutlinedButton, '重试'));
  await tap(find.text('开始同步'));
  await capture(
      '49', find.widgetWithText(OutlinedButton, '重新授权').hitTestable());
  await tap(find.widgetWithText(OutlinedButton, '重新授权'));
  await wait(find.text('重新连接抖音'));
  await tap(find.text('取消'));
  await tap(find.text('返回博主列表'));
  await tap(find.byTooltip('收起博主列表'));
  await tap(find.text('知识资产'));
  final authorLabel = '${_names.first} · v1';
  await tap(find.byWidgetPredicate((widget) =>
      widget is DropdownButton<String> &&
      (widget.items?.any((item) =>
              item.child is Text && (item.child as Text).data == authorLabel) ??
          false)));
  await tap(find.text(authorLabel).hitTestable().last);
  await tap(find.widgetWithText(FilterChip, '核实现有支出').first);
  await capture('21', find.text('关联作品 · 1'));
  await tap(find.text('散点'));
  await capture('22', find.text('散点'));
  await tap(find.text('网络'));
  await tap(find.text('关联作品 · 1'));
  await capture('23', find.text('关联作品 · 1'));
  await tap(find.byTooltip('全屏知识图谱'));
  await capture('44', find.byType(BackButton));
  await tap(find.byType(BackButton));
  for (final (kind, figure) in [
    ('ebook', '28'),
    ('web', '29'),
    ('skill', '30')
  ]) {
    final button = find.byKey(ValueKey('creator-generate-$kind'));
    await wait(button);
    await controller.ensureVisible(button);
    await tap(button);
    await capture(figure, find.text('来源博主 *'));
    await tap(find.text('取消'));
  }
  final generateWeb = find.byKey(const ValueKey('creator-generate-web'));
  await controller.ensureVisible(generateWeb);
  await tap(generateWeb);
  final assetTitle = find.descendant(
    of: find.byKey(const ValueKey('roundtable-asset-title')),
    matching: find.byType(EditableText),
  );
  await wait(assetTitle);
  controller.widget<EditableText>(assetTitle).controller.text = '付费验证操作手册';
  if (modelClient.requested.isCompleted) {
    throw StateError('资产测试开始前出现了意外模型请求');
  }
  await tap(find.widgetWithText(FilledButton, '生成'));
  await modelClient.requested.future.timeout(const Duration(seconds: 12));
  await capture('31', find.text('正在生成网页'));
  modelClient.release.complete();
  await capture('32', find.text('生成失败'));
  await tap(find.text('修改参数'));
  await wait(assetTitle);
  if (controller.widget<EditableText>(assetTitle).controller.text !=
      '付费验证操作手册') {
    throw StateError('资产失败后没有保留原名称');
  }
  await tap(find.text('取消'));
  if ((await database.creatorAssets()).isNotEmpty) {
    throw StateError('失败的资产不能进入成品列表');
  }
  debugPrint('ROUNDTABLE_VISUAL_BATCH_PASSED ${output.path}');
}
