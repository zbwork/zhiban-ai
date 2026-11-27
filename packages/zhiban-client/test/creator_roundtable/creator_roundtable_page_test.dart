import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_ui/widgets/ui_icon_button.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/config/client_assets.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:zhiban_client/pages/chat/widgets/model_picker_content.dart';
import 'package:zhiban_client/pages/local_workspace/local_model_picker.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_asset_dialog.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_roundtable_chat.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_roundtable_page.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_asset_workflow.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_expert_workflow.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_seat_portrait.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/douyin_creator_service.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_controller.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';
import 'package:zhiban_ui/widgets/ui_select.dart';
import 'package:zhiban_ui/widgets/ui_segmented_tabs.dart';

class _RoundtableStore extends Fake implements LocalWorkspaceStore {
  _RoundtableStore(this.creators, this.works, this.assets);
  final List<LocalRow> creators;
  final List<LocalRow>? works;
  final List<LocalRow> assets;

  @override
  Future<List<LocalRow>> creatorProfiles() async => creators;

  @override
  Future<List<LocalRow>> creatorAssets() async => assets;

  @override
  Future<LocalRow?> lastResumableCreatorAssetJob(String kind) async => null;

  @override
  Future<LocalRow?> latestCreatorExpert(String creatorId) async => null;

  @override
  Future<LocalRow?> lastCreatorExpertJob(String creatorId) async => null;

  @override
  Future<LocalRow?> nextQueuedCreatorExpertJob() async => null;

  @override
  Future<LocalRow?> lastResumableCreatorSyncJob(String creatorId) async => null;

  @override
  Future<List<LocalRow>> creatorWorks(String creatorId) async =>
      works ??
      [
        {
          'id': 'first',
          'title': '测试作品',
          'likes': 2,
          'comments': 0,
          'collects': 0,
          'source_url': 'https://www.douyin.com/video/1234567890123456789'
        },
        {
          'id': 'second',
          'title': '第二条作品',
          'likes': 3,
          'comments': 1,
          'collects': 0,
          'transcript': '第二条作品的逐字稿',
          'source_url': 'https://www.douyin.com/video/1234567890123456790'
        },
      ];
}

class _RoundtableDraftStore extends _RoundtableStore {
  _RoundtableDraftStore(
      [List<LocalRow> creators = const [
        {'id': 'a', 'name': '测试博主'}
      ]])
      : super(creators, null, []);

  @override
  Future<List<LocalRow>> roundtableChats() async => [];

  @override
  Future<LocalRow?> latestCreatorExpert(String creatorId) async =>
      {'id': creatorId, 'version': 1};
}

class _RunningSyncStore extends _RoundtableStore {
  _RunningSyncStore()
      : super(
            [
              {
                'id': 'a',
                'channel': 'douyin',
                'source_account_id': 'author',
                'name': '后台同步博主',
              },
            ],
            null,
            []);

  int started = 0;
  Object? failure;

  @override
  Future<String> beginCreatorSyncJob(
    String creatorId, {
    required int? latest,
    required String? model,
    String? resumeId,
  }) async {
    started++;
    return 'active-job';
  }

  @override
  Future<void> checkpointCreatorSyncJob(
      String id, Map<String, Object?> checkpoint) async {}

  @override
  Future<({String creatorId, int added})> importCreatorWorks(
      Map<String, dynamic> author, List<Map<String, dynamic>> works,
      {String channel = 'douyin', String? syncJobId}) async {
    return (creatorId: 'a', added: works.length);
  }

  @override
  Future<void> failCreatorJob(String id, String message) async {
    failure = (id, message);
  }
}

class _QueuedSyncStore extends _RunningSyncStore {
  _QueuedSyncStore() {
    creators.add({
      'id': 'b',
      'channel': 'douyin',
      'source_account_id': 'original',
      'name': '正在蒸馏的博主',
    });
  }

  LocalRow? task;

  @override
  Future<List<LocalRow>> creatorWorks(String creatorId) async => [
        {
          'id': 'work-$creatorId',
          'creator_id': creatorId,
          'source_work_id': '1234567890123456789',
          'title': '取证作品',
          'source_url': 'https://www.douyin.com/video/1234567890123456789',
          'source_version': 1,
          'metadata': '{"article_body":"先核对原始收据，再确认已付费用。"}',
        }
      ];

  @override
  Future<String> beginCreatorExpertJob(String creatorId,
      Map<String, Object> model, List<Map<String, Object>> evidence,
      {bool fromSync = false,
      LocalRow? creatorIdentity,
      bool queued = false}) async {
    expect(creatorId, 'a');
    expect(queued, isTrue);
    expect(fromSync, isTrue);
    task = {
      'id': 'queued-job',
      'status': 'queued',
      'model_snapshot': jsonEncode(model),
      'source_snapshot': jsonEncode(evidence),
      'request_payload': jsonEncode({
        'creator_ids': [creatorId],
        'trigger': 'work-sync',
        'creator_identity': creatorIdentity,
      }),
      'result_payload': '{}',
    };
    return 'queued-job';
  }

  @override
  Future<LocalRow?> nextQueuedCreatorExpertJob() async =>
      task?['status'] == 'queued' ? task : null;

  @override
  Future<LocalRow?> lastCreatorExpertJob(String creatorId) async =>
      creatorId == 'a' ? task : null;

  @override
  Future<void> resumeCreatorExpertJob(String id) async {
    expect(id, 'queued-job');
    task = {...task!, 'status': 'running'};
  }

  @override
  Future<void> failCreatorJob(String id, String message) async {
    expect(id, 'queued-job');
    task = {...task!, 'status': 'failed', 'error': message};
  }
}

class _QueuedSyncCredentials extends Fake implements ModelServiceStore {
  final active = Completer<String?>();
  int requested = 0;

  @override
  Future<String?> getApiKey(String providerId) async {
    expect(providerId, 'test');
    return ++requested == 1 ? active.future : null;
  }
}

class _WaitingSyncAdapter extends DouyinCreatorService {
  final request = Completer<Map<String, dynamic>>();
  final nextRequest = Completer<Map<String, dynamic>>();
  int reads = 0;

  @override
  Future<Map<String, dynamic>> readAuthorPage({
    required String cookie,
    required String authorId,
    required int cursor,
    int count = 20,
    required void Function(String) onStatus,
  }) {
    reads++;
    onStatus('正在读取公开作品…');
    return cursor == 0 ? request.future : nextRequest.future;
  }

  @override
  void close() {
    if (reads == 0) return;
    final current = reads == 1 ? request : nextRequest;
    if (!current.isCompleted) {
      current.completeError(const DouyinCreatorException('连接已关闭'));
    }
  }
}

class _PendingSyncStore extends _RoundtableStore {
  _PendingSyncStore()
      : super(
            const [
              {
                'id': 'a',
                'channel': 'douyin',
                'source_account_id': 'author',
                'name': '断点博主',
              },
            ],
            null,
            []);

  @override
  Future<LocalRow?> lastResumableCreatorSyncJob(String creatorId) async => {
        'id': 'job',
        'status': 'interrupted',
        'request_payload': '{"creator_id":"a","latest":7}',
        'result_payload':
            '{"author_id":"author","next_cursor":3,"cursors":[0],"works":{}}',
      };
}

class _AssetResumeStore extends _RoundtableStore {
  _AssetResumeStore() : super([], [], []);

  bool resumed = false;
  Map<String, Object>? candidate, draft;
  String? publishedFile, failure;

  @override
  Future<LocalRow?> lastResumableCreatorAssetJob(String kind) async => {
        'id': 'asset-original',
        'stage': draft != null
            ? 'render'
            : candidate != null
                ? 'review'
                : 'generate_review',
        'model_snapshot':
            '{"provider_id":"original","model_id":"model-original"}',
        'source_snapshot': '[{"expert_id":"author","version":1,"name":"原名"}]',
        'request_payload': '{"title":"原任务名称"}',
        if (draft != null || candidate != null)
          'result_payload': jsonEncode(draft ?? candidate),
      };

  @override
  Future<LocalRow?> publishedCreatorExpertVersion(
      String creatorId, int version) async {
    expect(creatorId, 'author');
    expect(version, 1);
    return {
      'id': 'author',
      'version': version,
      'name': '当前名称',
      'content':
          '{"methods":[{"id":"old","steps":[{"evidence_ids":["old-evidence"]}]}]}',
      'evidence':
          '[{"id":"old-evidence","text":"冻结原文","url":"https://www.douyin.com/video/1234567890123456789","start_ms":10,"end_ms":200}]',
    };
  }

  @override
  Future<void> resumeCreatorAssetJob(String id, String kind) async {
    expect(id, 'asset-original');
    expect(kind, 'web');
    resumed = true;
  }

  @override
  Future<void> checkpointCreatorAssetCandidate(
      String id, String kind, Map<String, Object> value) async {
    expect(id, 'asset-original');
    expect(kind, 'web');
    expect(candidate, isNull);
    candidate = value;
  }

  @override
  Future<void> checkpointCreatorAssetJob(
      String id, String kind, Map<String, Object> draft) async {
    expect(id, 'asset-original');
    expect(kind, 'web');
    this.draft = draft;
  }

  @override
  Future<void> saveCreatorAsset({
    required String id,
    required String kind,
    required String title,
    required String fileName,
    required Map<String, Object> model,
    required List<LocalRow> sources,
    String? jobId,
  }) async {
    expect(id, 'asset-original');
    expect(jobId, id);
    expect(title, '原任务名称');
    expect(model['model_id'], 'model-original');
    expect(sources.first, {'expert_id': 'author', 'version': 1, 'name': '原名'});
    expect(sources.last['id'], 'old-evidence');
    publishedFile = fileName;
  }

  @override
  Future<void> failCreatorJob(String id, String message) async {
    failure = message;
  }
}

class _ExpertRecoveryStore extends _RoundtableStore {
  _ExpertRecoveryStore(LocalRow work, {LocalRow? archivedWork})
      : super([
          {'id': 'a', 'name': '专家恢复样本', 'channel': 'douyin'},
        ], [
          work,
          if (archivedWork != null) archivedWork,
        ], []);

  @override
  Future<LocalRow?> lastCreatorExpertJob(String creatorId) async => {
        'status': 'failed',
        'source_snapshot': jsonEncode(creatorEvidence(works!)),
        'request_payload': jsonEncode({'trigger': 'work-sync'}),
        'error': '模型服务暂不可用',
      };
}

class _ImportStore extends _RoundtableStore {
  _ImportStore() : super([], [], []);

  @override
  Future<({String creatorId, int added})> importCreatorWorks(
    Map<String, dynamic> author,
    List<Map<String, dynamic>> incoming, {
    String channel = 'douyin',
    String? syncJobId,
  }) async {
    if (creators.isEmpty) {
      creators.add({
        'id': 'a',
        'name': author['name'],
        'avatar_url': author['avatar'],
        'work_count': incoming.length,
        'channel': channel,
      });
    }
    works!.addAll(incoming.map((work) => <String, Object?>{...work}));
    return (creatorId: 'a', added: incoming.length);
  }
}

class _ImportAdapter extends DouyinCreatorService {
  _ImportAdapter({this.avatar});
  final String? avatar;
  int reads = 0;

  @override
  Future<Map<String, dynamic>> read({
    required String cookie,
    required String link,
    required void Function(String) onStatus,
  }) async {
    reads++;
    expect(link, 'https://v.douyin.com/QSOW49trZuA/');
    if (reads == 1) throw const DouyinCreatorException('无法读取博主及作品。');
    return {
      'author': {
        'id': 'author-1',
        'name': '单条导入博主',
        if (avatar != null) 'avatar': avatar,
        'followers': 10,
        'works': 15,
        'bio': ''
      },
      'work': {'id': '1234567890123456789', 'title': '单条验收作品'},
      'posts': [
        {'id': '1234567890123456790', 'title': '这条不随单视频导入'}
      ],
    };
  }
}

class _RoundtableModels extends ModelProvidersNotifier {
  @override
  Future<List<AiProviderConfig>> build() async => const [
        AiProviderConfig(id: 'test', name: '测试模型服务', enabled: true, models: [
          AiModelConfig(id: 'a', modelId: 'gpt-test-a', displayName: '文本模型 A'),
          AiModelConfig(id: 'b', modelId: 'gpt-test-b', displayName: '文本模型 B'),
          AiModelConfig(id: 'c', modelId: 'whisper-test', displayName: '语音模型'),
        ]),
        AiProviderConfig(
          id: 'images',
          name: '测试图片服务',
          enabled: true,
          imageEditBaseUrl: 'https://images.example/v1',
          models: [
            AiModelConfig(
                id: 'edit', modelId: 'gpt-image-1', displayName: '测试图片编辑'),
            AiModelConfig(
                id: 'edit-alt',
                modelId: 'gpt-image-1.5',
                displayName: '另一张图模型'),
          ],
        ),
      ];
}

class _PortraitTestCredentials extends Fake implements ModelServiceStore {
  @override
  Future<String?> getApiKey(String providerId) async =>
      providerId == 'images' ? 'test-image-key' : null;
}

class _RoundtablePortraitFixture extends Fake
    implements CreatorSeatPortraitService {
  _RoundtablePortraitFixture(this.png);

  final File png;
  final response = Completer<void>();
  bool generated = false;
  final requestedModels = <String>[];
  int get requests => requestedModels.length;

  @override
  Future<File?> load(
          Directory root, String creatorId, String avatar, int slot) async =>
      generated && creatorId == 'a' && slot == 0 ? png : null;

  @override
  Future<File> generate({
    required Directory root,
    required String creatorId,
    required String avatar,
    required int slot,
    required AiProviderConfig provider,
    required String model,
    required String key,
    required CancelToken cancel,
  }) async {
    requestedModels.add(model);
    expect(creatorId, 'a');
    expect(avatar, 'https://p3.douyinpic.com/creator.png');
    expect(slot, 0);
    expect(provider.id, 'images');
    expect(key, 'test-image-key');
    await response.future;
    generated = true;
    return png;
  }
}

final _creatorDrawer = find.byKey(const ValueKey('roundtable-creators-drawer'));
final _creatorDrawerButton =
    find.byKey(const ValueKey('roundtable-open-creators'));

Future<void> _openCreatorDrawer(WidgetTester tester) async {
  await tester.tap(_creatorDrawerButton);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cache = Directory.systemTemp.createTempSync('roundtable-image-cache-');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    messenger.setMockMethodCallHandler(paths, (_) async => cache.path);
  });
  tearDownAll(() {
    messenger.setMockMethodCallHandler(paths, null);
    cache.deleteSync(recursive: true);
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final previous = ClientAssets.packageName;
    ClientAssets.packageName = null;
    addTearDown(() => ClientAssets.packageName = previous);
  });

  Future<void> open(WidgetTester tester, Size size,
      {List<LocalRow> creators = const [],
      bool configureModels = false,
      CreatorSeatPortraitService? portraits,
      ModelServiceStore? credentials,
      String? douyinSession,
      DouyinCreatorService Function()? adapter,
      LocalWorkspaceStore? store,
      Future<Directory> Function()? mediaDirectory,
      List<LocalRow>? works,
      List<LocalRow> assets = const [],
      double sidebarWidth = 0}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = LocalWorkspaceController(
        store ?? _RoundtableStore(creators, works, assets));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        localWorkspaceProvider.overrideWith((ref) async => controller),
        if (configureModels)
          modelProvidersProvider.overrideWith(_RoundtableModels.new),
        if (configureModels)
          modelCatalogProvider.overrideWith((_) async =>
              const ModelCatalog(providers: [], modelsByProviderId: {})),
        if (portraits != null)
          creatorSeatPortraitServiceProvider.overrideWithValue(portraits),
        if (credentials != null || portraits != null)
          modelServiceStoreProvider
              .overrideWithValue(credentials ?? _PortraitTestCredentials()),
        if (mediaDirectory != null)
          creatorAssetDirectoryProvider.overrideWithValue(mediaDirectory),
        if (adapter != null)
          creatorDouyinAdapterProvider.overrideWithValue(adapter),
        if (douyinSession != null)
          creatorDouyinSessionProvider
              .overrideWithValue(() async => douyinSession),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(width: sidebarWidth),
              const Expanded(child: CreatorRoundtablePage()),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('圆桌与知识资产共用已选文本模型', (tester) async {
    await open(tester, const Size(1280, 800), configureModels: true);
    final select = find.byKey(const ValueKey('roundtable-model-selector'));
    expect(tester.widget(select), isA<LocalModelPicker>());
    await tester.tap(select);
    await tester.pumpAndSettle();
    final popup = find.byType(ModelPickerEntry);
    expect(tester.getTopLeft(popup).dy,
        greaterThan(tester.getBottomLeft(select).dy));
    expect(
        tester
            .widget<ModelPickerEntry>(popup)
            .models
            .map((model) => model.label),
        ['文本模型 A', '文本模型 B']);
    expect(find.text('全部平台'), findsOneWidget);
    expect(find.text('刷新列表'), findsOneWidget);
    await tester.tap(find.text('文本模型 B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('知识资产'));
    await tester.pumpAndSettle();
    expect(find.text('文本模型 B'), findsOneWidget);
    await tester.tap(select);
    await tester.pumpAndSettle();
    final modelA = find.descendant(of: popup, matching: find.text('文本模型 A'));
    await tester.tap(modelA);
    await tester.pumpAndSettle();
    await tester.tap(find.text('圆桌专家团'));
    await tester.pumpAndSettle();
    expect(find.text('文本模型 A'), findsOneWidget);
  });

  testWidgets('模型下拉菜单打开时离开圆桌能正常释放菜单', (tester) async {
    await open(tester, const Size(1280, 800), configureModels: true);
    await tester.tap(find.byKey(const ValueKey('roundtable-model-selector')));
    await tester.pumpAndSettle();
    expect(find.text('文本模型 B'), findsOneWidget);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(navigator.pushReplacement<void, void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('下一页'))),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('文本模型 B'), findsNothing);
    expect(find.text('下一页'), findsOneWidget);
  });

  testWidgets('初次进入展示实景、两项标签、引导和底部提问栏', (tester) async {
    await open(tester, const Size(1280, 800));
    final stage = find.byKey(const ValueKey('roundtable-scene'));
    expect(stage, findsOneWidget);
    expect(tester.getSize(stage).width, greaterThan(850));
    expect(find.text('圆桌专家团'), findsOneWidget);
    expect(find.text('知识资产'), findsOneWidget);
    final title = find.text('博主圆桌');
    final firstTabIcon = find.byIcon(CupertinoIcons.person_2);
    expect(tester.getTopLeft(firstTabIcon).dx, tester.getTopLeft(title).dx);
    await tester.binding.setSurfaceSize(const Size(900, 800));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(stage).dx, tester.getTopLeft(title).dx);
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    await tester.pumpAndSettle();
    expect(find.text('作品与逐字稿'), findsNothing);
    expect(find.byTooltip('展开博主列表'), findsOneWidget);
    expect(find.text('向圆桌专家提问…'), findsOneWidget);
    await _openCreatorDrawer(tester);
    await tester.tap(find.text('跳过引导'));
    await tester.pumpAndSettle();
    expect(find.text('快速开始 · 1 / 2'), findsNothing);
    expect(
        (await SharedPreferences.getInstance())
            .getBool('creator_roundtable.guide_dismissed.v1'),
        isTrue);
    await tester.tap(find.byTooltip('收起博主列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('知识资产'));
    await tester.pumpAndSettle();
    expect(stage, findsNothing);
    expect(find.text('暂无知识图谱'), findsOneWidget);
    await tester.tap(find.text('圆桌专家团'));
    await tester.pumpAndSettle();
    expect(stage, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('添加博主弹窗支持取消和非法链接提示', (tester) async {
    await open(tester, const Size(1100, 780));
    await _openCreatorDrawer(tester);
    await tester.tap(find.text('+ 添加博主'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    final title = find.descendant(of: dialog, matching: find.text('添加博主'));
    expect(
        tester.getBottomLeft(find.text('读取作品')).dy -
            tester.getTopLeft(title).dy,
        lessThan(320));
    await tester.tap(find.text('读取作品'));
    await tester.pumpAndSettle();
    expect(find.text('请粘贴一条抖音作品链接或分享文本。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('完整分享文案可重试，提取短链并只导入当前作品', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = _ImportStore();
    final adapter = _ImportAdapter();
    final workspace = LocalWorkspaceController(store);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        localWorkspaceProvider.overrideWith((_) async => workspace),
        creatorDouyinAdapterProvider.overrideWithValue(() => adapter),
        creatorDouyinSessionProvider.overrideWithValue(() async => 'fixture'),
      ],
      child: const MaterialApp(home: Scaffold(body: CreatorRoundtablePage())),
    ));
    await tester.pumpAndSettle();
    await _openCreatorDrawer(tester);
    await tester.tap(find.text('+ 添加博主'));
    await tester.pumpAndSettle();
    const link =
        r'0.51 Q@K.wf :1pm 04/01 VlP:/ 风里雨里挣口饭，运费低的没法干，广西来宾到北京一车低价货走起# 记录卡车生活 # 货车司机  https\://v.douyin.com/QSOW49trZuA/ 复制此链接，打开Dou音搜索，直接观看视频！';
    final field = find.descendant(
      of: find.byKey(const ValueKey('roundtable-add-link')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, link);
    await tester.tap(find.text('读取作品'));
    await tester.pumpAndSettle();
    expect(find.text('蒸馏失败'), findsOneWidget);
    expect(store.works, isEmpty);

    await tester.tap(find.text('修改链接'));
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(field).controller.text, link);
    await tester.tap(find.text('读取作品'));
    await tester.pumpAndSettle();
    final preview =
        find.byKey(const ValueKey('roundtable-import-preview-dialog'));
    final confirm = find.widgetWithText(FilledButton, '添加到圆桌');
    expect(tester.getSize(preview).width, lessThanOrEqualTo(640));
    expect(tester.getSize(preview).height, lessThan(500));
    expect(
        tester.getTopLeft(confirm).dy -
            tester.getBottomLeft(find.textContaining('本次只归档上面这一条')).dy,
        lessThan(80));
    await tester.tap(find.text('添加到圆桌'));
    await tester.pumpAndSettle();
    expect(find.text('作品资料已保存'), findsOneWidget);
    expect(find.textContaining('专家待补充作品'), findsOneWidget);
    expect(find.text('已保存 1 条作品资料。'), findsOneWidget);
    expect(find.text('已发布博主专家'), findsNothing);
    expect(store.works!.map((row) => row['title']), ['单条验收作品']);
    await tester.tap(find.text('查看作品'));
    await tester.pumpAndSettle();
    expect(find.text('原片尚未下载到本机 · 暂无逐字稿'), findsOneWidget);
    expect(find.text('博主专家 · 待补充作品'), findsOneWidget);
    expect(find.text('生成专家'), findsNothing);
    expect(find.text('继续生成'), findsNothing);
  });

  testWidgets('不可问的席位直达蒸馏恢复入口', (tester) async {
    SharedPreferences.setMockInitialValues({
      'creator_roundtable.display_seats.v1': ['a'],
      'creator_roundtable.model.v1': jsonEncode(['test', 'gpt-test-a']),
    });
    final work = {
      'id': 'work',
      'creator_id': 'a',
      'source_version': 1,
      'source_url': 'https://www.douyin.com/video/1234567890123456789',
      'title': '可引用的作品',
      'transcript': '先核对凭证再发布结论。',
      'metadata': jsonEncode({
        'transcript_cues': [
          {'start_ms': 0, 'end_ms': 4000, 'text': '先核对凭证再发布结论。'},
        ],
      }),
    };
    final root = Directory.systemTemp.createTempSync('roundtable-expert-prep-');
    addTearDown(() => root.deleteSync(recursive: true));
    await open(tester, const Size(1280, 820),
        store: _ExpertRecoveryStore(work, archivedWork: {
          'id': 'missing-file',
          'creator_id': 'a',
          'source_version': 1,
          'source_work_id': '1234567890123456790',
          'source_url': 'https://www.douyin.com/video/1234567890123456790',
          'title': '待转写的归档作品',
          'metadata': jsonEncode({
            'local_media_file': '01010101-0101-0101-0101-010101010101.mp4',
          }),
        }),
        configureModels: true,
        mediaDirectory: () async => root);
    final pendingSeat = find.descendant(
      of: find.byKey(const ValueKey('roundtable-seat-0')),
      matching: find.text('暂不可问'),
    );
    expect(pendingSeat, findsOneWidget);
    await tester.tap(pendingSeat);
    await tester.pumpAndSettle();
    expect(find.text('知识更新未完成'), findsOneWidget);
    expect(find.text('模型服务暂不可用'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '重试知识更新'), findsOneWidget);
    expect(find.text('继续生成'), findsNothing);
    final prepare = find.widgetWithText(OutlinedButton, '补齐逐字稿并蒸馏');
    expect(prepare, findsOneWidget);
    expect(find.text('转写本地音视频'), findsNothing);
    final noEvidence = find.textContaining('暂未取得新证据');
    await tester.runAsync(() async {
      await tester.tap(prepare);
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (
          noEvidence.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(noEvidence, findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '重试知识更新'), findsOneWidget);
  });

  testWidgets('导入分享后自动入座并后台生成形象，窗口变化保持等比', (tester) async {
    SharedPreferences.setMockInitialValues({
      'creator_roundtable.model.v1': jsonEncode(['test', 'gpt-test-a']),
    });
    final root = Directory.systemTemp.createTempSync('roundtable-auto-seat-');
    addTearDown(() => root.delete(recursive: true));
    final png = File('assets/images/creator_roundtable_douyin.png')
        .copySync('${root.path}/portrait.png');
    final portraits = _RoundtablePortraitFixture(png);
    final store = _ImportStore();
    final adapter =
        _ImportAdapter(avatar: 'https://p3.douyinpic.com/creator.png')
          ..reads = 1;
    await open(tester, const Size(1280, 820),
        store: store,
        adapter: () => adapter,
        douyinSession: 'fixture',
        configureModels: true,
        portraits: portraits,
        mediaDirectory: () async => root);
    await _openCreatorDrawer(tester);
    await tester.tap(find.text('+ 添加博主'));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byKey(const ValueKey('roundtable-add-link')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, r'复制分享 https\://v.douyin.com/QSOW49trZuA/。');
    await tester.tap(find.text('读取作品'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始蒸馏'));
    await tester.pumpAndSettle();
    expect(find.text('已保存 1 条作品资料。'), findsOneWidget);
    expect(portraits.generated, isFalse);
    expect(portraits.requestedModels, ['gpt-image-1']);
    await tester.tap(find.widgetWithText(FilledButton, '完成').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('展示席位  1 / 8'), findsOneWidget);
    expect(find.text('人物入座'), findsNothing);
    expect(find.text('生成席位形象'), findsNothing);
    portraits.response.complete();
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(portraits.generated, isTrue,
        reason: tester
            .widgetList<SnackBar>(find.byType(SnackBar))
            .map((bar) => (bar.content as Text).data)
            .join(', '));
    expect(find.byKey(const ValueKey('generated-seat-0')), findsOneWidget);
    final scene = find.byKey(const ValueKey('roundtable-scene'));
    final portrait = find.byKey(const ValueKey('generated-seat-0'));
    final original = tester.getSize(scene);
    expect(original.aspectRatio, closeTo(1586 / 992, .001));
    await tester.binding.setSurfaceSize(const Size(920, 630));
    await tester.pumpAndSettle();
    final resized = tester.getSize(scene);
    expect(resized.width, lessThan(original.width));
    expect(resized.aspectRatio, closeTo(1586 / 992, .001));
    expect(tester.getRect(scene).contains(tester.getCenter(portrait)), isTrue);
  });

  testWidgets('从博主名单进入作品详情并返回', (tester) async {
    const cover = 'https://example.com/cover.jpg';
    final works = await _RoundtableStore([], null, []).creatorWorks('a');
    await open(tester, const Size(1200, 750), creators: [
      {'id': 'a', 'name': '测试博主', 'work_count': 2}
    ], works: [
      {...works.first, 'cover_url': cover},
      works.last,
    ]);
    await _openCreatorDrawer(tester);
    await tester.tap(find.text('测试博主'));
    await tester.pumpAndSettle();
    expect(find.text('逐字稿'), findsOneWidget);
    expect(find.text('打开原地址'), findsOneWidget);
    expect(find.text('暂无逐字稿'), findsOneWidget);
    final first = find.widgetWithText(ListTile, '测试作品');
    final second = find.widgetWithText(ListTile, '第二条作品');
    final thumbnail = tester.widget<UiNetworkImage>(
        find.descendant(of: first, matching: find.byType(UiNetworkImage)));
    expect(thumbnail.imageUrl, cover);
    expect(tester.widget<ListTile>(first).leading, isA<SizedBox>());
    expect(find.byKey(const ValueKey('creator-work-image-0')), findsNothing);
    expect(find.descendant(of: second, matching: find.byType(Image)),
        findsOneWidget);
    expect(tester.widget<ListTile>(first).selected, isTrue);
    expect(tester.widget<ListTile>(second).selected, isFalse);
    await tester.tap(find.text('第二条作品'));
    await tester.pumpAndSettle();
    expect(find.text('第二条作品的逐字稿'), findsOneWidget);
    expect(tester.widget<ListTile>(first).selected, isFalse);
    expect(tester.widget<ListTile>(second).selected, isTrue);
    await tester.tap(find.text('返回博主列表'));
    await tester.pumpAndSettle();
    expect(find.text('测试博主'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同步失败保留最近成功时间，重开恢复最新条数', (tester) async {
    await open(tester, const Size(1200, 750), douyinSession: '', creators: [
      {
        'id': 'a',
        'channel': 'douyin',
        'source_account_id': 'author',
        'name': '同步验收博主',
        'last_synced': DateTime(2026, 11, 23, 9).millisecondsSinceEpoch,
      },
    ]);

    await _openCreatorDrawer(tester);
    await tester.tap(find.text('同步验收博主'));
    await tester.pumpAndSettle();
    final lastSuccess = find.textContaining('最近完成 11 月 23 日');
    expect(lastSuccess, findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '立即同步'));
    await tester.pumpAndSettle();
    final quantity = find.byKey(const ValueKey('roundtable-sync-quantity'));
    await tester.tap(find.text('最新作品'));
    await tester.pumpAndSettle();
    await tester.enterText(quantity, '3');
    await tester.tap(find.text('开始同步'));
    await tester.pumpAndSettle();
    expect(find.text('重新连接抖音'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(lastSuccess, findsOneWidget);
    expect(find.text('请先重新连接抖音账号。'), findsOneWidget);
    expect(find.text('测试作品'), findsWidgets);
    await tester.tap(find.widgetWithText(OutlinedButton, '重新授权'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<RadioGroup<bool>>(find.byType(RadioGroup<bool>))
            .groupValue,
        false);
    expect(tester.widget<TextField>(quantity).controller?.text, '3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('另一位博主蒸馏期间同步作品，任务排队后自动开始', (tester) async {
    SharedPreferences.setMockInitialValues({
      'creator_roundtable.model.v1': '["test","gpt-test-a"]',
    });
    final store = _QueuedSyncStore();
    final credentials = _QueuedSyncCredentials();
    final adapter = _WaitingSyncAdapter();
    await open(tester, const Size(1200, 750),
        store: store,
        configureModels: true,
        credentials: credentials,
        douyinSession: 'fixture',
        adapter: () => adapter);
    await _openCreatorDrawer(tester);
    await tester.tap(find.text('正在蒸馏的博主'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续生成'));
    await tester.pumpAndSettle();
    expect(credentials.requested, 1);
    await tester.tap(find.text('返回博主列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('后台同步博主'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始同步'));
    await tester.pumpAndSettle();
    adapter.request.complete({
      'author': {'id': 'author'},
      'posts': [
        {'id': '1234567890123456789', 'published_at': 1},
      ],
      'next_cursor': null,
    });
    await tester.pumpAndSettle();

    expect(store.task?['status'], 'queued');
    expect(jsonDecode(store.task!['model_snapshot'] as String),
        {'provider_id': 'test', 'model_id': 'gpt-test-a'});
    expect(find.textContaining('已排队'), findsWidgets);
    expect(credentials.requested, 1);
    await tester.tap(find.text('完成').hitTestable());
    await tester.pumpAndSettle();
    credentials.active.complete(null);
    await tester.pumpAndSettle();

    expect(credentials.requested, 2);
    expect(store.task?['status'], 'failed');
    expect(find.text('重试知识更新'), findsOneWidget);
  });

  testWidgets('同步期间可以切换旧作品和返回圆桌，取消后释放原任务', (tester) async {
    final store = _RunningSyncStore();
    final adapter = _WaitingSyncAdapter();
    await open(tester, const Size(1200, 750),
        store: store, douyinSession: 'fixture', adapter: () => adapter);
    await _openCreatorDrawer(tester);
    await tester.tap(find.text('后台同步博主'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '立即同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始同步'));
    await tester.pumpAndSettle();

    final progress = find.byKey(const ValueKey('roundtable-sync-progress'));
    Finder status(String text) =>
        find.descendant(of: progress, matching: find.textContaining(text));
    expect(find.text('同步范围'), findsNothing);
    expect(status('第 1 页 ·'), findsOneWidget);
    expect(status('已核对 0 页 · 已读取 0 条作品'), findsOneWidget);
    adapter.request.complete({
      'author': {'id': 'author'},
      'posts': [
        {'id': '100000000001', 'published_at': 1},
        {'id': '100000000001', 'published_at': 1},
      ],
      'next_cursor': 20,
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(status('第 2 页 ·'), findsOneWidget);
    expect(status('已核对 1 页 · 已读取 1 条作品'), findsOneWidget);

    await tester.tap(find.text('后台继续'));
    await tester.pumpAndSettle();
    expect(progress, findsNothing);
    expect(find.text('查看进度'), findsOneWidget);
    await tester.tap(find.text('第二条作品'));
    await tester.pumpAndSettle();
    expect(find.text('第二条作品的逐字稿'), findsOneWidget);
    await tester.tap(find.text('返回博主列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('后台同步博主'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看进度'));
    await tester.pumpAndSettle();
    expect(status('第 2 页 ·'), findsOneWidget);
    expect(status('已核对 1 页 · 已读取 1 条作品'), findsOneWidget);
    expect(adapter.reads, 2);
    expect(store.started, 1);

    await tester.tap(find.text('取消同步'));
    await tester.pumpAndSettle();
    expect(status('同步已取消，可重新打开后继续。'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '关闭'));
    await tester.pumpAndSettle();
    expect(store.failure, ('active-job', '同步已取消，可重新打开后继续。'));
    expect(find.widgetWithText(OutlinedButton, '重试'), findsOneWidget);
    expect(find.text('取消同步'), findsNothing);
  });

  testWidgets('保存作品后仍可打开同一次同步查看媒体阶段', (tester) async {
    final store = _RunningSyncStore();
    final adapter = _WaitingSyncAdapter();
    final mediaDirectory = Completer<Directory>();
    await open(tester, const Size(1200, 750),
        store: store,
        douyinSession: 'fixture',
        adapter: () => adapter,
        mediaDirectory: () => mediaDirectory.future);
    await _openCreatorDrawer(tester);
    await tester.tap(find.text('后台同步博主'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始同步'));
    await tester.pumpAndSettle();
    adapter.request.complete({
      'author': {'id': 'author'},
      'posts': [
        {
          'id': '100000000001',
          'published_at': 1,
          'media_url': 'https://example.invalid/fixture.mp4',
        },
      ],
      'next_cursor': null,
    });
    await tester.pumpAndSettle();
    final progress = find.byKey(const ValueKey('roundtable-sync-progress'));
    Finder inProgress(String text) =>
        find.descendant(of: progress, matching: find.text(text));
    expect(inProgress('正在下载作品媒体…'), findsOneWidget);
    expect(inProgress('已同步 1 条新作品。'), findsOneWidget);
    expect(inProgress('取消同步'), findsNothing);

    await tester.tap(inProgress('后台继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看进度'));
    await tester.pumpAndSettle();
    expect(inProgress('正在下载作品媒体…'), findsOneWidget);
    expect(store.started, 1);

    mediaDirectory.completeError(StateError('fixture unavailable'));
    await tester.pumpAndSettle();
    expect(inProgress('媒体下载未完成，可再次同步。'), findsOneWidget);
    expect(inProgress('完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同步弹窗恢复已读页和原范围，更换范围显示新任务', (tester) async {
    await open(tester, const Size(1200, 750), store: _PendingSyncStore());
    await _openCreatorDrawer(tester);
    await tester.tap(find.text('断点博主'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '立即同步'));
    await tester.pumpAndSettle();
    final quantity = find.byKey(const ValueKey('roundtable-sync-quantity'));
    expect(tester.widget<TextField>(quantity).controller?.text, '7');
    expect(find.text('继续上次同步'), findsOneWidget);
    expect(find.textContaining('已读取 1 页'), findsOneWidget);
    await tester.enterText(quantity, '8');
    await tester.pumpAndSettle();
    expect(find.text('开始同步'), findsOneWidget);
    expect(find.text('继续上次同步'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长逐字稿在卡片内滚动并可读到最后一行', (tester) async {
    await open(tester, const Size(1240, 900), creators: [
      {'id': 'a', 'name': '逐字稿验收博主'},
    ], works: [
      {
        'id': 'long',
        'title': '长视频',
        'transcript': '逐字稿',
        'metadata': jsonEncode({
          'transcript_cues': [
            for (var i = 0; i < 30; i++)
              {'start_ms': i * 1000, 'text': '稿件行 ${i + 1}'},
          ],
        }),
        'source_url': 'https://www.douyin.com/video/1234567890123456789',
      },
    ]);
    await _openCreatorDrawer(tester);
    await tester.tap(find.text('逐字稿验收博主'));
    await tester.pumpAndSettle();
    final transcript = find.byKey(const ValueKey('roundtable-transcript-long'));
    expect(tester.getSize(transcript).height, lessThanOrEqualTo(360));
    expect(find.text('稿件行 1').hitTestable(), findsOneWidget);
    expect(find.text('稿件行 30').hitTestable(), findsNothing);
    final titlePosition = tester.getTopLeft(find.text('长视频').last);
    await tester.drag(transcript, const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(find.text('稿件行 30').hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(find.text('长视频').last), titlePosition);
  });

  testWidgets('作品内展开音频，文件缺失时可切回同一逐字稿', (tester) async {
    await open(tester, const Size(1240, 850),
        creators: [
          {'id': 'a', 'name': '音频博主', 'work_count': 1},
        ],
        works: [
          {
            'id': 'audio',
            'title': '音频验收作品',
            'transcript': '原稿仍可读取。',
            'metadata': jsonEncode({
              'local_media_file': '00000000-0000-0000-0000-000000000000.m4a',
            }),
            'source_url': 'https://www.douyin.com/video/1234567890123456789',
          },
        ],
        mediaDirectory: () async => throw StateError('本机目录不可读'));
    await _openCreatorDrawer(tester);
    await tester.tap(find.text('音频博主'));
    await tester.pumpAndSettle();
    final tabs = find.byKey(const ValueKey('roundtable-work-view'));
    expect(tester.widget<UiSegmentedTabs<bool>>(tabs).current, isFalse);
    expect(find.text('原稿仍可读取。'), findsOneWidget);
    await tester.tap(find.text('播放音频'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('本机媒体不可播放，可打开原作品或查看逐字稿。'), findsOneWidget);
    expect(find.text('打开原地址'), findsOneWidget);
    expect(find.text('原稿仍可读取。'), findsNothing);
    expect(tester.widget<UiSegmentedTabs<bool>>(tabs).current, isTrue);
    await tester.tap(find.descendant(of: tabs, matching: find.text('逐字稿')));
    await tester.pumpAndSettle();
    expect(tester.widget<UiSegmentedTabs<bool>>(tabs).current, isFalse);
    expect(find.text('原稿仍可读取。'), findsOneWidget);
    expect(find.text('音频验收作品'), findsWidgets);
  });

  testWidgets('图文要点卡和正文沿用原段落序号，窄窗口重排', (tester) async {
    const body = '试点前的三个信号\n\n最近一次：问清具体时间。\n'
        '已有成本：查发票。\n谁来付款：核实预算负责人。\n保留原始访谈记录。';
    await open(tester, const Size(1240, 900), creators: [
      {'id': 'a', 'name': '图文博主', 'work_count': 1}
    ], works: [
      {
        'id': 'article',
        'title': body,
        'likes': 1,
        'comments': 2,
        'collects': 3,
        'metadata': jsonEncode({'article_body': body}),
        'source_url': 'https://www.douyin.com/note/1234567890123456789',
      }
    ]);
    await _openCreatorDrawer(tester);
    await tester.tap(find.text('图文博主'));
    await tester.pumpAndSettle();
    expect(find.text('抖音图文'), findsOneWidget);
    expect(find.text('试点前的三个信号'), findsOneWidget);
    expect(find.text('正文第 2 段'), findsOneWidget);
    expect(find.text('正文第 4 段'), findsOneWidget);
    expect(find.text('保留原始访谈记录。'), findsOneWidget);
    expect(tester.getTopLeft(find.text('已有成本')).dy,
        tester.getTopLeft(find.text('最近一次')).dy);
    await tester.binding.setSurfaceSize(const Size(780, 900));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('已有成本')).dy,
        greaterThan(tester.getTopLeft(find.text('最近一次')).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口可展开博主侧栏而且没有溢出', (tester) async {
    await open(tester, const Size(580, 650));
    await _openCreatorDrawer(tester);
    expect(find.text('+ 添加博主'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('复核前继续资产使用原模型、原名称和版本证据', (tester) async {
    final store = _AssetResumeStore();
    final directory = Directory.systemTemp.createTempSync('roundtable-resume-');
    addTearDown(() => directory.deleteSync(recursive: true));
    var requests = 0;
    var reviews = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        creatorAssetDirectoryProvider.overrideWithValue(() async => directory),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: CreatorAssetDialog(
            kind: CreatorAssetKind.web,
            experts: const [
              {'id': 'author', 'name': '当前名称', 'version': 2}
            ],
            store: store,
            canGenerate: true,
            resolveModel: (_) => throw StateError('不应使用当前模型'),
            resolveOriginalModel: (saved, _) async {
              expect(saved,
                  {'provider_id': 'original', 'model_id': 'model-original'});
              return (
                snapshot: saved,
                complete: (_, payload) async {
                  requests++;
                  final data = payload as Map;
                  expect((data['evidence'] as Map).keys, ['old-evidence']);
                  if (data.containsKey('sections')) {
                    if (++reviews == 1) {
                      throw const CreatorWorkflowException('复核服务暂时不可用');
                    }
                    return '{"approved":true}';
                  }
                  expect(data['title'], '原任务名称');
                  return jsonEncode({
                    'sections': [
                      for (final title in CreatorAssetKind.web.sections)
                        {
                          'heading': title,
                          'text': '冻结原文',
                          'evidence_ids': ['old-evidence']
                        },
                    ]
                  });
                },
              );
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('继续上次生成'));
    await tester.tap(find.text('继续上次生成'));
    await tester.pumpAndSettle();
    expect(store.failure, '复核服务暂时不可用');
    expect(store.candidate, isNotNull);
    expect(store.draft, isNull);
    expect(requests, 2);
    expect(reviews, 1);
    store.failure = null;
    await tester.tap(find.text('重试'));
    for (var attempt = 0;
        attempt < 50 && store.publishedFile == null && store.failure == null;
        attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(store.failure, isNull);
    final fileName = store.publishedFile;
    await tester.pumpAndSettle();
    expect(store.resumed, isTrue);
    expect(requests, 3);
    expect(reviews, 2);
    expect((store.draft!['sources'] as Map).keys, ['old-evidence']);
    expect(fileName, 'asset-original.html');
    final contents = File('${directory.path}/$fileName').readAsStringSync();
    expect(contents, contains('原任务名称'));
    expect(contents, contains('冻结原文'));
  });

  testWidgets('生成失败后可恢复原资产名称与来源选择', (tester) async {
    final reply = Completer<RoundtableModel>();
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: CreatorAssetDialog(
            kind: CreatorAssetKind.skill,
            experts: const [
              {'id': 'a', 'name': '预算博主', 'version': 1},
              {'id': 'b', 'name': '项目博主', 'version': 2},
            ],
            store: _RoundtableStore(const [], null, const []),
            canGenerate: true,
            resolveModel: (_) => reply.future,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final title = find.byKey(const ValueKey('roundtable-asset-title'));
    await tester.enterText(title, '试点手册');
    await tester.tap(find.widgetWithText(CheckboxListTile, '项目博主'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('生成'));
    await tester.pump();
    expect(find.text('正在生成技能'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(title, findsNothing);

    reply.completeError(const CreatorWorkflowException('所选模型不可用。'));
    await tester.pumpAndSettle();
    expect(find.text('生成失败'), findsOneWidget);
    expect(find.text('所选模型不可用。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('修改参数'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(title).controller?.text, '试点手册');
    expect(find.text('已选 1 / 2 位'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.widgetWithText(CheckboxListTile, '项目博主'))
            .value,
        false);
  });

  testWidgets('三种完整资产列表分别显示类型、总数和操作', (tester) async {
    await open(tester, const Size(1400, 960), assets: [
      {'kind': 'ebook', 'title': '电子书甲', 'created': 1000},
      {'kind': 'web', 'title': '网页甲', 'created': 1000},
      {'kind': 'skill', 'title': '技能甲', 'created': 1000},
    ]);
    await tester.tap(find.text('知识资产'));
    await tester.pumpAndSettle();
    for (final (index, kind) in ['电子书', '网页', '技能'].indexed) {
      final more = find.text('查看更多').at(index);
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      final dialog = find.byType(Dialog);
      expect(find.descendant(of: dialog, matching: find.text('$kind资产')),
          findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('1 项$kind')),
          findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('$kind甲')),
          findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.byTooltip('打开')),
          findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.byTooltip('下载')),
          findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('900×859 窄高窗口保持圆桌横向比例和模型入口', (tester) async {
    // 社区版 900 宽窗口扣除 180 的应用导航。
    await open(tester, const Size(720, 859));
    final scene = find.byKey(const ValueKey('roundtable-scene'));
    final size = tester.getSize(scene);
    expect(size.aspectRatio, greaterThanOrEqualTo(1.37));
    expect(tester.widget<Image>(scene).fit, BoxFit.cover);
    expect(find.byTooltip('展开博主列表'), findsOneWidget);
    expect(tester.getCenter(_creatorDrawerButton).dx,
        greaterThan(tester.getRect(scene).right));
    final configure = find.byKey(const ValueKey('roundtable-configure-model'));
    expect(configure, findsOneWidget);
    expect(tester.getTopLeft(configure).dy,
        greaterThan(tester.getBottomLeft(find.text('博主圆桌')).dy));
    if (Platform.isMacOS) {
      expect(tester.getTopLeft(configure).dy, greaterThan(30));
    }
    expect(find.text('向圆桌专家提问…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('收起后保留头像和快捷操作，打开右抽屉不挤压圆桌', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 805);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, const Size(900, 805), creators: [
      {'id': 'a', 'name': '测试博主', 'work_count': 1},
    ]);
    final scene = find.byKey(const ValueKey('roundtable-scene'));
    final rail = find.byKey(const ValueKey('roundtable-compact-creators'));
    final sceneRect = tester.getRect(scene);
    expect(sceneRect.width, greaterThan(800));
    expect(tester.getSize(rail).width, 52);
    expect(tester.getRect(rail).left, greaterThan(sceneRect.right));
    expect(find.byTooltip('添加博主'), findsOneWidget);
    expect(find.byTooltip('配置渠道'), findsOneWidget);
    final expandButton = tester.widget<IconButton>(_creatorDrawerButton);
    expect((expandButton.icon as Icon).icon, CupertinoIcons.sidebar_left);
    expect(expandButton.style?.backgroundColor?.resolve({}), isNull);
    final addButton = find.byWidgetPredicate(
        (item) => item is IconButton && item.tooltip == '添加博主');
    final addFace = tester.widget<IconButton>(addButton).icon as Ink;
    expect((addFace.child as Icon).color,
        Theme.of(tester.element(addButton)).colorScheme.onPrimary);
    expect(_creatorDrawer, findsNothing);

    await _openCreatorDrawer(tester);
    expect(tester.getRect(scene), sceneRect);
    expect(tester.getRect(_creatorDrawer).right, 900);
    expect(tester.getSize(_creatorDrawer).width, 360);
    expect(find.text('测试博主').hitTestable(), findsOneWidget);
    await tester.tapAt(const Offset(40, 400));
    await tester.pumpAndSettle();
    expect(_creatorDrawer, findsNothing);
    expect(tester.getRect(scene), sceneRect);
    await tester
        .tap(find.byKey(const ValueKey('roundtable-compact-creator-a')));
    await tester.pumpAndSettle();
    expect(find.text('返回博主列表'), findsOneWidget);
    expect(find.text('测试作品'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('悬浮聊天按圆桌居中并隐藏重复提问栏', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, const Size(1280, 800),
        store: _RoundtableDraftStore(), sidebarWidth: 180);
    final stage = find.byKey(const ValueKey('roundtable-scene'));
    final composer = find.byKey(const ValueKey('roundtable-stage-composer'));
    final stageInput = find.byKey(const ValueKey('roundtable-stage-question'));
    final stageExperts = find.byKey(const ValueKey('roundtable-stage-experts'));
    Finder standardButton(String tooltip) => find.byWidgetPredicate(
        (widget) => widget is UiIconButton && widget.tooltip == tooltip);

    void expectStandardButton(Finder button, IconData icon) {
      expect(tester.getSize(button), const Size.square(32));
      final widget = tester.widget<UiIconButton>(button);
      expect(widget.iconSize, 16);
      expect(widget.icon, icon);
    }

    final stageExpand = standardButton('全屏展开对话');
    expectStandardButton(stageExpand, CupertinoIcons.fullscreen);

    void expectComposerAlignment(Finder input, List<Finder> controls) {
      final outline = find
          .descendant(of: input, matching: find.byType(InputDecorator))
          .first;
      final editor =
          find.descendant(of: input, matching: find.byType(EditableText));
      final fieldRect = tester.getRect(outline);
      final decoration = tester.widget<InputDecorator>(outline).decoration;
      final fieldBorder = decoration.enabledBorder! as OutlineInputBorder;
      final expertButton = find.descendant(
          of: controls.first, matching: find.byType(FilledButton));
      final expertStyle = tester.widget<FilledButton>(expertButton).style!;
      final expertShape =
          expertStyle.shape!.resolve({})! as RoundedRectangleBorder;
      expect(fieldBorder.borderRadius, BorderRadius.circular(10));
      expect(expertShape.borderRadius, fieldBorder.borderRadius);
      expect(expertStyle.side!.resolve({}), fieldBorder.borderSide);
      final inOrder = [controls.first, input, ...controls.skip(1)];
      for (var i = 1; i < inOrder.length; i++) {
        expect(
          tester.getRect(inOrder[i]).left -
              tester.getRect(inOrder[i - 1]).right,
          closeTo(8, .01),
        );
      }
      expect(fieldRect.height, 40);
      expect(tester.getCenter(editor).dy, closeTo(fieldRect.center.dy, 1));
      for (final control in controls) {
        final actual = tester.getRect(control);
        expect(actual.center.dy, fieldRect.center.dy);
      }
    }

    expectComposerAlignment(stageInput, [stageExperts, stageExpand]);
    final stageRect = tester.getRect(stageInput);
    await tester.tapAt(Offset(stageRect.center.dx, stageRect.top + 3));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('roundtable-chat-panel'));
    expect(tester.getCenter(panel).dx, closeTo(tester.getCenter(stage).dx, 1));
    expect(tester.getCenter(panel).dx, closeTo(699, 1));
    expect(tester.getSize(panel).width, greaterThan(800));
    expect(tester.getSize(panel).height, greaterThan(400));
    expect(
        tester.getRect(panel).bottom, lessThan(tester.getRect(stage).bottom));
    final send = find.byWidgetPredicate(
        (item) => item is IconButton && item.tooltip == '发送');
    final expand = standardButton('放大对话');
    expectStandardButton(expand, CupertinoIcons.fullscreen);
    expectStandardButton(standardButton('关闭'), CupertinoIcons.xmark);
    expectStandardButton(standardButton('开启新对话'), CupertinoIcons.pencil);
    final select = find.byKey(const ValueKey('roundtable-chat-experts'));
    expect(find.descendant(of: select, matching: find.text('1 位专家')),
        findsOneWidget);
    expect(find.descendant(of: select, matching: find.byType(CircleAvatar)),
        findsOneWidget);
    final selectButton =
        find.descendant(of: select, matching: find.byType(FilledButton));
    final selectStyle = tester.widget<FilledButton>(selectButton).style!;
    final selectColors = Theme.of(tester.element(select)).colorScheme;
    expect(selectStyle.backgroundColor!.resolve({}),
        selectColors.surfaceContainerLowest);
    expect(selectStyle.foregroundColor!.resolve({}),
        selectColors.onSurfaceVariant);
    final input = find.byKey(const ValueKey('roundtable-chat-question'));
    final disabledFace = tester.widget<IconButton>(send).icon as Ink;
    expect((disabledFace.child as Icon).icon, Icons.send_rounded);
    expect(
        tester.widget<UiInputField>(input).focusNode?.hasPrimaryFocus, isTrue);
    tester.testTextInput.enterText('验收输入');
    await tester.pumpAndSettle();
    final activeFace = tester.widget<IconButton>(send).icon as Ink;
    final scheme = Theme.of(tester.element(send)).colorScheme;
    final sendFace = activeFace.decoration as BoxDecoration;
    expect(sendFace.color, scheme.primary);
    expect(sendFace.shape, BoxShape.circle);
    expect((activeFace.child as Icon).color, scheme.onPrimary);
    expect(tester.getSize(send), const Size.square(40));
    expectComposerAlignment(input, [select, send, expand]);
    expect(composer, findsNothing);
    await tester.binding.setSurfaceSize(const Size(1080, 810));
    await tester.pumpAndSettle();
    final stageBounds = tester.getRect(stage);
    final railBounds =
        tester.getRect(find.byKey(const ValueKey('roundtable-compact-creators')));
    expect(stageBounds.top, greaterThan(railBounds.top + 30));
    expect(stageBounds.center.dy, closeTo(railBounds.center.dy, 1));
    expect(tester.getCenter(panel).dx, closeTo(stageBounds.center.dx, 1));
    expect(tester.getRect(panel).bottom, closeTo(stageBounds.bottom - 12, 1));
    final expandTarget =
        find.descendant(of: expand, matching: find.byType(GestureDetector));
    Focus.of(tester.element(expandTarget)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expectStandardButton(
        standardButton('退出全屏对话'), CupertinoIcons.fullscreen_exit);
    expectStandardButton(standardButton('收起对话'), CupertinoIcons.chevron_down);
    expect(
        tester.widget<UiInputField>(input).focusNode?.hasPrimaryFocus, isTrue);
    expectComposerAlignment(input, [select, send]);
    await tester.tap(find.byTooltip('退出全屏对话'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<UiInputField>(input).focusNode?.hasPrimaryFocus, isTrue);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(composer, findsOneWidget);
  });

  testWidgets('从输入栏直接全屏，收起再打开保留草稿', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, const Size(1280, 800), store: _RoundtableDraftStore());
    final question = find.byKey(const ValueKey('roundtable-chat-question'));
    await tester.tap(find.byTooltip('全屏展开对话'));
    await tester.pumpAndSettle();
    expect(find.text('对话列表'), findsOneWidget);
    expect(tester.widget<UiInputField>(question).enabled, isTrue);
    expect(tester.widget<UiInputField>(question).focusNode?.hasPrimaryFocus,
        isTrue);
    tester.testTextInput.enterText('保留这一段未发送的问题');
    await tester.pump();
    expect(
        tester.widget<UiInputField>(question).controller?.text, '保留这一段未发送的问题');
    await tester.tap(find.byTooltip('收起对话'));
    await tester.pumpAndSettle();
    expect(find.byType(CreatorRoundtableChat), findsNothing);
    await tester.tap(find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.hintText == '向圆桌专家提问…'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('放大对话'), findsOneWidget);
    expect(tester.widget<UiInputField>(question).focusNode?.hasPrimaryFocus,
        isTrue);
    expect(
        tester.widget<UiInputField>(question).controller?.text, '保留这一段未发送的问题');
  });

  for (final reducedMotion in [false, true]) {
    testWidgets('对话过渡与系统减少动态效果匹配 $reducedMotion', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: reducedMotion);
      addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await open(tester, const Size(1280, 800), store: _RoundtableDraftStore());
      await tester.tap(find.byTooltip('全屏展开对话'));
      await tester.pumpAndSettle();
      final chat = find.byType(CreatorRoundtableChat);
      final expected =
          reducedMotion ? Duration.zero : const Duration(milliseconds: 260);
      final route = ModalRoute.of(tester.element(chat))!;
      expect(route.transitionDuration, expected);
      expect(route.reverseTransitionDuration, expected);
      final content = find.byKey(const ValueKey('roundtable-chat-panel'));
      expect(tester.widget<AnimatedContainer>(content).duration, expected);
    });
  }

  testWidgets('席位名牌切换下一轮专家，选择面板立即回显，新对话默认全选', (tester) async {
    SharedPreferences.setMockInitialValues({
      'creator_roundtable.display_seats.v1': ['a', 'b'],
    });
    await open(
      tester,
      const Size(1280, 800),
      store: _RoundtableDraftStore(const [
        {'id': 'a', 'name': '第一位博主'},
        {'id': 'b', 'name': '第二位博主'},
      ]),
    );
    final firstSeat = find.descendant(
      of: find.byKey(const ValueKey('roundtable-seat-0')),
      matching: find.text('第一位博主'),
    );
    await tester.tap(firstSeat);
    await tester.pumpAndSettle();
    expect(find.text('展示席位  2 / 8'), findsOneWidget);
    final picker = find.byKey(const ValueKey('roundtable-stage-experts'));
    expect(find.descendant(of: picker, matching: find.text('1 位专家')),
        findsOneWidget);
    expect(find.descendant(of: picker, matching: find.byType(CircleAvatar)),
        findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(580, 650));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    final selectAll = find.widgetWithText(TextButton, '全选');
    final clear = find.widgetWithText(TextButton, '清空');
    final header = find.widgetWithText(UiSheetHeader, '选择专家');
    final close =
        find.descendant(of: header, matching: find.byType(UiIconButton));
    final allRect = tester.getRect(selectAll);
    final clearRect = tester.getRect(clear);
    final closeRect = tester.getRect(close);
    expect(allRect.height, 28);
    expect(clearRect.size, allRect.size);
    expect(closeRect.size, const Size.square(32));
    expect(tester.widget<UiIconButton>(close).icon, CupertinoIcons.xmark);
    expect(tester.widget<UiIconButton>(close).tooltip, '关闭');
    expect(clearRect.center.dy, allRect.center.dy);
    expect(closeRect.center.dy, allRect.center.dy);
    expect(clearRect.left - allRect.right, closeTo(4, .01));
    expect(closeRect.left - clearRect.right, closeTo(8, .01));
    final firstExpert = find.widgetWithText(ListTile, '第一位博主');
    expect(tester.widget<ListTile>(firstExpert).selected, isFalse);
    final secondExpert = find.widgetWithText(ListTile, '第二位博主');
    expect(tester.widget<ListTile>(secondExpert).selected, isTrue);
    expect(
        find.byKey(const ValueKey('roundtable-chat-question')), findsNothing);
    expect(tester.widget<ListTile>(firstExpert).leading, isA<CircleAvatar>());
    final selectedRow = tester.widget<ListTile>(secondExpert);
    expect(selectedRow.selectedTileColor, isNotNull);
    final check = find.descendant(
        of: secondExpert, matching: find.byIcon(Icons.check_rounded));
    expect(tester.getSize(check), const Size.square(18));
    expect(
        find.descendant(
            of: firstExpert, matching: find.byIcon(Icons.check_rounded)),
        findsNothing);
    await tester.tap(firstExpert);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(firstExpert).selected, isTrue);
    expect(tester.widget<TextButton>(selectAll).onPressed, isNull);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(secondExpert).selected, isFalse);
    expect(tester.widget<TextButton>(clear).onPressed, isNull);
    await tester.tap(selectAll);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(secondExpert).selected, isTrue);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.descendant(of: picker, matching: find.text('选择专家')),
        findsOneWidget);
    await tester.tap(find.byTooltip('全屏展开对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开启新对话'));
    await tester.pumpAndSettle();
    final chatPicker = find.byKey(const ValueKey('roundtable-chat-experts'));
    expect(find.descendant(of: chatPicker, matching: find.text('2 位专家')),
        findsOneWidget);
    expect(find.descendant(of: chatPicker, matching: find.byType(CircleAvatar)),
        findsNWidgets(2));
    await tester.tap(chatPicker);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(firstExpert).selected, isTrue);
    expect(tester.widget<ListTile>(secondExpert).selected, isTrue);
    await tester.tap(find.byTooltip('收起对话'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: picker, matching: find.text('2 位专家')),
        findsOneWidget);
    expect(find.text('展示席位  2 / 8'), findsOneWidget);
  });

  testWidgets('展示席位支持取消、保存并在重新打开后恢复', (tester) async {
    const creators = [
      {'id': 'a', 'name': '席位测试博主', 'work_count': 1},
    ];
    await open(tester, const Size(880, 760), creators: creators);
    final settings = find.byKey(const ValueKey('roundtable-seat-settings'));
    Future<void> select() async {
      await tester.tap(settings);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, '在圆桌展示'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已展示 1 / 8 席'), findsOneWidget);
    }

    await select();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('展示席位  0 / 8'), findsOneWidget);
    await select();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('展示席位  1 / 8'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await open(tester, const Size(880, 760), creators: creators);
    expect(find.text('展示席位  1 / 8'), findsOneWidget);
    expect(find.text('席位测试博主'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧席位缺图时自动补生成，重绘或重开复用已保存形象', (tester) async {
    SharedPreferences.setMockInitialValues({
      'creator_roundtable.display_seats.v1': ['a'],
    });
    final root =
        Directory.systemTemp.createTempSync('roundtable-seat-backfill-');
    addTearDown(() => root.delete(recursive: true));
    final png = File('assets/images/creator_roundtable_douyin.png')
        .copySync('${root.path}/portrait.png');
    final portraits = _RoundtablePortraitFixture(png);
    Future<void> openPage() => open(
          tester,
          const Size(1024, 768),
          configureModels: true,
          portraits: portraits,
          mediaDirectory: () async => root,
          creators: const [
            {
              'id': 'a',
              'name': '旧席位',
              'avatar_url': 'https://p3.douyinpic.com/creator.png',
            }
          ],
        );
    await openPage();
    expect(portraits.requests, 1);
    expect(find.text('生成席位形象'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(portraits.requests, 1);
    portraits.response.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('generated-seat-0')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await openPage();
    expect(find.byKey(const ValueKey('generated-seat-0')), findsOneWidget);
    expect(portraits.requests, 1);
  });

  testWidgets('从圆桌发起生成，保存后仅对应博主入座，重开后保留形象', (tester) async {
    const creators = [
      {
        'id': 'a',
        'name': '席位测试博主',
        'avatar_url': 'https://p3.douyinpic.com/creator.png',
      },
      {'id': 'b', 'name': '暂无头像的博主'},
    ];
    final root = Directory.systemTemp.createTempSync('roundtable-portrait-ui-');
    addTearDown(() => root.delete(recursive: true));
    final png = File('assets/images/creator_roundtable_douyin.png')
        .copySync('${root.path}/portrait.png');
    final portraits = _RoundtablePortraitFixture(png);
    Future<void> openPage() => open(
          tester,
          const Size(1024, 768),
          configureModels: true,
          creators: creators,
          portraits: portraits,
          mediaDirectory: () async => root,
        );
    await openPage();
    expect(find.text('人物入座'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('roundtable-seat-settings')));
    await tester.pumpAndSettle();
    expect(find.text('生成形象'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, '在圆桌展示').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '在圆桌展示'));
    await tester.pumpAndSettle();
    expect(find.text('暂无公开头像'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '生成形象'));
    await tester.pumpAndSettle();
    expect(find.text('生成席位形象'), findsOneWidget);
    expect(find.text('席位测试博主 · 第 1 席'), findsOneWidget);
    expect(find.textContaining('将公开头像发送给所选图片服务'), findsOneWidget);
    final imageModelSelect = find.byType(UiSelect<int>);
    final select = tester.widget<UiSelect<int>>(imageModelSelect);
    expect(select.options.map((option) => option.label), ['测试图片编辑', '另一张图模型']);
    expect(select.value, 0);
    await tester.tap(find.widgetWithText(FilledButton, '生成形象'));
    await tester.pumpAndSettle();
    expect(find.text('生成中…'), findsOneWidget);
    portraits.response.complete();
    await tester.pumpAndSettle();
    final regenerate = find.widgetWithText(TextButton, '重新生成');
    expect(regenerate, findsOneWidget);
    await tester.tap(regenerate);
    await tester.pumpAndSettle();
    await tester.tap(imageModelSelect);
    await tester.pumpAndSettle();
    await tester.tap(find.text('另一张图模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '生成形象'));
    await tester.pumpAndSettle();
    expect(portraits.requestedModels, ['gpt-image-1', 'gpt-image-1.5']);
    await tester.tap(find.widgetWithText(FilledButton, '完成'));
    await tester.pumpAndSettle();

    void expectSeatedPortrait() {
      expect(find.text('展示席位  2 / 8'), findsOneWidget);
      final image =
          tester.widget<Image>(find.byKey(const ValueKey('generated-seat-0')));
      expect((image.image as FileImage).file.path, png.path);
      expect(find.byKey(const ValueKey('generated-seat-1')), findsNothing);
    }

    expectSeatedPortrait();
    await tester.pumpWidget(const SizedBox.shrink());
    await openPage();
    expectSeatedPortrait();
  });

  testWidgets('移除前面的博主不会移动其他席位', (tester) async {
    const creators = [
      {'id': 'a', 'name': '第一席', 'work_count': 1},
      {'id': 'b', 'name': '第二席', 'work_count': 1},
      {'id': 'c', 'name': '新博主', 'work_count': 1},
    ];
    const size = Size(880, 760);
    await open(tester, size, creators: creators);
    final settings = find.byKey(const ValueKey('roundtable-seat-settings'));
    final first = find.byKey(const ValueKey('roundtable-seat-0'));
    final second = find.byKey(const ValueKey('roundtable-seat-1'));

    Future<void> edit(List<String> names) async {
      await tester.tap(settings);
      await tester.pumpAndSettle();
      for (final name in names) {
        await tester.tap(find.descendant(
          of: find.widgetWithText(ListTile, name).last,
          matching: find.byType(OutlinedButton),
        ));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
    }

    await edit(['第一席', '第二席']);
    final fixedPosition = tester
        .getCenter(find.descendant(of: second, matching: find.text('第二席')));
    await edit(['第一席']);
    expect(first, findsNothing);
    expect(
        tester
            .getCenter(find.descendant(of: second, matching: find.text('第二席'))),
        fixedPosition);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await open(tester, size, creators: creators);
    expect(first, findsNothing);
    expect(find.descendant(of: second, matching: find.text('第二席')),
        findsOneWidget);
    await edit(['新博主']);
    expect(
        find.descendant(of: first, matching: find.text('新博主')), findsOneWidget);
  });
}
