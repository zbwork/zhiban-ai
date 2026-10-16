import 'package:crypto/crypto.dart' as crypto;
import 'package:zhiban_client/pages/chat/widgets/file_preview/local_artifact_source.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/attachment_preview_dialog.dart';
import 'package:nexwork/pages/chat/widgets/file_preview/attachment_preview_host.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_loader.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  test(
      'archived local file falls back to authenticated cloud preview when helper is offline',
      () => HttpOverrides.runWithHttpOverrides(() async {
            final bus = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            final storage =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            var signatures = 0;
            bus.listen((request) async {
              signatures++;
              expect(request.uri.path,
                  '/api/agent-bus/v1/drive/files/55555555-5555-4555-8555-555555555555/preview');
              expect(request.headers.value('authorization'), 'Bearer fixture');
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode({
                'data': {'url': 'http://127.0.0.1:${storage.port}/file'}
              }));
              await request.response.close();
            });
            storage.listen((request) async {
              expect(request.headers.value('authorization'), isNull);
              request.response.write('generated file');
              await request.response.close();
            });
            final source = LocalArtifactSource(
                artifactId: '33333333-3333-4333-8333-333333333333',
                deviceId: '44444444-4444-4444-8444-444444444444',
                sha256: crypto.sha256
                    .convert(utf8.encode('generated file'))
                    .toString(),
                conversationId: '22222222-2222-4222-8222-222222222222',
                driveFileId: '55555555-5555-4555-8555-555555555555');
            final loader = AttachmentPreviewLoader(
                apiBase:
                    Uri.parse('http://127.0.0.1:${bus.port}/api/agent-bus/v1'),
                loadAuthHeaders: () async =>
                    {'Authorization': 'Bearer fixture'});
            try {
              final bytes = await loader.read(
                  AttachmentPreviewTarget(url: source.url, name: 'result.txt'),
                  'text');
              expect(utf8.decode(bytes), 'generated file');
              expect(signatures, 1);
            } finally {
              loader.dispose();
              await bus.close(force: true);
              await storage.close(force: true);
            }
          }, _LoopbackHttpOverrides()));

  testWidgets(
      'images without extensions route to the chat scope and preserve download',
      (tester) async {
    AttachmentPreviewTarget? selected;
    await tester.pumpWidget(MaterialApp(
        home: AttachmentPreviewScope(
            open: (target) => selected = target,
            child: Builder(
                builder: (context) => TextButton(
                    onPressed: () {
                      expect(
                          tryOpenChatImagePreview(context,
                              rawUrl: '/message-files/id/download?token=sample',
                              displayName: '设计图'),
                          true);
                    },
                    child: const Text('图片'))))));
    await tester.tap(find.text('图片'));
    expect(selected!.url, '/message-files/id/preview?token=sample');
    expect(selected!.downloadUrl, '/message-files/id/download?token=sample');
    expect(
        attachmentPreviewFormat(selected!.name, selected!.url, selected!.mime),
        'image');
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      expect(
          tryOpenChatImagePreview(context,
              rawUrl: 'https://example.test/a.png'),
          false);
      return const SizedBox();
    })));
  });
  test(
      'authorized preview refreshes signatures without leaking bearer to storage',
      () => HttpOverrides.runWithHttpOverrides(() async {
            final bus = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            final storage =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            var signatures = 0;
            var downloads = 0;
            bus.listen((request) async {
              expect(
                  request.headers.value('authorization'), 'Bearer test-only');
              expect(request.uri.path,
                  '/api/agent-bus/v1/message-files/id/preview');
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode({
                'data': {
                  'url':
                      'http://127.0.0.1:${storage.port}/blob?signature=${++signatures}'
                }
              }));
              await request.response.close();
            });
            storage.listen((request) async {
              expect(request.headers.value('authorization'), isNull);
              downloads++;
              request.response.write('Hello');
              await request.response.close();
            });
            final loader = AttachmentPreviewLoader(
                apiBase:
                    Uri.parse('http://127.0.0.1:${bus.port}/api/agent-bus/v1'),
                loadAuthHeaders: () async =>
                    {'Authorization': 'Bearer test-only'});
            try {
              const target = AttachmentPreviewTarget(
                  url: '/message-files/id/preview', name: 'data.txt');
              for (var i = 0; i < 2; i++) {
                expect(utf8.decode(await loader.read(target, 'text')), 'Hello');
              }
              // A foreign absolute URL that resembles a protected API must stay public.
              await loader.read(
                  AttachmentPreviewTarget(
                      url:
                          'http://127.0.0.1:${storage.port}/message-files/foreign/preview',
                      name: 'data.txt'),
                  'text');
              expect(signatures, 2);
              expect(downloads, 3);
            } finally {
              loader.dispose();
              await bus.close(force: true);
              await storage.close(force: true);
            }
          }, _LoopbackHttpOverrides()));
  test('HTML subframes cannot navigate to remote or local resources', () {
    final viewer = Uri.file(
            r'C:\Program Files\知办AI\data\flutter_assets\assets\file_preview\viewer.html',
            windows: true)
        .toString();
    expect(
        isAllowedPreviewNavigation(viewer,
            isMainFrame: true, viewerFileUrl: viewer),
        true);
    expect(
        isAllowedPreviewNavigation(viewer,
            isMainFrame: false, viewerFileUrl: viewer),
        false);
    for (final denied in [
      'file:///C:/Users/test/private.txt',
      '$viewer?other=1',
      'https://evil.test/viewer.html'
    ]) {
      expect(
          isAllowedPreviewNavigation(denied,
              isMainFrame: true, viewerFileUrl: viewer),
          false);
    }
    expect(
        isAllowedPreviewNavigation('blob:https://preview.zhiban.invalid/id',
            isMainFrame: false),
        true);
    for (final url in [
      'https://evil.test',
      'file:///etc/passwd',
      'javascript:alert(1)'
    ]) {
      expect(isAllowedPreviewNavigation(url, isMainFrame: false), false);
    }
    expect(isAllowedPreviewNavigation('about:blank', isMainFrame: true), true);
    expect(
        isAllowedPreviewNavigation('https://preview.zhiban.invalid/',
            isMainFrame: true),
        true);
    expect(isAllowedPreviewNavigation('https://evil.test', isMainFrame: true),
        false);
  });
  test('friendly names use MIME; legacy Office stays unsupported', () {
    expect(
        attachmentPreviewFormat('报告', '/message-files/id/preview',
            'application/vnd.openxmlformats-officedocument.presentationml.presentation'),
        'pptx');
    expect(attachmentPreviewFormat('data.xlsx', 'https://a/f?token=x'), 'xlsx');
    expect(attachmentPreviewFormat('old.xls', 'https://a/f'), 'unsupported');
    expect(attachmentPreviewFormat('代码.py', 'https://a/f'), 'text');
    expect(attachmentPreviewFormat('图.svg', 'https://a/f'), 'image');
  });
  test('only matching scheme host and port is a trusted API origin', () {
    final base = Uri.parse('https://bus.example/api/agent-bus/v1');
    expect(
        isTrustedPreviewApi(
            Uri.parse('https://bus.example/message-files/a'), base),
        true);
    for (final url in [
      'https://evil.test/message-files/a',
      'http://bus.example/message-files/a',
      'https://bus.example:444/message-files/a'
    ]) {
      expect(isTrustedPreviewApi(Uri.parse(url), base), false);
    }
  });
  test('local preview reads bytes and enforces text limit before allocation',
      () async {
    final dir = await Directory.systemTemp.createTemp('preview-test-');
    final loader = AttachmentPreviewLoader();
    try {
      final file = File('${dir.path}/data.txt');
      await file.writeAsString('Hello');
      expect(
          await loader.read(
              AttachmentPreviewTarget(url: file.path, name: 'data.txt'),
              'text'),
          [72, 101, 108, 108, 111]);
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(2 * 1024 * 1024 + 1);
      await handle.close();
      await expectLater(
          loader.read(AttachmentPreviewTarget(url: file.path, name: 'data.txt'),
              'text'),
          throwsStateError);
    } finally {
      loader.dispose();
      await dir.delete(recursive: true);
    }
  });
  test('preview URI parsing preserves valid escapes and repairs bare percent',
      () {
    expect(tryParsePreviewUri('https://bus.example/a%20b.pptx')!.toString(),
        'https://bus.example/a%20b.pptx');
    expect(tryParsePreviewUri('https://bus.example/50%完成.pptx')!.toString(),
        'https://bus.example/50%25%E5%AE%8C%E6%88%90.pptx');
    expect(tryParsePreviewUri('https://bus.example/a%2Fb.pptx')!.toString(),
        'https://bus.example/a%2Fb.pptx');
  });
  test('local preview reads a filename containing a literal percent', () async {
    final dir = await Directory.systemTemp.createTemp('preview-percent-');
    final loader = AttachmentPreviewLoader();
    try {
      final file = File('${dir.path}/50%完成.pptx');
      await file.writeAsBytes([80, 75, 3, 4]);
      expect(
          await loader.read(
              AttachmentPreviewTarget(url: file.path, name: '50%完成.pptx'),
              'pptx'),
          [80, 75, 3, 4]);
    } finally {
      loader.dispose();
      await dir.delete(recursive: true);
    }
  });
  for (final width in [850.0, 1400.0]) {
    testWidgets(
        'preview opens/closes and preserves conversation at width $width',
        (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget app(String session) => MaterialApp(
          home: Scaffold(
              body: AttachmentPreviewHost(
                  sessionKey: session,
                  child: Builder(
                      builder: (context) => Center(
                          child: TextButton(
                              onPressed: () =>
                                  AttachmentPreviewScope.of(context)!.open(
                                      const AttachmentPreviewTarget(
                                          url: 'https://example.test/a.zip',
                                          name: '资料.zip')),
                              child: const Text('打开文件')))))));
      await tester.pumpWidget(app('one'));
      await tester.tap(find.text('打开文件'));
      await tester.pumpAndSettle();
      expect(find.text('资料.zip'), findsOneWidget);
      expect(find.textContaining('暂不支持'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final chatWidth = tester.getSize(find.byType(Center).first).width;
      expect(chatWidth, lessThan(width));
      expect(chatWidth, greaterThanOrEqualTo(400));
      expect(find.byKey(const ValueKey('attachment-preview-divider')),
          findsOneWidget);
      await tester.tap(find.byTooltip('展开预览'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('还原'), findsOneWidget);
      expect(tester.getSize(find.byType(Center).first).width, chatWidth);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('还原'));
      await tester.pumpAndSettle();
      expect(find.text('资料.zip'), findsOneWidget);
      expect(tester.getSize(find.byType(Center).first).width, chatWidth);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭预览'));
      await tester.pumpAndSettle();
      expect(find.text('资料.zip'), findsNothing);
      expect(find.text('打开文件'), findsOneWidget);
      await tester.tap(find.text('打开文件'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(app('two'));
      await tester.pumpAndSettle();
      expect(find.text('资料.zip'), findsNothing);
    });
  }
}
