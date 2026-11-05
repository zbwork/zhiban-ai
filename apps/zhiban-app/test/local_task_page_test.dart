import 'package:bot_toast/bot_toast.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexwork/pages/task/task_page.dart';
import 'package:nexwork/pages/task/widgets/task_editor_dialog.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_app.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_page.dart';
import 'package:zhiban_client/pages/local_workspace/local_workspace_controller.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_task_service.dart';
import 'package:zhiban_client/pages/task/models/task_models.dart';
import 'package:zhiban_client/pages/task/providers/task_provider.dart';
import 'package:zhiban_client/pages/task/widgets/task_cards.dart';
import 'package:zhiban_client/pages/task/widgets/task_editor_content.dart';
import 'package:zhiban_core/chat/chat_models.dart';

class NoNetwork extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('private API forbidden');
  }
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('community route scopes task notifier to local service',
      (tester) async {
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    final store = (await tester.runAsync(() => LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath)))!;
    final controller = LocalWorkspaceController(store);
    final network = NoNetwork();
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(ProviderScope(
          overrides: [
            localWorkspaceProvider.overrideWith((ref) async => controller),
            taskServiceProvider.overrideWith((ref) =>
                throw StateError('root remote service must not initialize')),
            agentsProvider.overrideWith(
                () => throw StateError('remote employees forbidden')),
            conversationsProvider.overrideWith(
                () => throw StateError('remote conversations forbidden')),
          ],
          child: LocalWorkspaceApp(
              localTaskBuilder: (agents, openRun, changes) => TaskPage(
                  localAgents: agents,
                  onOpenLocalRun: openRun,
                  localChanges: changes))));
      await settle(tester);
      final context = tester.element(find.byType(LocalWorkspacePage));
      GoRouter.of(context).go('/task');
      await settle(tester);
      expect(find.byType(TaskPage), findsOneWidget);
      expect(find.text('新建'), findsOneWidget);
      expect(find.text('任务页面暂时不可用'), findsNothing);
      expect(network.calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    }, network);
    controller.dispose();
    await tester.runAsync(store.db.close);
  });

  testWidgets(
      'original local task page creates, edits, runs, pauses, shows history and deletes without private API',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    final store = (await tester.runAsync(() => LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath)))!;
    await tester.runAsync(() => store.saveEmployee({
          'id': 'employee',
          'name': '本地助手',
          'prompt': '',
          'provider_id': 'p',
          'model_id': 'm',
          'skills': '[]',
          'created': 1
        }));
    final service = LocalTaskService(store,
        isBusy: (_) => false,
        execute: (_, prompt, token) async =>
            {'id': 'reply', 'status': 'complete', 'content': '执行结果'});
    final agent = AgentItem.fromJson(
        {'uuid': 'employee', 'name': '本地助手', 'execution_locus': 'local'});
    final network = NoNetwork();
    CronRunEntry? opened;
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(ProviderScope(
          overrides: [
            taskServiceProvider.overrideWithValue(service),
            agentsProvider.overrideWith(
                () => throw StateError('remote agents forbidden')),
            conversationsProvider.overrideWith(
                () => throw StateError('remote conversations forbidden')),
            taskSelectableAgentsProvider.overrideWith(
                (ref) => throw StateError('remote contacts forbidden')),
          ],
          child: MaterialApp(
              builder: BotToastInit(),
              home: TaskPage(
                  localAgents: [agent],
                  localChanges: service.changes,
                  onOpenLocalRun: (entry) async {
                    opened = entry;
                  }))));
      await settle(tester);
      expect(find.text('任务列表'), findsOneWidget);
      expect(find.textContaining('关闭后暂停'), findsOneWidget);
      await tester.tap(find.text('新建'));
      await settle(tester);
      expect(find.byType(TaskEditorDialog), findsOneWidget);
      expect(find.byType(TaskEditorContent), findsOneWidget);
      expect(find.text('使用模板'), findsNothing);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '本地定时测试');
      final prompt =
          find.byWidgetPredicate((w) => w is TextField && w.maxLines == 8);
      expect(prompt, findsOneWidget);
      await tester.ensureVisible(prompt);
      await tester.enterText(prompt, '请汇总今天的工作');
      await tester.tap(find.text('创建'));
      await settle(tester);
      expect(find.byType(TaskEditorDialog), findsNothing);
      expect(find.byType(TaskJobCard), findsOneWidget);
      expect(
          (await tester.runAsync(service.listJobs))!.single.payload.displayText,
          '请汇总今天的工作');
      await tester.tap(find.byType(CupertinoSwitch));
      await settle(tester);
      expect((await tester.runAsync(service.listJobs))!.single.enabled, false);
      await tester.tap(find.byType(CupertinoSwitch));
      await settle(tester);
      expect((await tester.runAsync(service.listJobs))!.single.enabled, true);
      final card = tester.widget<TaskJobCard>(find.byType(TaskJobCard));
      card.onEdit!();
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, '编辑后的任务');
      await tester.tap(find.text('保存'));
      await settle(tester);
      expect((await tester.runAsync(service.listJobs))!.single.name, '编辑后的任务');
      await tester.tap(find.text('立即执行'));
      await settle(tester);
      await settle(tester);
      await tester.tap(find.text('历史任务'));
      await settle(tester);
      expect(find.byType(TaskRunEntryTile), findsOneWidget);
      expect(find.text('执行结果'), findsWidgets);
      await tester.tap(find.text('在对话中查看'));
      await tester.pump();
      expect(opened?.conversationUuid, 'employee');
      await tester.tap(find.text('任务列表'));
      await settle(tester);
      tester.widget<TaskJobCard>(find.byType(TaskJobCard)).onDelete();
      await settle(tester);
      await tester.tap(find.text('删除').last);
      await settle(tester);
      expect(await tester.runAsync(service.listJobs), isEmpty);
      expect(await tester.runAsync(service.listRecentRuns), hasLength(1));
      expect(network.calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    }, network);
    service.dispose();
    await tester.runAsync(store.db.close);
    await tester.binding.setSurfaceSize(null);
  });
}
