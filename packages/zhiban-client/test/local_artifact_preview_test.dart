import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/emp/blocks/emp_blocks_view.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/local_artifact_source.dart';

void main() {
  const conversation = '22222222-2222-4222-8222-222222222222';
  final block = <String, dynamic>{
    'type': 'file',
    'name': '本机报告.docx',
    'mime':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'size': 20,
    'local_artifact': {
      'artifact_id': '33333333-3333-4333-8333-333333333333',
      'device_id': '44444444-4444-4444-8444-444444444444',
      'sha256': 'a' * 64
    }
  };
  test(
      'opaque source round trips with conversation scope and rejects file paths',
      () {
    final source = LocalArtifactSource.fromBlock(block, conversation)!;
    expect(
        LocalArtifactSource.parse(source.url)!.toRequest(), source.toRequest());
    expect(LocalArtifactSource.parse('file:///Users/example/private.docx'),
        isNull);
    expect(LocalArtifactSource.parse('${source.url}&path=/etc/passwd'), isNull);
    expect(LocalArtifactSource.fromBlock(block, '../other'), isNull);
  });
  testWidgets(
      'local file cards use the existing desktop AttachmentPreviewScope',
      (tester) async {
    AttachmentPreviewTarget? target;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AttachmentPreviewScope(
                open: (value) => target = value,
                child: EmpBlocksView(
                    blocks: [block], conversationUuid: conversation)))));
    await tester.tap(find.text('本机报告.docx'));
    await tester.pump();
    expect(target, isNotNull);
    expect(target!.name, '本机报告.docx');
    expect(
        LocalArtifactSource.parse(target!.url)!.conversationId, conversation);
    expect(find.byType(Dialog), findsNothing);
  });
  testWidgets('local deliverables show archive status without upload controls',
      (tester) async {
    final second = {
      ...block,
      'name': '验收表.xlsx',
      'archive_status': 'failed',
      'local_artifact': {
        ...block['local_artifact'] as Map,
        'artifact_id': '55555555-5555-4555-8555-555555555555'
      }
    };
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: EmpBlocksView(blocks: [
      {...block, 'archive_status': 'synced'},
      second
    ], conversationUuid: conversation))));
    expect(find.byTooltip('预览'), findsNWidgets(2));
    expect(find.byTooltip('下载'), findsNWidgets(2));
    expect(find.text('上传到我的云盘'), findsNothing);
    expect(find.text('同步到云盘'), findsNothing);
    expect(find.text('确认上传'), findsNothing);
    expect(find.textContaining('已归档云盘'), findsOneWidget);
    expect(find.textContaining('云盘归档未完成'), findsOneWidget);
  });
}
