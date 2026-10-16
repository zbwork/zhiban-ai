import 'package:flutter/material.dart';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/emp/blocks/emp_blocks_view.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/chat_artifact_card.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/chat_artifact_download.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/local_artifact_source.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const conversation = '22222222-2222-4222-8222-222222222222';
  final ref = {
    'artifact_id': '33333333-3333-4333-8333-333333333333',
    'device_id': '44444444-4444-4444-8444-444444444444',
    'sha256': 'a' * 64
  };
  const formats = {
    '报告.docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    '报表.xlsx':
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    '演示.pptx':
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    '说明.md': 'text/markdown',
    '图片.png': 'image/png',
    '视频.mp4': 'video/mp4'
  };
  testWidgets('local cards suppress only matching sandbox download links',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: EmpBlocksView(conversationUuid: conversation, blocks: [
      {
        'type': 'markdown',
        'text': '[重复入口](sandbox:/mnt/data/report.md)\n\n'
            '[缺少附件](sandbox:/mnt/data/missing.md)\n\n'
            '[参考网页](https://example.test/report.md)',
      },
      {
        'type': 'file',
        'name': 'report.md',
        'mime': 'text/markdown',
        'local_artifact': ref,
      },
    ]))));
    expect(find.textContaining('重复入口'), findsNothing);
    expect(find.textContaining('缺少附件'), findsOneWidget);
    expect(find.textContaining('参考网页'), findsOneWidget);
    expect(find.byType(ChatArtifactCard), findsOneWidget);
  });
  for (final format in formats.entries) {
    testWidgets('cloud ${format.key} refreshes expired signed URLs by file ID',
        (tester) async {
      const id = '55555555-5555-4555-8555-555555555555';
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: EmpBlocksView(blocks: [
        {
          'type': 'file',
          'name': format.key,
          'mime': format.value,
          'file_id': id,
          'preview_url': 'https://expired.test/old?Signature=expired',
          'download_url': 'https://expired.test/old?Signature=expired',
        }
      ]))));
      final card =
          tester.widget<ChatArtifactCard>(find.byType(ChatArtifactCard));
      expect(Uri.parse(card.target.url).path,
          '/api/agent-bus/v1/drive/files/$id/preview');
      expect(Uri.parse(card.target.downloadUrl!).path,
          '/api/agent-bus/v1/drive/files/$id/download');
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
    testWidgets(
        'cloud/local ${format.key} share cards, actions and preview host',
        (tester) async {
      final targets = <AttachmentPreviewTarget>[];
      final blocks = [
        {
          'type': 'file',
          'name': format.key,
          'mime': format.value,
          'url': 'https://example.test/${format.key}',
          'size': 42
        },
        {
          'type': 'file',
          'name': format.key,
          'mime': format.value,
          'local_artifact': ref,
          'size': 42,
          'archive_status': 'synced',
          'drive_file_id': '55555555-5555-4555-8555-555555555555'
        },
      ];
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: AttachmentPreviewScope(
                      open: targets.add,
                      child: EmpBlocksView(
                          blocks: blocks, conversationUuid: conversation))))));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(find.byType(ChatArtifactCard), findsNWidgets(2));
      expect(find.byTooltip('下载'), findsNWidgets(2));
      expect(find.text('在文件夹中显示'), findsNothing);
      final names = find.text(format.key);
      await tester.ensureVisible(names.first);
      await tester.tap(names.first);
      await tester.pump();
      await tester.ensureVisible(names.last);
      await tester.tap(names.last);
      await tester.pump();
      expect(targets, hasLength(2));
      expect(targets.map((e) => e.mime), everyElement(format.value));
      expect(LocalArtifactSource.parse(targets.last.url), isNotNull);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  for (final brightness in Brightness.values) {
    testWidgets('narrow large-text cards preserve actions in $brightness',
        (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
              child: const Scaffold(
                  body: ChatArtifactCard(
                      target: AttachmentPreviewTarget(
                          url: 'https://example.test/report.xlsx',
                          name: '很长的季度销售明细与汇总数据报告.xlsx'),
                      sizeText: '25 MB')))));
      await tester.pumpAndSettle();
      expect(find.byTooltip('预览'), findsOneWidget);
      expect(find.byTooltip('下载'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'compact group deduplicates republished snapshots, keeps versions and actions',
      (tester) async {
    final oldDevice = LocalAgentService.instance.deviceId;
    LocalAgentService.instance.deviceId = ref['device_id']!;
    addTearDown(() => LocalAgentService.instance.deviceId = oldDevice);
    final files = List.generate(
        4,
        (i) => <String, dynamic>{
              'type': 'file',
              'name': '采购文件$i.docx',
              'mime': formats['报告.docx'],
              'local_artifact': {
                ...ref,
                'artifact_id': '33333333-3333-4333-8333-33333333333$i'
              },
              'archive_status': 'synced',
              'drive_file_id': '55555555-5555-4555-8555-55555555555$i',
            });
    final republished = {
      ...files.first,
      'local_artifact': {
        ...ref,
        'artifact_id': '66666666-6666-4666-8666-666666666666'
      }
    };
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: EmpBlocksView(
                blocks: [...files, republished],
                conversationUuid: conversation))));
    expect(find.byType(ChatArtifactGroup), findsOneWidget);
    expect(find.byType(ChatArtifactCard), findsNWidgets(4));
    expect(find.text('附件'), findsNothing);
    expect(find.text('已归档云盘'), findsOneWidget);
    expect(find.byTooltip('在文件夹中显示'), findsNWidgets(4));
    expect(
        tester.getSize(find.byType(ChatArtifactGroup)).height, lessThan(330));
    expect(
        tester
            .getSize(find.byKey(const ValueKey('chat-artifact-card')).first)
            .width,
        lessThanOrEqualTo(560));
    final newer = {
      ...files.first,
      'local_artifact': {...ref, 'sha256': 'b' * 64}
    };
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: EmpBlocksView(
                    blocks: [files.first, republished, newer],
                    conversationUuid: conversation)))));
    expect(find.byType(ChatArtifactCard), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'preview selection highlights only the active file and clears on close',
      (tester) async {
    String? selected;
    late StateSetter update;
    await tester.pumpWidget(
        MaterialApp(home: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return Scaffold(
          body: AttachmentPreviewScope(
              selectedUrl: selected,
              open: (target) => setState(() => selected = target.url),
              child: EmpBlocksView(blocks: const [
                {
                  'type': 'file',
                  'name': 'A.docx',
                  'url': 'https://example.test/a.docx'
                },
                {
                  'type': 'file',
                  'name': 'B.docx',
                  'url': 'https://example.test/b.docx'
                },
              ])));
    })));
    await tester.tap(find.text('A.docx'));
    await tester.pump();
    final colors = find
        .byKey(const ValueKey('chat-artifact-card'))
        .evaluate()
        .map((e) => (e.widget as Container).color)
        .toList();
    expect(colors.first, isNot(colors.last));
    update(() => selected = null);
    await tester.pump();
    final cleared = find
        .byKey(const ValueKey('chat-artifact-card'))
        .evaluate()
        .map((e) => (e.widget as Container).color)
        .toSet();
    expect(cleared, hasLength(1));
  });

  test('download retains local snapshot identity and cloud original URL', () {
    const local = AttachmentPreviewTarget(
        url: 'local-artifact://opaque-reference',
        name: 'snapshot.png',
        downloadUrl: 'https://example.test/changed.png');
    expect(artifactDownloadTarget(local).url, local.url);
    const cloud = AttachmentPreviewTarget(
        url: 'https://example.test/thumbnail.png',
        name: 'original.png',
        downloadUrl: 'https://example.test/original.png');
    expect(artifactDownloadTarget(cloud).url, cloud.downloadUrl);
  });
  test('video MIME/extensions and outbound link schemes are explicit', () {
    for (final name in ['movie.mp4', 'clip.webm', 'recording.MOV']) {
      expect(attachmentPreviewFormat(name, ''), 'video');
    }
    expect(attachmentPreviewFormat('movie', '', 'video/mp4'), 'video');
    expect(attachmentPreviewFormat('unknown.bin', ''), 'unsupported');
    expect(isAllowedPreviewLink('https://example.com/report?q=1'), true);
    for (final link in [
      'file:///etc/passwd',
      'javascript:alert(1)',
      '../secret',
      // Synthetic userinfo must still be rejected by the preview policy.
      'https://' 'user:secret@example.com/'
    ]) {
      expect(isAllowedPreviewLink(link), false);
    }
  });
}
