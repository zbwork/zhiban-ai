import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name} tabs have no rectangular press highlight',
        (tester) async {
      var current = 0;
      const captureKey = ValueKey('tabs-feedback-capture');
      await tester.pumpWidget(MaterialApp(
        theme:
            brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
        home: Scaffold(
          body: StatefulBuilder(builder: (context, setState) {
            return RepaintBoundary(
              key: captureKey,
              child: SizedBox(
                width: 390,
                child: UiSlantedTabs<int>(
                  tabs: const [
                    UiSlantedTab(value: 0, label: '全部'),
                    UiSlantedTab(value: 1, label: '我创建的'),
                    UiSlantedTab(value: 2, label: '组织创建'),
                  ],
                  current: current,
                  onChanged: (value) => setState(() => current = value),
                ),
              ),
            );
          }),
        ),
      ));
      await tester.pumpAndSettle();

      Future<List<int>> pixels() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(captureKey),
        );
        return (await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          return bytes!.buffer.asUint8List();
        }))!;
      }

      final resting = await pixels();
      final touch =
          await tester.startGesture(tester.getCenter(find.text('我创建的')));
      await tester.pumpAndSettle();
      expect(current, 0);
      expect(listEquals(await pixels(), resting), isTrue,
          reason:
              'Holding a tab must not paint a rectangle over its gradient.');
      await touch.up();
      await tester.pumpAndSettle();
      expect(current, 1);

      final unfocused = await pixels();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(listEquals(await pixels(), unfocused), isFalse,
          reason: 'Keyboard focus must remain visible.');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(current, 0);
    });
  }

  testWidgets('supports two controlled tabs and reports the tapped value',
      (tester) async {
    var current = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            return Scaffold(
              body: SizedBox(
                width: 320,
                child: UiSlantedTabs<int>(
                  tabs: const [
                    UiSlantedTab(value: 0, label: '技能广场'),
                    UiSlantedTab(value: 1, label: '我的技能'),
                  ],
                  current: current,
                  onChanged: (value) => setState(() => current = value),
                ),
              ),
            );
          },
        ),
      ),
    );

    expect(find.text('技能广场'), findsOneWidget);
    expect(find.text('我的技能'), findsOneWidget);
    expect(tester.getCenter(find.text('技能广场')).dx, 66);

    await tester.tap(find.text('我的技能'));
    await tester.pumpAndSettle();

    expect(current, 1);
    expect(tester.getCenter(find.text('我的技能')).dx, 254);
    final selection = tester.widget<AnimatedPositioned>(
      find.byKey(const ValueKey('ui-slanted-tabs-selection')),
    );
    expect(selection.left, 148);
    expect(selection.width, 172);
  });

  testWidgets('keeps more than three tabs equally wide and fully tappable',
      (tester) async {
    var tapped = -1;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: UiSlantedTabs<int>(
              tabs: const [
                UiSlantedTab(value: 0, label: '全部'),
                UiSlantedTab(value: 1, label: '我创建的'),
                UiSlantedTab(value: 2, label: '组织创建'),
                UiSlantedTab(value: 3, label: '其他'),
              ],
              current: 0,
              onChanged: (value) => tapped = value,
            ),
          ),
        ),
      ),
    );

    final hitTargets = tester.widgetList<InkWell>(find.byType(InkWell));
    expect(hitTargets, hasLength(4));
    for (final target in find.byType(InkWell).evaluate()) {
      expect(tester.getSize(find.byElementPredicate((e) => e == target)),
          const Size(100, 70));
    }

    await tester.tapAt(const Offset(350, 60));
    expect(tapped, 3);
  });

}
