import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
// These desktop plugins are supplied by zhiban_client.
// ignore: depend_on_referenced_packages
import 'package:file_selector_macos/file_selector_macos.dart';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
// The native preview plugin is supplied by the shared client.
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/layout/main_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The desktop plugin is supplied by zhiban_client.
// ignore: depend_on_referenced_packages
import 'package:window_manager/window_manager.dart';
import 'package:zhiban_client/layout/widgets/sidebar_nav_item.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_asset_dialog.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_roundtable_page.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_asset_workflow.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_graph_topics.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_graph_precedence.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/douyin_creator_service.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_app.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_controller.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_model_client.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/window/window_controller.dart';

import 'creator_roundtable_capture.dart';

/// The login page renders its heading before the provider returns the QR.
Future<bool> _containsScannableQr(File screenshot) async {
  final result = await Process.run('/usr/bin/swift', [
    '-e',
    '''
import Darwin
import Foundation
import Vision
let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
try VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    .perform([request])
exit((request.results ?? []).isEmpty ? 1 : 0)
''',
    screenshot.path,
  ]);
  if (result.exitCode == 0) return true;
  if (result.exitCode == 1 && (result.stderr as String).isEmpty) return false;
  throw StateError('无法使用 macOS Vision 核对扫码截图。');
}

class _RoundtableLiveBinding extends WidgetsFlutterBinding
    with TestDefaultBinaryMessengerBinding {}

class _GraphExportFileSelector extends FileSelectorMacOS {
  _GraphExportFileSelector(this.directory);

  final String directory;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) =>
      super.getSaveLocation(
        acceptedTypeGroups: acceptedTypeGroups,
        options: SaveDialogOptions(
          initialDirectory: directory,
          suggestedName: options.suggestedName,
          confirmButtonText: options.confirmButtonText,
          canCreateDirectories: options.canCreateDirectories,
        ),
      );
}

class _SyncKnowledgeFixture extends DouyinCreatorService {
  int reads = 0;

  @override
  Future<Map<String, dynamic>> readAuthorPage({
    required String cookie,
    required String authorId,
    required int cursor,
    int count = 20,
    required void Function(String) onStatus,
  }) async {
    reads++;
    return {
      'author': {'id': authorId, 'name': '圆桌验收博主', 'works': 2},
      'posts': [
        {
          'id': '1234567890123456794',
          'title': '采购预算反馈验收',
          'published_at': 1795478400,
          'article_body': '需要确定采购预算时，先核对已付款发票，再联系有签字权的预算负责人。'
              '请对方在书面确认里写明采购金额和付款日期。如果找不到负责人，暂停发出采购单并补充信息。',
        },
      ],
      'next_cursor': null,
    };
  }
}

class _SyncResumeFixture extends DouyinCreatorService {
  final cursors = <int>[];
  final restored = <String>[];

  @override
  Future<Map<String, dynamic>> readAuthorPage({
    required String cookie,
    required String authorId,
    required int cursor,
    int count = 20,
    required void Function(String) onStatus,
  }) async {
    cursors.add(cursor);
    return {
      'author': {'id': authorId, 'name': '圆桌验收博主', 'works': 2},
      'posts': [
        {'id': '1234567890123456790', 'title': '续传取得的新作品', 'published_at': 2},
      ],
      'next_cursor': null,
    };
  }

  @override
  Future<Map<String, dynamic>> readSyncedWork({
    required String cookie,
    required String authorId,
    required String workId,
    required void Function(String) onStatus,
  }) async {
    restored.add(workId);
    return {'id': workId, 'title': '付费试点验收样本', 'published_at': 1};
  }
}

class _KnowledgeModelProbe extends LocalModelClient {
  _KnowledgeModelProbe({this.precedenceFixture = false});
  final bool precedenceFixture;
  bool failNextGraph = false;
  int otherCalls = 0;

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
    if (precedenceFixture && system.startsWith('你从逐字稿和图片文字')) {
      final source =
          (jsonDecode(messages.single['content']!) as List).single as Map;
      return jsonEncode({
        'methods': [
          for (final (action, stop) in [
            ('核对实际发票', '发票缺失时暂停'),
            ('确认审批人', '没有授权审批人时暂停'),
          ])
            {
              'problem': action,
              'applies_when': '采购正式下单前',
              'limits': stop,
              'steps': [
                {
                  'action': action,
                  'evidence_ids': [source['id']]
                }
              ],
            },
        ],
      });
    }
    if (system.startsWith('你负责知识图谱')) {
      if (failNextGraph) {
        failNextGraph = false;
        throw const LocalModelException('验收注入：图谱暂不可用');
      }
    } else {
      otherCalls++;
    }
    return super.complete(
        provider: provider,
        protocol: protocol,
        model: model,
        apiKey: apiKey,
        system: system,
        messages: messages,
        cancelToken: cancelToken);
  }
}

/// Uses the real configured model but only sends this test's synthetic data.
Future<void> main() async {
  const syncLoginOnly = bool.fromEnvironment('ROUNDTABLE_SYNC_LOGIN_ONLY');
  const knowledgeSync = bool.fromEnvironment('ROUNDTABLE_SYNC_KNOWLEDGE');
  const precedenceOnly = bool.fromEnvironment('ROUNDTABLE_LIVE_PRECEDENCE');
  const realSyncLogin = bool.fromEnvironment('ROUNDTABLE_REAL_SYNC_LOGIN');
  const qrCapture = bool.fromEnvironment('ROUNDTABLE_QR_EMBEDDED_CAPTURE');
  InAppWebViewController? loginView;
  if (realSyncLogin && qrCapture) {
    // ignore: invalid_use_of_visible_for_testing_member
    CreatorRoundtablePage.debugOnLoginPageLoaded =
        (controller) => loginView = controller;
  }
  const disconnectOnly = bool.fromEnvironment('ROUNDTABLE_REAL_DISCONNECT');
  const articleOnly = bool.fromEnvironment('ROUNDTABLE_ARTICLE_ONLY');
  const resumeFixture = bool.fromEnvironment('ROUNDTABLE_SYNC_RESUME_FIXTURE');
  final binding = syncLoginOnly || knowledgeSync
      ? _RoundtableLiveBinding()
      : WidgetsFlutterBinding.ensureInitialized();
  if (resumeFixture) SharedPreferences.setMockInitialValues({});
  if (articleOnly || (realSyncLogin && qrCapture)) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1512, 859));
  } else {
    await WindowController.instance.init(hasToken: true);
  }
  final directory =
      await Directory.systemTemp.createTemp('roundtable-pipeline-ui-');
  final databasePath = '${directory.path}/roundtable.db';
  const readOnlySnapshot =
      String.fromEnvironment('ROUNDTABLE_TEST_GRAPH_SNAPSHOT');
  if (readOnlySnapshot.isNotEmpty) {
    await File(readOnlySnapshot).copy(databasePath);
  }
  var store = await LocalWorkspaceStore.open(path: databasePath);
  const verifyConflict = bool.fromEnvironment('ROUNDTABLE_LIVE_TOPIC_CONFLICT');
  const topicsOnly =
      verifyConflict || bool.fromEnvironment('ROUNDTABLE_LIVE_TOPICS');
  const multi = topicsOnly || bool.fromEnvironment('ROUNDTABLE_LIVE_MULTI');
  const articleTitle = '客户访谈里的三个真实信号';
  const articleBody = '$articleTitle\n最近一次：问清日期、场景和当事人角色。\n'
      '已有成本：核对实际账单、外包支出或人工工时。\n'
      '谁来付款：把日常使用者和预算确认人分别记录。\n'
      '访谈结束后，记录客户接下来的实际行动。';
  final imported = await store.importCreatorWorks(
    {
      'id': realSyncLogin
          ? const String.fromEnvironment('ROUNDTABLE_SYNC_PUBLIC_AUTHOR')
          : 'controlled-author',
      'name': '圆桌验收博主',
      'works': 1,
    },
    [
      {
        'id': '1234567890123456789',
        'title': articleOnly ? articleTitle : '付费试点验收样本',
        if (articleOnly) 'article_body': articleBody,
        if (articleOnly) 'published_at': 1795478400,
      },
    ],
  );
  final work = (await store.creatorWorks(imported.creatorId)).single;
  const transcript = precedenceOnly
      ? '采购正式下单前，先核对实际发票，再确认审批人。'
          '发票缺失时暂停，没有授权审批人时暂停。'
      : '演示案例：验证企业是否愿意为新工具付费。第一步，'
          '当客户说需求紧迫时，核对同类问题最近三个月的实际发票和支出。第二步，'
          '找到有审批权限的预算负责人，让其确认预算范围。第三步，约定一周付费试点，'
          '用处理时间和交付质量验收。如果没有支出记录或审批人，先停止并补齐信息。'
          '输出当前支出、预算负责人、试点范围和验收标准。';
  if (!articleOnly && readOnlySnapshot.isEmpty) {
    await store.saveCreatorTranscript(
        workId: work['id'] as String,
        sourceVersion: 1,
        transcript: transcript,
        cues: [
          {'start_ms': 0, 'end_ms': 27000, 'text': transcript}
        ]);
  }
  const secondName = '圆桌交付验收博主';
  String? secondId;
  if (multi) {
    final second = await store.importCreatorWorks(
      {'id': 'controlled-second-author', 'name': secondName, 'works': 1},
      [
        {'id': '1234567890123456790', 'title': '试点交付验收样本'}
      ],
    );
    secondId = second.creatorId;
    final secondWork = (await store.creatorWorks(secondId)).single;
    const secondTranscript = topicsOnly
        ? '演示案例：核实公司是否有真实采购意向。先查同类项目实际付款流水和发票，'
            '再找有最终支出审批权的人确认可用金额，最后邀请对方签字确认一周的付费验证项目和验收条件。'
            '拿不到付款记录或支出决策人时，先补证据。'
        : '演示案例：为企业付费试点约定验收标准。'
            '先记录当前人工处理时间作为基线，再定义一周试点的样本量和合格标准，'
            '最后由项目负责人和客户一起核对结果。如果没有有效基线，先补测并延后验收。';
    if (readOnlySnapshot.isEmpty) {
      await store.saveCreatorTranscript(
        workId: secondWork['id'] as String,
        sourceVersion: 1,
        transcript: secondTranscript,
        cues: [
          {'start_ms': 0, 'end_ms': 23000, 'text': secondTranscript}
        ],
      );
    }
  }
  const conflictName = '圆桌互斥条件验收博主';
  const conflictTitle = '匿名采购意向试点验收样本';
  const conflictSource = '演示案例：同样是核实新工具的采购意向，但试点启动前严格禁止要求客户签署付款或预算承诺，'
      '也不得收费。先把不接受承诺的规则写进试点通知，再邀请候选客户提交匿名意向，最后汇总意向结果。'
      '有人要求提前签署付费承诺或付款时立即停止试点。';
  String? conflictId;
  if (verifyConflict) {
    final result = await store.importCreatorWorks(
      {'id': 'controlled-conflict-author', 'name': conflictName, 'works': 1},
      [
        {
          'id': '1234567890123456792',
          'title': conflictTitle,
          'article_body': conflictSource
        },
      ],
    );
    conflictId = result.creatorId;
  }
  final String? resumeJob;
  if (resumeFixture) {
    resumeJob = await store.beginCreatorSyncJob(imported.creatorId,
        latest: 2, model: null);
    await store.checkpointCreatorSyncJob(resumeJob, {
      'author_id': 'controlled-author',
      'next_cursor': 3,
      'cursors': [0],
      'works': {'1234567890123456789': 1},
    });
    await store.db.close();
    store = await LocalWorkspaceStore.open(path: databasePath);
  } else {
    resumeJob = null;
  }

  final workspace = LocalWorkspaceController(store);
  final assets = Directory('${directory.path}/assets');
  final screenshot = GlobalKey();
  final syncProbe = knowledgeSync ? _SyncKnowledgeFixture() : null;
  final resumeProbe = resumeFixture ? _SyncResumeFixture() : null;
  final modelProbe = knowledgeSync || precedenceOnly
      ? _KnowledgeModelProbe(precedenceFixture: precedenceOnly)
      : null;
  runApp(ProviderScope(
    overrides: [
      localWorkspaceProvider.overrideWith((ref) async => workspace),
      creatorAssetDirectoryProvider.overrideWithValue(() async => assets),
      if (resumeProbe != null) ...[
        creatorDouyinAdapterProvider.overrideWithValue(() => resumeProbe),
        creatorDouyinSessionProvider.overrideWithValue(() async => 'fixture'),
      ] else if (syncProbe != null)
        creatorDouyinAdapterProvider.overrideWithValue(() => syncProbe),
      if (modelProbe != null)
        creatorRoundtableModelClientProvider.overrideWithValue(modelProbe),
    ],
    child: RepaintBoundary(
      key: screenshot,
      child: LocalWorkspaceApp(
        shellBuilder: (child) => MainLayout(localWorkspace: true, child: child),
      ),
    ),
  ));
  final controller = LiveWidgetController(binding);

  Future<void> waitFor(Finder finder,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final until = DateTime.now().add(timeout);
    while ((binding.rootElement == null || finder.evaluate().isEmpty) &&
        DateTime.now().isBefore(until)) {
      binding.scheduleFrame();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (binding.rootElement == null || finder.evaluate().isEmpty) {
      throw StateError('无法找到 $finder');
    }
  }

  Future<void> tap(Finder finder) async {
    await waitFor(finder);
    await controller.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Future<void> openCreatorDrawer() async {
    if (find
        .byKey(const ValueKey('roundtable-creators-drawer'))
        .evaluate()
        .isEmpty) {
      await tap(find.byKey(const ValueKey('roundtable-open-creators')));
    }
  }

  await tap(find.ancestor(
      of: find.text('博主圆桌'), matching: find.byType(SidebarNavItem)));

  if (disconnectOnly) {
    if (!Platform.resolvedExecutable
        .startsWith('/private/tmp/roundtable-scan.')) {
      throw StateError('断开验收仅能在独立扫码应用中运行。');
    }
    await tap(find.widgetWithText(OutlinedButton, '配置渠道'));
    await waitFor(find.text('已授权'));
    await tap(find.text('断开抖音'));
    await waitFor(find.text('未授权'));
    await tap(find.byTooltip('关闭').last);
    await tap(find.widgetWithText(OutlinedButton, '配置渠道'));
    await waitFor(find.text('未授权'));
    if (find.text('断开抖音').evaluate().isNotEmpty) {
      throw StateError('重新打开渠道设置后仍有抖音会话。');
    }
    debugPrint('ROUNDTABLE_REAL_DISCONNECT_PASSED');
    return;
  }

  if (articleOnly) {
    await openCreatorDrawer();
    await tap(find.widgetWithText(ListTile, '圆桌验收博主'));
    await waitFor(find.text('抖音图文'));
    await waitFor(find.text('正文第 4 段'));
    await waitFor(find.text('访谈结束后，记录客户接下来的实际行动。'));
    await binding.endOfFrame;
    final render =
        screenshot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1.5);
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final file = File('${directory.path}/article.png');
      await file.writeAsBytes(data.buffer.asUint8List());
      debugPrint('ROUNDTABLE_ARTICLE_UI_PASSED ${file.path}');
    } finally {
      image.dispose();
    }
    return;
  }

  if (resumeProbe != null) {
    final id = imported.creatorId;
    await openCreatorDrawer();
    await tap(find.widgetWithText(ListTile, '圆桌验收博主'));
    await tap(find.text('立即同步'));
    await waitFor(find.textContaining('已读取 1 页'));
    final quantity = find.byKey(const ValueKey('roundtable-sync-quantity'));
    if (controller.widget<TextField>(quantity).controller?.text != '2') {
      throw StateError('未恢复原同步范围。');
    }
    await tap(find.text('继续上次同步'));
    await waitFor(find.text('已同步 1 条新作品。'));
    final works = await store.creatorWorks(id);
    final jobs = await store.db
        .query('creator_jobs', where: 'id = ?', whereArgs: [resumeJob]);
    if (!listEquals(resumeProbe.cursors, [3]) ||
        !listEquals(resumeProbe.restored, ['1234567890123456789']) ||
        jobs.single['status'] != 'complete' ||
        works.length != 2 ||
        !works.any((item) => item['title'] == '续传取得的新作品')) {
      throw StateError('续传的游标、任务或落库结果不符。');
    }
    await waitFor(find.text('有新证据，选择可用模型后可更新知识。'));
    debugPrint('ROUNDTABLE_SYNC_RESUME_FIXTURE_PASSED');
    await store.db.close();
    exit(0);
  }

  if (realSyncLogin) {
    Future<bool> captureQrStep(String figure,
        {InAppWebViewController? view}) async {
      if (!qrCapture) return true;
      await controller.pump(const Duration(milliseconds: 300));
      final png = await captureRoundtablePng(screenshot,
          previewController: view,
          previewBounds: view == null
              ? null
              : controller.getRect(find.byType(InAppWebView)));
      final frame = File('${directory.path}/$figure.png');
      await frame.writeAsBytes(png);
      if (view != null && !await _containsScannableQr(frame)) {
        await frame.delete();
        return false;
      }
      debugPrint('ROUNDTABLE_QR_SCREENSHOT $figure ${directory.path}');
      return true;
    }

    await openCreatorDrawer();
    await tap(find.widgetWithText(ListTile, '圆桌验收博主'));
    await tap(find.text('立即同步'));
    await tap(find.text('最新作品'));
    final number = find.descendant(
      of: find.byKey(const ValueKey('roundtable-sync-quantity')),
      matching: find.byType(EditableText),
    );
    controller
        .state<EditableTextState>(number)
        .updateEditingValue(const TextEditingValue(text: '1'));
    await tap(find.text('开始同步'));
    await waitFor(find.text('请先重新连接抖音账号。'));
    await tap(find.text('重新连接抖音'));
    await tap(find.text('去授权'));
    await waitFor(find.text('抖音授权说明'));
    await tap(find.text('前往授权'));
    await waitFor(find.text('连接抖音账号'));
    if (qrCapture) {
      final deadline = DateTime.now().add(const Duration(seconds: 35));
      while (loginView == null && DateTime.now().isBefore(deadline)) {
        await controller.pump(const Duration(milliseconds: 200));
      }
      final view = loginView;
      if (view == null) throw StateError('抖音登录页面尚未加载');
      await view.evaluateJavascript(source: '''
        if (!document.body.innerText.includes('扫码登录')) {
          const login = [...document.querySelectorAll('button, [role="button"], span, div')].find(
            element => element.getClientRects().length > 0 && element.textContent.trim() === '登录');
          login?.click();
        }
      ''');
      var ready = false;
      while (!ready && DateTime.now().isBefore(deadline)) {
        ready = await view.evaluateJavascript(
                source:
                    "document.body.innerText.includes('扫码登录') || document.body.innerText.includes('扫码或验证码登录')") ==
            true;
        if (!ready) await controller.pump(const Duration(milliseconds: 250));
      }
      if (!ready) throw StateError('未从抖音登录页读取到扫码状态');
      final qrDeadline = DateTime.now().add(const Duration(seconds: 30));
      while (!await captureQrStep('55', view: view)) {
        if (DateTime.now().isAfter(qrDeadline)) {
          throw StateError('抖音页面出现登录框，但未显示可识别的二维码。');
        }
        await controller.pump(const Duration(milliseconds: 500));
      }
    }
    debugPrint('ROUNDTABLE_REAL_QR_WAITING');
    await waitFor(find.text('确认授权范围'), timeout: const Duration(minutes: 20));
    await captureQrStep('56');
    await tap(find.widgetWithText(FilledButton, '确认范围'));
    await waitFor(find.text('抖音授权成功'));
    await captureQrStep('57');
    await tap(
        find.byKey(const ValueKey('roundtable-douyin-authorization-done')));
    await waitFor(find.text('立即同步'));
    if (controller.widget<EditableText>(number).controller.text != '1') {
      throw StateError('授权返回后没有保留原同步数量。');
    }
    await tap(find.text('开始同步'));
    await waitFor(find.textContaining('已同步 1 条新作品'),
        timeout: const Duration(minutes: 2));
    final works = await store.creatorWorks(imported.creatorId);
    if (works.length != 2 ||
        !works.any((item) => item['source_work_id'] == '1234567890123456789')) {
      throw StateError('同步后预期保留旧作品并新增一条。');
    }
    debugPrint('ROUNDTABLE_REAL_QR_SYNC_PASSED');
    return;
  }

  if (syncLoginOnly) {
    const cookieChannel =
        MethodChannel('com.pichillilorenzo/flutter_inappwebview_cookiemanager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(cookieChannel, (call) async {
      if (call.method == 'getCookies') return <Map<String, dynamic>>[];
      throw MissingPluginException(call.method);
    });
    try {
      await openCreatorDrawer();
      await tap(find.widgetWithText(ListTile, '圆桌验收博主'));
      await tap(find.text('立即同步'));
      await tap(find.text('最新作品'));
      await tap(find.text('开始同步'));
      await waitFor(find.text('请先重新连接抖音账号。'));
      await tap(find.text('重新连接抖音'));
      await waitFor(find.text('未授权'));
      await tap(find.text('去授权'));
      await waitFor(find.text('抖音授权说明'));
      await tap(find.text('取消'));
      await waitFor(find.text('未授权'));
      await tap(find.byTooltip('关闭').last);
      final range = find.byType(RadioGroup<bool>);
      await waitFor(range);
      if ((range.evaluate().single.widget as RadioGroup<bool>).groupValue !=
              false ||
          (await store.creatorWorks(imported.creatorId)).length != 1) {
        throw StateError('原同步范围或既有作品未保留。');
      }
      debugPrint('ROUNDTABLE_SYNC_LOGIN_UI_PASSED');
    } finally {
      messenger.setMockMethodCallHandler(cookieChannel, null);
    }
    return;
  }

  Future<void> generateExpert(String name, String id,
      {bool update = false}) async {
    if (readOnlySnapshot.isNotEmpty) {
      if (await store.latestCreatorExpert(id) == null) {
        throw StateError('测试快照缺少已发布专家 $name');
      }
      return;
    }
    await openCreatorDrawer();
    await tap(find.widgetWithText(ListTile, name));
    final generate =
        find.widgetWithText(OutlinedButton, update ? '更新专家' : '继续生成');
    await waitFor(generate);
    if ((generate.evaluate().single.widget as OutlinedButton).onPressed ==
        null) {
      throw StateError('需在圆桌页先选中一个已配置的模型。');
    }
    await tap(generate);
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    final targetVersion = update ? 2 : 1;
    while (((await store.latestCreatorExpert(id))?['version'] as int? ?? 0) <
        targetVersion) {
      final job = await store.lastCreatorExpertJob(id);
      if (job?['status'] == 'failed') {
        throw StateError('专家生成失败: ${job?['error']}');
      }
      if (DateTime.now().isAfter(deadline)) throw StateError('专家生成等待超时');
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
    await tap(find.text('返回博主列表').hitTestable());
    await tap(find.byTooltip('收起博主列表'));
    await waitFor(find.text('圆桌专家团'));
  }

  await generateExpert('圆桌验收博主', imported.creatorId);
  if (precedenceOnly) {
    final expert = (await store.latestCreatorExpert(imported.creatorId))!;
    final content = jsonDecode(expert['content'] as String) as Map;
    final edge = creatorGraphPrecedence(content).single;
    final names = {
      for (final method in (content['methods'] as List).whereType<Map>())
        method['id']: method['problem'],
    };
    if (names[edge.before] != '核对实际发票' || names[edge.after] != '确认审批人') {
      throw StateError('前置关系方向与原文不符');
    }
    if (const bool.fromEnvironment('ROUNDTABLE_LIVE_GRAPH_EXPORT')) {
      final exportDir = await Directory('/private/tmp').createTemp('rt-graph-');
      await openCreatorDrawer();
      await tap(find.widgetWithText(ListTile, '圆桌验收博主'));
      debugPrint('ROUNDTABLE_GRAPH_EXPORT_READY ${exportDir.path}');
      final selector = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = _GraphExportFileSelector(exportDir.path);
      try {
        await tap(find.byTooltip('下载专家 Skill'));
      } finally {
        FileSelectorPlatform.instance = selector;
      }
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (DateTime.now().isBefore(deadline)) {
        final files = await exportDir
            .list()
            .where((entry) => entry is File && entry.path.endsWith('.zip'))
            .toList();
        if (files.length == 1) {
          final result = await Process.run(
              '/usr/bin/unzip', ['-p', files.single.path, 'graph.json']);
          if (result.exitCode != 0) {
            throw StateError('导出的技能包没有图谱文件');
          }
          final document = jsonDecode(result.stdout as String) as Map;
          final edges = (document['edges'] as List).cast<Map>();
          final references = (document['source_refs'] as List).cast<Map>();
          if (document['version'] != expert['version'] ||
              !edges.any((item) =>
                  item['type'] == 'precedes' &&
                  item['from_id'] == edge.before &&
                  item['to_id'] == edge.after &&
                  (item['evidence_ids'] as List).contains(edge.sourceId)) ||
              !references.any((ref) =>
                  ref['id'] == edge.sourceId && ref['text'] == transcript)) {
            throw StateError('图谱文件的版本、方向或原文不一致');
          }
          debugPrint('ROUNDTABLE_GRAPH_EXPORT_UI_PASSED');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      throw StateError('技能包保存超时');
    }
    await tap(find.text('知识资产'));
    final before = find.widgetWithText(FilterChip, '核对实际发票');
    final after = find.widgetWithText(FilterChip, '确认审批人');
    await waitFor(before);
    await waitFor(after);
    final beforeRect = controller.getRect(before);
    final afterRect = controller.getRect(after);
    final afterPoint = Offset(afterRect.center.dx, afterRect.top + 20);
    final elbow = Offset(
      beforeRect.center.dx - 118,
      (beforeRect.top + afterRect.top) / 2 + 20,
    );
    await controller.tapAt(Offset.lerp(elbow, afterPoint, .36)!);
    await waitFor(find.text('前置关系 · 原文顺序'));
    await tap(find.text('查看归档作品'));
    await waitFor(find.text(transcript));
    debugPrint('ROUNDTABLE_GRAPH_PRECEDENCE_UI_PASSED');
    return;
  }
  if (knowledgeSync) {
    final id = imported.creatorId;
    final old = (await store.latestCreatorExpert(id))!;
    modelProbe!.failNextGraph = true;
    const cookieChannel =
        MethodChannel('com.pichillilorenzo/flutter_inappwebview_cookiemanager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(cookieChannel, (call) async {
      if (call.method != 'getCookies') {
        throw MissingPluginException(call.method);
      }
      return [
        {
          'name': 'sessionid',
          'value': 'isolated-fixture',
          'domain': 'www.douyin.com',
          'path': '/'
        }
      ];
    });
    try {
      await openCreatorDrawer();
      await tap(find.widgetWithText(ListTile, '圆桌验收博主'));
      await tap(find.text('立即同步'));
      await tap(find.text('开始同步'));
      await waitFor(find.text('已同步 1 条新作品。').hitTestable());
      await tap(find.widgetWithText(FilledButton, '完成').hitTestable());
      await waitFor(find.text('重试知识更新'), timeout: const Duration(minutes: 3));
      final failed = (await store.lastCreatorExpertJob(id))!;
      if ((await store.latestCreatorExpert(id))?['content'] != old['content'] ||
          (await store.creatorWorks(id)).length != 2 ||
          failed['status'] != 'failed' ||
          !(failed['error'] as String).contains('验收注入')) {
        throw StateError('知识失败后作品或上一发布版本未保留');
      }
      final calls = modelProbe.otherCalls;
      await tap(find.text('重试知识更新'));
      await waitFor(find.text('博主专家 · v2'),
          timeout: const Duration(minutes: 3));
      final finished = (await store.lastCreatorExpertJob(id))!;
      final updated = (await store.latestCreatorExpert(id))!;
      if (syncProbe!.reads != 1 ||
          modelProbe.otherCalls != calls ||
          finished['id'] != failed['id'] ||
          finished['source_snapshot'] != failed['source_snapshot'] ||
          finished['model_snapshot'] != failed['model_snapshot'] ||
          finished['status'] != 'complete' ||
          creatorGraphTopics(updated).isEmpty) {
        throw StateError('重试没有复用原任务、检查点和模型');
      }
      debugPrint('ROUNDTABLE_SYNC_KNOWLEDGE_RETRY_PASSED');
    } finally {
      messenger.setMockMethodCallHandler(cookieChannel, null);
    }
    return;
  }
  if (const bool.fromEnvironment('ROUNDTABLE_LIVE_UPDATE')) {
    final first = (await store.latestCreatorExpert(imported.creatorId))!;
    await generateExpert('圆桌验收博主', imported.creatorId, update: true);
    final versions = await store.db.query('creator_experts',
        where: 'id = ?', whereArgs: [imported.creatorId], orderBy: 'version');
    if (versions.length != 2 ||
        versions.first['content'] != first['content'] ||
        versions.first['evidence'] != first['evidence'] ||
        versions.last['version'] != 2) {
      throw StateError('Updating expert did not keep the published history');
    }
    debugPrint('ROUNDTABLE_EXPERT_UPDATE_UI_PASSED');
  }
  if (secondId != null) await generateExpert(secondName, secondId);
  if (conflictId != null) await generateExpert(conflictName, conflictId);
  debugPrint('ROUNDTABLE_EXPERT_PASSED');
  if (topicsOnly) {
    final first = creatorGraphTopics(
        (await store.latestCreatorExpert(imported.creatorId))!);
    final second =
        creatorGraphTopics((await store.latestCreatorExpert(secondId!))!);
    final shared = first
        .where((topic) => second.any((item) => item.id == topic.id))
        .firstOrNull;
    if (shared == null) {
      throw StateError('两个有不同措辞的付费验证方法未归入同一主题。');
    }
    CreatorGraphTopic? separate;
    if (conflictId != null) {
      final third =
          creatorGraphTopics((await store.latestCreatorExpert(conflictId))!);
      final compatibleIds =
          [...first, ...second].map((item) => item.id).toSet();
      if (third.isEmpty ||
          third.any((topic) => compatibleIds.contains(topic.id))) {
        throw StateError('限制提前付款的试点被并入要求付费试点的主题。');
      }
      separate = third.first;
    }
    await tap(find.text('知识资产'));
    final authors = find.byWidgetPredicate((widget) =>
        widget is DropdownButton<String> &&
        (widget.items?.any((item) =>
                item.child is Text && (item.child as Text).data == '全部博主') ??
            false));
    await tap(authors);
    await tap(find.text('全部博主').last);
    await tap(find.widgetWithText(FilterChip, shared.title));
    await waitFor(find.text('关联作品 · 2'));
    final compatible = [
      work,
      (await store.creatorWorks(secondId)).single,
    ];
    for (final expected in compatible) {
      await tap(
          find.byKey(ValueKey('roundtable-graph-work:${expected['id']}')));
      await waitFor(find.text('关联作品 · 1'));
      await tap(find.text('查看归档作品'));
      await waitFor(find.textContaining('专家引用 ·'));
      await waitFor(find.text(expected['title'] as String, findRichText: true));
      await tap(find.byTooltip('关闭').last);
    }
    debugPrint('ROUNDTABLE_MULTI_AUTHOR_TOPICS_UI_PASSED');
    if (separate != null) {
      await tap(find.widgetWithText(FilterChip, separate.title));
      await waitFor(find.text('关联作品 · 1'));
      await tap(find.text('查看归档作品'));
      await waitFor(find.text(conflictTitle, findRichText: true));
      await waitFor(
          find.textContaining('严格禁止要求客户签署付款或预算承诺', findRichText: true));
      debugPrint('ROUNDTABLE_OPPOSING_RULES_UI_PASSED');
      await store.db.close();
      exit(0);
    }
    return;
  }
  await tap(find.byKey(const ValueKey('roundtable-stage-experts')));
  final question = find.byKey(const ValueKey('roundtable-chat-question'));
  const prompt = '验证企业付费意愿，应该如何确认预算并验收试点？';
  await waitFor(question);
  await controller.tap(question);
  controller
      .state<EditableTextState>(
          find.descendant(of: question, matching: find.byType(EditableText)))
      .updateEditingValue(const TextEditingValue(text: prompt));
  if (multi) {
    final choose = find.byKey(const ValueKey('roundtable-chat-experts'));
    await tap(choose);
    await waitFor(find.widgetWithText(CheckboxListTile, secondName));
    for (final name in ['圆桌验收博主', secondName]) {
      if (!controller
          .widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, name))
          .value!) {
        throw StateError('Published expert is not selected: $name');
      }
    }
    await tap(choose);
    await tap(find.byTooltip('放大对话'));
    await tap(find.byTooltip('退出全屏对话'));
    await tap(find.byTooltip('关闭').last);
    await tap(find.byKey(const ValueKey('roundtable-stage-experts')));
    final restored = question;
    await waitFor(restored);
    if (controller.widget<TextField>(restored).controller?.text != prompt) {
      throw StateError('Draft changed when reopening the roundtable');
    }
  }
  await tap(find.byTooltip('发送'));
  final visibleCitations = find.text('查看引用').hitTestable();
  await waitFor(visibleCitations, timeout: const Duration(minutes: 3));
  await tap(visibleCitations.first);
  await waitFor(find
      .textContaining(multi ? RegExp(r'00:00:(23|27)\.000') : '00:00:27.000'));
  final chats = await store.roundtableChats();
  if (chats.length != 1) throw StateError('真实问答未保存会话');
  if (multi) {
    final turns = await store.roundtableTurns(chats.single['id'] as String);
    final names = [
      for (final turn in turns.where((row) => row['role'] == 'assistant'))
        (jsonDecode(turn['expert_snapshot'] as String) as Map)['expert']['name']
    ];
    if (names.length != 3 ||
        names.last != '系统综合' ||
        !names.contains('圆桌验收博主') ||
        !names.contains(secondName)) {
      throw StateError('Two expert replies or the synthesis were not saved');
    }
    debugPrint('ROUNDTABLE_MULTI_EXPERT_UI_PASSED');
  }
  debugPrint('ROUNDTABLE_PIPELINE_UI_PASSED ${directory.path}');
  if (const bool.fromEnvironment('ROUNDTABLE_LIVE_ASSETS')) {
    await tap(find.byTooltip('关闭').last);
    await tap(find.text('知识资产'));
    for (final kind in CreatorAssetKind.values) {
      final button = find.byKey(ValueKey('creator-generate-${kind.name}'));
      await waitFor(button);
      final ready = DateTime.now().add(const Duration(seconds: 10));
      while (
          (button.evaluate().single.widget as FilledButton).onPressed == null) {
        if (DateTime.now().isAfter(ready)) {
          throw StateError('资产生成入口不可用: ${kind.label}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      await tap(button);
      final title = find.descendant(
        of: find.byKey(const ValueKey('roundtable-asset-title')),
        matching: find.byType(EditableText),
      );
      await waitFor(title);
      await controller.tap(title);
      controller
          .state<EditableTextState>(title)
          .updateEditingValue(TextEditingValue(text: '付费试点验收·${kind.label}'));
      await tap(find.text('生成'));
      final until = DateTime.now().add(const Duration(minutes: 3));
      while (true) {
        final saved = (await store.creatorAssets())
            .where((row) => row['kind'] == kind.name)
            .firstOrNull;
        if (saved != null) {
          final bytes =
              await File('${assets.path}/${saved['file_path']}').readAsBytes();
          verifyRenderedCreatorAsset(kind, bytes);
          debugPrint('ROUNDTABLE_ASSET_PASSED ${kind.name} ${bytes.length}');
          break;
        }
        final jobs = await store.db.query('creator_jobs',
            where: 'kind = ?',
            whereArgs: ['asset-${kind.name}'],
            orderBy: 'created DESC',
            limit: 1);
        if (jobs.firstOrNull?['status'] == 'failed') {
          throw StateError('${kind.label}生成失败: ${jobs.single['error']}');
        }
        if (DateTime.now().isAfter(until)) {
          throw StateError('${kind.label}生成超时');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await waitFor(find.text('知识资产'));
    }
    debugPrint('ROUNDTABLE_ASSETS_UI_PASSED ${assets.path}');
  }
}
