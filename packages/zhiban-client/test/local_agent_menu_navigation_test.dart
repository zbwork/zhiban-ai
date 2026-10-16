import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/local_agent_controls.dart';
import 'package:zhiban_client/pages/chat/widgets/model_picker_content.dart';
import 'package:zhiban_client/services/conversation_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('model menu closes when the shell sidebar changes page',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    addTearDown(ConversationModels.instance.clear);
    final conversation = ValueNotifier<String?>('conversation');
    addTearDown(conversation.dispose);
    final agent = AgentItem.fromJson({
      'uuid': 'cloud-agent',
      'name': '云端助手',
      'supports_model_selection': true,
    });
    final router = GoRouter(initialLocation: '/chat', routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          body: Row(children: [
            SizedBox(
              width: 180,
              child: Column(children: [
                TextButton(
                    onPressed: () => context.go('/chat'),
                    child: const Text('对话')),
                TextButton(
                    onPressed: () => context.go('/digital-employee'),
                    child: const Text('数字员工')),
              ]),
            ),
            Expanded(child: child),
          ]),
        ),
        routes: [
          GoRoute(
            path: '/chat',
            pageBuilder: (context, state) => NoTransitionPage(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: ValueListenableBuilder<String?>(
                  valueListenable: conversation,
                  builder: (context, value, child) => value == null
                      ? const Text('输入区已关闭')
                      : LocalAgentControls(agent: agent, conversation: value),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/digital-employee',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: Center(child: Text('数字员工页面'))),
          ),
        ],
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AgentControlButton));
    await tester.pumpAndSettle();
    expect(find.byType(ModelPickerEntry), findsOneWidget);

    await tester.tap(find.text('数字员工'));
    await tester.pumpAndSettle();
    expect(find.text('数字员工页面').hitTestable(), findsOneWidget);
    expect(find.byType(ModelPickerEntry), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('对话'));
    await tester.pumpAndSettle();
    expect(find.byType(ModelPickerEntry), findsNothing);
    await tester.tap(find.byType(AgentControlButton));
    await tester.pumpAndSettle();
    expect(find.byType(ModelPickerEntry), findsOneWidget);

    // A pushed page can retain the chat widget underneath it.
    router.push('/digital-employee');
    await tester.pumpAndSettle();
    expect(find.text('数字员工页面').hitTestable(), findsOneWidget);
    expect(find.byType(ModelPickerEntry), findsNothing);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(ModelPickerEntry), findsNothing);

    await tester.tap(find.byType(AgentControlButton));
    await tester.pumpAndSettle();
    conversation.value = 'second-conversation';
    await tester.pumpAndSettle();
    expect(find.byType(ModelPickerEntry), findsNothing);
    await tester.tap(find.byType(AgentControlButton));
    await tester.pumpAndSettle();
    expect(find.byType(ModelPickerEntry), findsOneWidget);

    // Removing the owner must close only its menu, not a newer dialog.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
    navigator.push(DialogRoute<void>(
      context: navigator.context,
      builder: (context) => AlertDialog(
        title: const Text('保留其他弹框'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭弹框')),
        ],
      ),
    ));
    await tester.pumpAndSettle();
    conversation.value = null;
    await tester.pumpAndSettle();
    expect(find.byType(ModelPickerEntry, skipOffstage: false), findsNothing);
    expect(find.text('保留其他弹框').hitTestable(), findsOneWidget);
    await tester.tap(find.text('关闭弹框'));
    await tester.pumpAndSettle();
    expect(find.text('输入区已关闭').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
