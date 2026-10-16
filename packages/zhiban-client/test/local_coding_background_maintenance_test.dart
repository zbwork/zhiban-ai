import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_background_maintenance.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_tools_service.dart';

void main() {
  test('2026-09-15 · 已切换且程序变了:静默重写知办配置(Codex 共用配置只做一次),不切换未切换的形态', () async {
    final service = _FakeOperations(_snapshot(
      switched: {LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop},
      refresh: {LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop},
    ));
    await LocalCodingBackgroundMaintenance(service).run();
    expect(service.switched, [LocalCodingTarget.codexCli]);
    expect(service.componentInstalls, 0);
  });

  test('2026-09-15 · Claude 桌面端已切换且缺运行组件:补组件并等到结束;未切换就不动', () async {
    final service = _FakeOperations(_snapshot(
      switched: {LocalCodingTarget.claudeDesktop},
      componentMissing: true,
    ));
    await LocalCodingBackgroundMaintenance(service,
            pollInterval: const Duration(milliseconds: 1))
        .run();
    expect(service.componentInstalls, 1);
    expect(service.polls, 1);
    expect(service.switched, isEmpty);

    final official = _FakeOperations(_snapshot(componentMissing: true));
    await LocalCodingBackgroundMaintenance(official).run();
    expect(official.componentInstalls, 0);
    expect(official.switched, isEmpty);
  });

  test('F31 §3.2.1 托管=已接入 · 已切换的形态目录有新版就自动升级;走官方服务的不动', () async {
    // 本地失败的一半是版本太老,而用户既不知道自己版本老、也不知道怎么升。
    // 恢复官方配置后不再托管:装好的版本留着,但不再自动升。
    final service = _FakeOperations(_snapshot(
      switched: {LocalCodingTarget.codexCli},
      upgradable: {LocalCodingTarget.codexCli, LocalCodingTarget.claudeCli},
    ));
    await LocalCodingBackgroundMaintenance(
      service,
      pollInterval: const Duration(milliseconds: 1),
    ).run();
    expect(service.upgraded, [LocalCodingTarget.codexCli]);
  });

  test('升级后重新检测，补新 Claude 宿主并刷新 Codex 共用配置一次', () async {
    final targets = {
      LocalCodingTarget.codexCli,
      LocalCodingTarget.codexDesktop,
      LocalCodingTarget.claudeDesktop
    };
    final service = _FakeOperations(
      _snapshot(switched: targets, upgradable: targets),
      afterUpgrade: _snapshot(
          switched: targets, refresh: targets, componentMissing: true),
    );
    await LocalCodingBackgroundMaintenance(service,
            pollInterval: const Duration(milliseconds: 1))
        .run();
    expect(service.upgraded, containsAll(targets));
    expect(service.calls.where((call) => call == 'inspect'), hasLength(2));
    expect(service.switched,
        [LocalCodingTarget.codexCli, LocalCodingTarget.claudeDesktop]);
    expect(service.componentInstalls, 1);
  });

  test('升级失败不触发成功收尾', () async {
    final service = _FakeOperations(
        _snapshot(
            switched: {LocalCodingTarget.claudeDesktop},
            upgradable: {LocalCodingTarget.claudeDesktop}),
        upgradeState: LocalCodingOperationState.failed,
        afterUpgrade: _snapshot(
            switched: {LocalCodingTarget.claudeDesktop},
            componentMissing: true));
    await LocalCodingBackgroundMaintenance(service,
            pollInterval: const Duration(milliseconds: 1))
        .run();
    expect(service.calls.where((call) => call == 'inspect'), hasLength(1));
    expect(service.componentInstalls, 0);
  });

  test('升级后检测失败不使用旧快照继续修复', () async {
    final service = _FakeOperations(
        _snapshot(
            switched: {LocalCodingTarget.claudeDesktop},
            upgradable: {LocalCodingTarget.claudeDesktop}),
        failPostUpgradeInspect: true);
    await LocalCodingBackgroundMaintenance(service,
            pollInterval: const Duration(milliseconds: 1))
        .run();
    expect(service.calls.where((call) => call == 'inspect'), hasLength(2));
    expect(service.componentInstalls, 0);
    expect(service.switched, isEmpty);
  });

  test('升级后已失去授权或恢复官方，不补组件或改配置', () async {
    for (final stillSwitched in [true, false]) {
      final service = _FakeOperations(
          _snapshot(
              switched: {LocalCodingTarget.claudeDesktop},
              upgradable: {LocalCodingTarget.claudeDesktop}),
          afterUpgrade: _snapshot(
              switched: stillSwitched ? {LocalCodingTarget.claudeDesktop} : {},
              authorized: !stillSwitched,
              refresh: {LocalCodingTarget.claudeDesktop},
              componentMissing: true));
      await LocalCodingBackgroundMaintenance(service,
              pollInterval: const Duration(milliseconds: 1))
          .run();
      expect(service.calls.where((call) => call == 'inspect'), hasLength(2));
      expect(service.componentInstalls, 0);
      expect(service.switched, isEmpty);
    }
  });

  test('F31 §3.2.1 托管 · 接管安装永远不在后台做(它要改用户的 shell 配置)', () async {
    final service = _FakeOperations(_snapshot(
      switched: {LocalCodingTarget.codexCli},
      adoptable: {LocalCodingTarget.codexCli},
    ));
    await LocalCodingBackgroundMaintenance(
      service,
      pollInterval: const Duration(milliseconds: 1),
    ).run();
    expect(service.upgraded, isEmpty);
  });

  test('2026-09-15 · 没有设备授权或环境未开放:什么都不做', () async {
    final service = _FakeOperations(_snapshot(
      switched: {LocalCodingTarget.codexCli},
      refresh: {LocalCodingTarget.codexCli},
      authorized: false,
    ));
    await LocalCodingBackgroundMaintenance(service).run();
    expect(service.switched, isEmpty);
  });

  test('2026-09-18 · 检测前先试一次自动重新接入(登录后 3 秒那次可能赶上网络没好)', () async {
    final service = _FakeOperations(_snapshot(
      switched: {LocalCodingTarget.codexCli},
      authorized: true),
    );
    await LocalCodingBackgroundMaintenance(service).run();
    expect(service.calls.take(2), ['reconnect', 'inspect']);
  });
}

class _FakeOperations extends Fake implements LocalCodingToolsOperations {
  _FakeOperations(this.snapshot,
      {this.afterUpgrade,
      this.upgradeState = LocalCodingOperationState.succeeded,
      this.failPostUpgradeInspect = false});

  final LocalCodingToolsSnapshot? afterUpgrade;
  final LocalCodingOperationState upgradeState;
  final bool failPostUpgradeInspect;
  bool _pollingUpgrade = false;

  final LocalCodingToolsSnapshot snapshot;
  final List<LocalCodingTarget> switched = [];
  final List<LocalCodingTarget> upgraded = [];
  int componentInstalls = 0;
  int polls = 0;
  final List<String> calls = [];

  @override
  Future<bool> reconnectIfSameIdentity() async {
    calls.add('reconnect');
    return false;
  }

  @override
  Future<LocalCodingToolsSnapshot> inspect({
    void Function(LocalCodingInspectProgress progress)? onProgress,
  }) async {
    calls.add('inspect');
    if (upgraded.isNotEmpty) {
      if (failPostUpgradeInspect) throw StateError('detection unavailable');
      return afterUpgrade ?? snapshot;
    }
    return snapshot;
  }

  @override
  Future<LocalCodingToolsSnapshot> switchToZhiban(
      LocalCodingTarget target) async {
    switched.add(target);
    return snapshot;
  }

  @override
  Future<LocalCodingOperation> startInstall(
    LocalCodingTarget target, {
    LocalCodingInstallMode mode = LocalCodingInstallMode.install,
    String? component,
  }) async {
    _pollingUpgrade = mode == LocalCodingInstallMode.upgrade;
    if (_pollingUpgrade) {
      upgraded.add(target);
    } else {
      componentInstalls++;
    }
    return _operation(target, LocalCodingOperationState.running);
  }

  @override
  Future<LocalCodingOperation> pollOperation(String operationId) async {
    polls++;
    return _operation(LocalCodingTarget.claudeDesktop,
        _pollingUpgrade ? upgradeState : LocalCodingOperationState.succeeded);
  }
}

LocalCodingOperation _operation(
        LocalCodingTarget target, LocalCodingOperationState state) =>
    LocalCodingOperation(
      operationId: 'op-1',
      target: target,
      kind: LocalCodingOperationKind.install,
      state: state,
      stage: 'downloading',
      progressKind: LocalCodingProgressKind.indeterminate,
      cancellable: false,
      nextActions: const [],
    );

LocalCodingToolsSnapshot _snapshot({
  Set<LocalCodingTarget> switched = const {},
  Set<LocalCodingTarget> refresh = const {},
  bool componentMissing = false,
  bool authorized = true,
  Set<LocalCodingTarget> upgradable = const {},
  Set<LocalCodingTarget> adoptable = const {},
}) {
  const deviceId = '11111111-1111-4111-8111-111111111111';
  return LocalCodingToolsSnapshot(
    deviceId: deviceId,
    environment: 'prod',
    credentialStatus: LocalCodingCredentialStatus(
      identityPresent: true,
      authorizationPresent: authorized,
      deviceId: deviceId,
      environment: 'prod',
      targets: const {LocalCodingTarget.codexCli, LocalCodingTarget.claudeCli},
    ),
    tools: {
      for (final target in LocalCodingTarget.values)
        target: LocalCodingToolState(
          target: target,
          generation: 1,
          uiState: LocalCodingToolUiState.installedUnmanaged,
          installedVersion: '1.0.0',
          installSource: adoptable.contains(target) ? 'npm' : 'official',
          availableVersion: upgradable.contains(target) ? '2.0.0' : '',
          updateAvailable: upgradable.contains(target),
          adoptVersion: adoptable.contains(target) ? '2.0.0' : '',
          verificationLevel: 'l0',
          nextActions: const ['detect'],
          components: target == LocalCodingTarget.claudeDesktop
              ? [
                  LocalCodingComponent(
                    id: LocalCodingComponent.claudeCodeHost,
                    version: '2.1.299',
                    state: componentMissing
                        ? LocalCodingComponentState.missing
                        : LocalCodingComponentState.present,
                  ),
                ]
              : const [],
        ),
    },
    configurations: {
      for (final target in LocalCodingTarget.values)
        target: LocalCodingConfigurationStatus(
          target: target,
          state: LocalCodingConfigurationState.notConfigured,
          verificationLevel: 'l0',
          nextActions: const ['switch_global'],
          currentService: switched.contains(target)
              ? LocalCodingCurrentService.zhiban
              : LocalCodingCurrentService.official,
          globalSwitched: switched.contains(target),
          globalUpgradeAvailable: refresh.contains(target),
        ),
    },
    expectedProfileVersions: const {},
    registrationAvailable: true,
    supportedMethods: const {'install.execute'},
  );
}
