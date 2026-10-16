import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_ai_generated.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_im_history_panel.dart';
import 'package:zhiban_ui/widgets/ui_ai_generated_label.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_detail_dialog.dart';

ImMessage message({
  String uid = 't_tenant_a_employee',
  String text = '生成结果',
  bool revoked = false,
  String status = '',
  List<Map<String, dynamic>> blocks = const [],
}) =>
    ImMessage(
      messageId: uid,
      clientMsgNo: uid,
      fromUid: uid,
      channelId: 'group',
      channelType: 2,
      timestamp: 1,
      text: text,
      empBlocks: blocks,
      isRevoked: revoked,
      agentMessageStatus: status,
    );

void main() {
  test('IM footer waits for terminal content', () {
    for (final status in ['streaming', 'pending', 'failed']) {
      expect(isAiGeneratedImContent(message(status: status)), isFalse);
    }
    for (final status in ['final', 'completed', 'awaiting_user', 'cancelled']) {
      expect(isAiGeneratedImContent(message(status: status)), isTrue);
    }
  });
  for (final status in ['failed', 'awaiting_user']) {
    testWidgets('IM $status footer follows payload semantics in history',
        (tester) async {
      final text = status == 'failed' ? '数字员工暂时无法回复，请稍后再试。' : '请确认申请';
      final reply = message(status: status, text: text, blocks: [
        {'type': 'markdown', 'text': text},
      ]);
      final expected = status == 'awaiting_user';
      expect(isAiGeneratedImContent(reply, senderKind: 'agent'), expected);
      expect(isAiGeneratedImContent(reply), expected);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatImHistoryPanel(
            messages: [reply],
            selfUid: 'me',
            resolveSenderName: (_) => '数字员工',
            onClose: () {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('AI 生成'), expected ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  for (final example in ['', '示例结果']) {
    testWidgets('desktop skill footer follows actual example: $example',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
        body: SkillDetailDialog(
            skill: Skill.fromJson({
          'skill_uuid': 'sample',
          'code': 'sample',
          'name': '示例技能',
          'usage_example': example,
        })),
      )));
      await tester.pumpAndSettle();
      expect(
          find.text('AI 生成'), example.isEmpty ? findsNothing : findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('agent provenance survives membership removal, excludes human/system',
      () {
    expect(isAiGeneratedImContent(message()), isTrue);
    expect(isAiGeneratedImContent(message(uid: 'custom'), senderKind: 'agent'),
        isTrue);
    expect(isAiGeneratedImContent(message(uid: 't_tenant_u_human')), isFalse);
    expect(isAiGeneratedImContent(message(revoked: true)), isFalse);
    expect(isAiGeneratedImContent(message(text: '')), isFalse);
    expect(isAiGeneratedImContent(message(), senderKind: 'human'), isFalse);
    expect(
        isAiGeneratedImContent(message(text: '', blocks: [
          {
            'type': 'file',
            'name': '报告.pdf',
            'url': 'https://example.com/report.pdf'
          },
        ])),
        isTrue);
  });

  testWidgets('history marks only employee content after its body',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: ChatImHistoryPanel(
        messages: [message(), message(uid: 't_tenant_u_human', text: '用户原文')],
        selfUid: 'me',
        resolveSenderName: (_) => '发送人',
        onClose: () {},
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('AI 生成'), findsOneWidget);
    expect(tester.getTopLeft(find.text('AI 生成')).dy,
        greaterThan(tester.getTopLeft(find.text('生成结果')).dy));
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('footer readable in $brightness and scaled narrow layout',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
            body: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const SizedBox(width: 120, child: UiAiGeneratedLabel()),
        )),
      ));
      expect(find.bySemanticsLabel('AI 生成'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }
}
