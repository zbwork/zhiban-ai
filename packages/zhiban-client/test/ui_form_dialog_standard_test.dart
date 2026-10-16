import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_ui/themes/app_theme.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';

// The outer decorator owns the control height; its collapsed TextField only
// occupies the editable line box.
Finder inputShell() => find.ancestor(
      of: find.byType(TextField),
      matching: find.byType(InputDecorator),
    );

void main() {
  for (final hintCase in <String, String?>{
    'null hint': null,
    'text hint': '名称',
  }.entries) {
    testWidgets(
        'single-line UiInputField uses the same centered box with ${hintCase.key}',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: UiInputField(
                controller: controller,
                hintText: hintCase.value,
              ),
            ),
          ),
        );

        await tester.tap(find.byType(TextField));
        await tester.pumpAndSettle();

        final fieldRect = tester.getRect(inputShell());
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(fieldRect.height, 40);
        expect(field.textAlignVertical, TextAlignVertical.center);
        expect(field.expands, isFalse);
        expect(field.minLines, 1);
        expect(field.maxLines, 1);
        expect(field.decoration?.isCollapsed, isTrue);
        expect(field.style?.leadingDistribution, TextLeadingDistribution.even);
        expect(
          field.decoration?.hintText,
          hintCase.value?.isNotEmpty == true ? hintCase.value : null,
        );
        expect(
          field.decoration?.hintStyle?.color,
          AppTheme.light().inputDecorationTheme.hintStyle?.color,
        );

        double caretCenterY() {
          final editableState =
              tester.state<EditableTextState>(find.byType(EditableText));
          final renderEditable = editableState.renderEditable;
          final caretRect = renderEditable.getLocalRectForCaret(
            TextPosition(offset: controller.selection.extentOffset),
          );
          final caretTop = renderEditable.localToGlobal(caretRect.topLeft).dy;
          return caretTop + caretRect.height / 2;
        }

        final emptyCaretCenter = caretCenterY();
        expect(emptyCaretCenter, closeTo(fieldRect.center.dy, 1));

        await tester.enterText(find.byType(TextField), '知办AI');
        await tester.pump();
        expect(tester.getRect(inputShell()), fieldRect);
        expect(caretCenterY(), closeTo(emptyCaretCenter, 1));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('single-line UiInputField rejects line breaks', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UiInputField(controller: controller)
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '第一行\n第二行');
    expect(controller.text, '第一行第二行');
  });

  testWidgets('expanding input starts at 40 pixels and grows after a newline',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: UiInputField(
              controller: controller,
              hintText: '欢迎语',
              minLines: 1,
              maxLines: 3,
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byType(TextField)).height, 40);
      await tester.enterText(find.byType(TextField), '第一行\n第二行');
      await tester.pump();
      expect(tester.getSize(find.byType(TextField)).height, greaterThan(40));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('UiInputField supports specialized formatted values',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UiInputField(
            controller: controller,
            hintText: '0.00',
            prefixText: '￥ ',
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    // Send the first edit without enterText reopening a lost input connection.
    tester.testTextInput.enterText('12a');
    expect(controller.text, '12');
    await tester.pump();
    final decoration = tester.widget<InputDecorator>(inputShell()).decoration;
    expect(decoration.prefixText, '￥ ');
    expect(find.text('￥ '), findsOneWidget);

    tester.widget<TextField>(find.byType(TextField)).focusNode!.unfocus();
    controller.clear();
    await tester.pumpAndSettle();
    expect(tester.testTextInput.hasAnyClients, isFalse);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    tester.testTextInput.enterText('34b');
    expect(controller.text, '34');
  });

  testWidgets('input dialog keeps invalid values open and shows the error',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showUiInputDialog(
              context,
              title: '修改群名',
              hintText: '请输入新的群名',
              maxLength: 64,
              validator: (value) => value.isEmpty ? '群名不能为空' : null,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pump();

    expect(find.text('群名不能为空'), findsOneWidget);
    expect(find.byType(UiInputDialog), findsOneWidget);
  });
}
