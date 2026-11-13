// Opt-in real refresh acceptance: independent member account and bundle only.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/community_workspace_app.dart';
import 'package:zhiban_client/layout/widgets/sidebar_user_mini.dart';
import 'package:zhiban_client/layout/widgets/sidebar_nav_item.dart';
import 'package:zhiban_client/window/window_controller.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final screen = GlobalKey();
  final role = 'member';
  final base = Directory('/tmp/community-refresh-ui/$role');
  await base.create(recursive: true);
  await WindowController.instance.init(hasToken: true);
  runApp(RepaintBoundary(key: screen, child: const CommunityWorkspaceApp()));
  final uiController = LiveWidgetController(binding);
  Future<void> waitFor(Finder f) async {
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (f.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await uiController.pump(const Duration(milliseconds: 100));
    }
    if (f.evaluate().isEmpty) throw StateError('Absent UI: $f');
  }

  Future<void> tap(Finder f) async {
    await waitFor(f);
    await uiController.ensureVisible(f);
    await uiController.tap(f);
    await uiController.pump(const Duration(milliseconds: 200));
  }

  Future<void> type(Finder f, String value) async {
    await tap(f);
    uiController.state<EditableTextState>(f).updateEditingValue(
        TextEditingValue(
            text: value,
            selection: TextSelection.collapsed(offset: value.length)));
    await uiController.pump(const Duration(milliseconds: 150));
  }

  Finder input(String hint) => find.descendant(
      of: find
          .byWidgetPredicate((w) => w is UiInputField && w.hintText == hint),
      matching: find.byType(EditableText));
  Future<String> shot(String name) async {
    await uiController.pump(const Duration(milliseconds: 100));
    final image = await (screen.currentContext!.findRenderObject()!
            as RenderRepaintBoundary)
        .toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final path = '${base.path}/$name.png';
    await File(path).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
    return path;
  }

  try {
    const fixturePath = String.fromEnvironment('COMMUNITY_UI_FIXTURE');
    final admin = jsonDecode(await File(fixturePath).readAsString()) as Map;
    final member = role == 'member'
        ? jsonDecode(
            await File('${File(fixturePath).parent.path}/second-user.json')
                .readAsString()) as Map
        : null;
    await tap(find.byType(SidebarUserMini));
    await tap(find.text('连接服务器'));
    await type(input('https://ai.example.com'), admin['busUrl'] as String);
    await tap(find.text('检测并连接'));
    await type(input('邮箱 / 手机号 / 用户名'),
        (member?['Email'] ?? admin['email']) as String);
    await type(
        input('请输入密码'), (member?['Password'] ?? admin['password']) as String);
    await tap(find.text('登录'));
    await waitFor(find.text('通讯录'));
    await File('${base.path}/ready.json')
        .writeAsString(jsonEncode({'status': 'ready', 'role': role}));
    final prefs = await SharedPreferences.getInstance();
    final previousRefresh = prefs.getString(AppConfig.storageRefreshTokenKey);
    if (previousRefresh == null || previousRefresh.isEmpty) {
      throw StateError('Refresh token missing after UI login / tenant switch');
    }
    var forced = false;
    var saw401 = false;
    final failureInjection = InterceptorsWrapper(onRequest: (options, handler) {
      if (!forced && options.path == '/contacts/tree') {
        forced = true;
        options.headers['Authorization'] = 'Bearer expired-refresh-test-access';
      }
      handler.next(options);
    }, onResponse: (response, handler) {
      if (response.requestOptions.path == '/contacts/tree' &&
          response.statusCode == 401) {
        saw401 = true;
      }
      handler.next(response);
    });
    request.interceptors.insert(1, failureInjection);
    await tap(find.ancestor(
        of: find.text('通讯录'), matching: find.byType(SidebarNavItem)));
    await tap(find.text('默认部门'));
    await waitFor(find.text('本机管理员'));
    final until = DateTime.now().add(const Duration(seconds: 40));
    while (
        prefs.getString(AppConfig.storageRefreshTokenKey) == previousRefresh &&
            DateTime.now().isBefore(until)) {
      await uiController.pump(const Duration(milliseconds: 100));
    }
    request.interceptors.remove(failureInjection);
    final nextRefresh = prefs.getString(AppConfig.storageRefreshTokenKey);
    if (!forced ||
        !saw401 ||
        nextRefresh == null ||
        nextRefresh.isEmpty ||
        nextRefresh == previousRefresh) {
      throw StateError('Real 401 refresh or rotation did not complete');
    }
    await shot('renewed-contacts');
    await File('${base.path}/refresh-check.json').writeAsString(jsonEncode({
      'status': 'passed',
      'independentAccount': true,
      'forcedReal401': saw401,
      'refreshPreservedAfterScopeSwitch': true,
      'refreshRotated': true,
      'contactsVisible': true,
      'loggedIn': find.text('登录').evaluate().isEmpty,
    }));
    debugPrint('REFRESH_UI_PASSED; independent member remains signed in');
  } catch (error, stack) {
    await File('${base.path}/ready.json').writeAsString(
        jsonEncode({'status': 'failed', 'error': error.toString()}));
    debugPrint('UI setup failed: $error\n$stack');
    await shot('setup-failure');
  }
}
