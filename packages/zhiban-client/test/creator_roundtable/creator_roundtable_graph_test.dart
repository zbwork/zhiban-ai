import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/creator_roundtable/creator_roundtable_graph.dart';

void main() {
  testWidgets('点击前置连线只回到支持先后顺序的那一段', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final opened = <Object?>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CreatorRoundtableGraph(
      experts: [
        {
          'id': 'creator',
          'name': '博主',
          'version': 1,
          'content': jsonEncode({
            'methods': [
              {
                'id': 'before',
                'problem': '核对实际发票',
                'steps': [
                  {
                    'evidence_ids': ['ordered', 'support']
                  }
                ]
              },
              {
                'id': 'after',
                'problem': '确认审批人',
                'steps': [
                  {
                    'evidence_ids': ['ordered']
                  }
                ]
              },
            ],
            'graph_precedence': [
              {
                'before': 'before',
                'after': 'after',
                'source_id': 'ordered',
                'before_quote': '核对实际发票',
                'after_quote': '确认审批人'
              },
            ],
          }),
          'evidence': jsonEncode([
            {'id': 'ordered', 'work_id': 'first', 'text': '先核对实际发票，再确认审批人。'},
            {'id': 'support', 'work_id': 'second', 'text': '录入发票的独立证据。'},
          ]),
        }
      ],
      onOpenWork: (_, evidence) => opened.add(evidence['id']),
    ))));
    await tester.pumpAndSettle();
    final first = tester.getRect(find.widgetWithText(FilterChip, '核对实际发票'));
    final second = tester.getRect(find.widgetWithText(FilterChip, '确认审批人'));
    await tester.tapAt(
        Offset(first.left - 14, (first.center.dy + second.center.dy) / 2));
    await tester.pumpAndSettle();
    expect(find.text('前置关系 · 原文顺序'), findsOneWidget);
    expect(find.text('先核对实际发票，再确认审批人。'), findsOneWidget);
    expect(find.text('录入发票的独立证据。'), findsNothing);
    await tester.tap(find.text('查看归档作品'));
    expect(opened, ['ordered']);
  });

  testWidgets('同一主题的两份作品回跳到各自博主', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CreatorRoundtableGraph(
          experts: [
            for (final id in ['甲', '乙'])
              {
                'id': id,
                'name': '博主$id',
                'version': 1,
                'content': jsonEncode({
                  'methods': [
                    {
                      'id': '方法$id',
                      'problem': '核实预算$id',
                      'applies_when': '已取得$id方书面预算',
                      'limits': '只适用$id方的预算审批',
                      'steps': [
                        {
                          'evidence_ids': ['来源$id']
                        }
                      ],
                    },
                  ],
                  'graph_topics': [
                    {
                      'id': 'shared',
                      'title': '付费验证',
                      'meaning': '验证预算',
                      'method_id': '方法$id',
                      'fingerprint': id,
                      'evidence_ids': ['来源$id'],
                    },
                  ],
                }),
                'evidence': jsonEncode([
                  {'id': '来源$id', 'work_id': '作品$id', 'text': '原文$id'},
                ]),
              },
          ],
          onOpenWork: (creatorId, source) =>
              opened.add('$creatorId/${source['work_id']}'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('博主甲 · v1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部博主').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '付费验证'));
    await tester.pumpAndSettle();
    expect(find.text('关联作品 · 2'), findsOneWidget);
    final method = find.widgetWithText(FilterChip, '核实预算甲');
    final condition = find.widgetWithText(FilterChip, '适用条件 · 已取得甲方书面预算');
    expect(find.widgetWithText(FilterChip, '适用条件 · 已取得乙方书面预算'), findsOneWidget);
    final sourceBox = tester.getRect(method);
    final targetBox = tester.getRect(condition);
    final otherMethod =
        tester.getRect(find.widgetWithText(FilterChip, '核实预算乙'));
    final otherCondition =
        tester.getRect(find.widgetWithText(FilterChip, '适用条件 · 已取得乙方书面预算'));
    final limit = tester.getRect(find.text('边界 · 只适用甲方的预算审批'));
    final otherLimit = tester.getRect(find.text('边界 · 只适用乙方的预算审批'));
    expect(sourceBox.center.dy, (targetBox.center.dy + limit.center.dy) / 2);
    expect(otherMethod.center.dy,
        (otherCondition.center.dy + otherLimit.center.dy) / 2);
    expect(limit.bottom, lessThan(otherCondition.top));

    final work = tester.getRect(find.widgetWithText(FilterChip, '作品 1'));
    final canvas = tester.getRect(find.byType(InteractiveViewer));
    final citationRoute =
        Offset((sourceBox.right + work.left) / 2, canvas.top + 12);
    await tester.tapAt(citationRoute);
    await tester.pumpAndSettle();
    expect(find.text('关联作品 · 2'), findsOneWidget);
    await tester.tap(method);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(method).selected, isTrue);
    await tester.tapAt(citationRoute);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(method).selected, isFalse);
    expect(find.text('原文甲'), findsOneWidget);
    await tester.tapAt(Offset((sourceBox.right + targetBox.left) / 2,
        (sourceBox.center.dy + targetBox.center.dy) / 2));
    await tester.pumpAndSettle();
    expect(find.text('关联作品 · 1'), findsOneWidget);
    expect(find.text('原文甲'), findsOneWidget);
    await tester.tap(condition);
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看归档作品'));
    await tester.pumpAndSettle();
    for (final work in ['作品 1', '作品 2']) {
      await tester.tap(find.widgetWithText(FilterChip, work));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看归档作品'));
      await tester.pumpAndSettle();
    }
    expect(opened, ['甲/作品甲', '甲/作品甲', '乙/作品乙']);
  });

  testWidgets('图谱的方法和作品节点打开同一个真实证据', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CreatorRoundtableGraph(
      experts: [
        {
          'id': 'author',
          'name': '验收专家',
          'version': 1,
          'evidence': jsonEncode([
            {
              'id': 'source',
              'work_id': 'work',
              'start_ms': 0,
              'text': '核对支出发票',
              'url': 'https://www.douyin.com/video/1234567890123456789',
            },
            {
              'id': 'source-2',
              'work_id': 'work-2',
              'image_number': 2,
              'text': '验收第二批样本',
              'url': 'https://www.douyin.com/note/1234567890123456790',
            },
          ]),
          'content': jsonEncode({
            'methods': [
              {
                'id': 'method',
                'problem': '确认预算',
                'steps': [
                  {
                    'action': '查发票',
                    'evidence_ids': ['source']
                  },
                ]
              },
              {
                'id': 'method-2',
                'problem': '确定验收范围',
                'applies_when': '有试点交付',
                'steps': [
                  {
                    'action': '检查样本',
                    'evidence_ids': ['source-2']
                  },
                ],
              },
            ]
          }),
        }
      ],
    ))));
    await tester.pumpAndSettle();
    for (final node in ['确认预算', '作品 1']) {
      await tester.tap(find.text(node));
      await tester.pumpAndSettle();
      expect(find.text('核对支出发票'), findsOneWidget);
      expect(find.text('打开原作品'), findsOneWidget);
    }
    final modeTabs = find.byType(TabBar);
    expect(tester.widget<TabBar>(modeTabs).controller!.index, 0);
    final worksCard = find.byKey(const ValueKey('roundtable-related-works'));
    expect(tester.widget<Material>(worksCard).clipBehavior, Clip.antiAlias);
    await tester.tap(find.text('散点'));
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(modeTabs).controller!.index, 1);
    final chips = find.byType(FilterChip);
    final boxes = List.generate(
        chips.evaluate().length, (index) => tester.getRect(chips.at(index)));
    for (final (index, box) in boxes.indexed) {
      expect(box.height, 48);
      expect(boxes.skip(index + 1).any(box.overlaps), isFalse);
    }
    expect(find.text('核对支出发票'), findsOneWidget);
    await tester.tap(find.byTooltip('放大图谱'));
    await tester.pumpAndSettle();
    expect(find.text('125%'), findsOneWidget);
    final transform = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    final viewportBefore = transform.value.storage.toList();
    await tester.tap(find.text('关联作品 · 1'));
    await tester.pumpAndSettle();
    expect(find.text('核对支出发票'), findsNothing);
    await tester.tap(find.byTooltip('全屏知识图谱'));
    await tester.pumpAndSettle();
    final full = find.byType(Dialog);
    final fullTabs = find.descendant(of: full, matching: modeTabs);
    expect(tester.widget<TabBar>(fullTabs).controller!.index, 1);
    expect(
        find.descendant(of: full, matching: find.text('125%')), findsOneWidget);
    await tester
        .tap(find.descendant(of: full, matching: find.text('关联作品 · 1')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: full, matching: find.text('核对支出发票')),
      findsOneWidget,
    );
    await tester
        .tap(find.descendant(of: full, matching: find.byType(BackButton)));
    await tester.pumpAndSettle();
    expect(find.text('核对支出发票'), findsOneWidget);
    expect(find.text('125%'), findsOneWidget);
    expect(transform.value.storage, viewportBefore);
    await tester.tap(find.byTooltip('全屏知识图谱'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(full, findsNothing);
    expect(find.text('核对支出发票'), findsOneWidget);
    await tester.tap(find.byTooltip('复位图谱'));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);
    await tester.tap(find.text('网络'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '试点交付');
    await tester.pumpAndSettle();
    expect(find.text('确认预算'), findsNothing);
    expect(find.text('确定验收范围'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选作品'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('作品 1').first);
    await tester.pumpAndSettle();
    expect(find.text('没有符合筛选条件的内容'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选作品'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部作品').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定验收范围'));
    await tester.pumpAndSettle();
    expect(find.text('第 2 张图片'), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(700, 600));
    await tester.pumpAndSettle();
    expect(find.text('第 2 张图片'), findsOneWidget);
    await tester.tap(find.text('关联作品 · 1'));
    await tester.pumpAndSettle();
    expect(find.text('第 2 张图片'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
