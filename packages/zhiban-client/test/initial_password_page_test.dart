import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/login/initial_password_page.dart';

void main() {
  testWidgets(
      'initial password rejects weak and mismatched values before network',
      (tester) async {
    var calls = 0;
    await tester
        .pumpWidget(MaterialApp(home: InitialPasswordPage(onSave: (_) async {
      calls++;
    })));
    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'short');
    await tester.tap(find.text('设置密码并重新登录'));
    await tester.pump();
    expect(find.text('新密码长度至少 8 位'), findsOneWidget);
    expect(calls, 0);
    await tester.enterText(fields.at(0), 'test-password-one');
    await tester.enterText(fields.at(1), 'different-password');
    await tester.tap(find.text('设置密码并重新登录'));
    await tester.pump();
    expect(find.text('两次输入的密码不一致'), findsOneWidget);
    expect(calls, 0);
  });
  testWidgets('initial password preserves retry when server rejects password',
      (tester) async {
    var calls = 0;
    await tester
        .pumpWidget(MaterialApp(home: InitialPasswordPage(onSave: (_) async {
      calls++;
      throw StateError('fixture rejection');
    })));
    for (final f in find.byType(EditableText).evaluate().toList()) {
      await tester.enterText(find.byWidget(f.widget), 'test-password-one');
    }
    await tester.tap(find.text('设置密码并重新登录'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.textContaining('fixture rejection'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });
}
