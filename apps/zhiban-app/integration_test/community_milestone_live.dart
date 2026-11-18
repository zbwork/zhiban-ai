import 'package:zhiban_client/app_bootstrap.dart' show MyApp;
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:nexwork/routes/app_router.dart';
// Opt-in UI-only acceptance for two independent native clients.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:local_notifier/local_notifier.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/community_workspace_app.dart';
import 'package:zhiban_client/layout/widgets/sidebar_user_mini.dart';
import 'package:zhiban_client/layout/widgets/sidebar_nav_item.dart';
import 'package:zhiban_client/window/window_controller.dart';
import 'package:zhiban_client/services/app_notification_service.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';

class _NativeNotificationAudit with LocalNotificationListener {
  _NativeNotificationAudit(this.file);
  final File file;
  void record(String event, LocalNotification n) {
    file.writeAsStringSync(
        '${jsonEncode({
              'event': event,
              'id': n.identifier,
              'title': n.title,
              'body': n.body,
              'time': DateTime.now().toIso8601String()
            })}\n',
        mode: FileMode.append);
  }

  @override
  void onLocalNotificationShow(LocalNotification n) =>
      record('nativeDelivered', n);
  @override
  void onLocalNotificationClick(LocalNotification n) =>
      record('nativeClicked', n);
}

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final screen = GlobalKey();
  const compiledRole = String.fromEnvironment('COMMUNITY_UI_ROLE');
  final role = compiledRole.isNotEmpty
      ? compiledRole
      : Platform.environment['COMMUNITY_UI_ROLE'] ?? 'member';
  const outputRoot = String.fromEnvironment('COMMUNITY_UI_OUTPUT_ROOT',
      defaultValue: '/tmp/community-milestone-recheck-20261113');
  final base = Directory('$outputRoot/$role');
  await base.create(recursive: true);
  localNotifier.addListener(_NativeNotificationAudit(
      File('${base.path}/native-notifications.jsonl')));
  await WindowController.instance.init(hasToken: true);
  const reuseSession = bool.fromEnvironment('COMMUNITY_UI_REUSE_SESSION');
  if (reuseSession) {
    const path = String.fromEnvironment('COMMUNITY_UI_FIXTURE');
    final fixture = jsonDecode(await File(path).readAsString()) as Map;
    AppConfig.serverApiUrl = '${fixture['busUrl']}/api/agent-bus/v1';
    if (!await const SessionService().hasValidSession()) {
      throw StateError('No valid independent test session to resume');
    }
  }
  runApp(RepaintBoundary(
      key: screen,
      child: reuseSession
          ? MyApp(
              initialLocation: '/chat',
              hasToken: true,
              routerFactory: createAppRouter)
          : const CommunityWorkspaceApp()));
  await AppNotificationService.bringToFront();
  final uiController = LiveWidgetController(binding);
  debugPrint('M1_UI_STARTED role=$role');
  Future<void> waitFor(Finder f) async {
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (f.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await uiController.pump(const Duration(milliseconds: 100));
    }
    if (f.evaluate().isEmpty) throw StateError('Absent UI: $f');
  }

  Future<void> tap(Finder f) async {
    await waitFor(f);
    final target = f.first;
    await uiController.ensureVisible(target);
    await uiController.tap(target);
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

  Map<String, Object?> snapshot() => {
        'notificationAttempts': localNotifier.listeners
            .whereType<LocalNotification>()
            .map((n) => {'id': n.identifier, 'title': n.title, 'body': n.body})
            .toList(),
        'texts': find
            .byType(Text)
            .evaluate()
            .map((e) =>
                (e.widget as Text).data ??
                (e.widget as Text).textSpan?.toPlainText())
            .toList(),
        'inputs': find.byType(EditableText).evaluate().map((e) {
          final w = e.widget as EditableText;
          return {
            'hint': w.obscureText ? '<password>' : w.controller.text,
            'obscure': w.obscureText
          };
        }).toList(),
        'icons': find
            .byType(Icon)
            .evaluate()
            .map((e) => (e.widget as Icon).icon?.codePoint)
            .toList(),
      };
  try {
    const fixturePath = String.fromEnvironment('COMMUNITY_UI_FIXTURE');
    final admin = jsonDecode(await File(fixturePath).readAsString()) as Map;
    if (!['member', 'peer'].contains(role)) {
      throw StateError('Only independent test roles are permitted');
    }
    final member = ['member', 'peer'].contains(role)
        ? jsonDecode(await File(
                '${File(fixturePath).parent.path}/${role == 'peer' ? 'third-user.json' : 'second-user.json'}')
            .readAsString()) as Map
        : null;
    debugPrint('M1_UI_LOGIN_BEGIN role=$role');
    if (!reuseSession) {
      await tap(find.byType(SidebarUserMini));
      await tap(find.text('连接服务器'));
      await type(input('https://ai.example.com'), admin['busUrl'] as String);
      await tap(find.text('检测并连接'));
      const enterpriseName =
          String.fromEnvironment('COMMUNITY_UI_ENTERPRISE_LOGIN');
      if (enterpriseName.isNotEmpty) {
        final signIn = find.text('企业登录 · $enterpriseName');
        await waitFor(signIn);
        await shot('desktop-enterprise-login');
        await tap(signIn);
      } else {
        await type(input('邮箱 / 手机号 / 用户名'),
            (member?['Email'] ?? admin['email']) as String);
        await type(input('请输入密码'),
            (member?['Password'] ?? admin['password']) as String);
        await tap(find.text('登录'));
      }
      const tenantName = String.fromEnvironment('COMMUNITY_UI_TENANT_NAME');
      if (tenantName.isNotEmpty) {
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (find.text('通讯录').evaluate().isEmpty &&
            find.text(tenantName).evaluate().isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await uiController.pump(const Duration(milliseconds: 100));
        }
        if (find.text('通讯录').evaluate().isEmpty &&
            find.text(tenantName).evaluate().isNotEmpty) {
          await tap(find.text(tenantName));
        }
      }
      if (find.text('设置你的密码').evaluate().isNotEmpty) {
        await File('${base.path}/password-required.json').writeAsString(
            jsonEncode({'status': 'requires-user-password', 'role': role}));
        final deadline = DateTime.now().add(const Duration(minutes: 20));
        while (find.text('通讯录').evaluate().isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await uiController.pump(const Duration(milliseconds: 200));
        }
      }
    }
    await waitFor(find.text('通讯录'));
    debugPrint('M1_UI_READY role=$role');
    await File('${base.path}/ready.json')
        .writeAsString(jsonEncode({'status': 'ready', 'role': role}));
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final command = File('${base.path}/command.json');
      if (!await command.exists()) continue;
      final data = jsonDecode(await command.readAsString()) as Map;
      await command.delete();
      final result = <String, Object?>{'id': data['id']};
      try {
        await AppNotificationService.bringToFront();
        await uiController.pump().timeout(const Duration(seconds: 5));
        final action = data['action'];
        Finder textFinder() {
          final f = data['contains'] == true
              ? find.textContaining(data['text'] as String)
              : find.text(data['text'] as String);
          return data['index'] == null ? f : f.at(data['index'] as int);
        }

        if (action == 'nav') {
          await tap(find.ancestor(
              of: find.text(data['text'] as String),
              matching: find.byType(SidebarNavItem)));
        } else if (action == 'tap') {
          await tap(textFinder());
        } else if (action == 'type') {
          final f = data['hint'] != null
              ? input(data['hint'] as String)
              : find.byType(EditableText).at((data['index'] as int?) ?? 0);
          await type(f, data['value'] as String);
        } else if (action == 'send') {
          await tap(find.byIcon(CupertinoIcons.paperplane_fill).last);
        } else if (action == 'wait') {
          await waitFor(textFinder());
        } else if (action == 'scroll') {
          await uiController.drag(
              find.byType(Scrollable).at((data['index'] as int?) ?? 0),
              Offset(0, (data['dy'] as num).toDouble()));
          await uiController.pump(const Duration(milliseconds: 300));
        } else if (action == 'icon') {
          await tap(find
              .byWidgetPredicate(
                  (w) => w is Icon && w.icon?.codePoint == data['code'])
              .at((data['index'] as int?) ?? 0));
        } else if (action != 'snapshot') {
          throw StateError('Unknown UI action $action');
        }
        result['status'] = 'passed';
        result['snapshot'] = snapshot();
        if (data['shot'] != null) {
          result['screenshot'] = await shot(data['shot'] as String);
        }
      } catch (error, stack) {
        result['status'] = 'failed';
        result['error'] = error.toString();
        result['snapshot'] = snapshot();
        result['stack'] = stack.toString();
        debugPrint('UI command failed: $error\n$stack');
      }
      await File('${base.path}/result-${data['id']}.json')
          .writeAsString(jsonEncode(result));
    }
  } catch (error, stack) {
    await File('${base.path}/ready.json').writeAsString(
        jsonEncode({'status': 'failed', 'error': error.toString()}));
    await File('${base.path}/setup-snapshot.json')
        .writeAsString(jsonEncode(snapshot()));
    debugPrint('UI setup failed: $error\n$stack');
    // Leave setup failure visible; do not overwrite it with capture errors.
  }
}
