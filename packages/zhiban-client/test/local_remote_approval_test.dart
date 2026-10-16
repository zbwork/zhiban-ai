import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/local_approval_card.dart';
import 'package:zhiban_client/pages/chat/widgets/local_approval_host.dart';
import 'package:zhiban_client/services/local_runtime_api.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

class ApprovalApi extends LocalRuntimeApi {
  bool connected = true;
  int decisions = 0;
  Completer<List<Map<String, dynamic>>>? delayedPoll;
  List<Map<String, dynamic>> pending = [
    {
      'id': 'approval-1',
      'run': 'run-1',
      'revision': 2,
      'intent_hash': 'hash',
      'display': {
        'tool': 'write_file',
        'operation': 'write',
        'target': '报告.txt'
      },
    },
  ];
  @override
  Future<LocalDesktopStatus> desktopStatus() async =>
      LocalDesktopStatus.fromJson(
          {'online': connected, 'available': connected});
  @override
  Future<List<Map<String, dynamic>>> approvals(String conversation) async {
    final delayed = delayedPoll;
    delayedPoll = null;
    return delayed == null ? List.of(pending) : await delayed.future;
  }

  @override
  Future<Map<String, dynamic>> decide(
      Map<String, dynamic> approval, bool approved, String scope) async {
    decisions++;
    pending = [];
    return {'status': approved ? 'approved' : 'rejected'};
  }
}

void main() {
  testWidgets(
      'new local approval wakes an obscured desktop once without approving',
      (tester) async {
    if (!PlatformUtils.isDesktop) return;
    final service = LocalAgentService.instance;
    final calls = <String>[];
    const channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call.method);
      if (call.method == 'show') {
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      return true;
    });
    addTearDown(() {
      service.approvals.clear();
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final api = ApprovalApi()..pending = [];
    await tester.pumpWidget(ProviderScope(
        overrides: [localRuntimeApiProvider.overrideWithValue(api)],
        child: const MaterialApp(
            home: LocalApprovalHost(child: Scaffold(body: Text('后台'))))));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    final request = {
      'id': 'wake-1',
      'revision': 1,
      'run': 'run-1',
      'intent_hash': 'hash',
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 120000,
      'intent': {
        'tool': 'computer',
        'operation': 'desktop',
        'args': {'action': 'inspect', 'app': 'Notion'}
      }
    };
    api.pending = [request];
    service.approvals['wake-1'] = request;
    // Simulate the notification emitted by the authenticated helper pipe.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    service.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls.where((name) => name == 'show' || name == 'focus'),
        ['show', 'focus']);
    expect(find.text('等待你的批准'), findsOneWidget);
    expect(api.decisions, 0);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    service.notifyListeners();
    await tester.pump();
    expect(calls.where((name) => name == 'show' || name == 'focus'),
        ['show', 'focus']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('visible inactive desktop still receives and resolves approvals',
      (tester) async {
    if (!PlatformUtils.isDesktop) return;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final api = ApprovalApi();
    await tester.pumpWidget(ProviderScope(
        overrides: [localRuntimeApiProvider.overrideWithValue(api)],
        child: const MaterialApp(
            home: LocalApprovalHost(child: Scaffold(body: Text('后台可见桌面'))))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('等待你的批准'), findsOneWidget);
    api.pending = [];
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('等待你的批准'), findsNothing);
    expect(find.text('后台可见桌面'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  test('online legacy helper is unavailable with an upgrade explanation', () {
    final status = LocalDesktopStatus.fromJson({
      'online': true,
      'available': false,
      'reason': 'upgrade_required',
    });
    expect(status.available, false);
    expect(status.message, '电脑已在线，请更新电脑端后再派活');
    expect(LocalDesktopStatus.fromJson({'online': true}).available, true);
  });
  testWidgets('late pending response cannot reopen a decided approval',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final api = ApprovalApi();
    await tester.pumpWidget(ProviderScope(
        overrides: [localRuntimeApiProvider.overrideWithValue(api)],
        child: const MaterialApp(
            home: LocalApprovalHost(child: Scaffold(body: Text('会话'))))));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('等待你的批准'), findsOneWidget);
    final stale = List<Map<String, dynamic>>.of(api.pending);
    final delayed = Completer<List<Map<String, dynamic>>>();
    api.delayedPoll = delayed;
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('允许本次'));
    await tester.pump();
    expect(api.decisions, 1);
    expect(find.text('等待你的批准'), findsNothing);
    delayed.complete(stale);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('等待你的批准'), findsNothing);
    expect(find.text('会话'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'global approval closes after other endpoint decides without popping the current page',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final api = ApprovalApi();
    await tester.pumpWidget(ProviderScope(
        overrides: [localRuntimeApiProvider.overrideWithValue(api)],
        child: const MaterialApp(
            home: LocalApprovalHost(child: Scaffold(body: Text('其他会话'))))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('等待你的批准'), findsOneWidget);
    api.pending = [];
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('等待你的批准'), findsNothing);
    expect(find.text('其他会话'), findsOneWidget);
    expect(api.decisions, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'same approval disappears from both views after either view decides',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final api = ApprovalApi();
    await tester.pumpWidget(ProviderScope(
        overrides: [localRuntimeApiProvider.overrideWithValue(api)],
        child: const MaterialApp(
            home: Scaffold(
                body: Row(children: [
          Expanded(
              child: LocalApprovalPanel(conversation: 'same-conversation')),
          Expanded(
              child: LocalApprovalPanel(conversation: 'same-conversation')),
        ])))));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('等待你的批准'), findsNWidgets(2));
    await tester.tap(find.text('允许本次').first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('等待你的批准'), findsNothing);
    expect(api.decisions, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'remote decision, offline state and foreground recovery use authoritative pending list',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final api = ApprovalApi();
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
        overrides: [localRuntimeApiProvider.overrideWithValue(api)],
        child: const MaterialApp(
            home: Scaffold(
                body: LocalApprovalPanel(conversation: 'conversation')))));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('报告.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
    api.pending = [];
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('等待你的批准'), findsNothing);
    api.connected = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    final container = ProviderScope.containerOf(
        tester.element(find.byType(LocalApprovalPanel)));
    expect(container.read(localDesktopOnlineProvider), false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    api.connected = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(container.read(localDesktopOnlineProvider), true);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
