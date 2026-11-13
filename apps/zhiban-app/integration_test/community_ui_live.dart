// Opt-in real UI acceptance that leaves the production workspace mounted.
// No mocks, provider overrides, direct business calls, or session injection.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/community_workspace_app.dart';
import 'package:zhiban_client/layout/widgets/sidebar_user_mini.dart';
import 'package:zhiban_client/layout/widgets/sidebar_nav_item.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/agent_card.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_card.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/prompt_input.dart';
import 'package:zhiban_client/window/window_controller.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final screen = GlobalKey();
  await WindowController.instance.init(hasToken: true);
  runApp(RepaintBoundary(key: screen, child: const CommunityWorkspaceApp()));
  final controller = LiveWidgetController(binding);
  final evidence = Directory('/tmp/community-ui-final');
  await evidence.create(recursive: true);
  final checks = <String, Object?>{};
  Future<void> waitFor(Finder finder) async {
    final until = DateTime.now().add(const Duration(seconds: 40));
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(until)) {
      await controller.pump(const Duration(milliseconds: 150));
    }
    if (finder.evaluate().isEmpty) {
      throw StateError('UI element absent: $finder');
    }
  }

  Future<void> tap(Finder finder) async {
    await waitFor(finder);
    await controller.tap(finder);
    await controller.pump(const Duration(milliseconds: 200));
  }

  Future<void> nav(String label) => tap(find.ancestor(
      of: find.text(label), matching: find.byType(SidebarNavItem)));
  Future<void> shot(String name, {bool immediate = false}) async {
    if (!immediate) await controller.pump(const Duration(milliseconds: 350));
    final image = await (screen.currentContext!.findRenderObject()!
            as RenderRepaintBoundary)
        .toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('${evidence.path}/$name.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
    debugPrint('UI screenshot: $name');
  }

  Finder input(String hint) => find.descendant(
      of: find
          .byWidgetPredicate((w) => w is UiInputField && w.hintText == hint),
      matching: find.byType(EditableText));
  Future<void> text(String hint, String value) async {
    final finder = input(hint);
    await tap(finder);
    controller.state<EditableTextState>(finder).updateEditingValue(
        TextEditingValue(
            text: value,
            selection: TextSelection.collapsed(offset: value.length)));
    await controller.pump(const Duration(milliseconds: 100));
  }

  void measure(Finder finder, String name) {
    final rects = finder.evaluate().map((e) {
      final b = e.renderObject! as RenderBox;
      return b.localToGlobal(Offset.zero) & b.size;
    }).toList();
    if (rects.length < 2) throw StateError('$name needs multiple real cards');
    rects.sort((a, b) =>
        a.top == b.top ? a.left.compareTo(b.left) : a.top.compareTo(b.top));
    final row =
        rects.where((r) => (r.top - rects.first.top).abs() < 1).toList();
    if (row.length < 2) throw StateError('$name needs multiple columns');
    final gap = row[1].left - row[0].right;
    if ((gap - 8).abs() > 0.6) throw StateError('$name horizontal gap $gap');
    final next = rects.where((r) => r.top > row.first.top + 1).toList();
    double? vertical;
    if (next.isNotEmpty) {
      final bottom = row.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
      vertical = next.first.top - bottom;
      if ((vertical - 8).abs() > 0.6) {
        throw StateError('$name vertical gap $vertical');
      }
    }
    checks[name] = {
      'horizontal': gap,
      'vertical': vertical,
      'cards': rects.length
    };
  }

  try {
    const path = String.fromEnvironment('COMMUNITY_UI_FIXTURE');
    final fixture = jsonDecode(await File(path).readAsString()) as Map;
    await tap(find.byType(SidebarUserMini));
    await tap(find.text('连接服务器'));
    await text('https://ai.example.com', fixture['busUrl'] as String);
    await tap(find.text('检测并连接'));
    await text('邮箱 / 手机号 / 用户名', fixture['email'] as String);
    await text('请输入密码', fixture['password'] as String);
    await tap(find.text('登录'));
    await waitFor(find.text('通讯录'));
    checks['connected'] = true;
    await nav('通讯录');
    await tap(find.text('默认部门'));
    await waitFor(find.text('本机验证成员'));
    checks['contacts'] = true;
    await shot('01-contacts');
    await controller.tap(find.ancestor(
        of: find.text('数字员工'), matching: find.byType(SidebarNavItem)));
    final loadingDeadline = DateTime.now().add(const Duration(seconds: 30));
    var partialLoadingObserved = false;
    while (DateTime.now().isBefore(loadingDeadline)) {
      await controller.pump(const Duration(milliseconds: 16));
      if (find.byType(AgentCard).evaluate().isNotEmpty &&
          find.byType(AgentCardSkeleton).evaluate().isNotEmpty) {
        partialLoadingObserved = true;
        await shot('02-employees-partial-loading', immediate: true);
        break;
      }
      if (find.text('个人任务规划专家').evaluate().isNotEmpty) break;
    }
    checks['employeePartialLoadingObserved'] = partialLoadingObserved;
    await waitFor(find.text('个人任务规划专家'));
    measure(find.byType(AgentCard), 'employees');
    await shot('02-employees');
    await nav('技能广场');
    await waitFor(find.byType(SkillCard));
    measure(find.byType(SkillCard), 'skills');
    await shot('03-skills');
    await nav('自动任务');
    await tap(find.text('新建'));
    await waitFor(find.text('新建任务'));
    await controller.pump(const Duration(seconds: 1));
    if (find.textContaining('404').evaluate().isNotEmpty) {
      throw StateError('Task dialog shows 404');
    }
    checks['newTaskDialog'] = true;
    await shot('04-task-dialog');
    await tap(find.text('取消'));
    await nav('对话');
    await waitFor(find.byType(PromptInput));
    if (find.text('内容由AI生成，请仔细甄别').evaluate().isNotEmpty) {
      throw StateError('Removed footer visible');
    }
    checks['footerRemoved'] = true;
    await shot('05-server-chat');
    checks['status'] = 'passed';
    debugPrint('UI_ACCEPTANCE_PASSED; workspace remains connected');
  } catch (error, stack) {
    checks['status'] = 'failed';
    checks['error'] = error.toString();
    debugPrint('UI_ACCEPTANCE_FAILED: $error\n$stack');
    await shot('failure');
  } finally {
    await File('${evidence.path}/checks.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(checks));
  }
}
