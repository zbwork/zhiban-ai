import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_ui/widgets/ui_select.dart';

void main() {
  test('all ZAP environments are professional regardless of vendor or metadata',
      () {
    RuntimeEnvironmentOption option(
            String framework, Map<String, dynamic> metadata) =>
        RuntimeEnvironmentOption.fromJson({
          'UUID': 'id',
          'Name': '示例助手',
          'Framework': framework,
          'Metadata': metadata
        });
    for (final metadata in <Map<String, dynamic>>[
      {},
      {'vendor': 'agent-example/zhiban'},
      {'vendor': 'zhiban/dsh'},
      {'agent_category': 'general'},
      {'runtime_card': 'bad'}
    ]) {
      expect(option(' ZAP ', metadata).agentGroup, '职业模板');
      expect(option('zap', metadata).agentTypeLabel, '示例助手');
    }
    for (final framework in ['openclaw', 'hermes', 'dsh']) {
      expect(
          option(framework, {'vendor': 'fia', 'agent_category': 'professional'})
              .agentGroup,
          '通用智能体');
    }
  });

  for (final dark in [false, true]) {
    testWidgets(
        'tabbed select browsing, search, selection and scroll stay usable ($dark)',
        (tester) async {
      tester.view.physicalSize = const Size(460, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      String? selected = 'hermes';
      await tester.pumpWidget(MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: Scaffold(
              body: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 32, 12, 0),
                    child: StatefulBuilder(
                        builder: (context, setState) => UiSelect<String>(
                              menuMaxHeight: 390,
                              groupTabs: const ['通用智能体', '职业模板'],
                              value: selected,
                              options: [
                                const UiSelectOption(
                                    value: 'openclaw',
                                    label: 'OpenClaw',
                                    group: '通用智能体',
                                    description: '环境一',
                                    icon: CupertinoIcons.cube),
                                const UiSelectOption(
                                    value: 'hermes',
                                    label: 'Hermes',
                                    group: '通用智能体',
                                    icon: CupertinoIcons.person_crop_square),
                                const UiSelectOption(
                                    value: 'dsh',
                                    label: 'DSH',
                                    group: '通用智能体',
                                    icon: CupertinoIcons.sparkles),
                                for (var i = 0; i < 12; i++)
                                  UiSelectOption(
                                      value: 'role$i',
                                      label: '职业$i',
                                      group: '职业模板',
                                      description: '业务说明$i',
                                      icon: CupertinoIcons.briefcase),
                              ],
                              onChanged: (value) =>
                                  setState(() => selected = value),
                            )),
                  )))));
      final fieldRect = tester.getRect(find.byType(UiSelect<String>));
      final arrowRect =
          tester.getRect(find.byIcon(Icons.keyboard_arrow_down_rounded));
      expect(fieldRect.right - arrowRect.right, closeTo(14, 1));
      expect(find.text('通用智能体'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.person_crop_square), findsOneWidget);
      await tester.tap(find.text('Hermes'));
      await tester.pumpAndSettle();
      expect(find.text('通用智能体'), findsNWidgets(2));
      expect(find.text('职业模板'), findsOneWidget);
      expect(find.text('环境一'), findsOneWidget);
      expect(tester.widget<Text>(find.text('环境一')).style?.decoration,
          TextDecoration.none);
      await tester.tap(find.text('职业模板'));
      await tester.pumpAndSettle();
      expect(selected, 'hermes');
      expect(find.text('环境一'), findsNothing);
      expect(find.text('职业0'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '业务说明11');
      await tester.pumpAndSettle();
      expect(find.text('职业11'), findsOneWidget);
      expect(find.text('职业0'), findsNothing);
      expect(selected, 'hermes');
      await tester.enterText(find.byType(TextField), '不存在');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的 Agent 类型'), findsOneWidget);
      await tester.tap(find.text('通用智能体').last);
      await tester.pumpAndSettle();
      expect(find.text('环境一'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      await tester.tap(find.text('职业模板'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('职业11'), 150,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text('职业11'));
      await tester.pumpAndSettle();
      expect(selected, 'role11');
      expect(find.text('职业模板'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.briefcase), findsOneWidget);
      await tester.tap(find.text('职业11'));
      await tester.pumpAndSettle();
      expect(find.text('职业11').hitTestable(), findsNWidgets(2));
      await tester.tapAt(const Offset(4, 600));
      await tester.pumpAndSettle();
      expect(find.text('职业11'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty tab keeps value and Escape from search closes menu',
      (tester) async {
    String? selected = 'hermes';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 300,
                    child: UiSelect<String>(
                        value: selected,
                        groupTabs: const ['通用智能体', '职业模板'],
                        options: const [
                          UiSelectOption(
                              value: 'hermes', label: 'Hermes', group: '通用智能体')
                        ],
                        onChanged: (value) => selected = value))))));
    await tester.tap(find.text('Hermes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('职业模板'));
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的 Agent 类型'), findsOneWidget);
    expect(selected, 'hermes');
    await tester.enterText(find.byType(TextField), 'test');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(selected, 'hermes');
    expect(tester.takeException(), isNull);
  });

  testWidgets('plain select keeps original ungrouped content and selection',
      (tester) async {
    String? selected;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 280,
                    child: StatefulBuilder(
                      builder: (context, setState) => UiSelect<String>(
                          value: selected,
                          options: const [
                            UiSelectOption(value: 'a', label: '第一项'),
                            UiSelectOption(value: 'b', label: '第二项')
                          ],
                          onChanged: (value) =>
                              setState(() => selected = value)),
                    ))))));
    await tester.tap(find.text('请选择'));
    await tester.pumpAndSettle();
    expect(find.text('通用智能体'), findsNothing);
    await tester.tap(find.text('第二项'));
    await tester.pumpAndSettle();
    expect(selected, 'b');
    expect(find.text('第二项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
