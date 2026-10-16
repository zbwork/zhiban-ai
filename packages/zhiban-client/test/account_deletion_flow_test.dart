import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/pages/settings/account_deletion_flow.dart';
import 'package:zhiban_client/pages/settings/account_security_page.dart';
import 'package:zhiban_client/pages/settings/settings_page.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/account_info_api.dart';

void main() {
  Widget buildHarness({required VoidCallback onOpen}) {
    return MaterialApp(
      builder: BotToastInit(),
      navigatorObservers: [BotToastNavigatorObserver()],
      home: Scaffold(
        body: Builder(
          builder: (context) =>
              TextButton(onPressed: onOpen, child: const Text('注销账号')),
        ),
      ),
    );
  }

  testWidgets('桌面端注销账号仅在打开账号安全弹框后展示', (tester) async {
    final router = GoRouter(
      initialLocation: RoutePaths.settings,
      routes: [
        GoRoute(
          path: RoutePaths.settings,
          builder: (context, state) => const SettingsPage(),
        ),
        GoRoute(
          path: RoutePaths.accountSecurity,
          builder: (context, state) => const AccountSecurityPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountInfoProvider.overrideWith((ref) async => null)],
        child: MaterialApp.router(
          builder: BotToastInit(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('账号与安全'), findsOneWidget);
    expect(find.text('账号安全'), findsOneWidget);
    expect(find.text('注销账号'), findsNothing);

    await tester.tap(find.text('账号安全'));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, RoutePaths.settings);
    expect(find.byType(AccountSecurityBody), findsOneWidget);
    expect(find.text('注销账号'), findsOneWidget);

    await tester.tap(find.text('注销账号'));
    await tester.pumpAndSettle();

    expect(find.text(accountDeletionConfirmationTitle), findsOneWidget);
  });

  testWidgets('注销账号展示详细二次确认', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: BotToastInit(),
        navigatorObservers: [BotToastNavigatorObserver()],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => requestFrontendAccountDeletion(
                context,
                onConfirmed: () async {},
              ),
              child: const Text('注销账号'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('注销账号'));
    await tester.pumpAndSettle();

    expect(find.text(accountDeletionConfirmationTitle), findsOneWidget);
    expect(find.text(accountDeletionConfirmationDescription), findsOneWidget);
    expect(
      accountDeletionConfirmationDescription,
      contains('服务器上的账号资料、聊天记录及其他相关数据将一并删除'),
    );
    expect(accountDeletionConfirmationDescription, contains('删除后无法恢复'));
    expect(accountDeletionConfirmationDescription, isNot(contains('隐私政策')));
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确认注销'), findsOneWidget);
  });

  testWidgets('取消注销不执行退出流程', (tester) async {
    var confirmedCalls = 0;
    late BuildContext dialogContext;
    await tester.pumpWidget(
      buildHarness(
        onOpen: () => requestFrontendAccountDeletion(
          dialogContext,
          onConfirmed: () async => confirmedCalls += 1,
        ),
      ),
    );
    dialogContext = tester.element(find.text('注销账号'));

    await tester.tap(find.text('注销账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(confirmedCalls, 0);
    expect(find.text(accountDeletionToastMessage), findsNothing);
  });

  testWidgets('确认注销先 toast 提示再执行退出流程', (tester) async {
    final events = <String>[];
    late BuildContext dialogContext;
    late Future<bool> flow;
    await tester.pumpWidget(
      buildHarness(
        onOpen: () {
          flow = requestFrontendAccountDeletion(
            dialogContext,
            showToast: (message) => events.add('toast:$message'),
            onConfirmed: () async => events.add('logout'),
          );
        },
      ),
    );
    dialogContext = tester.element(find.text('注销账号'));

    await tester.tap(find.text('注销账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认注销'));
    await tester.pump(const Duration(seconds: 1));
    await flow;

    expect(events, ['toast:$accountDeletionToastMessage', 'logout']);
  });
}
