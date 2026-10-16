import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_ui/widgets/ui_dropdown_menu.dart';

void main() {
  const items = [
    UiDropdownMenuItem(value: 'cli', label: '打开 CLI'),
    UiDropdownMenuItem(value: 'desktop', label: '打开桌面端'),
  ];

  Future<void> pumpAnchor(
    WidgetTester tester, {
    required GlobalKey anchorKey,
    required Alignment alignment,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: alignment,
          child: Builder(
            builder: (context) => SizedBox(
              key: anchorKey,
              width: 120,
              height: 40,
              child: TextButton(
                onPressed: () => showUiDropdownMenuBelow<String>(
                  context: context,
                  anchorKey: anchorKey,
                  items: items,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets('2026-09-20 · 触发按钮贴着窗口底部时菜单翻到按钮上方,每一项都看得全', (tester) async {
    final anchorKey = GlobalKey();
    await pumpAnchor(tester,
        anchorKey: anchorKey, alignment: Alignment.bottomLeft);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final anchorTop = tester.getTopLeft(find.byKey(anchorKey)).dy;
    for (final label in ['打开 CLI', '打开桌面端']) {
      final rect = tester.getRect(find.text(label));
      expect(rect.bottom, lessThanOrEqualTo(600 - 8), reason: '$label 超出窗口底部');
      expect(rect.bottom, lessThanOrEqualTo(anchorTop),
          reason: '$label 盖住了触发按钮');
    }
  });

  testWidgets('下方放得下时仍在按钮正下方弹出', (tester) async {
    final anchorKey = GlobalKey();
    await pumpAnchor(tester,
        anchorKey: anchorKey, alignment: Alignment.topLeft);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final anchorBottom = tester.getBottomLeft(find.byKey(anchorKey)).dy;
    expect(tester.getRect(find.text('打开 CLI')).top,
        greaterThanOrEqualTo(anchorBottom));
  });

  testWidgets('按光标位置弹出的菜单靠近窗口底部时整体上移,不被裁掉', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showUiDropdownContextMenu<String>(
              context: context,
              globalPosition: const Offset(300, 590),
              items: items,
            ),
            child: const Text('右键'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('右键'));
    await tester.pumpAndSettle();

    expect(
        tester.getRect(find.text('打开桌面端')).bottom, lessThanOrEqualTo(600 - 8));
  });
}
