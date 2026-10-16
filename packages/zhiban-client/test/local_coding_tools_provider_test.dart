import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';
import 'package:zhiban_client/pages/local_coding_tools/providers/local_coding_tools_provider.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_tools_service.dart';

void main() {
  test('slow operation polling never overlaps the next timer tick', () async {
    final svc = _RecordingOperations()
      ..snapshot = _snapshot()
      ..startInstallResponse = _op(state: LocalCodingOperationState.running, stage: 'preflight');
    final held = Completer<LocalCodingOperation>();
    svc.pollOverride = (_) => held.future;
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    await container.read(localCodingToolsProvider.notifier).startInstall(LocalCodingTarget.codexCli);
    await Future<void>.delayed(const Duration(milliseconds: 1700));
    final callsBeforeRelease = svc.pollCalls;
    held.complete(_op(state: LocalCodingOperationState.succeeded, stage: 'detecting'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(callsBeforeRelease, 1);
    expect(container.read(localCodingToolsProvider).value!.operationFor(LocalCodingTarget.codexCli), isNull);
  });

  test('batch keeps polling failure code and message instead of UNKNOWN', () async {
    final svc = _RecordingOperations()
      ..snapshot = _catalogSnapshot(switched: {LocalCodingTarget.codexCli})
      ..startVerifyResponse = _op(state: LocalCodingOperationState.running, stage: 'l1', kind: LocalCodingOperationKind.verify)
      ..pollOverride = (_) async => throw const LocalCodingToolsException('rpc_timeout', '本地连接组件响应超时，请重试');
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);
    await notifier.connectTargets([LocalCodingTarget.codexCli]).timeout(const Duration(seconds: 5));
    final item = container.read(localCodingToolsProvider).value!.batchFor(LocalCodingVendor.codex)!.itemFor(LocalCodingTarget.codexCli);
    expect(item.errorCode, 'rpc_timeout');
    expect(item.errorMessage, '本地连接组件响应超时，请重试');
    svc.pollOverride = null;
    await notifier.connectTargets([LocalCodingTarget.codexCli]).timeout(const Duration(seconds: 5));
    expect(container.read(localCodingToolsProvider).value!.batchFor(LocalCodingVendor.codex)!.allSucceeded, isTrue);
  });

  test('refreshQuiet keeps the old snapshot then swaps in silently', () async {
    final svc = _RecordingOperations();
    final first = _snapshotWithVersion('1.0.0');
    final second = _snapshotWithVersion('1.0.1');
    svc.snapshot = first;

    final container = ProviderContainer(overrides: [
      localCodingToolsServiceProvider.overrideWithValue(svc)],
    );
    addTearDown(container.dispose);

    // 第一次 build:显式 inspect 得到 v1.0.0。
    final initial = await container.read(localCodingToolsProvider.future);
    expect(initial.snapshot.tools[LocalCodingTarget.codexCli]?.installedVersion,
        '1.0.0');
    expect(svc.inspectCalls, 1);

    // 后台切换 fake 返回 v1.0.1,然后 refreshQuiet。
    svc.snapshot = second;
    final beforeState =
        container.read(localCodingToolsProvider).value!.snapshot;
    // v1.7 §12 · 静默刷新过程中不进入 loading。
    final notifier = container.read(localCodingToolsProvider.notifier);
    final future = notifier.refreshQuiet();
    // 刷新期间旧快照仍可读、state 仍是 AsyncData。
    expect(container.read(localCodingToolsProvider).isLoading, isFalse);
    // 再次进入页面不显示检测进度(2026-09-15):只有首次进入与「重新检测」显示。
    expect(container.read(localCodingInspectProgressProvider), isNull);
    expect(
        container.read(localCodingToolsProvider).value?.snapshot == beforeState,
        isTrue);
    await future;
    // 刷新完成后已换成新快照。
    expect(
        container
            .read(localCodingToolsProvider)
            .value
            ?.snapshot
            .tools[LocalCodingTarget.codexCli]
            ?.installedVersion,
        '1.0.1');
    expect(svc.inspectCalls, 2);
  });

  test('startInstall stores op then polling advances to succeeded and cleans',
      () async {
    final svc = _RecordingOperations();
    svc.snapshot = _snapshot();
    // Two poll ticks: still running, then succeeded.
    svc.pollScript = <LocalCodingOperation>[
      _op(state: LocalCodingOperationState.running, stage: 'downloading'),
      _op(state: LocalCodingOperationState.succeeded, stage: 'detecting'),
    ];
    svc.startInstallResponse =
        _op(state: LocalCodingOperationState.running, stage: 'preflight');

    final container = ProviderContainer(overrides: [
      localCodingToolsServiceProvider.overrideWithValue(svc)],
    );
    addTearDown(container.dispose);
    await container.read(localCodingToolsProvider.future);

    final notifier = container.read(localCodingToolsProvider.notifier);
    final error = await notifier.startInstall(LocalCodingTarget.codexCli);
    expect(error, isNull);

    // 立刻可见 running operation。
    LocalCodingToolsPageData data =
        container.read(localCodingToolsProvider).value!;
    expect(data.operationFor(LocalCodingTarget.codexCli)?.stage, 'preflight');

    // Second startInstall while busy 直接返回 null(mutex)。
    expect(await notifier.startInstall(LocalCodingTarget.codexCli), isNull);
    expect(svc.startInstallCalls, 1);

    // 让 500 ms 轮询触发若干次(4 s 足够跑完 2 tick + 收尾)。
    final done = Completer<void>();
    Timer.periodic(const Duration(milliseconds: 200), (t) {
      final op = container.read(localCodingToolsProvider).value?.operationFor(
            LocalCodingTarget.codexCli
          );
      if (op == null) {
        t.cancel();
        done.complete();
      }
    });
    await done.future.timeout(const Duration(seconds: 5));

    expect(svc.pollCalls, greaterThanOrEqualTo(2));
    // 终态后 provider 自动 inspect 刷新快照。
    expect(svc.inspectCalls, greaterThanOrEqualTo(2));
  });

  test('connectTargets 按 CLI → 桌面端 串行执行,批处理到终态并给出横幅;环境未开放时装完即停', () async {
    final svc = _RecordingOperations();
    svc.snapshot = _snapshot();
    svc.startInstallResponse =
        _op(state: LocalCodingOperationState.running, stage: 'preflight');
    // pollScript 为空时 fake 直接返回 succeeded。

    final container = ProviderContainer(overrides: [
      localCodingToolsServiceProvider.overrideWithValue(svc)],
    );
    addTearDown(container.dispose);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    // 传入顺序故意颠倒,批处理应按 CLI 在前重排。
    final result = notifier.connectTargets(
        [LocalCodingTarget.codexDesktop, LocalCodingTarget.codexCli]);
    final batch = container
        .read(localCodingToolsProvider)
        .value!
        .batchFor(LocalCodingVendor.codex)!;
    // F31 §3.2.1 · 接入链;此夹具环境未开放(registrationAvailable=false),
    // 第①步装完即停,不写配置。
    expect(batch.kind, LocalCodingBatchKind.connect);
    expect(batch.targets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(batch.plans[LocalCodingTarget.codexCli]?.action,
        LocalCodingProgramAction.install);
    expect(batch.itemFor(LocalCodingTarget.codexCli).status,
        LocalCodingBatchItemStatus.running);
    expect(batch.itemFor(LocalCodingTarget.codexDesktop).status,
        LocalCodingBatchItemStatus.pending);
    expect(batch.done, isFalse);
    // 同厂商批处理进行中,再次发起直接返回 null。
    expect(await notifier.connectTargets([LocalCodingTarget.codexDesktop]),
        isNull);

    expect(await result.timeout(const Duration(seconds: 10)), isNull);
    final data = container.read(localCodingToolsProvider).value!;
    final done = data.batchFor(LocalCodingVendor.codex)!;
    expect(done.done, isTrue);
    expect(done.allSucceeded, isTrue);
    expect(svc.installedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(svc.startInstallCalls, 2);
    expect(svc.switchCalls, 0);
    expect(data.banner?.text, '安装完成，Codex 已可以在本机使用');
    // 各项 operation 成功后已清掉,卡片不再处于处理中。
    expect(data.operationFor(LocalCodingTarget.codexCli), isNull);
    expect(data.operationFor(LocalCodingTarget.codexDesktop), isNull);

    notifier.dismissBatch(LocalCodingVendor.codex);
    expect(
        container
            .read(localCodingToolsProvider)
            .value!
            .batchFor(LocalCodingVendor.codex),
        isNull);
  });

  test('M3 Task 8 · 装 Claude 桌面端后自动跟一步运行组件预置;Bridge 报已安装视为成功', () async {
    final svc = _RecordingOperations();
    svc.snapshot = _snapshot();
    svc.startInstallResponse =
        _op(state: LocalCodingOperationState.running, stage: 'preflight');

    final container = ProviderContainer(overrides: [
      localCodingToolsServiceProvider.overrideWithValue(svc)],
    );
    addTearDown(container.dispose);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    expect(
        await notifier
            .connectTargets([LocalCodingTarget.claudeDesktop]).timeout(
                const Duration(seconds: 10)),
        isNull);
    var data = container.read(localCodingToolsProvider).value!;
    var batch = data.batchFor(LocalCodingVendor.claude)!;
    expect(svc.installedTargets, [LocalCodingTarget.claudeDesktop]);
    expect(svc.installedComponents, ['claude_desktop:claude_code_host']);
    expect(batch.componentFor(LocalCodingTarget.claudeDesktop)?.status,
        LocalCodingBatchItemStatus.succeeded);
    expect(batch.allSucceeded, isTrue);
    expect(data.banner?.text, '安装完成，Claude 已可以在本机使用');
    notifier.dismissBatch(LocalCodingVendor.claude);

    // 组件已在位时 Bridge 报 ALREADY_INSTALLED:不算失败,批处理照常完成。
    svc.componentInstallError = const LocalCodingToolsException(
        'LCT-CLAUDE_DESKTOP-INSTALL-ALREADY_INSTALLED', '已安装');
    expect(
        await notifier
            .installComponent(LocalCodingTarget.claudeDesktop)
            .timeout(const Duration(seconds: 10)),
        isNull);
    data = container.read(localCodingToolsProvider).value!;
    batch = data.batchFor(LocalCodingVendor.claude)!;
    expect(batch.componentOnly, isTrue);
    expect(batch.componentFor(LocalCodingTarget.claudeDesktop)?.status,
        LocalCodingBatchItemStatus.succeeded);
    expect(batch.allSucceeded, isTrue);
    expect(data.banner?.text, '修复完成，Claude 桌面端 的运行组件已就绪');
    // Codex 桌面端没有运行组件,不会多出组件步。
    notifier.dismissBatch(LocalCodingVendor.claude);
    svc.installedComponents.clear();
    expect(
        await notifier.connectTargets([LocalCodingTarget.codexDesktop]).timeout(
            const Duration(seconds: 10)),
        isNull);
    expect(svc.installedComponents, isEmpty);
  });

  test('M3 · connectTargets 某一形态写配置失败只标记该项,另一形态照常成功,不出成功横幅', () async {
    final svc = _RecordingOperations();
    svc.snapshot = _installedOfficialSnapshot();
    svc.switchFailFor = LocalCodingTarget.codexDesktop;
    svc.startVerifyResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l1',
        kind: LocalCodingOperationKind.verify);
    svc.pollScript = <LocalCodingOperation>[
      _op(
          state: LocalCodingOperationState.succeeded,
          stage: 'l3',
          kind: LocalCodingOperationKind.verify),
    ];

    final container = ProviderContainer(overrides: [
      localCodingToolsServiceProvider.overrideWithValue(svc)],
    );
    addTearDown(container.dispose);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    final error = await notifier.connectTargets([
      LocalCodingTarget.codexCli,
      LocalCodingTarget.codexDesktop
    ]).timeout(const Duration(seconds: 10));
    expect(error, isA<LocalCodingToolsException>());
    expect((error as LocalCodingToolsException).code, 'switch_boom');

    final data = container.read(localCodingToolsProvider).value!;
    final batch = data.batchFor(LocalCodingVendor.codex)!;
    expect(batch.done, isTrue);
    expect(batch.anyFailed, isTrue);
    expect(batch.allSucceeded, isFalse);
    expect(batch.itemFor(LocalCodingTarget.codexCli).status,
        LocalCodingBatchItemStatus.succeeded);
    expect(batch.itemFor(LocalCodingTarget.codexDesktop).status,
        LocalCodingBatchItemStatus.failed);
    expect(
        batch.itemFor(LocalCodingTarget.codexDesktop).errorCode, 'switch_boom');
    expect(svc.switchedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(svc.startVerifyCalls, 1);
    expect(svc.lastVerifyScope, LocalCodingVerifyScope.global);
    expect(data.banner, isNull);
    // 失败项的 compound 保留给进度弹框显示错误码;关闭弹框时一并清掉。
    expect(data.compoundFor(LocalCodingTarget.codexDesktop)?.failed, isTrue);
    notifier.dismissBatch(LocalCodingVendor.codex);
    final after = container.read(localCodingToolsProvider).value!;
    expect(after.batchFor(LocalCodingVendor.codex), isNull);
    expect(after.compoundFor(LocalCodingTarget.codexDesktop), isNull);
  });

  test('诊断详情 · App 侧校验失败(Bridge 无记录)也能在 diagnostics 里看到错误码与说明', () async {
    final svc = _RecordingOperations();
    svc.snapshot = _installedOfficialSnapshot();
    svc.switchFailFor = LocalCodingTarget.codexDesktop;
    svc.startVerifyResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l1',
        kind: LocalCodingOperationKind.verify);
    svc.pollScript = <LocalCodingOperation>[
      _op(
          state: LocalCodingOperationState.succeeded,
          stage: 'l3',
          kind: LocalCodingOperationKind.verify),
    ];
    final container = ProviderContainer(overrides: [
      localCodingToolsServiceProvider.overrideWithValue(svc)],
    );
    addTearDown(container.dispose);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    await notifier.connectTargets([
      LocalCodingTarget.codexCli,
      LocalCodingTarget.codexDesktop
    ]).timeout(const Duration(seconds: 10));

    // 失败项带上给用户看的一句话;成功项不留 App 侧记录。
    final batch = container
        .read(localCodingToolsProvider)
        .value!
        .batchFor(LocalCodingVendor.codex)!;
    expect(batch.itemFor(LocalCodingTarget.codexDesktop).errorMessage, '切换失败');
    // 假 service 的 diagnostics 抛 UnimplementedError → Bridge 侧无记录 →
    // 回落到 App 侧记录。
    final diag = await notifier.diagnostics(LocalCodingTarget.codexDesktop);
    expect(diag, isNotNull);
    expect(diag!.errorCode, 'switch_boom');
    expect(diag.stage, 'app');
    expect(diag.kind, 'app.connect');
    expect(diag.suggestions, contains('切换失败'));
    expect(await notifier.diagnostics(LocalCodingTarget.codexCli), isNull);
  });

  test('F31 §3.2.1 · connectTargets 未安装且环境开放:安装 → 写配置 → 验证,横幅"接入完成"', () async {
    final svc = _RecordingOperations();
    svc.snapshot = _installedOfficialSnapshot(notInstalled: {
      LocalCodingTarget.codexCli,
      LocalCodingTarget.codexDesktop,
    });
    svc.startInstallResponse =
        _op(state: LocalCodingOperationState.running, stage: 'preflight');
    svc.startVerifyResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l1',
        kind: LocalCodingOperationKind.verify);
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    final result = notifier.connectTargets(
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    final batch = container
        .read(localCodingToolsProvider)
        .value!
        .batchFor(LocalCodingVendor.codex)!;
    expect(batch.kind, LocalCodingBatchKind.connect);
    expect(batch.plans[LocalCodingTarget.codexCli]?.action,
        LocalCodingProgramAction.install);
    expect(batch.plans[LocalCodingTarget.codexCli]?.writeConfig, isTrue);

    expect(await result.timeout(const Duration(seconds: 10)), isNull);
    final data = container.read(localCodingToolsProvider).value!;
    expect(data.batchFor(LocalCodingVendor.codex)!.allSucceeded, isTrue);
    expect(svc.installedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(svc.installModes,
        [LocalCodingInstallMode.install, LocalCodingInstallMode.install]);
    expect(svc.switchedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(svc.startVerifyCalls, 2);
    expect(svc.lastVerifyScope, LocalCodingVerifyScope.global);
    expect(data.banner?.title, '接入完成，Codex 已可以使用知办模型 API');
    expect(data.banner?.text, localCodingRelaunchHint);
  });

  test('F31 §3.2.1 · connectTargets npm 旧版本:接管到目录版本 → 写配置 → 验证', () async {
    final svc = _RecordingOperations();
    svc.snapshot = _catalogSnapshot(adoptVersion: '0.154.0');
    svc.startInstallResponse =
        _op(state: LocalCodingOperationState.running, stage: 'preflight');
    svc.startVerifyResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l1',
        kind: LocalCodingOperationKind.verify);
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    final plan = notifier.connectPlanFor(LocalCodingTarget.codexCli);
    expect(plan.action, LocalCodingProgramAction.adopt);
    expect(plan.fromVersion, '0.153.4');
    expect(plan.toVersion, '0.154.0');
    expect(
        await notifier.connectTargets([LocalCodingTarget.codexCli]).timeout(
            const Duration(seconds: 10)),
        isNull);
    expect(svc.installModes, [LocalCodingInstallMode.adopt]);
    expect(svc.switchedTargets, [LocalCodingTarget.codexCli]);
    expect(svc.startVerifyCalls, 1);
    expect(container.read(localCodingToolsProvider).value!.banner?.title,
        '接入完成，Codex 已可以使用知办模型 API');
  });

  test('F31 §3.2.1 · connectTargets 标准位置低于目录:升级 → 写配置 → 验证;桌面端不是切不了的原因,不进链', () async {
    final svc = _RecordingOperations();
    // 目录对命令行和桌面端都给了更高版本;桌面端能正常切换,版本留给后台维护。
    svc.snapshot = _catalogSnapshot(availableVersion: '0.154.0');
    svc.startInstallResponse =
        _op(state: LocalCodingOperationState.running, stage: 'preflight');
    svc.startVerifyResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l1',
        kind: LocalCodingOperationKind.verify);
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    expect(notifier.connectPlanFor(LocalCodingTarget.codexCli).action,
        LocalCodingProgramAction.upgrade);
    expect(notifier.connectPlanFor(LocalCodingTarget.codexDesktop).action,
        LocalCodingProgramAction.none);
    expect(
        await notifier.connectTargets([
          LocalCodingTarget.codexCli,
          LocalCodingTarget.codexDesktop
        ]).timeout(const Duration(seconds: 10)),
        isNull);
    expect(svc.installedTargets, [LocalCodingTarget.codexCli]);
    expect(svc.installModes, [LocalCodingInstallMode.upgrade]);
    expect(svc.switchedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(svc.startVerifyCalls, 2);
  });

  test('F31 §3.2.1 · connectTargets 已是目录版本(或用户版本更高):不换程序,直接写配置', () async {
    final svc = _RecordingOperations();
    // 不降级由 Bridge 保证:目录不高于已装版本时给不出 available_version。
    svc.snapshot = _catalogSnapshot();
    svc.startVerifyResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l1',
        kind: LocalCodingOperationKind.verify);
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    expect(
        await notifier.connectTargets([LocalCodingTarget.codexCli]).timeout(
            const Duration(seconds: 10)),
        isNull);
    expect(svc.installModes, isEmpty);
    expect(svc.switchedTargets, [LocalCodingTarget.codexCli]);
    expect(svc.startVerifyCalls, 1);
  });

  // 2026-09-17 · 1.2.7 真机:已接入的 Claude 配置只缺新键(根证书补充),Bridge 报
  // global_upgrade_available,但接入链只看"未切换 / 漂移",直接跳去验证——缺的正是
  // 让验证通过的那一项,「修复并重试」每点一次都是同一个证书错误。
  test('F31 §3.2.1 · connectTargets 已切换、未漂移但 Bridge 报配置可升级:先重写配置再验证',
      () async {
    final svc = _RecordingOperations();
    svc.snapshot = _installedOfficialSnapshot(
      switched: {LocalCodingTarget.claudeCli},
      upgrade: {LocalCodingTarget.claudeCli},
    );
    svc.startVerifyResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l1',
        kind: LocalCodingOperationKind.verify);
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    expect(notifier.connectPlanFor(LocalCodingTarget.claudeCli).writeConfig,
        isTrue);
    await notifier.connectTargets([LocalCodingTarget.claudeCli]).timeout(
        const Duration(seconds: 10));
    expect(svc.switchedTargets, [LocalCodingTarget.claudeCli]);
  });

  test('F31 §3.2.1 · connectTargets 已切换且未漂移:不写配置,只重新验证', () async {
    final svc = _RecordingOperations();
    svc.snapshot = _catalogSnapshot(switched: {LocalCodingTarget.codexCli});
    svc.startVerifyResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l1',
        kind: LocalCodingOperationKind.verify);
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    expect(notifier.connectPlanFor(LocalCodingTarget.codexCli).writeConfig,
        isFalse);
    expect(
        await notifier.connectTargets([LocalCodingTarget.codexCli]).timeout(
            const Duration(seconds: 10)),
        isNull);
    expect(svc.installModes, isEmpty);
    expect(svc.switchCalls, 0);
    expect(svc.startVerifyCalls, 1);
    expect(svc.lastVerifyScope, LocalCodingVerifyScope.global);
    expect(container.read(localCodingToolsProvider).value!.banner?.title,
        '接入完成，Codex 已可以使用知办模型 API');
  });

  test('F31 §3.2.1 · connectTargets 安装损坏:按锁定版本重装,再写配置 + 验证', () async {
    final svc = _RecordingOperations();
    svc.snapshot =
        _installedOfficialSnapshot(repairable: {LocalCodingTarget.codexCli});
    svc.startInstallResponse =
        _op(state: LocalCodingOperationState.running, stage: 'preflight');
    svc.startVerifyResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l1',
        kind: LocalCodingOperationKind.verify);
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    expect(
        await notifier.connectTargets([LocalCodingTarget.codexCli]).timeout(
            const Duration(seconds: 10)),
        isNull);
    expect(svc.installModes, [LocalCodingInstallMode.repair]);
    expect(svc.switchCalls, 1);
    expect(svc.startVerifyCalls, 1);
  });

  test('F31 §3.2.1 · connectTargets 第①步失败:该形态停在程序步,配置未动,不出横幅', () async {
    final svc = _RecordingOperations();
    svc.snapshot = _catalogSnapshot(availableVersion: '0.154.0');
    svc.startInstallResponse =
        _op(state: LocalCodingOperationState.running, stage: 'preflight');
    svc.pollScript = [
      _op(state: LocalCodingOperationState.running, stage: 'installing'),
      LocalCodingOperation(
        operationId: 'op-1',
        target: LocalCodingTarget.codexCli,
        kind: LocalCodingOperationKind.install,
        state: LocalCodingOperationState.failed,
        stage: 'downloading',
        progressKind: LocalCodingProgressKind.indeterminate,
        cancellable: false,
        errorCode: 'LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED',
        nextActions: const ['retry', 'diagnostics'],
      ),
    ];
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    final error = await notifier
        .connectTargets([LocalCodingTarget.codexCli]).timeout(
            const Duration(seconds: 10));
    expect((error as LocalCodingToolsException).code,
        'LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED');
    expect(svc.switchCalls, 0);
    expect(svc.startVerifyCalls, 0);
    final data = container.read(localCodingToolsProvider).value!;
    final batch = data.batchFor(LocalCodingVendor.codex)!;
    expect(batch.done, isTrue);
    expect(batch.itemFor(LocalCodingTarget.codexCli).errorCode,
        'LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED');
    expect(data.banner, isNull);
  });

  test('F31 §3.2.1 · Claude 桌面端不支持第三方推理且目录更高:它是切不了的原因,升级进链', () async {
    final svc = _RecordingOperations();
    svc.snapshot = _catalogSnapshot(
        availableVersion: '0.154.0', claudeDesktopThirdPartyUnsupported: true);
    svc.startInstallResponse =
        _op(state: LocalCodingOperationState.running, stage: 'preflight');
    svc.startVerifyResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l2',
        kind: LocalCodingOperationKind.verify);
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    expect(notifier.connectPlanFor(LocalCodingTarget.claudeDesktop).action,
        LocalCodingProgramAction.upgrade);
    expect(
        await notifier.connectTargets([LocalCodingTarget.claudeDesktop])
            .timeout(const Duration(seconds: 10)),
        isNull);
    expect(svc.installedTargets, [LocalCodingTarget.claudeDesktop]);
    expect(svc.installModes, [LocalCodingInstallMode.upgrade]);
    expect(svc.switchedTargets, [LocalCodingTarget.claudeDesktop]);
  });

  test('F31 §3.2.1 · Codex 命令行过旧又没有升级路径:不替桌面端写共用配置', () async {
    final svc = _RecordingOperations();
    svc.snapshot = _catalogSnapshot(codexCliTooOld: true);
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    final error = await notifier
        .connectTargets([LocalCodingTarget.codexDesktop]).timeout(
            const Duration(seconds: 10));
    expect((error as LocalCodingToolsException).code, 'shared_config_too_old');
    expect(svc.switchCalls, 0);
    expect(svc.installModes, isEmpty);
  });

  test('F31 §3.2.1 · 进页面只检测:build / reload / refreshQuiet 都不再自动切换', () async {
    final svc = _RecordingOperations();
    svc.snapshot = _installedOfficialSnapshot();
    final container = _container(svc);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.switchCalls, 0);
    await notifier.reload();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.switchCalls, 0);
    await notifier.refreshQuiet();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.switchCalls, 0);
    expect(container.read(localCodingToolsProvider).value!.batches, isEmpty);
  });

  test(
      '契约 §2.7.4 · upgradeTargets:startInstall(mode=upgrade)→ 已切换态再做全局验证;横幅带版本',
      () async {
    final svc = _RecordingOperations();
    svc.snapshot = _catalogSnapshot(
      switched: {LocalCodingTarget.codexCli},
      availableVersion: '0.154.0',
    );
    svc.startInstallResponse =
        _op(state: LocalCodingOperationState.running, stage: 'preflight');
    svc.startVerifyResponse = _op(
      state: LocalCodingOperationState.running,
      stage: 'l1',
      kind: LocalCodingOperationKind.verify,
    );
    // pollScript 为空时 fake 直接返回 succeeded。

    final container = ProviderContainer(overrides: [
      localCodingToolsServiceProvider.overrideWithValue(svc)],
    );
    addTearDown(container.dispose);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    final result = notifier.upgradeTargets(
        [LocalCodingTarget.codexDesktop, LocalCodingTarget.codexCli]);
    final batch = container
        .read(localCodingToolsProvider)
        .value!
        .batchFor(LocalCodingVendor.codex)!;
    expect(batch.kind, LocalCodingBatchKind.upgrade);
    expect(batch.targets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);

    expect(await result.timeout(const Duration(seconds: 10)), isNull);
    final data = container.read(localCodingToolsProvider).value!;
    expect(data.batchFor(LocalCodingVendor.codex)!.allSucceeded, isTrue);
    expect(svc.installedTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(svc.installModes, [
      LocalCodingInstallMode.upgrade,
      LocalCodingInstallMode.upgrade,
    ]);
    // 只有已切换的命令行形态在升级后做了全局验证;桌面端走官方,不验证。
    expect(svc.startVerifyCalls, 1);
    expect(svc.lastVerifyScope, LocalCodingVerifyScope.global);
    expect(data.banner?.text, '升级完成，Codex CLI 0.154.0、Codex 桌面端 0.154.0 已可以使用');
  });

  test(
      '契约 §2.7.4 · upgradeTargets 失败:升级中同厂商再次发起返回 null;失败项带错误码,不出横幅',
      () async {
    final svc = _RecordingOperations();
    svc.snapshot = _catalogSnapshot(availableVersion: '0.154.0');
    svc.startInstallResponse =
        _op(state: LocalCodingOperationState.running, stage: 'preflight');
    svc.pollScript = [
      _op(state: LocalCodingOperationState.running, stage: 'installing'),
      LocalCodingOperation(
        operationId: 'op-1',
        target: LocalCodingTarget.codexCli,
        kind: LocalCodingOperationKind.install,
        state: LocalCodingOperationState.failed,
        stage: 'detecting',
        progressKind: LocalCodingProgressKind.indeterminate,
        cancellable: false,
        errorCode: 'LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED',
        nextActions: const ['retry', 'diagnostics'],
      ),
    ];

    final container = ProviderContainer(overrides: [
      localCodingToolsServiceProvider.overrideWithValue(svc)],
    );
    addTearDown(container.dispose);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);

    final result = notifier.upgradeTargets([LocalCodingTarget.codexCli]);
    expect(
        container
            .read(localCodingToolsProvider)
            .value!
            .batchFor(LocalCodingVendor.codex)!
            .kind,
        LocalCodingBatchKind.upgrade);
    expect(await notifier.upgradeTargets([LocalCodingTarget.codexCli]), isNull);

    final error = await result.timeout(const Duration(seconds: 10));
    expect(error, isA<LocalCodingToolsException>());
    expect((error as LocalCodingToolsException).code,
        'LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED');
    expect(svc.installModes, [LocalCodingInstallMode.upgrade]);
    expect(svc.startVerifyCalls, 0);
    final data = container.read(localCodingToolsProvider).value!;
    final batch = data.batchFor(LocalCodingVendor.codex)!;
    expect(batch.done, isTrue);
    expect(batch.itemFor(LocalCodingTarget.codexCli).errorCode,
        'LCT-CODEX_CLI-INSTALL-DOWNLOAD_FAILED');
    expect(data.banner, isNull);
  });

  test('一键上报诊断把本机现场交给支持,返回反馈编号', () async {
    final svc = _RecordingOperations();
    svc.snapshot = _snapshotWithVersion('0.133.0');
    final container = ProviderContainer(overrides: [
      localCodingToolsServiceProvider.overrideWithValue(svc)],
    );
    addTearDown(container.dispose);
    await container.read(localCodingToolsProvider.future);

    final reference = await container
        .read(localCodingToolsProvider.notifier)
        .reportDiagnostics(LocalCodingTarget.codexCli);

    expect(reference, 'feedback-uuid-0001');
    final info = svc.reportedClientInfo;
    expect(info, isNotNull);
    expect(info!['kind'], 'local_coding_tools');
    expect(info['vendor'], 'codex');
    expect(info['reported_target'], LocalCodingTarget.codexCli.id);
    // 现场要带上这一版的本机状态,才有定位价值。
    final targets = info['targets'] as List;
    expect(targets, isNotEmpty);
    expect((targets.first as Map)['installed_version'], '0.133.0');
    // 不得夹带配置内容或令牌。
    final dumped = info.toString();
    expect(dumped.contains('Bearer'), isFalse);
    expect(dumped.contains('apiKeyHelper'), isFalse);

    svc.reportReference = null;
    expect(
        await container
            .read(localCodingToolsProvider.notifier)
            .reportDiagnostics(LocalCodingTarget.codexCli),
        isNull);
  });

  test('F31 §3.2.1 · 恢复官方配置不再记"用户选择官方";之后再接入照常重新写配置', () async {
    final svc = _RecordingOperations();
    svc.snapshot =
        _installedOfficialSnapshot(switched: {LocalCodingTarget.codexCli});
    svc.startVerifyResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l1',
        kind: LocalCodingOperationKind.verify);
    final container = ProviderContainer(overrides: [
      localCodingToolsServiceProvider.overrideWithValue(svc)],
    );
    addTearDown(container.dispose);
    await container.read(localCodingToolsProvider.future);
    final notifier = container.read(localCodingToolsProvider.notifier);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(svc.switchCalls, 0);

    // Bridge 恢复后返回的快照已是官方服务:直接上屏,收尾不再全量检测。
    svc.snapshot = _installedOfficialSnapshot();
    final inspectsBeforeRestore = svc.inspectCalls;
    expect(await notifier.restoreTargets([LocalCodingTarget.codexCli]), isNull);
    expect(svc.restoreCalls, 1);
    expect(svc.inspectCalls, inspectsBeforeRestore);
    final restoredData = container.read(localCodingToolsProvider).value!;
    expect(
        restoredData.snapshot.configurations[LocalCodingTarget.codexCli]!
            .switchedToZhiban,
        isFalse);
    expect(restoredData.banner?.title, '已恢复 Codex 官方配置');
    expect(restoredData.banner?.text, localCodingRelaunchHint);

    // 再接入:配置又是官方的,链会重新写一次;没有任何"选择官方"记忆挡着。
    expect(
        await notifier.connectTargets([LocalCodingTarget.codexCli]).timeout(
            const Duration(seconds: 10)),
        isNull);
    expect(svc.switchedTargets, [LocalCodingTarget.codexCli]);
  });
}

ProviderContainer _container(_RecordingOperations svc) {
  final container = ProviderContainer(overrides: [
    localCodingToolsServiceProvider.overrideWithValue(svc)],
  );
  addTearDown(container.dispose);
  return container;
}

/// 已安装、走官方服务、可切换的快照;[switched] 里的形态视为已切且 L3;
/// [notInstalled] / [repairable] 里的形态分别未安装 / 安装损坏。
LocalCodingToolsSnapshot _installedOfficialSnapshot({
  Set<LocalCodingTarget> switched = const {},
  Set<LocalCodingTarget> upgrade = const {},
  Set<LocalCodingTarget> notInstalled = const {},
  Set<LocalCodingTarget> repairable = const {},
}) {
  const deviceId = '11111111-1111-4111-8111-111111111111';
  return LocalCodingToolsSnapshot(
    deviceId: deviceId,
    environment: 'prod',
    credentialStatus: const LocalCodingCredentialStatus(
      identityPresent: true,
      authorizationPresent: true,
      targets: {},
    ),
    tools: {
      for (final target in LocalCodingTarget.values)
        target: LocalCodingToolState(
          target: target,
          generation: 1,
          uiState: notInstalled.contains(target)
              ? LocalCodingToolUiState.notInstalled
              : repairable.contains(target)
                  ? LocalCodingToolUiState.repairable
                  : switched.contains(target)
                      ? LocalCodingToolUiState.ready
                      : LocalCodingToolUiState.installedUnmanaged,
          installedVersion: notInstalled.contains(target) ? '' : '1.0.0',
          installSource: 'official',
          verificationLevel: 'l0',
          nextActions: const ['detect'],
        ),
    },
    configurations: {
      for (final target in LocalCodingTarget.values)
        target: LocalCodingConfigurationStatus(
          target: target,
          state: LocalCodingConfigurationState.notConfigured,
          verificationLevel: 'l0',
          nextActions: const ['configure'],
          currentService: switched.contains(target)
              ? LocalCodingCurrentService.zhiban
              : LocalCodingCurrentService.official,
          globalSwitched: switched.contains(target),
          globalVerificationLevel: switched.contains(target) ? 'l3' : '',
          globalUpgradeAvailable: upgrade.contains(target),
        ),
    },
    expectedProfileVersions: const {},
    registrationAvailable: true,
    supportedMethods: const {
      'install.plan',
      'install.execute',
      'operation.get',
      'verify.execute',
    },
  );
}

class _RecordingOperations implements LocalCodingToolsOperations {
  LocalCodingToolsSnapshot? snapshot;
  int inspectCalls = 0;
  int startInstallCalls = 0;
  int pollCalls = 0;
  int cancelCalls = 0;
  LocalCodingOperation? startInstallResponse;
  List<LocalCodingOperation> pollScript = [];
  Future<LocalCodingOperation> Function(String)? pollOverride;

  @override
  Future<LocalCodingToolsSnapshot> inspect({
    void Function(LocalCodingInspectProgress progress)? onProgress,
  }) async {
    inspectCalls++;
    return snapshot!;
  }

  @override
  Future<LocalCodingToolsSnapshot> registerOrRotate() async => snapshot!;

  @override
  Future<LocalCodingToolsSnapshot> enable(LocalCodingTarget target) async =>
      snapshot!;

  @override
  Future<LocalCodingLaunchResult?> launch(
    LocalCodingTarget target, {
    LocalCodingLaunchMode mode = LocalCodingLaunchMode.managed,
  }) async =>
      null;

  @override
  Future<void> removeAuthorization() async {}

  @override
  Future<bool> reconnectIfSameIdentity() async => false;

  @override
  Future<LocalCodingRequirements> requirements(
          LocalCodingTarget target) async =>
      throw UnimplementedError();

  final List<LocalCodingTarget> installedTargets = [];

  @override
  Future<LocalCodingOperation> startInstall(
    LocalCodingTarget target, {
    LocalCodingInstallMode mode = LocalCodingInstallMode.install,
    String? component,
  }) async {
    startInstallCalls++;
    if (component != null) {
      installedComponents.add('${target.id}:$component');
      final error = componentInstallError;
      if (error != null) throw error;
      return startInstallResponse!;
    }
    installedTargets.add(target);
    installModes.add(mode);
    return startInstallResponse!;
  }

  final List<LocalCodingInstallMode> installModes = [];
  final List<String> installedComponents = [];
  Object? componentInstallError;

  @override
  Future<LocalCodingOperation> startVerify(
    LocalCodingTarget target, {
    LocalCodingVerifyScope scope = LocalCodingVerifyScope.overlay,
  }) async {
    startVerifyCalls++;
    lastVerifyScope = scope;
    return startVerifyResponse ?? (throw UnimplementedError());
  }

  int startVerifyCalls = 0;
  LocalCodingVerifyScope? lastVerifyScope;
  LocalCodingOperation? startVerifyResponse;

  @override
  Future<LocalCodingToolsSnapshot> switchToZhiban(
      LocalCodingTarget target) async {
    switchCalls++;
    switchedTarget = target;
    switchedTargets.add(target);
    if (target == switchFailFor) {
      throw const LocalCodingToolsException('switch_boom', '切换失败');
    }
    return snapshot!;
  }

  int switchCalls = 0;
  LocalCodingTarget? switchedTarget;
  final List<LocalCodingTarget> switchedTargets = [];
  LocalCodingTarget? switchFailFor;

  @override
  Future<LocalCodingToolsSnapshot> restoreOfficial(
      LocalCodingTarget target) async {
    restoreCalls++;
    restoredTarget = target;
    return snapshot!;
  }

  int restoreCalls = 0;
  LocalCodingTarget? restoredTarget;

  @override
  Future<LocalCodingLaunchResult> openApp(LocalCodingTarget target) async {
    openAppCalls++;
    openedTarget = target;
    return LocalCodingLaunchResult(
        target: target, state: 'launched', projectName: '~');
  }

  int openAppCalls = 0;
  LocalCodingTarget? openedTarget;

  @override
  Future<LocalCodingToolsSnapshot> applyProxyFix() async => snapshot!;

  @override
  Future<LocalCodingOperation> pollOperation(String operationId) async {
    pollCalls++;
    if (pollOverride != null) return pollOverride!(operationId);
    if (pollScript.isEmpty) {
      return _op(
          state: LocalCodingOperationState.succeeded, stage: 'detecting');
    }
    return pollScript.removeAt(0);
  }

  @override
  Future<LocalCodingOperation> cancelOperation(String operationId) async {
    cancelCalls++;
    return _op(
        state: LocalCodingOperationState.cancelled, stage: 'downloading');
  }

  @override
  Future<LocalCodingToolsSnapshot> removeConfiguration(
    LocalCodingTarget target,
  ) async =>
      snapshot!;

  @override
  Future<LocalCodingToolsSnapshot> repairConfiguration(
    LocalCodingTarget target,
  ) async =>
      snapshot!;

  @override
  Future<LocalCodingDiagnostics> diagnostics(LocalCodingTarget target) async =>
      throw UnimplementedError();

  Map<String, dynamic>? reportedClientInfo;
  String? reportReference = 'feedback-uuid-0001';

  @override
  Future<String?> reportDiagnostics({
    required String title,
    required String description,
    required Map<String, dynamic> clientInfo,
  }) async {
    reportedClientInfo = clientInfo;
    return reportReference;
  }
}

/// 已安装官方来源、Bridge 接了目录的快照:[availableVersion] / [rollbackVersion]
/// 落在每个 target 上;[switched] 里的形态已切换为知办模型 API。
LocalCodingToolsSnapshot _catalogSnapshot({
  Set<LocalCodingTarget> switched = const {},
  String availableVersion = '',
  String rollbackVersion = '',
  // 2026-09-17 · Codex 命令行是 npm 装的,知办可接管到这个版本(只落在命令行上)。
  String adoptVersion = '',
  // Codex 命令行低于最低可切换版本且没有升级 / 接管路径。
  bool codexCliTooOld = false,
  // Claude 桌面端不支持第三方推理配置(老版本)。
  bool claudeDesktopThirdPartyUnsupported = false,
}) {
  const deviceId = '11111111-1111-4111-8111-111111111111';
  return LocalCodingToolsSnapshot(
    deviceId: deviceId,
    environment: 'prod',
    credentialStatus: const LocalCodingCredentialStatus(
      identityPresent: true,
      authorizationPresent: true,
      targets: {},
    ),
    tools: {
      for (final target in LocalCodingTarget.values)
        target: LocalCodingToolState(
          target: target,
          generation: 1,
          uiState: LocalCodingToolUiState.installedUnmanaged,
          installedVersion: '0.153.4',
          installSource: target == LocalCodingTarget.codexCli &&
                  (adoptVersion.isNotEmpty || codexCliTooOld)
              ? 'npm'
              : 'official',
          verificationLevel: 'l0',
          nextActions: const ['detect'],
          errorCode: target == LocalCodingTarget.codexCli && codexCliTooOld
              ? 'LCT-CODEX_CLI-DETECT-VERSION_TOO_OLD'
              : target == LocalCodingTarget.claudeDesktop &&
                      claudeDesktopThirdPartyUnsupported
                  ? 'LCT-CLAUDE_DESKTOP-DETECT-THIRD_PARTY_UNSUPPORTED'
                  : '',
          supportsEnable: !(target == LocalCodingTarget.codexCli &&
                  codexCliTooOld) &&
              !(target == LocalCodingTarget.claudeDesktop &&
                  claudeDesktopThirdPartyUnsupported),
          availableVersion: availableVersion,
          updateAvailable: availableVersion.isNotEmpty,
          rollbackVersion: rollbackVersion,
          adoptVersion:
              target == LocalCodingTarget.codexCli ? adoptVersion : '',
        ),
    },
    configurations: {
      for (final target in LocalCodingTarget.values)
        target: LocalCodingConfigurationStatus(
          target: target,
          state: LocalCodingConfigurationState.notConfigured,
          verificationLevel: 'l0',
          nextActions: const ['configure'],
          currentService: switched.contains(target)
              ? LocalCodingCurrentService.zhiban
              : LocalCodingCurrentService.official,
          globalSwitched: switched.contains(target),
          globalBackupAvailable: switched.contains(target),
          globalVerificationLevel: switched.contains(target) ? 'l3' : '',
        ),
    },
    expectedProfileVersions: const {},
    registrationAvailable: true,
    supportedMethods: const {
      'install.plan',
      'install.execute',
      'operation.get',
      'verify.execute',
      'catalog.apply',
    },
  );
}

LocalCodingOperation _op({
  required LocalCodingOperationState state,
  required String stage,
  LocalCodingOperationKind kind = LocalCodingOperationKind.install,
}) {
  return LocalCodingOperation(
    operationId: 'op-1',
    target: LocalCodingTarget.codexCli,
    kind: kind,
    state: state,
    stage: stage,
    progressKind: LocalCodingProgressKind.indeterminate,
    cancellable: state == LocalCodingOperationState.running,
    nextActions: state == LocalCodingOperationState.running
        ? const ['cancel']
        : const [],
    result: state == LocalCodingOperationState.succeeded ? const {} : null,
  );
}

LocalCodingToolsSnapshot _snapshotWithVersion(String version) {
  const deviceId = '11111111-1111-4111-8111-111111111111';
  return LocalCodingToolsSnapshot(
    deviceId: deviceId,
    environment: 'prod',
    credentialStatus: const LocalCodingCredentialStatus(
      identityPresent: true,
      authorizationPresent: false,
      targets: {},
    ),
    tools: {
      for (final target in LocalCodingTarget.values)
        target: LocalCodingToolState(
          target: target,
          generation: 1,
          uiState: LocalCodingToolUiState.installedUnmanaged,
          installedVersion: version,
          verificationLevel: 'l0',
          nextActions: const ['detect'],
        ),
    },
    configurations: {
      for (final target in LocalCodingTarget.values)
        target: LocalCodingConfigurationStatus(
          target: target,
          state: LocalCodingConfigurationState.notConfigured,
          verificationLevel: 'l0',
          nextActions: const ['configure'],
        ),
    },
    expectedProfileVersions: const {},
    registrationAvailable: false,
  );
}

LocalCodingToolsSnapshot _snapshot() {
  const deviceId = '11111111-1111-4111-8111-111111111111';
  return LocalCodingToolsSnapshot(
    deviceId: deviceId,
    environment: 'prod',
    credentialStatus: const LocalCodingCredentialStatus(
      identityPresent: true,
      authorizationPresent: false,
      targets: {},
    ),
    tools: {
      for (final target in LocalCodingTarget.values)
        target: LocalCodingToolState(
          target: target,
          generation: 1,
          uiState: LocalCodingToolUiState.notInstalled,
          verificationLevel: 'l0',
          nextActions: const ['detect'],
        ),
    },
    configurations: {
      for (final target in LocalCodingTarget.values)
        target: LocalCodingConfigurationStatus(
          target: target,
          state: LocalCodingConfigurationState.notConfigured,
          verificationLevel: 'l0',
          nextActions: const ['configure'],
        ),
    },
    expectedProfileVersions: const {},
    registrationAvailable: false,
    supportedMethods: const {
      'install.plan',
      'install.execute',
      'operation.get'
    },
  );
}
