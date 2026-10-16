import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/model_service/providers/managed_model_service_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/layout/session_bootstrap_providers.dart';
import 'package:zhiban_client/pages/runtime_prewarm/models/prewarm_task.dart';
import 'package:zhiban_client/pages/runtime_prewarm/providers/prewarm_providers.dart';
import 'package:zhiban_client/pages/runtime_prewarm/services/prewarm_service.dart';

class _CountingPrewarmService extends PrewarmService {
  int ensureCalls = 0;

  @override
  Future<PrewarmEnsureResult> ensure() async {
    ensureCalls += 1;
    return const PrewarmEnsureResult(
      degraded: false,
      created: 0,
      reused: 0,
      tasks: <PrewarmTask>[],
    );
  }

  @override
  Future<List<PrewarmTask>> listTasks() async => const <PrewarmTask>[];
}

Future<void> _flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('local helper starts once without opening any local conversation',
      () async {
    var starts = 0;
    final session = ProviderContainer(overrides: [
      sessionLocalAgentStarterProvider.overrideWithValue(() async {
        starts++;
      }),
    ]);
    session.read(sessionLocalAgentBootstrapProvider);
    session.read(sessionLocalAgentBootstrapProvider);
    await _flushMicrotasks();
    expect(starts, 1);
    session.dispose();
    final next = ProviderContainer(overrides: [
      sessionLocalAgentStarterProvider.overrideWithValue(() async {
        starts++;
      }),
    ]);
    addTearDown(next.dispose);
    next.read(sessionLocalAgentBootstrapProvider);
    await _flushMicrotasks();
    expect(starts, 2);
  });

  test('disposed session never starts a helper from its queued bootstrap',
      () async {
    var starts = 0;
    final session = ProviderContainer(overrides: [
      sessionLocalAgentStarterProvider.overrideWithValue(() async {
        starts++;
      }),
    ]);
    session.read(sessionLocalAgentBootstrapProvider);
    session.dispose();
    await _flushMicrotasks();
    expect(starts, 0);
  });

  test('云端预热默认关闭时不初始化模型服务也不调用 runtime ensure', () async {
    final service = _CountingPrewarmService();
    var modelServiceLoads = 0;
    final session = ProviderContainer(overrides: [
      prewarmServiceProvider.overrideWithValue(service),
      managedModelServiceProvider.overrideWith((ref) async {
        modelServiceLoads++;
        return const ManagedModelService(
            status: 'ready', keyReady: true, models: [], message: 'ready');
      }),
    ]);
    addTearDown(session.dispose);

    session.read(sessionPrewarmBootstrapProvider);
    await _flushMicrotasks();

    expect(modelServiceLoads, 0);
    expect(service.ensureCalls, 0);
  });

  test('模型初始化完成后才预热，旧租户晚到结果不触发新会话预热', () async {
    final service = _CountingPrewarmService();
    final gate = Completer<ManagedModelService>();
    final session = ProviderContainer(overrides: [
      cloudRuntimePrewarmEnabledProvider.overrideWithValue(true),
      prewarmServiceProvider.overrideWithValue(service),
      managedModelServiceProvider.overrideWith((ref) => gate.future),
    ]);
    session.read(sessionPrewarmBootstrapProvider);
    await _flushMicrotasks();
    expect(service.ensureCalls, 0);
    session.dispose();
    gate.complete(const ManagedModelService(
        status: 'ready', keyReady: true, models: [], message: 'ready'));
    await _flushMicrotasks();
    expect(service.ensureCalls, 0);
  });

  test('同一会话只预热一次，切换企业的新 session scope 会再次预热', () async {
    final service = _CountingPrewarmService();

    final firstSession = ProviderContainer(
      overrides: [
        cloudRuntimePrewarmEnabledProvider.overrideWithValue(true),
        prewarmServiceProvider.overrideWithValue(service),
        managedModelServiceProvider.overrideWith((ref) async =>
            const ManagedModelService(
                status: 'ready', keyReady: true, models: [], message: 'ready'))
      ],
    );
    firstSession.read(sessionPrewarmBootstrapProvider);
    firstSession.read(sessionPrewarmBootstrapProvider);
    await _flushMicrotasks();
    expect(service.ensureCalls, 1);
    firstSession.dispose();

    final secondSession = ProviderContainer(
      overrides: [
        cloudRuntimePrewarmEnabledProvider.overrideWithValue(true),
        prewarmServiceProvider.overrideWithValue(service),
        managedModelServiceProvider.overrideWith((ref) async =>
            const ManagedModelService(
                status: 'ready', keyReady: true, models: [], message: 'ready'))
      ],
    );
    addTearDown(secondSession.dispose);
    secondSession.read(sessionPrewarmBootstrapProvider);
    await _flushMicrotasks();

    expect(service.ensureCalls, 2);
  });
}
