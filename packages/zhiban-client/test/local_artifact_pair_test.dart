import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/emp/blocks/emp_blocks_view.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/chat_artifact_card.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/attachment_preview_target.dart';

void main() {
  const conversation = '22222222-2222-4222-8222-222222222222';
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Map<String, dynamic> file(String name,
          {String device = '44444444-4444-4444-8444-444444444444',
          String hash = 'a'}) =>
      {
        'type': 'image',
        'name': name,
        'mime': name.endsWith('.svg') ? 'image/svg+xml' : 'image/png',
        'local_artifact': {
          'artifact_id': '33333333-3333-4333-8333-333333333333',
          'device_id': device,
          'sha256': hash * 64
        },
      };
  Future<void> render(WidgetTester tester, List<Map<String, dynamic>> blocks,
      {void Function(AttachmentPreviewTarget)? open}) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: AttachmentPreviewScope(
                    open: open ?? (_) {},
                    child: EmpBlocksView(
                        conversationUuid: conversation, blocks: blocks))))));
    await tester.pump();
  }

  for (final reversed in [false, true]) {
    testWidgets(
        'design pair has one preview and independent source action, reversed=$reversed',
        (tester) async {
      final targets = <AttachmentPreviewTarget>[];
      final blocks = [file('宣传手册.svg'), file('宣传手册.png')];
      await render(tester, reversed ? blocks.reversed.toList() : blocks,
          open: targets.add);
      final cards = tester
          .widgetList<ChatArtifactCard>(find.byType(ChatArtifactCard))
          .toList();
      expect(cards, hasLength(2));
      expect(cards.where((c) => !c.compact), hasLength(1));
      expect(cards.first.target.name, '宣传手册.png');
      expect(cards.last.format, 'image');
      expect(find.textContaining('可编辑源文件'), findsOneWidget);
      await tester.tap(find.text('宣传手册.svg'));
      await tester.pump();
      await tester.tap(find.text('宣传手册.png'));
      await tester.pump();
      expect(targets.map((t) => t.name), ['宣传手册.svg', '宣传手册.png']);
      expect(targets.first.mime, 'image/svg+xml');
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'single, ambiguous and cross-device images keep independent previews',
      (tester) async {
    for (final blocks in [
      [file('宣传手册.svg')],
      [file('宣传手册.svg'), file('宣传手册.png'), file('宣传手册.png', hash: 'b')],
      [
        file('宣传手册.svg'),
        file('宣传手册.png', device: '55555555-5555-4555-8555-555555555555')
      ],
    ]) {
      await render(tester, blocks);
      expect(
          tester
              .widgetList<ChatArtifactCard>(find.byType(ChatArtifactCard))
              .every((c) => !c.compact),
          isTrue);
      expect(tester.takeException(), isNull);
    }
  });
}
