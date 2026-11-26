import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

// The real platform picker is registered by the desktop app.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
// The native preview plugin is supplied by the shared client.
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nexwork/layout/main_layout.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The desktop plugin is supplied by zhiban_client.
// ignore: depend_on_referenced_packages
import 'package:window_manager/window_manager.dart';
import 'package:zhiban_client/layout/widgets/sidebar_nav_item.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_panel.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_import_feedback.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_roundtable_page.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_skill_preview.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_asset_dialog.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_asset_workflow.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_expert_workflow.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_image_ocr.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_remote_media.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/douyin_creator_service.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_app.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_controller.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_seat_portrait.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_model_client.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/services/local_api_key_file_store.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';
import 'package:zhiban_client/window/window_controller.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';

import 'creator_roundtable_capture.dart';
import 'creator_roundtable_visual_batch.dart' as import_visual;

class _TestFileSelector extends FileSelectorPlatform {
  _TestFileSelector(this.delegate, this.directory, {this.directSave = false});

  final FileSelectorPlatform delegate;
  final String directory;
  final bool directSave;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) =>
      delegate.openFile(
        acceptedTypeGroups: acceptedTypeGroups,
        initialDirectory: directory,
        confirmButtonText: confirmButtonText,
      );

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    if (options.suggestedName case final String name when directSave) {
      return FileSaveLocation('$directory/$name');
    }
    return delegate.getSaveLocation(
      acceptedTypeGroups: acceptedTypeGroups,
      options: SaveDialogOptions(
        initialDirectory: directory,
        confirmButtonText: options.confirmButtonText,
        suggestedName: options.suggestedName,
        canCreateDirectories: options.canCreateDirectories,
      ),
    );
  }
}

class _MediaFixturePicker extends FileSelectorPlatform {
  _MediaFixturePicker(this.input);

  File input;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async =>
      XFile(input.path);
}

class _RealSyncTrace extends DouyinCreatorService {
  _RealSyncTrace(this.cursors);

  final List<int> cursors;

  @override
  Future<Map<String, dynamic>> readAuthorPage({
    required String cookie,
    required String authorId,
    required int cursor,
    int count = 20,
    required void Function(String) onStatus,
  }) {
    cursors.add(cursor);
    return super.readAuthorPage(
        cookie: cookie,
        authorId: authorId,
        cursor: cursor,
        count: count,
        onStatus: onStatus);
  }
}

/// Counts verified local files attached to the newly synced works. Remote
/// media URLs and the browser session never enter the verification output.
Future<int> _verifyNewSyncMedia(
  List<LocalRow> works,
  Directory root,
) async {
  var checked = 0;

  Future<bool> verify(String folder, String? filename, Object? digest) async {
    if (filename == null || digest is! String) return false;
    final file = File('${root.path}/$folder/$filename');
    if (!await file.exists() || await file.length() == 0) return false;
    return (await sha256.bind(file.openRead()).first).toString() == digest;
  }

  for (final work in works) {
    final metadata = jsonDecode(work['metadata'] as String) as Map;
    final images = (metadata['images'] as List? ?? const []).cast<String>();
    for (final (index, source) in images.indexed) {
      final name = creatorArchivedImageName(metadata, index, source);
      final entries = metadata['local_images'] as Map?;
      final entry = entries?['$index'] as Map?;
      if (!await verify('images', name, entry?['sha256'])) return 0;
      checked++;
    }
    if (Uri.parse(work['source_url'] as String).path.startsWith('/video/')) {
      if (!await verify('media', creatorArchivedMediaName(metadata),
          metadata['local_media_digest'])) {
        return 0;
      }
      checked++;
    }
  }
  return checked;
}

class _MainlineModels extends ModelProvidersNotifier {
  @override
  Future<List<AiProviderConfig>> build() async => const [
        AiProviderConfig(
          id: 'roundtable-qa',
          name: '验收服务',
          enabled: true,
          imageEditBaseUrl: 'http://127.0.0.1/v1',
          models: [
            AiModelConfig(
                id: 'text',
                modelId: 'gpt-roundtable-qa',
                displayName: '圆桌验收文本模型'),
            AiModelConfig(
                id: 'image', modelId: 'gpt-image-1', displayName: '圆桌验收图片模型'),
          ],
        ),
      ];
}

class _MainlineKeys extends ModelServiceStore {
  @override
  Future<String?> getApiKey(String providerId) async => 'isolated-test-key';
}

/// Deterministic response for the image endpoint. The production service still
/// reads the public author photo, validates the multipart request and saves PNG.
class _MainlineImageEndpoint implements HttpClientAdapter {
  int calls = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions request, Stream<Uint8List>? data,
      Future<void>? cancel) async {
    final body = BytesBuilder();
    await for (final block in data!) {
      body.add(block);
    }
    final input = utf8.decode(body.takeBytes(), allowMalformed: true);
    if (request.uri.host != '127.0.0.1' ||
        !input.contains('avatar.png') ||
        !input.contains('transparent')) {
      throw StateError('头像未进入席位图片编辑请求');
    }
    calls++;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..color = const Color(0xff354e73);
    canvas.drawCircle(const Offset(50, 30), 16, paint);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(17, 49, 66, 43), const Radius.circular(15)),
        paint);
    final picture = recorder.endRecording();
    final image = await picture.toImage(100, 100);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      return ResponseBody.fromString(
          jsonEncode({
            'data': [
              {'b64_json': base64Encode(bytes.buffer.asUint8List())},
            ],
          }),
          200);
    } finally {
      image.dispose();
      picture.dispose();
    }
  }

  @override
  void close({bool force = false}) {}
}

class _MainlineTextModel extends LocalModelClient {
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
      return jsonEncode({
        'methods': [
          {
            'problem': '如何复核试点成本',
            'applies_when': '已有支出凭证',
            'limits': '缺少凭证时暂停判断',
            'steps': [
              {
                'action': '核对已发生的支出',
                'evidence_ids': [input.first['id']]
              }
            ],
          }
        ]
      });
    }
    if (system.startsWith('独立审查')) return '{"supported":[0]}';
    if (system.startsWith('你负责知识图谱归类')) {
      final row = (input['methods'] as List).single;
      return jsonEncode({
        'memberships': [
          {
            'method_id': row['method']['id'],
            'title': '复核实际支出',
            'meaning': '核对已经发生的成本',
            'evidence_ids': [row['evidence'][0]['id']],
          }
        ]
      });
    }
    if (system.startsWith('你是基于作者作品')) {
      return jsonEncode({
        'points': [
          {
            'text': '先核对实际支出，缺少凭证时暂停判断。',
            'evidence_ids': [input['evidence'][0]['id']],
          }
        ]
      });
    }
    throw StateError('未配置的圆桌验收文本模型调用');
  }
}

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  const assetLists = bool.fromEnvironment('ROUNDTABLE_ASSET_LISTS');
  const mainline = bool.fromEnvironment('ROUNDTABLE_MAINLINE_REVIEW');
  final modelConfig = Platform.environment['ROUNDTABLE_TEST_MODEL_CONFIG'];
  final credentials = Platform.environment['ROUNDTABLE_TEST_MODEL_CREDENTIALS'];
  final useRealModels = mainline && modelConfig != null && credentials != null;
  final imageEndpoint =
      mainline && !useRealModels ? _MainlineImageEndpoint() : null;
  ModelServiceStore? realModelStore;
  if (mainline) {
    if (!Platform.resolvedExecutable
        .startsWith('/private/tmp/roundtable-mainline.')) {
      throw StateError('主线验收须在独立调试应用启动');
    }
    await (await SharedPreferences.getInstance())
        .remove('creator_roundtable.display_seats.v1');
    if (useRealModels) {
      final raw = jsonDecode(await File(modelConfig).readAsString());
      final providers = (raw as List)
          .cast<Map<String, dynamic>>()
          .map(AiProviderConfig.fromJson)
          .toList();
      realModelStore = ModelServiceStore(
          fileStore: LocalApiKeyFileStore(root: Directory(credentials)));
      await realModelStore.saveProviders(providers);
    }
  }
  const windowCapture = String.fromEnvironment('ROUNDTABLE_WINDOW_CAPTURE');
  const checkExternalHtml = bool.fromEnvironment('ROUNDTABLE_EXTERNAL_HTML');
  const embeddedCapture = bool.fromEnvironment('ROUNDTABLE_EMBEDDED_CAPTURE');
  InAppWebViewController? livePreview;
  if (embeddedCapture) {
    // ignore: invalid_use_of_visible_for_testing_member
    AttachmentPreviewPanel.debugOnRendererReady = (view) => livePreview = view;
  }
  const graphRelations = bool.fromEnvironment('ROUNDTABLE_GRAPH_RELATIONS');
  const realResume = bool.fromEnvironment('ROUNDTABLE_DOUYIN_REAL_RESUME');
  if (assetLists || graphRelations || realResume) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1512, 859));
  } else {
    await WindowController.instance.init(hasToken: true);
  }
  final screenshots = GlobalKey();
  const fixture = String.fromEnvironment('ROUNDTABLE_EXPORT_FIXTURE');
  const douyinLink = String.fromEnvironment('ROUNDTABLE_DOUYIN_LINK');
  const douyinImages = bool.fromEnvironment('ROUNDTABLE_DOUYIN_IMAGES');
  const resumeAsset = bool.fromEnvironment('ROUNDTABLE_ASSET_RESUME');
  const mediaFixture = String.fromEnvironment('ROUNDTABLE_MEDIA_FIXTURE');
  const archiveFixture = String.fromEnvironment('ROUNDTABLE_ARCHIVE_FIXTURE');
  const ocrFixture = String.fromEnvironment('ROUNDTABLE_OCR_FIXTURE');
  if (fixture.isEmpty &&
      douyinLink.isEmpty &&
      !resumeAsset &&
      mediaFixture.isEmpty &&
      archiveFixture.isEmpty &&
      ocrFixture.isEmpty) {
    throw StateError('Provide a test scenario');
  }
  final temp =
      await Directory('/private/tmp').createTemp('roundtable-export-ui-');
  final database = '${temp.path}/roundtable.db';
  if (fixture.isNotEmpty) {
    await File('$fixture/roundtable.db').copy(database);
  }
  var store = await LocalWorkspaceStore.open(path: database);
  const resumeTitle = '断点恢复验收';
  const originalModel = {'model_id': 'original-model'};
  const originalVersions = [
    {'expert_id': 'original-expert', 'version': 2}
  ];
  String? resumeId;
  String? mediaCreatorId;
  if (mediaFixture.isNotEmpty ||
      archiveFixture.isNotEmpty ||
      ocrFixture.isNotEmpty) {
    final imported = await store.importCreatorWorks(
      {'id': 'media-author', 'name': '本地媒体验收博主'},
      [
        {
          'id': assetLists ? '7198765432109876543' : '1234567890123456789',
          'title': '本地视频样本',
          if (ocrFixture.isNotEmpty)
            'images': ['https://roundtable-test.invalid/image.png'],
        }
      ],
    );
    mediaCreatorId = imported.creatorId;
  }
  if (resumeAsset) {
    const kind = CreatorAssetKind.web;
    resumeId = await store.beginCreatorAssetJob(
        kind.name, resumeTitle, originalModel, originalVersions);
    await store.checkpointCreatorAssetJob(
      resumeId,
      kind.name,
      creatorAssetCheckpoint((
        sections: [
          for (final heading in kind.sections)
            (heading: heading, text: '先检查预算凭证', ids: ['resume-evidence']),
        ],
        sources: {
          'resume-evidence': {
            'id': 'resume-evidence',
            'text': '先检查预算凭证',
            'start_ms': 0,
            'end_ms': 1000,
            'url': 'https://www.douyin.com/video/1234567890123456789',
          },
        },
      )),
    );
    await store.db.close();
    store = await LocalWorkspaceStore.open(path: database);
    if ((await store.lastResumableCreatorAssetJob(kind.name))?['status'] !=
        'interrupted') {
      throw StateError('Asset job was not restored as interrupted');
    }
  }
  final workspace = LocalWorkspaceController(store);
  final assetFolder = Directory(
      fixture.isEmpty || resumeAsset || archiveFixture.isNotEmpty || realResume
          ? '${temp.path}/assets'
          : '$fixture/assets');
  if (archiveFixture.isNotEmpty && assetLists) {
    await assetFolder.create(recursive: true);
    for (final row in await store.creatorAssets()) {
      final fileName = row['file_path'] as String;
      await File('$fixture/assets/$fileName')
          .copy('${assetFolder.path}/$fileName');
    }
  }
  final cursorTraces = <List<int>>[];
  runApp(ProviderScope(
      overrides: [
        localWorkspaceProvider.overrideWith((ref) async => workspace),
        if (realModelStore != null)
          modelServiceStoreProvider.overrideWithValue(realModelStore),
        if (imageEndpoint != null) ...[
          modelProvidersProvider.overrideWith(_MainlineModels.new),
          modelServiceStoreProvider.overrideWithValue(_MainlineKeys()),
          modelCatalogProvider.overrideWith((_) async =>
              const ModelCatalog(providers: [], modelsByProviderId: {})),
          creatorRoundtableModelClientProvider
              .overrideWithValue(_MainlineTextModel()),
          creatorSeatPortraitServiceProvider.overrideWithValue(
              CreatorSeatPortraitService(
                  transport: Dio()..httpClientAdapter = imageEndpoint)),
        ],
        if (realResume)
          creatorDouyinAdapterProvider.overrideWithValue(() {
            final trace = <int>[];
            cursorTraces.add(trace);
            return _RealSyncTrace(trace);
          }),
        creatorAssetDirectoryProvider
            .overrideWithValue(() async => assetFolder),
        if (ocrFixture.isNotEmpty)
          creatorImageReaderProvider
              .overrideWithValue((_) => File(ocrFixture).readAsBytes()),
        if (douyinImages)
          creatorImageReaderProvider
              .overrideWithValue((_) async => throw StateError('预期只从本机副本识别')),
      ],
      child: RepaintBoundary(
        key: screenshots,
        child: LocalWorkspaceApp(
          shellBuilder: (child) =>
              MainLayout(localWorkspace: true, child: child),
        ),
      )));
  final controller = LiveWidgetController(binding);
  Future<void> tap(Finder finder) async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (binding.rootElement == null ||
        finder.hitTestable().evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Control unavailable: $finder');
      }
      binding.scheduleFrame();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await controller.tap(finder.hitTestable());
  }

  Future<void> openCreatorDrawer() async {
    if (find
        .byKey(const ValueKey('roundtable-creators-drawer'))
        .evaluate()
        .isEmpty) {
      await tap(find.byKey(const ValueKey('roundtable-open-creators')));
    }
  }

  Future<void> capture(String figure, {bool includePreview = false}) async {
    await controller.pump(const Duration(milliseconds: 300));
    if (windowCapture.isNotEmpty && !includePreview) {
      final result = await Process.run(
          windowCapture, ['$pid', '${temp.path}/$figure.png']);
      final file = File('${temp.path}/$figure.png');
      if (result.exitCode != 0 || !await file.exists()) {
        debugPrint('ROUNDTABLE_WINDOW_CAPTURE_UNAVAILABLE $figure');
        return;
      }
      final codec = await ui.instantiateImageCodec(await file.readAsBytes(),
          targetWidth: 32, targetHeight: 32);
      final image = (await codec.getNextFrame()).image;
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final colors = <int>{};
      if (bytes != null) {
        for (var offset = 0; offset < bytes.lengthInBytes; offset += 4) {
          colors.add(bytes.getUint32(offset));
        }
      }
      image.dispose();
      codec.dispose();
      if (colors.length < 8) {
        debugPrint('ROUNDTABLE_WINDOW_CAPTURE_UNUSABLE $figure');
        return;
      }
      debugPrint('ROUNDTABLE_WINDOW_CAPTURED $figure ${temp.path}');
      return;
    }
    final view = includePreview ? livePreview : null;
    if (includePreview && view == null) {
      throw StateError('未取得实际 WebView：$figure');
    }
    final png = await captureRoundtablePng(
      screenshots,
      previewController: view,
      previewBounds:
          view == null ? null : controller.getRect(find.byType(InAppWebView)),
    );
    await File('${temp.path}/$figure.png').writeAsBytes(png);
    if (includePreview) {
      debugPrint('ROUNDTABLE_WEBVIEW_CAPTURED $figure ${temp.path}');
    }
  }

  await tap(find.ancestor(
      of: find.text('博主圆桌'), matching: find.byType(SidebarNavItem)));
  if (realResume) {
    Future<void> waitFor(List<Finder> controls, Duration timeout) async {
      final deadline = DateTime.now().add(timeout);
      while (controls.every((control) => control.evaluate().isEmpty)) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Missing $controls');
        }
        await controller.pump(const Duration(milliseconds: 250));
      }
    }

    try {
      final profile = (await store.creatorProfiles()).single;
      final id = profile['id'] as String;
      final existing = await store.creatorWorks(id);
      if (existing.isEmpty || (profile['work_count'] as int) <= 20) {
        throw StateError(
            'Use a previously imported public author with multiple pages');
      }
      await openCreatorDrawer();
      await tap(find.widgetWithText(ListTile, profile['name'] as String));
      final login = find.byWidgetPredicate((widget) =>
          widget is Text && (widget.data == '重新连接抖音' || widget.data == '重新授权'));
      final error = find.textContaining('失败。');
      var pending = await store.lastResumableCreatorSyncJob(id);
      if (pending == null) {
        await tap(find.text('立即同步'));
        await tap(find.text('最新作品'));
        final quantity = find.byKey(const ValueKey('roundtable-sync-quantity'));
        await waitFor([quantity], const Duration(seconds: 5));
        controller.widget<TextField>(quantity).controller!.text = '3';
        await tap(find.text('开始同步'));
        final firstPage = find.textContaining('第 1 页 ·');
        await waitFor([firstPage, login, error], const Duration(minutes: 1));
        if (login.evaluate().isNotEmpty) {
          await capture('49');
          debugPrint('ROUNDTABLE_REAL_RESUME_LOGIN_REQUIRED ${temp.path}');
          exit(2);
        }
        if (error.evaluate().isNotEmpty) {
          await capture('48');
          throw StateError('Douyin reported a failure before page one');
        }
        await capture('45');
        await waitFor([find.textContaining('第 3 页 ·'), login, error],
            const Duration(minutes: 2));
        if (login.evaluate().isNotEmpty || error.evaluate().isNotEmpty) {
          await capture(login.evaluate().isNotEmpty ? '49' : '48');
          throw StateError('Douyin did not return two validated pages');
        }
        await tap(find.text('取消同步'));
        final checkpointDeadline =
            DateTime.now().add(const Duration(seconds: 15));
        while (pending == null && DateTime.now().isBefore(checkpointDeadline)) {
          pending = await store.lastResumableCreatorSyncJob(id);
          await controller.pump(const Duration(milliseconds: 150));
        }
      }
      if (pending == null) throw StateError('Cancelled sync has no checkpoint');
      if (!listEquals(
          (await store.creatorWorks(id)).map((row) => row['id']).toList(),
          existing.map((row) => row['id']).toList())) {
        throw StateError('Cancelled sync changed archived works');
      }
      final progress = jsonDecode(pending['result_payload'] as String) as Map;
      final next = progress['next_cursor'];
      final completedPages = (progress['cursors'] as List).length;
      if (next is! int || completedPages < 2) {
        throw StateError('Checkpoint does not retain the validated pages');
      }
      final previousTraces = cursorTraces.length;
      if (find
          .byKey(const ValueKey('roundtable-sync-progress'))
          .evaluate()
          .isNotEmpty) {
        await tap(find.widgetWithText(FilledButton, '关闭').hitTestable());
      }
      final retry = find.text('重试');
      await tap(retry.evaluate().isNotEmpty ? retry : find.text('立即同步'));
      await tap(find.text('继续上次同步'));
      final startDeadline = DateTime.now().add(const Duration(seconds: 30));
      final deadline = DateTime.now().add(const Duration(minutes: 12));
      var started = false;
      while (DateTime.now().isBefore(deadline)) {
        final job = (await store.db.query('creator_jobs',
                where: 'id = ?', whereArgs: [pending['id']]))
            .single;
        started |= job['status'] == 'running' ||
            cursorTraces.skip(previousTraces).any((trace) => trace.isNotEmpty);
        if (!started && login.evaluate().isNotEmpty) {
          await capture('49');
          debugPrint('ROUNDTABLE_REAL_RESUME_LOGIN_REQUIRED ${temp.path}');
          exit(2);
        }
        if (started && job['status'] == 'failed') {
          await capture('48');
          throw StateError('Douyin sync failed: ${job['error']}');
        }
        if (!started && DateTime.now().isAfter(startDeadline)) {
          throw StateError('Resume did not start a new request');
        }
        if (job['status'] == 'complete') {
          final resumed = cursorTraces.skip(previousTraces).single;
          final archived = await store.creatorWorks(id);
          final ids = archived.map((row) => row['id']).toSet();
          if (resumed.isEmpty ||
              resumed.first != next ||
              resumed.contains(0) ||
              !ids.containsAll(existing.map((row) => row['id'])) ||
              ids.length <= existing.length ||
              ids.length > existing.length + 3) {
            throw StateError('Resume cursor or local archive is inconsistent');
          }
          await waitFor(
              [find.textContaining('条新作品')], const Duration(seconds: 20));
          await capture('47');
          debugPrint('ROUNDTABLE_REAL_MULTIPAGE_RESUME_PASSED '
              '${completedPages + resumed.length} pages, '
              '${ids.length - existing.length} new works, ${temp.path}');
          if (const bool.fromEnvironment(
              'ROUNDTABLE_DOUYIN_VERIFY_SYNC_MEDIA')) {
            final previousIds = existing.map((row) => row['id']).toSet();
            final mediaDeadline =
                DateTime.now().add(const Duration(minutes: 2));
            while (DateTime.now().isBefore(mediaDeadline)) {
              final latest = await store.creatorWorks(id);
              final fresh = latest
                  .where((row) => !previousIds.contains(row['id']))
                  .toList();
              final files = await _verifyNewSyncMedia(fresh, assetFolder);
              if (files > 0) {
                debugPrint('ROUNDTABLE_REAL_SYNC_MEDIA_PASSED '
                    '${fresh.length} works, $files verified files, ${temp.path}');
                exit(0);
              }
              await controller.pump(const Duration(seconds: 1));
            }
            throw StateError('Newly synced media files are missing or invalid');
          }
          exit(0);
        }
        await controller.pump(const Duration(milliseconds: 300));
      }
      throw StateError('Douyin multi-page resume exceeded the test window');
    } catch (error, stack) {
      stderr.writeln('ROUNDTABLE_REAL_MULTIPAGE_RESUME_FAILED $error');
      stderr.writeln(stack);
      exit(1);
    }
  }
  if (ocrFixture.isNotEmpty) {
    await openCreatorDrawer();
    await tap(find.widgetWithText(ListTile, '本地媒体验收博主'));
    await tap(find.byKey(const ValueKey('creator-work-image-0')));
    await tap(find.text('识别图片文字'));
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (find.text('第 1 张图片 · 识别文字').evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('OCR text did not appear');
      }
      await controller.pump(const Duration(milliseconds: 150));
    }
    final evidence =
        creatorEvidence(await store.creatorWorks(mediaCreatorId!)).single;
    if (evidence['image_number'] != 1 ||
        !(evidence['text'] as String).contains('ROUND TABLE')) {
      throw StateError('Image evidence did not match the fixture');
    }
    debugPrint('ROUNDTABLE_IMAGE_OCR_UI_PASSED');
    return;
  }
  if (archiveFixture.isNotEmpty) {
    final picker = _MediaFixturePicker(File('$archiveFixture/clip.mp4'));
    FileSelectorPlatform.instance = picker;
    await openCreatorDrawer();
    await tap(find.widgetWithText(ListTile, '本地媒体验收博主'));
    final media = [
      File('$archiveFixture/clip.mp4'),
      if (File('$archiveFixture/clip.mov').existsSync())
        File('$archiveFixture/clip.mov'),
      File('$archiveFixture/voice.m4a'),
    ];
    for (final (index, original) in media.indexed) {
      final extension = original.path.split('.').last;
      final video = extension != 'm4a';
      picker.input = await original.copy('${temp.path}/selected.$extension');
      final expected = await picker.input.readAsBytes();
      final digest = sha256.convert(expected).toString();
      final archiveButton = find.text(index == 0 ? '归档本地音视频' : '更换归档媒体');
      if (archiveButton.evaluate().isEmpty) await tap(find.text('补充资料'));
      await tap(archiveButton);
      final play = find.text(video ? '播放视频' : '播放音频');
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      String? archivedFile;
      while (DateTime.now().isBefore(deadline)) {
        final work = (await store.creatorWorks(mediaCreatorId!)).single;
        final metadata = jsonDecode(work['metadata'] as String) as Map;
        if (metadata['local_media_digest'] == digest &&
            play.evaluate().isNotEmpty) {
          archivedFile = metadata['local_media_file'] as String;
          break;
        }
        await controller.pump(const Duration(milliseconds: 150));
      }
      if (archivedFile == null || !archivedFile.endsWith('.$extension')) {
        throw StateError('Archive action did not complete for $extension');
      }
      await picker.input.delete();
      final stored = File('${assetFolder.path}/media/$archivedFile');
      if (!listEquals(expected, await stored.readAsBytes())) {
        throw StateError('Archived media bytes differ for $extension');
      }
      await tap(play);
      final panel = find.byType(AttachmentPreviewPanel);
      final ready = DateTime.now().add(const Duration(seconds: 30));
      while (panel.evaluate().isEmpty ||
          find.text('正在加载预览…').evaluate().isNotEmpty) {
        if (DateTime.now().isAfter(ready)) {
          throw StateError('Media preview timed out');
        }
        await controller.pump(const Duration(milliseconds: 150));
      }
      if (find
          .descendant(of: panel, matching: find.text('外部打开'))
          .evaluate()
          .isNotEmpty) {
        throw StateError('Media preview rejected $extension');
      }
      final figure = switch (extension) {
        'mov' => '15-mov',
        'mp4' => '15',
        _ => '17',
      };
      if (embeddedCapture) {
        final state = await livePreview?.callAsyncJavaScript(
          functionBody: '''
            const media = document.querySelector('video, audio');
            if (!media || !Number.isFinite(media.duration) || media.duration <= 0)
              return null;
            media.currentTime = Math.min(.65, media.duration / 2);
            return media.tagName.toLowerCase();
          ''',
        );
        if (state?.value != (video ? 'video' : 'audio')) {
          throw StateError('媒体预览未加载实际 $extension 内容');
        }
        await capture(figure, includePreview: true);
      } else if (windowCapture.isNotEmpty) {
        await capture(figure);
      }
      debugPrint('ROUNDTABLE_MEDIA_ARCHIVE_VERIFIED $extension');
      await tap(find.byTooltip('关闭预览'));
      await controller.pump(const Duration(milliseconds: 350));
    }
    if (!assetLists) return;
    await tap(find.text('返回博主列表'));
    await tap(find.byTooltip('收起博主列表'));
  }
  if (mediaCreatorId != null && mediaFixture.isNotEmpty) {
    final input = File(mediaFixture);
    FileSelectorPlatform.instance =
        _TestFileSelector(FileSelectorPlatform.instance, input.parent.path);
    await openCreatorDrawer();
    await tap(find.widgetWithText(ListTile, '本地媒体验收博主'));
    debugPrint('ROUNDTABLE_MEDIA_SELECT ${input.path}');
    await tap(find.text('补充资料'));
    await tap(find.text('转写本地音视频'));
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      final work = (await store.creatorWorks(mediaCreatorId)).single;
      final visible = find.byWidgetPredicate((widget) =>
          widget is SelectableText && widget.data?.contains('先核对已有支出') == true);
      if (work['source_version'] == 2 && visible.evaluate().isNotEmpty) {
        final metadata = jsonDecode(work['metadata'] as String) as Map;
        final cue = (metadata['transcript_cues'] as List).single as Map;
        if (metadata['transcript_source'] != 'embedded_subtitle' ||
            cue['start_ms'] != 200 ||
            cue['end_ms'] != 1500) {
          throw StateError('The stored subtitle did not match the media');
        }
        debugPrint('ROUNDTABLE_MEDIA_UI_PASSED');
        return;
      }
      await controller.pump(const Duration(milliseconds: 200));
    }
    throw StateError('Media transcript was not shown');
  }
  if (douyinLink.isNotEmpty) {
    Future<void> waitFor(Finder finder,
        {Duration timeout = const Duration(seconds: 30)}) async {
      final deadline = DateTime.now().add(timeout);
      while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        await controller.pump(const Duration(milliseconds: 150));
      }
      if (finder.evaluate().isEmpty) throw StateError('验收界面未出现：$finder');
    }

    if (mainline) {
      await tap(find.ancestor(
        of: find.text('配置渠道'),
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
      ));
      await waitFor(find.text('已授权'));
      await capture('mainline-authorized');
      await tap(find.widgetWithText(FilledButton, '完成'));
      final model = find.byKey(const ValueKey('roundtable-model-selector'));
      await waitFor(model.hitTestable());
      if (controller.getRect(model).top < 30) {
        throw StateError('模型选择与 macOS 标题栏重叠');
      }
      await tap(model);
      final targetModel =
          find.text(useRealModels ? 'BeeBridge 文本验收' : '圆桌验收文本模型');
      await waitFor(targetModel);
      await tap(targetModel.last);
    }
    final normalized = DouyinCreatorService.normalizeLink(douyinLink);
    final homepage = Uri.parse(normalized).pathSegments.firstOrNull == 'user';
    const expectedWork =
        String.fromEnvironment('ROUNDTABLE_DOUYIN_EXPECTED_WORK');
    if (expectedWork.isNotEmpty) await capture('roundtable-import-header');
    await openCreatorDrawer();
    await tap(find.text('+ 添加博主'));
    await controller.pump(const Duration(milliseconds: 350));
    final linkField = find.descendant(
        of: find.byKey(const ValueKey('roundtable-add-link')),
        matching: find.byType(EditableText));
    controller.widget<EditableText>(linkField).controller.text = douyinLink;
    final read = find.widgetWithText(FilledButton, '读取作品');
    await tap(read);
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    var waitingForLogin = false;
    while (DateTime.now().isBefore(deadline)) {
      final confirm = find.textContaining(RegExp(r'^(添加到圆桌|开始蒸馏)$'));
      if (confirm.evaluate().isNotEmpty) {
        await tap(confirm);
        await tap(find.descendant(
          of: find.byType(CreatorImportFeedback),
          matching: find.textContaining(RegExp(r'^(后台处理|完成)$')),
        ));
        final persisted = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(persisted)) {
          final creators = await store.creatorProfiles();
          if (creators.length == 1) {
            final works =
                await store.creatorWorks(creators.single['id'] as String);
            if (homepage
                ? works.isNotEmpty && works.length <= 20
                : works.length == 1) {
              debugPrint(homepage
                  ? 'ROUNDTABLE_DOUYIN_PROFILE_UI_PASSED ${works.length}'
                  : 'ROUNDTABLE_DOUYIN_UI_PASSED');
              if (expectedWork.isNotEmpty) {
                if (works.single['source_work_id'] != expectedWork ||
                    (creators.single['avatar_url'] as String? ?? '').isEmpty) {
                  throw StateError('分享文案导入的作品或博主头像不符');
                }
                await capture('roundtable-shortlink-added');
                debugPrint('ROUNDTABLE_SHARE_TEXT_UI_PASSED ${temp.path}');
              }
              if (mainline) {
                final profile = creators.single;
                final id = profile['id'] as String;
                await waitFor(find.byKey(const ValueKey('generated-seat-0')),
                    timeout: const Duration(minutes: 3));
                if (imageEndpoint != null && imageEndpoint.calls != 1) {
                  throw StateError('应自动且仅生成一次席位形象');
                }
                await capture('mainline-seated');
                if (useRealModels) {
                  debugPrint('ROUNDTABLE_REAL_PORTRAIT_PASSED ${temp.path}');
                }
                final scene = find.byKey(const ValueKey('roundtable-scene'));
                final first = controller.getSize(scene);
                await windowManager.setSize(const Size(940, 660));
                await controller.pump(const Duration(milliseconds: 400));
                final second = controller.getSize(scene);
                if (first == second ||
                    (second.aspectRatio - 1586 / 992).abs() > .01 ||
                    (first.aspectRatio - 1586 / 992).abs() > .01) {
                  throw StateError('缩放窗口后圆桌画面未等比适配');
                }
                await capture('mainline-resized');
                await windowManager.setSize(const Size(1260, 820));
                await controller.pump(const Duration(milliseconds: 350));
                await openCreatorDrawer();
                await tap(
                    find.widgetWithText(ListTile, profile['name'] as String));
                await waitFor(find.text('打开原地址'));
                await capture('mainline-detail');
                await tap(find.text('返回博主列表'));
                await tap(find.byTooltip('收起博主列表'));
                final expert = await store.latestCreatorExpert(id);
                if (expert != null) {
                  await tap(find.byTooltip('全屏展开对话'));
                  final question =
                      find.byKey(const ValueKey('roundtable-chat-question'));
                  await waitFor(question);
                  final input = find.descendant(
                      of: question, matching: find.byType(EditableText));
                  controller.state<EditableTextState>(input).updateEditingValue(
                      const TextEditingValue(text: '这条验收证据建议先做什么？'));
                  await controller.pump(const Duration(milliseconds: 150));
                  await tap(find.byTooltip('发送'));
                  await waitFor(find.text('查看引用'),
                      timeout: const Duration(minutes: 2));
                  await tap(find.text('查看引用'));
                  final chats = await store.roundtableChats();
                  final turns =
                      await store.roundtableTurns(chats.single['id'] as String);
                  if (turns.length != 2 ||
                      turns.last['role'] != 'assistant' ||
                      (jsonDecode(turns.last['evidence'] as String) as List)
                          .isEmpty) {
                    throw StateError('问答或证据未归档');
                  }
                  await capture('mainline-chat');
                  await tap(find.byTooltip('收起对话'));
                  await controller.pump(const Duration(milliseconds: 400));
                  if (useRealModels) debugPrint('ROUNDTABLE_REAL_CHAT_PASSED');
                } else {
                  debugPrint('ROUNDTABLE_CHAT_NOT_RUN_NO_SOURCE_EVIDENCE');
                }
                final model =
                    find.byKey(const ValueKey('roundtable-model-selector'));
                final sidebar = find.byType(SidebarNavItem);
                final router = GoRouter.of(controller.element(sidebar.first));
                final nav = sidebar
                    .evaluate()
                    .map((element) => element.widget as SidebarNavItem)
                    .toList();
                // Leave the previous route with the model menu still open.
                await tap(model);
                router.go(nav.singleWhere((item) => item.label == '技能广场').path);
                await controller.pump(const Duration(milliseconds: 450));
                await waitFor(find.text('技能广场'));
                router.go(nav.singleWhere((item) => item.label == '博主圆桌').path);
                await waitFor(scene);
                await controller.pump(const Duration(milliseconds: 450));
                await capture('mainline-returned');
                debugPrint('ROUNDTABLE_MAINLINE_PASSED ${temp.path}');
                return;
              }
              if (douyinImages) {
                final profile = creators.single;
                final id = profile['id'] as String;
                await openCreatorDrawer();
                await tap(
                    find.widgetWithText(ListTile, profile['name'] as String));
                final deadline = DateTime.now().add(const Duration(minutes: 2));
                List<String> images = [];
                while (true) {
                  final work = (await store.creatorWorks(id)).single;
                  final metadata =
                      jsonDecode(work['metadata'] as String) as Map;
                  images =
                      (metadata['images'] as List? ?? const []).cast<String>();
                  if (images.isNotEmpty &&
                      images.indexed.every((image) =>
                          creatorArchivedImageName(
                              metadata, image.$1, image.$2) !=
                          null)) {
                    break;
                  }
                  if (find.textContaining('张图片未归档').evaluate().isNotEmpty) {
                    throw StateError('部分图文图片未归档');
                  }
                  if (DateTime.now().isAfter(deadline)) {
                    throw StateError('图文图片归档等待超时');
                  }
                  await controller.pump(const Duration(milliseconds: 150));
                }
                const index =
                    int.fromEnvironment('ROUNDTABLE_DOUYIN_OCR_INDEX');
                if (index < 0 || index >= images.length) {
                  throw StateError('样本没有所选序号的图片');
                }
                await tap(find.byKey(ValueKey('creator-work-image-$index')));
                final modal = find.byType(AlertDialog);
                final localImage = find.descendant(
                    of: modal,
                    matching: find.byWidgetPredicate((widget) =>
                        widget is Image && widget.image is FileImage));
                final previewDeadline =
                    DateTime.now().add(const Duration(seconds: 10));
                while (localImage.evaluate().isEmpty) {
                  if (DateTime.now().isAfter(previewDeadline)) {
                    throw StateError('预览未读取本地图片');
                  }
                  await controller.pump(const Duration(milliseconds: 150));
                }
                final image = controller.widget<Image>(localImage);
                if (await (image.image as FileImage).file.length() == 0) {
                  throw StateError('本机图片文件为空');
                }
                await tap(find.text('识别图片文字'));
                final ocrDeadline =
                    DateTime.now().add(const Duration(seconds: 20));
                final text = find.text('第 ${index + 1} 张图片 · 识别文字');
                while (text.evaluate().isEmpty) {
                  if (DateTime.now().isAfter(ocrDeadline)) {
                    throw StateError('第 ${index + 1} 张本机图片未识别到文字');
                  }
                  await controller.pump(const Duration(milliseconds: 150));
                }
                debugPrint(
                    'ROUNDTABLE_DOUYIN_IMAGE_OCR_UI_PASSED ${images.length}');
                return;
              }
              if (const bool.fromEnvironment('ROUNDTABLE_DOUYIN_MEDIA')) {
                final profile = creators.single;
                await openCreatorDrawer();
                await tap(
                    find.widgetWithText(ListTile, profile['name'] as String));
                final play = find.text('播放视频');
                final archiveDeadline =
                    DateTime.now().add(const Duration(seconds: 45));
                while (play.evaluate().isEmpty) {
                  if (DateTime.now().isAfter(archiveDeadline) ||
                      find.textContaining('个视频未归档').evaluate().isNotEmpty) {
                    throw StateError('Douyin video was not archived');
                  }
                  await controller.pump(const Duration(milliseconds: 150));
                }
                final archived =
                    (await store.creatorWorks(profile['id'] as String)).single;
                final metadata =
                    jsonDecode(archived['metadata'] as String) as Map;
                final file = File(
                    '${assetFolder.path}/media/${metadata['local_media_file']}');
                if (await file.length() <= 12) {
                  throw StateError('Douyin archive is incomplete');
                }
                await tap(play);
                final panel = find.byType(AttachmentPreviewPanel);
                final ready = DateTime.now().add(const Duration(seconds: 30));
                while (panel.evaluate().isEmpty ||
                    find.text('正在加载预览…').evaluate().isNotEmpty) {
                  if (DateTime.now().isAfter(ready)) {
                    throw StateError('Douyin archive preview timed out');
                  }
                  await controller.pump(const Duration(milliseconds: 150));
                }
                if (find
                    .descendant(of: panel, matching: find.text('外部打开'))
                    .evaluate()
                    .isNotEmpty) {
                  throw StateError('Douyin media preview rejected archive');
                }
                debugPrint(
                    'ROUNDTABLE_DOUYIN_MEDIA_UI_PASSED ${await file.length()}');
                return;
              }
              if (homepage &&
                  const bool.fromEnvironment(
                      'ROUNDTABLE_DOUYIN_COMPLETE_SYNC')) {
                final profile = creators.single;
                final count = profile['work_count'] as int;
                if (works.length < 2 || count > 12) {
                  throw StateError('Use a small public test creator');
                }
                final missing = works.first['id'];
                // Simulate a workstation that has not archived the latest post.
                await store.db.delete('creator_works',
                    where: 'id = ?', whereArgs: [missing]);
                await openCreatorDrawer();
                await tap(
                    find.widgetWithText(ListTile, profile['name'] as String));
                for (final latest in [true, false]) {
                  await tap(find.widgetWithText(OutlinedButton, '立即同步'));
                  if (latest) {
                    await tap(find.text('最新作品'));
                    await controller.pump(const Duration(milliseconds: 200));
                    final input = find.descendant(
                        of: find
                            .byKey(const ValueKey('roundtable-sync-quantity')),
                        matching: find.byType(EditableText));
                    controller.widget<EditableText>(input).controller.text =
                        '1';
                  }
                  await tap(find.text('开始同步'));
                  final status =
                      find.text(latest ? '已同步 1 条新作品。' : '暂无新作品，已核对所选范围。');
                  final deadline =
                      DateTime.now().add(const Duration(minutes: 2));
                  while (status.evaluate().isEmpty) {
                    if (find.text('重新连接抖音').evaluate().isNotEmpty ||
                        DateTime.now().isAfter(deadline)) {
                      throw StateError('Douyin sync did not finish');
                    }
                    await controller.pump(const Duration(milliseconds: 150));
                  }
                  final archived =
                      await store.creatorWorks(profile['id'] as String);
                  if (archived.length != works.length ||
                      archived.first['id'] != missing) {
                    throw StateError(
                        'Completed sync did not restore the latest post');
                  }
                  await tap(
                      find.widgetWithText(FilledButton, '完成').hitTestable());
                }
                debugPrint('ROUNDTABLE_DOUYIN_SYNC_UI_PASSED');
              }
              if (!homepage &&
                  const bool.fromEnvironment('ROUNDTABLE_DOUYIN_CANCEL_SYNC')) {
                final profile = creators.single;
                await openCreatorDrawer();
                await tap(
                    find.widgetWithText(ListTile, profile['name'] as String));
                await tap(find.text('立即同步'));
                await tap(find.text('最新作品'));
                await tap(find.text('开始同步'));
                final syncDeadline =
                    DateTime.now().add(const Duration(minutes: 2));
                while (find.textContaining('第 3 页 ·').evaluate().isEmpty) {
                  if (find.text('重新连接抖音').evaluate().isNotEmpty ||
                      DateTime.now().isAfter(syncDeadline)) {
                    throw StateError(
                        'Douyin sync did not reach the third page');
                  }
                  await controller.pump(const Duration(milliseconds: 100));
                }
                await tap(find.text('取消同步'));
                await controller.pump(const Duration(milliseconds: 300));
                final archived =
                    await store.creatorWorks(profile['id'] as String);
                if (archived.length != 1 ||
                    archived.single['id'] != works.single['id']) {
                  throw StateError('Cancelled sync changed archived works');
                }
                debugPrint('ROUNDTABLE_DOUYIN_MULTIPAGE_CANCEL_PASSED');
              }
              return;
            }
          }
          await controller.pump(const Duration(milliseconds: 200));
        }
        throw StateError('Imported Douyin work not persisted');
      }
      if (!waitingForLogin && find.text('抖音授权说明').evaluate().isNotEmpty) {
        await tap(find.text('前往授权'));
        debugPrint('ROUNDTABLE_DOUYIN_LOGIN_REQUIRED');
        waitingForLogin = true;
      }
      if (waitingForLogin && find.text('确认授权范围').evaluate().isNotEmpty) {
        await tap(find.widgetWithText(FilledButton, '确认范围'));
        await tap(
            find.byKey(const ValueKey('roundtable-douyin-authorization-done')));
        await tap(read);
        waitingForLogin = false;
      }
      final error = find.byWidgetPredicate((widget) =>
          widget is Text &&
          (widget.data?.endsWith('。') ?? false) &&
          widget.style?.color ==
              Theme.of(controller.element(read)).colorScheme.error);
      if (!waitingForLogin && error.evaluate().isNotEmpty) {
        throw StateError(controller.widget<Text>(error.first).data!);
      }
      await controller.pump(const Duration(milliseconds: 200));
    }
    throw StateError('Douyin UI validation timed out');
  }
  await tap(find.text('知识资产'));
  if (graphRelations) {
    final authors = find.byWidgetPredicate((widget) =>
        widget is DropdownButton<String> &&
        (widget.items?.any((item) => item.value == '') ?? false) &&
        (widget.items?.any((item) =>
                item.child is Text && (item.child as Text).data == '全部博主') ??
            false));
    await tap(authors);
    await tap(find.text('全部博主'));
    await controller.pump(const Duration(milliseconds: 350));
    final condition = find
        .byWidgetPredicate((widget) =>
            widget is FilterChip &&
            widget.label is Text &&
            ((widget.label as Text).data?.startsWith('适用条件 · ') ?? false))
        .first;
    await tap(condition);
    await controller.pump(const Duration(milliseconds: 250));
    await tap(find.text('查看归档作品').first);
    final refs = find.textContaining('专家引用 ·');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (refs.evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('条件节点没有定位到专家引用');
      }
      await controller.pump(const Duration(milliseconds: 120));
    }
    await tap(find.byTooltip('关闭').last);
    await controller.pump(const Duration(milliseconds: 350));
    await binding.endOfFrame;
    final boundary = screenshots.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.5);
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final file = File('${temp.path}/graph-relations.png');
      await file.writeAsBytes(data.buffer.asUint8List());
      debugPrint('ROUNDTABLE_GRAPH_RELATIONS_UI_PASSED ${file.path}');
    } finally {
      image.dispose();
    }
    return;
  }
  final exported = await Directory('${temp.path}/exports').create();
  FileSelectorPlatform.instance = _TestFileSelector(
      FileSelectorPlatform.instance, exported.path,
      directSave: assetLists);
  final knowledgeScroll =
      find.ancestor(of: find.text('知识图谱'), matching: find.byType(Scrollable));
  final layoutDeadline = DateTime.now().add(const Duration(seconds: 20));
  while (knowledgeScroll.evaluate().isEmpty) {
    if (DateTime.now().isAfter(layoutDeadline)) {
      throw StateError('Knowledge asset list unavailable');
    }
    await controller.pump(const Duration(milliseconds: 100));
  }
  final scrollable = find.byWidget(knowledgeScroll.evaluate().single.widget);
  if (resumeAsset) {
    final generate = find.byKey(const ValueKey('creator-generate-web'));
    await controller.scrollUntilVisible(generate, 160, scrollable: scrollable);
    await tap(generate);
    await tap(find.text('继续上次生成'));
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      final asset = (await store.creatorAssets()).singleOrNull;
      if (asset != null) {
        if (asset['id'] != resumeId ||
            asset['title'] != resumeTitle ||
            !(asset['model_snapshot'] as String).contains('original-model') ||
            !(asset['source_snapshot'] as String).contains('original-expert')) {
          throw StateError('Asset resume changed the original task parameters');
        }
        final bytes = await File('${assetFolder.path}/${asset['file_path']}')
            .readAsBytes();
        verifyRenderedCreatorAsset(CreatorAssetKind.web, bytes);
        debugPrint('ROUNDTABLE_ASSET_RESUME_UI_PASSED');
        return;
      }
      await controller.pump(const Duration(milliseconds: 100));
    }
    throw StateError('Resumed asset was not published');
  }
  if (!assetLists) {
    await tap(find.text('作品 1'));
    if (const bool.fromEnvironment('ROUNDTABLE_GRAPH_ONLY')) {
      final refs = find.text('关联作品 · 1');
      final openWork = find.text('查看归档作品');
      await tap(find.text('散点'));
      await tap(find.byTooltip('放大图谱'));
      await controller.pump(const Duration(milliseconds: 250));
      if (find.text('125%').evaluate().isEmpty || openWork.evaluate().isEmpty) {
        throw StateError('Scatter did not preserve the selected work');
      }
      await tap(refs);
      await controller.pump(const Duration(milliseconds: 250));
      if (openWork.evaluate().isNotEmpty) {
        throw StateError('Related works did not collapse');
      }
      await tap(refs);
      await tap(find.byTooltip('全屏知识图谱'));
      await controller.pump(const Duration(milliseconds: 350));
      final screen = find.byType(Dialog);
      if (find
              .descendant(of: screen, matching: find.text('125%'))
              .evaluate()
              .isEmpty ||
          find.descendant(of: screen, matching: openWork).evaluate().isEmpty) {
        throw StateError('Fullscreen did not preserve graph state');
      }
      await tap(find.descendant(of: screen, matching: find.byType(BackButton)));
      await controller.pump(const Duration(milliseconds: 350));
    }
    await tap(find.text('查看归档作品'));
    await tap(find.descendant(
      of: find.ancestor(
          of: find.text('关联作品'), matching: find.byType(UiSheetHeader)),
      matching: find.byTooltip('关闭'),
    ));
    await controller.pump(const Duration(milliseconds: 300));
    if (find.text('查看归档作品').evaluate().isEmpty) {
      throw StateError('Graph lost its selected work after preview');
    }
    debugPrint('ROUNDTABLE_GRAPH_RETURN_PASSED');
    if (const bool.fromEnvironment('ROUNDTABLE_GRAPH_ONLY')) {
      await tap(find.byTooltip('复位图谱'));
      await controller.pump(const Duration(milliseconds: 250));
      if (find.text('100%').evaluate().isEmpty) {
        throw StateError('Zoom did not reset');
      }
      debugPrint('ROUNDTABLE_GRAPH_LAYOUT_UI_PASSED');
      return;
    }
  }
  final rows = await store.creatorAssets();
  for (final kind in CreatorAssetKind.values) {
    final asset = rows.singleWhere((row) => row['kind'] == kind.name);
    var row = find.widgetWithText(ListTile, asset['title'] as String);
    if (assetLists) {
      final more = find.byKey(ValueKey('creator-more-${kind.name}'));
      await controller.scrollUntilVisible(more, 160, scrollable: scrollable);
      await tap(more);
      final dialog = find.byType(Dialog);
      row = find.descendant(of: dialog, matching: row);
      final listTitle =
          find.descendant(of: dialog, matching: find.text('${kind.label}资产'));
      final settle = DateTime.now().add(const Duration(seconds: 5));
      while (listTitle.evaluate().isEmpty && DateTime.now().isBefore(settle)) {
        await controller.pump(const Duration(milliseconds: 100));
      }
      if (listTitle.evaluate().isEmpty) throw StateError('资产列表未出现');
      await controller.pump(const Duration(milliseconds: 350));
      await binding.endOfFrame;
      final boundary = screenshots.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      try {
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('${temp.path}/asset-list-${kind.name}.png')
            .writeAsBytes(data.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    }
    final save = find.descendant(of: row, matching: find.byTooltip('下载'));
    if (!assetLists) {
      await controller.scrollUntilVisible(save, 160, scrollable: scrollable);
    }
    await controller.ensureVisible(save);
    await tap(find.descendant(of: row, matching: find.byTooltip('打开')));
    if (kind == CreatorAssetKind.skill) {
      final preview = find.byType(CreatorSkillPreview);
      await tap(find.descendant(
          of: preview, matching: find.widgetWithText(ListTile, '输入')));
      await tap(find.descendant(of: preview, matching: find.byTooltip('放大')));
      await controller.pump(const Duration(milliseconds: 200));
      final zoom = find.descendant(of: preview, matching: find.text('125%'));
      final section = find.descendant(
          of: preview, matching: find.widgetWithText(ListTile, '输入'));
      if (zoom.evaluate().isEmpty ||
          !controller.widget<ListTile>(section).selected) {
        throw StateError('缩放后应保留技能预览当前章节');
      }
      await capture('35');
      await tap(find.descendant(of: preview, matching: find.text('下载技能')));
      await tap(find.descendant(of: preview, matching: find.byTooltip('关闭')));
    } else {
      final panel = find.byType(AttachmentPreviewPanel);
      final readyDeadline = DateTime.now().add(const Duration(seconds: 30));
      while (panel.evaluate().isEmpty ||
          find.text('正在加载预览…').evaluate().isNotEmpty) {
        if (DateTime.now().isAfter(readyDeadline)) {
          throw StateError('Preview timed out: ${kind.name}');
        }
        await controller.pump(const Duration(milliseconds: 200));
      }
      if (find
          .descendant(of: panel, matching: find.text('外部打开'))
          .evaluate()
          .isNotEmpty) {
        throw StateError('Preview failed: ${kind.name}');
      }
      await capture(kind == CreatorAssetKind.ebook ? '33' : '34',
          includePreview: embeddedCapture);
      if (embeddedCapture && kind == CreatorAssetKind.ebook) {
        final chapter = await livePreview?.callAsyncJavaScript(
          functionBody: '''
            const select = document.querySelector('select[aria-label="章节"]');
            const target = select && [...select.options].find(option =>
              option.textContent === '导读' && Number(option.value) > 0);
            if (!target) return null;
            select.value = target.value;
            select.dispatchEvent(new Event('change'));
            await new Promise(resolve => requestAnimationFrame(resolve));
            return select.selectedOptions[0]?.textContent + ':' +
                document.querySelector('[aria-label="页码"] .tool-counter')?.textContent;
          ''',
        );
        final response = chapter?.value;
        if (response is! String ||
            !RegExp(r'^导读:[2-9] / [2-9]$').hasMatch(response)) {
          throw StateError('PDF 章节和页码未同步：$response');
        }
        debugPrint('ROUNDTABLE_PDF_CHAPTER_VERIFIED $response');
        await capture('37', includePreview: true);
      }
      if (checkExternalHtml && kind == CreatorAssetKind.web) {
        final localFile = File('${assetFolder.path}/${asset['file_path']}');
        await tap(find.byTooltip('新窗口打开'));
        debugPrint('ROUNDTABLE_EXTERNAL_HTML_REQUESTED ${localFile.path}');
        await Future<void>.delayed(const Duration(seconds: 7));
      }
      await tap(find.byTooltip('关闭预览'));
    }
    await controller.pump(const Duration(milliseconds: 300));
    debugPrint('ROUNDTABLE_PREVIEW_VERIFIED ${kind.name}');
    debugPrint('ROUNDTABLE_EXPORT_READY ${kind.name} ${exported.path}');
    if (kind != CreatorAssetKind.skill) await tap(save);
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (true) {
      final files = await exported
          .list()
          .where((f) => f is File && f.path.endsWith('.${kind.extension}'))
          .toList();
      if (files.length == 1) {
        final expected =
            await File('$fixture/assets/${asset['file_path']}').readAsBytes();
        final downloaded = await (files.single as File).readAsBytes();
        if (listEquals(expected, downloaded)) {
          verifyRenderedCreatorAsset(kind, downloaded);
          debugPrint(
              'ROUNDTABLE_EXPORT_VERIFIED ${kind.name} ${downloaded.length}');
          break;
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Export not verified: ${kind.name}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (assetLists) await tap(find.text('完成'));
  }
  if (assetLists) debugPrint('ROUNDTABLE_ASSET_LISTS_UI_PASSED ${temp.path}');
  debugPrint('ROUNDTABLE_EXPORT_UI_PASSED ${exported.path}');
  if (const bool.fromEnvironment('ROUNDTABLE_IMPORT_VISUAL')) {
    await import_visual.main();
  }
}
