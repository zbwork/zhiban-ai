import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/local_approval_card.dart';

void main() {
  testWidgets(
      'home search approval states metadata scope and keeps three choices',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LocalApprovalCard(
      request: const {
        'intent': {
          'tool': 'search_files',
          'operation': 'read',
          'args': {'scope': 'home', 'path': ''}
        }
      },
      onAnswer: (_, __) async {},
    ))));
    expect(find.text('检索本机文件'), findsOneWidget);
    expect(find.text('用户主目录'), findsOneWidget);
    expect(find.text('只检索文件名和数量，不读取文件内容。'), findsOneWidget);
    expect(find.text('查看工作目录外的文件内容'), findsNothing);
    for (final label in ['允许本次', '本次任务允许', '拒绝']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets(
      'computer approval shows the actual app and text before executing',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LocalApprovalCard(
      request: const {
        'intent': {
          'tool': 'computer',
          'operation': 'desktop',
          'args': {
            'action': 'type_text',
            'app': 'Notion',
            'element': 12,
            'text': '测试内容',
          }
        }
      },
      onAnswer: (approved, scope) async {
        if (approved && scope == 'once') calls++;
      },
    ))));
    expect(find.text('填写文本'), findsOneWidget);
    expect(find.textContaining('Notion\n输入：测试内容\n控件：12'), findsOneWidget);
    expect(calls, 0);
    await tester.tap(find.text('允许本次'));
    await tester.pump();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });
}
