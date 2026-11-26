import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_skill_preview.dart';

void main() {
  testWidgets('技能预览在目录、翻节和缩放间保持当前章节，并能下载', (tester) async {
    var downloads = 0;
    await tester.pumpWidget(MaterialApp(
      home: CreatorSkillPreview(
        title: '试点核验',
        content: '# 试点核验\n\n## 输入\n\n客户访谈记录\n\n'
            '## 操作步骤\n\n复核近期记录\n\n## 来源\n\n证据 1',
        onDownload: () => downloads++,
      ),
    ));
    IconButton navigation(String label) =>
        tester.widget<IconButton>(find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == label));

    expect(navigation('上一节').onPressed, isNull);
    await tester.tap(find.widgetWithText(ListTile, '操作步骤'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.text('复核近期记录'), findsOneWidget);
    await tester.tap(find.byTooltip('放大'));
    await tester.pumpAndSettle();
    expect(find.text('125%'), findsOneWidget);
    expect(find.text('复核近期记录'), findsOneWidget);
    await tester.tap(find.byTooltip('下一节'));
    await tester.pumpAndSettle();
    expect(find.text('证据 1'), findsOneWidget);
    expect(navigation('下一节').onPressed, isNull);
    await tester.tap(find.byTooltip('上一节'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    await tester.tap(find.text('下载技能'));
    expect(downloads, 1);
  });

  testWidgets('缺少已知标题的旧技能仍可预览完整内容', (tester) async {
    const text = '# 旧技能\n\n手工核对原记录';
    await tester.pumpWidget(MaterialApp(
      home: CreatorSkillPreview(
        title: '旧技能',
        content: text,
        onDownload: () {},
      ),
    ));
    expect(find.text('全文'), findsOneWidget);
    expect(find.text(text), findsOneWidget);
  });
}
