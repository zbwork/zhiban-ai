import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexwork/layout/main_layout.dart';
import 'package:zhiban_client/pages/settings/settings_page.dart';
import 'package:nexwork/layout/widgets/desktop_sidebar.dart';
import 'package:zhiban_client/layout/models/main_nav_item.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:nexwork/layout/widgets/sidebar_profile_popover.dart';

void main() {
  testWidgets(
      'local settings shows local tools without account or support actions',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(overrides: [
      accountInfoProvider.overrideWith(
          (ref) => throw StateError('Local settings must not load account')),
    ], child: const MaterialApp(home: SettingsPage(localWorkspace: true))));
    await tester.pumpAndSettle();
    for (final label in ['模型服务', '本地运行']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in [
      '编辑资料',
      '更换头像',
      '基础资料',
      '登录状态',
      '账号安全',
      '分享给朋友',
      '联系客服',
      '清除缓存',
      '关于我们',
      '账号与安全',
      '支持与服务'
    ]) {
      expect(find.text(label), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'local mode retains original sidebar and collapse without loading account',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1080, 820));
    final router = GoRouter(initialLocation: '/chat', routes: [
      ShellRoute(
          builder: (context, state, child) =>
              MainLayout(localWorkspace: true, child: child),
          routes: [
            for (final path in [
              ...mainNavItems.map((e) => e.path),
              '/settings/model-service',
              '/settings/ai-coding-tools'
            ])
              GoRoute(
                  path: path,
                  builder: (context, state) => Text('page:${state.uri.path}')),
          ]),
    ]);
    await tester.pumpWidget(ProviderScope(overrides: [
      authMeProvider
          .overrideWith((ref) => throw StateError('Auth must not load')),
      accountInfoProvider.overrideWith(
          (ref) => throw StateError('Account must not load in local mode')),
    ], child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
    expect(tester.getSize(sidebar).width, 180);
    expect(find.text('本地用户'), findsOneWidget);
    for (final label in ['对话', '数字员工', '技能广场']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in ['自动任务', '云盘', '通讯录']) {
      expect(find.text(label), findsNothing);
    }
    await tester.tap(find.text('数字员工'));
    await tester.pumpAndSettle();
    expect(find.text('page:/digital-employee'), findsOneWidget);
    await tester.tap(find.byType(SidebarToggleButton));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 64);
    await tester.tap(find.byType(SidebarToggleButton));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 180);
    await tester.tap(find.text('本地用户'));
    await tester.pumpAndSettle();
    expect(find.byType(SidebarProfilePopover), findsOneWidget);
    expect(find.text('帮助与客服'), findsNothing);
    expect(find.text('检查更新'), findsNothing);
    expect(find.text('本地开发工具'), findsOneWidget);
    await tester.tap(find.text('本地开发工具'));
    await tester.pumpAndSettle();
    expect(find.text('page:/settings/ai-coding-tools'), findsOneWidget);
    await tester.tap(find.text('本地用户'));
    await tester.pumpAndSettle();
    expect(find.text('退出登录'), findsNothing);
    await tester.tapAt(const Offset(600, 400));
    await tester.pumpAndSettle();
    expect(find.byType(SidebarProfilePopover), findsNothing);
    await tester.tap(find.text('本地用户'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(SidebarProfilePopover), matching: find.text('设置')));
    await tester.pumpAndSettle();
    expect(find.text('page:/settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
