// Opt-in real macOS UI acceptance. No service/provider/network substitutions.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nexwork/community_workspace_app.dart';
import 'package:zhiban_client/layout/widgets/sidebar_user_mini.dart';
import 'package:zhiban_client/window/window_controller.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixturePath = String.fromEnvironment('COMMUNITY_UI_FIXTURE');
  const evidencePath = String.fromEnvironment('COMMUNITY_UI_EVIDENCE',
      defaultValue: '/tmp/community-ui-milestone');
  final screen = GlobalKey();
  testWidgets('milestone 1: connect server and show real tenant contacts',
      (tester) async {
    expect(fixturePath, isNotEmpty,
        reason: 'Explicit private fixture required');
    final fixture = jsonDecode(await File(fixturePath).readAsString())
        as Map<String, dynamic>;
    await WindowController.instance.init(hasToken: true);
    runApp(RepaintBoundary(key: screen, child: const CommunityWorkspaceApp()));
    Future<void> waitFor(Finder finder,
        {Duration timeout = const Duration(seconds: 40)}) async {
      final until = DateTime.now().add(timeout);
      while (finder.evaluate().isEmpty && DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(finder, findsWidgets);
    }

    Future<void> capture(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      final boundary =
          screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$evidencePath/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      debugPrint('UI screenshot: $name');
    }

    Finder input(String hint) => find.descendant(
        of: find
            .byWidgetPredicate((w) => w is UiInputField && w.hintText == hint),
        matching: find.byType(TextField));
    await waitFor(find.byType(SidebarUserMini));
    await tester.tap(find.byType(SidebarUserMini));
    await waitFor(find.text('连接服务器'));
    await tester.tap(find.text('连接服务器'));
    await waitFor(input('https://ai.example.com'));
    await tester.enterText(
        input('https://ai.example.com'), fixture['busUrl'] as String);
    await tester.tap(find.text('检测并连接'));
    await waitFor(input('邮箱 / 手机号 / 用户名'));
    await capture('01-server-login');
    await tester.enterText(input('邮箱 / 手机号 / 用户名'), fixture['email'] as String);
    await tester.enterText(input('请输入密码'), fixture['password'] as String);
    await tester.tap(find.text('登录').last);
    await waitFor(find.text('通讯录'));
    await tester.tap(find.text('通讯录').first);
    await waitFor(find.text('组织架构'));
    await tester.tap(find.text('默认部门'));
    await waitFor(find.text('本机验证成员'));
    await capture('02-server-contacts');
    expect(find.text('本机验证成员'), findsWidgets);
    debugPrint('PASS UI server connection, login, tenant and real contacts');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
