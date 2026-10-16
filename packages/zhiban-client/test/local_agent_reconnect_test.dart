import 'dart:async';
import 'package:dio/dio.dart';
import 'package:zhiban_client/services/local_workspace_error.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/local_agent_controls.dart';
import 'package:zhiban_client/services/conversation_models.dart';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeLocal extends ChangeNotifier implements LocalAgentService {
  @override
  bool online = false;
  @override
  String status = 'connecting';
  @override
  String errorMessage = '';
  int calls = 0, contextCalls = 0;
  @override
  int lifecycleGeneration = 0;
  final selections = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> control(
      String path, Map<String, dynamic> body) async {
    if (path != '/app/workspaces/select') {
      throw StateError('unexpected control');
    }
    selections.add(Map.of(body));
    load = null;
    return body;
  }

  Future<Map<String, dynamic>> Function(String)? load;
  @override
  Future<Map<String, dynamic>> workspace(
      String employee, String conversation, String name) async {
    calls++;
    if (load != null) return load!(conversation);
    if (!online) throw StateError('internal transport detail');
    return {
      'selection': {'workspace': '/workspace/$conversation', 'mode': 'assist'}
    };
  }

  @override
  Future<String> contextId(String conversation) async {
    contextCalls++;
    return conversation;
  }

  void connect() {
    online = true;
    status = 'online';
    notifyListeners();
  }

  void ping() => notifyListeners();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final agent = AgentItem.fromJson(
      {'uuid': 'employee', 'name': '本地助手', 'execution_locus': 'local'});
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(ConversationModels.instance.clear);
  Widget host(FakeLocal local, String conversation,
          {Future<String?> Function()? picker}) =>
      MaterialApp(
          home: Scaffold(
              body: LocalAgentControls(
                  agent: agent,
                  conversation: conversation,
                  localService: local,
                  chooseWorkspaceDirectory: picker)));

  testWidgets('reconnect restores workspace and clears the old load error once',
      (tester) async {
    final local = FakeLocal();
    await tester.pumpWidget(host(local, 'first'));
    await tester.pumpAndSettle();
    expect(find.text('本机运行组件正在重新连接，请稍候'), findsOneWidget);
    expect(local.calls, 1);
    local.connect();
    await tester.pumpAndSettle();
    expect(local.calls, 2);
    expect(find.text('本机运行组件正在重新连接，请稍候'), findsNothing);
    expect(find.text('first'), findsOneWidget);
    local.ping();
    local.ping();
    await tester.pumpAndSettle();
    expect(local.calls, 2);
    await tester.pumpWidget(const SizedBox());
    local.dispose();
  });

  testWidgets(
      'recovery during a pending failed load is retried without another status event',
      (tester) async {
    final local = FakeLocal();
    final pending = Completer<Map<String, dynamic>>();
    local.load = (_) => pending.future;
    await tester.pumpWidget(host(local, 'first'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(local.calls, 1);
    local.load = null;
    local.connect();
    pending.completeError(StateError('old IPC failed'));
    await tester.pumpAndSettle();
    expect(local.calls, 2);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    local.dispose();
  });

  testWidgets('an online workspace error is not called a disconnected helper',
      (tester) async {
    final local = FakeLocal()..connect();
    local.load = (_) => Future.error(StateError('private response'));
    await tester.pumpWidget(host(local, 'first'));
    await tester.pumpAndSettle();
    expect(find.text('本地会话信息加载失败，请重试'), findsOneWidget);
    expect(find.textContaining('private response'), findsNothing);
    local.load = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('本地会话信息加载失败，请重试'), findsNothing);
    expect(find.text('first'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    local.dispose();
  });

  testWidgets(
      'a delayed previous conversation cannot overwrite the current workspace',
      (tester) async {
    final local = FakeLocal()..connect();
    final old = Completer<Map<String, dynamic>>();
    local.load = (conversation) => conversation == 'first'
        ? old.future
        : Future.value({
            'selection': {'workspace': '/workspace/second', 'mode': 'assist'}
          });
    await tester.pumpWidget(host(local, 'first'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(local.calls, 1);
    await tester.pumpWidget(host(local, 'second'));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
    old.complete({
      'selection': {'workspace': '/workspace/first', 'mode': 'full'}
    });
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);
    expect(find.text('完全访问'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    local.dispose();
  });
  const contextId = '11111111-1111-4111-8111-111111111111';
  LocalWorkspaceError directoryError(String code) => LocalWorkspaceError.from(
      DioException(
          requestOptions: RequestOptions(path: '/app/workspaces/default'),
          response: Response(
              requestOptions: RequestOptions(path: '/app/workspaces/default'),
              statusCode: 403,
              data: {
                'error': {'code': code, 'message': 'SECRET /private/path'}
              })),
      contextId: contextId);

  testWidgets(
      'directory failure keeps an explicit recovery action and uses the verified context in assist mode',
      (tester) async {
    final local = FakeLocal()..connect();
    local.load =
        (_) => Future.error(directoryError('local.workspace_path_conflict'));
    await tester
        .pumpWidget(host(local, 'first', picker: () async => '/chosen'));
    await tester.pumpAndSettle();
    expect(find.text('选择工作目录'), findsOneWidget);
    expect(find.textContaining('默认工作目录被同名文件占用'), findsOneWidget);
    expect(find.textContaining('SECRET'), findsNothing);
    await tester.tap(find.text('选择工作目录'));
    await tester.pumpAndSettle();
    expect(local.selections, [
      {
        'employee': 'employee',
        'conversation': contextId,
        'workspace': '/chosen',
        'mode': 'assist'
      }
    ]);
    expect(find.text('重试'), findsNothing);
    expect(find.text('选择工作目录'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    local.dispose();
  });

  testWidgets(
      'an employee identity mismatch cannot be fixed by changing its directory binding',
      (tester) async {
    final local = FakeLocal()..connect();
    local.load = (_) =>
        Future.error(directoryError('local.workspace_identity_mismatch'));
    await tester.pumpWidget(host(local, 'first'));
    await tester.pumpAndSettle();
    expect(find.textContaining('配置与数字员工不匹配'), findsOneWidget);
    expect(find.text('选择工作目录'), findsNothing);
    expect(local.selections, isEmpty);
    await tester.pumpWidget(const SizedBox());
    local.dispose();
  });

  testWidgets(
      'a folder picker returning after switching conversations does not write stale settings',
      (tester) async {
    final local = FakeLocal()..connect();
    final chosen = Completer<String?>();
    local.load =
        (_) => Future.error(directoryError('local.workspace_path_conflict'));
    await tester.pumpWidget(host(local, 'first', picker: () => chosen.future));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择工作目录'));
    await tester.pump();
    local.load = null;
    await tester.pumpWidget(host(local, 'second'));
    await tester.pumpAndSettle();
    chosen.complete('/old-selection');
    await tester.pumpAndSettle();
    expect(local.selections, isEmpty);
    expect(find.text('second'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    local.dispose();
  });

  testWidgets(
      'successful workspace preparation reuses its context without another server lookup',
      (tester) async {
    final local = FakeLocal()..connect();
    local.load = (_) async => {
          'selection': {
            'conversation': contextId,
            'workspace': '/ready',
            'mode': 'assist'
          }
        };
    await tester.pumpWidget(host(local, 'first'));
    await tester.pumpAndSettle();
    expect(find.text('ready'), findsOneWidget);
    expect(local.contextCalls, 0);
    await tester.pumpWidget(const SizedBox());
    local.dispose();
  });
}
