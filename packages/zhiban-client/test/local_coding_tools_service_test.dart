import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_bridge_client.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_catalog_api.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_tools_service.dart';

void main() {
  const deviceId = '11111111-1111-4111-8111-111111111111';
  const credentialId = '22222222-2222-4222-8222-222222222222';
  const deviceCredential = 'lctd.$credentialId.'
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV';
  const profiles = {
    'codex_cli': 'codex-v1',
    'claude_cli': 'claude-v1'
  };

  test('project launch uses picker bookmark and one initialized session',
      () async {
    final events = <String>[];
    final session = _FakeSession(events: events)
      ..configuredTargets.add(LocalCodingTarget.claudeCli)
      ..configurationProfileVersions[LocalCodingTarget.claudeCli] = 'claude-v1';
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
      projectDirectoryPicker: () async {
        events.add('project.pick');
        return '/Users/alice/private-project';
      },
      projectBookmarkCreator: (path) async {
        expect(path, '/Users/alice/private-project');
        events.add('project.bookmark');
        return 'Ym9va21hcms=';
      },
    );

    final result = await service.launch(LocalCodingTarget.claudeCli);

    expect(result?.state, 'launched');
    expect(result?.projectName, 'private-project');
    expect(events, [
      'project.pick',
      'project.bookmark',
      'open',
      'status',
      'config.status.claude_cli',
      'detect.claude_cli',
      'project.grant.create',
      'launch.plan.claude_cli',
      'launch.execute',
      'close',
    ]);
    expect(session.createdBookmark, 'Ym9va21hcms=');
    expect(session.launchInstallationId, 'opaque-claude_cli');
    expect(session.launchProfileVersion, 'claude-v1');
  });

  test('cancelled project picker does not open bridge', () async {
    final events = <String>[];
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(_FakeSession(events: events), events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
      projectDirectoryPicker: () async {
        events.add('project.pick');
        return null;
      },
      projectBookmarkCreator: (_) async => throw StateError('not called'),
    );

    expect(await service.launch(LocalCodingTarget.codexCli), isNull);
    expect(events, ['project.pick']);
  });

  test('one click authorizes then configures only the selected target',
      () async {
    final events = <String>[];
    final session = _FakeSession(events: events, authorizationPresent: false);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(
        events: events,
        registration: const LocalCodingDeviceRegistration(
          credentialId: credentialId,
          deviceCredential: deviceCredential,
        ),
      ),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    final snapshot = await service.enable(LocalCodingTarget.codexCli);

    expect(events, [
      'open',
      'status',
      'config.status.codex_cli',
      'detect.codex_cli',
      'prepare',
      'http.register',
      'commit',
      'config.plan.codex_cli',
      'config.execute',
      'status',
      // 2026-09-15 · 按厂商检测:Codex 两形态的安装与配置读完再读 Claude。
      'detect.codex_cli',
      'detect.codex_desktop',
      'config.status.codex_cli',
      'config.status.codex_desktop',
      'detect.claude_cli',
      'detect.claude_desktop',
      'config.status.claude_cli',
      'config.status.claude_desktop',
      'close',
    ]);
    expect(snapshot.configurationFor(LocalCodingTarget.codexCli).configured,
        isTrue);
    expect(snapshot.configurationCurrent(LocalCodingTarget.codexCli), isTrue);
    expect(snapshot.configurationFor(LocalCodingTarget.claudeCli).configured,
        isFalse);
  });

  test('one click rotates stale authorization before updating the profile',
      () async {
    final events = <String>[];
    final session = _FakeSession(events: events);
    session.configuredTargets.add(LocalCodingTarget.codexCli);
    session.configurationProfileVersions[LocalCodingTarget.codexCli] =
        'codex-old';
    session.authorizationProfileVersions['codex_cli'] = 'codex-old';
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(
        events: events,
        registration: const LocalCodingDeviceRegistration(
          credentialId: credentialId,
          deviceCredential: deviceCredential,
        ),
      ),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    final snapshot = await service.enable(LocalCodingTarget.codexCli);

    expect(
        events,
        containsAllInOrder([
          'status',
          'config.status.codex_cli',
          'detect.codex_cli',
          'prepare',
          'http.register',
          'commit',
          'config.plan.codex_cli',
          'config.execute',
        ]));
    expect(session.committedProfiles, profiles);
    expect(snapshot.configurationCurrent(LocalCodingTarget.codexCli), isTrue);
  });

  test('one click stops before planning when managed file is in conflict',
      () async {
    final events = <String>[];
    final session = _FakeSession(
      events: events,
      authorizationPresent: false
    )..conflictTargets.add(LocalCodingTarget.codexCli);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    await expectLater(
      service.enable(LocalCodingTarget.codexCli),
      throwsA(isA<LocalCodingToolsException>().having(
        (error) => error.code,
        'code',
        'configuration_conflict',
      )),
    );

    expect(events, [
      'open',
      'status',
      'config.status.codex_cli',
      'close'
    ]);
  });

  test('registers with prepare HTTP commit ordering in the same session',
      () async {
    final events = <String>[];
    final session = _FakeSession(events: events);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(
        events: events,
        registration: const LocalCodingDeviceRegistration(
          credentialId: credentialId,
          deviceCredential: deviceCredential,
        ),
      ),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    final snapshot = await service.registerOrRotate();

    expect(events, [
      'open',
      'prepare',
      'http.register',
      'commit',
      'status',
      // 2026-09-15 · 按厂商检测:Codex 两形态的安装与配置读完再读 Claude。
      'detect.codex_cli',
      'detect.codex_desktop',
      'config.status.codex_cli',
      'config.status.codex_desktop',
      'detect.claude_cli',
      'detect.claude_desktop',
      'config.status.claude_cli',
      'config.status.claude_desktop',
      'close',
    ]);
    expect(snapshot.authorizationConnected, isTrue);
    expect(session.committedProfiles, profiles);
    expect(session.committedCredential, deviceCredential);
  });

  test('registration response is validated before credential commit', () async {
    final events = <String>[];
    final session = _FakeSession(events: events);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(
        events: events,
        registration: const LocalCodingDeviceRegistration(
          credentialId: 'bad-id',
          deviceCredential: 'secret-must-not-leak',
        ),
      ),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    await expectLater(
      service.registerOrRotate(),
      throwsA(
        isA<LocalCodingToolsException>()
            .having(
              (error) => error.toString(),
              'sanitized',
              isNot(contains('secret-must-not-leak')),
            )
            .having(
              (error) => error.requiresReregistration,
              'requires re-registration',
              isTrue,
            ),
      ),
    );
    expect(events, ['open', 'prepare', 'http.register', 'close']);
  });

  test('commit failure is reported as requiring re-registration', () async {
    final events = <String>[];
    final session = _FakeSession(events: events, failCommit: true);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(
        events: events,
        registration: const LocalCodingDeviceRegistration(
          credentialId: credentialId,
          deviceCredential: deviceCredential,
        ),
      ),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    await expectLater(
      service.registerOrRotate(),
      throwsA(isA<LocalCodingToolsException>().having(
        (error) => error.requiresReregistration,
        'requires re-registration',
        isTrue,
      )),
    );
    expect(events, ['open', 'prepare', 'http.register', 'commit', 'close']);
  });

  test(
      'remote revoke failure still clears local authorization and queues retry',
      () async {
    final events = <String>[];
    final pendingStore = _MemoryPendingRevocationStore();
    final session = _FakeSession(events: events);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events, failRevoke: true),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: pendingStore,
    );

    await expectLater(
      service.removeAuthorization(),
      throwsA(isA<LocalCodingToolsException>().having(
        (error) => error.remoteRevocationPending,
        'remote retry pending',
        isTrue,
      )),
    );

    expect(events, ['http.revoke', 'open', 'clear', 'close']);
    expect(pendingStore.value?.deviceId, deviceId);
    expect(pendingStore.value?.accountId, 'account-1');
    expect(pendingStore.value?.remoteRevocationPending, isTrue);
    expect(pendingStore.value?.localCleanupPending, isFalse);

    final snapshot = await service.inspect();
    expect(snapshot.remoteRevocationPending, isTrue);
    expect(snapshot.authorizationConnected, isFalse);
  });

  test('检测过程可视化 · inspect 按厂商逐项上报进度,Codex 读完配置时快照还没有 Claude', () async {
    final events = <String>[];
    final session = _FakeSession(events: events)
      ..supported = {
        ..._FakeSession(events: []).supported,
        'network.proxy_status'
      };
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    final progress = <LocalCodingInspectProgress>[];
    final snapshot = await service.inspect(onProgress: progress.add);

    final steps = progress.first.steps;
    expect(steps.map((s) => '${s.vendor?.name ?? '-'}:${s.kind.name}'), [
      '-:prepare',
      'codex:detectCli',
      'codex:detectDesktop',
      'codex:readConfig',
      'claude:detectCli',
      'claude:detectDesktop',
      'claude:readConfig',
      'codex:network',
    ]);
    expect(progress.map((p) => p.completed), [0, 1, 2, 3, 4, 5, 6, 7, 8]);
    final codexRead =
        progress.firstWhere((p) => p.configRead(LocalCodingVendor.codex));
    expect(codexRead.snapshot?.hasTarget(LocalCodingTarget.codexCli), isTrue);
    expect(codexRead.snapshot?.hasTarget(LocalCodingTarget.claudeCli), isFalse);
    expect(codexRead.vendorDone(LocalCodingVendor.codex), isFalse);
    // Claude 的中间步骤沿用 Codex 读完时的快照,不会把已填好的卡片清空。
    expect(progress[5].snapshot?.hasTarget(LocalCodingTarget.codexCli), isTrue);
    expect(progress.last.current, isNull);
    expect(progress.last.vendorDone(LocalCodingVendor.codex), isTrue);
    expect(snapshot.hasTarget(LocalCodingTarget.claudeDesktop), isTrue);
  });

  test('契约 §2.7 · 单个 target 的检测结果读不懂只把这张卡标为检测异常,其它照常读完', () async {
    final events = <String>[];
    final session = _FakeSession(events: events)
      ..unreadableTargets.add(LocalCodingTarget.codexCli);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    final snapshot = await service.inspect();

    final codex = snapshot.stateFor(LocalCodingTarget.codexCli);
    expect(codex.uiState, LocalCodingToolUiState.unsupported);
    expect(codex.resultUnreadable, isTrue);
    expect(codex.errorCode, 'LCT-CODEX_CLI-DETECT-RESULT_UNREADABLE');
    expect(codex.supportsEnable, isFalse);
    expect(codex.installationId, isEmpty);
    // 其余三个形态照常检测,四个配置状态照常读取。
    for (final target in LocalCodingTarget.values) {
      expect(snapshot.hasTarget(target), isTrue);
      if (target == LocalCodingTarget.codexCli) continue;
      expect(snapshot.stateFor(target).uiState,
          LocalCodingToolUiState.installedUnmanaged);
    }
    expect(events.where((e) => e.startsWith('config.status')), hasLength(4));
    expect(snapshot.configRefreshEligible(LocalCodingTarget.codexCli), isFalse);
  });

  test('unsafe configuration keeps installation results and other targets',
      () async {
    final events = <String>[];
    final session = _FakeSession(events: events)
      ..unsafeTargets.add(LocalCodingTarget.codexCli);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.5.1',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
          accountId: 'account-1', tenantId: 'tenant-1'),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );
    final snapshot = await service.inspect();
    expect(snapshot.configurationFor(LocalCodingTarget.codexCli).pathUnsafe,
        isTrue);
    expect(snapshot.configurationFor(LocalCodingTarget.codexCli).currentService,
        LocalCodingCurrentService.unknown);
    for (final target in LocalCodingTarget.values) {
      expect(snapshot.hasTarget(target), isTrue);
      expect(snapshot.stateFor(target).uiState,
          LocalCodingToolUiState.installedUnmanaged);
      if (target != LocalCodingTarget.codexCli) {
        expect(snapshot.configurationFor(target).pathUnsafe, isFalse);
      }
    }
    expect(events.where((e) => e.startsWith('config.status')), hasLength(4));
    expect(events, isNot(contains('prepare')));
  });

  test('2026-09-16 · 服务端撤销欠账不再拦住重新接入,接入成功即结清', () async {
    // 测试用户实测:两个工具都是最新版,切换仍被"上次设备授权撤销尚未完成，请恢复
    // 网络后重试"永久挡住。这条记录只是清理欠账——本机凭证已删、旧授权与本机私钥
    // 绑定用不了,重新接入本身又是 Rotate,顶掉旧凭证。
    final events = <String>[];
    final pendingStore = _MemoryPendingRevocationStore()
      ..value = const LocalCodingPendingRevocation(
        deviceId: deviceId,
        accountId: 'account-1',
        tenantId: 'tenant-1',
        environment: 'prod',
      );
    final session = _FakeSession(events: events);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(
        events: events,
        failRevoke: true,
        registration: const LocalCodingDeviceRegistration(
          credentialId: credentialId,
          deviceCredential: deviceCredential,
        ),
      ),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: pendingStore,
    );

    await service.registerOrRotate();

    // 撤销顺手重试了一次(仍失败),但接入照常走完;接入成功后欠账结清。
    expect(events.take(4), ['http.revoke', 'open', 'prepare', 'http.register']);
    expect(pendingStore.value, isNull);
  });

  test('local clear failure stays pending and is retried before inspection',
      () async {
    final events = <String>[];
    final pendingStore = _MemoryPendingRevocationStore();
    final session = _FakeSession(events: events, failClear: true);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: pendingStore,
    );

    await expectLater(
      service.removeAuthorization(),
      throwsA(isA<LocalCodingToolsException>()),
    );
    expect(pendingStore.value?.remoteRevocationPending, isFalse);
    expect(pendingStore.value?.localCleanupPending, isTrue);

    events.clear();
    session.failClear = false;
    await service.inspect();

    expect(events, [
      'open',
      'clear',
      'close',
      'open',
      'status',
      // 2026-09-15 · 按厂商检测:Codex 两形态的安装与配置读完再读 Claude。
      'detect.codex_cli',
      'detect.codex_desktop',
      'config.status.codex_cli',
      'config.status.codex_desktop',
      'detect.claude_cli',
      'detect.claude_desktop',
      'config.status.claude_cli',
      'config.status.claude_desktop',
      'close',
    ]);
    expect(pendingStore.value, isNull);
  });

  test('matching pending revoke retries before read-only inspection', () async {
    final events = <String>[];
    final pendingStore = _MemoryPendingRevocationStore()
      ..value = const LocalCodingPendingRevocation(
        deviceId: deviceId,
        accountId: 'account-1',
        tenantId: 'tenant-1',
        environment: 'prod',
      );
    final session = _FakeSession(events: events);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: pendingStore,
    );

    await service.inspect();

    expect(events.first, 'http.revoke');
    expect(pendingStore.value, isNull);
  });

  test('missing profile versions allows inspect but blocks registration',
      () async {
    final events = <String>[];
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(
        _FakeSession(events: events),
        events,
      ),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: const {},
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    final snapshot = await service.inspect();
    expect(snapshot.registrationAvailable, isFalse);
    await expectLater(
      service.registerOrRotate(),
      throwsA(isA<LocalCodingToolsException>()),
    );
  });

  // ─── M1G · install / verify 长操作与错误映射 ─────────────────────────
  test('契约 §2.7.4 · inspect 先拉目录交给 Bridge 验签;404 让 Bridge 清除;取不到或验签失败不影响快照',
      () async {
    final events = <String>[];
    final session = _FakeSession(events: events)
      ..supported = {..._FakeSession(events: []).supported, 'catalog.apply'};
    final signed = LocalCodingSignedCatalog(
      catalog: const {'schema': 1, 'targets': {}},
      kid: 'lc-catalog-test',
      signature: 'YWJj',
    );
    final catalogApi = _FakeCatalogApi(events: events, catalog: signed);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      catalogApi: catalogApi,
      catalogRuntime: (platform: 'macos', arch: 'arm64'),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'test',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    await service.inspect();
    // 目录在 detect 之前交给 Bridge,带本环境与 kid。
    expect(events.take(3).toList(),
        ['open', 'http.catalog', 'catalog.apply.test.lc-catalog-test']);
    expect(catalogApi.lastPlatform, 'macos');
    expect(catalogApi.lastArch, 'arm64');
    expect(session.appliedCatalog?.signature, 'YWJj');
    expect(events.last, 'close');

    // 5 分钟内再次检测:不再打 Bus,但每个新会话都要再交一次目录。
    events.clear();
    await service.inspect();
    expect(catalogApi.calls, 1);
    expect(events.take(2).toList(),
        ['open', 'catalog.apply.test.lc-catalog-test']);
    expect(session.catalogApplyCalls, 2);

    // Bridge 验签拒绝:快照照常返回。
    session.nextCatalogApplyError = 'LCT-BRIDGE-CATALOG-UNTRUSTED_KEY';
    final snap = await service.inspect();
    expect(snap.tools.length, LocalCodingTarget.values.length);
    session.nextCatalogApplyError = null;

    // 老 Bridge 不支持 catalog.apply:既不拉目录也不下发。
    final legacy = _FakeSession(events: events);
    final legacyService = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(legacy, events),
      api: _FakeApi(events: events),
      catalogApi: _FakeCatalogApi(events: events, catalog: signed),
      catalogRuntime: (platform: 'macos', arch: 'arm64'),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'test',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );
    events.clear();
    await legacyService.inspect();
    expect(events.where((e) => e.startsWith('http.catalog')), isEmpty);
    expect(events.where((e) => e.startsWith('catalog.apply')), isEmpty);
  });

  test(
      '契约 §2.7.4 · Bus 没有目录(404)→ catalog.apply(null);目录暂时取不到 → 不下发,沿用 Bridge 落盘目录',
      () async {
    final events = <String>[];
    final session = _FakeSession(events: events)
      ..supported = {..._FakeSession(events: []).supported, 'catalog.apply'};
    final catalogApi = _FakeCatalogApi(events: events, catalog: null);
    LocalCodingToolsService build() => LocalCodingToolsService(
          bridgeFactory: _FakeSessionFactory(session, events),
          api: _FakeApi(events: events),
          catalogApi: catalogApi,
          catalogRuntime: (platform: 'macos', arch: 'arm64'),
          deviceIdLoader: () async => deviceId,
          appVersionLoader: () async => '1.1.7',
          environmentLoader: () => 'test',
          profileVersions: profiles,
          identityLoader: () async => const LocalCodingSessionIdentity(
            accountId: 'account-1',
            tenantId: 'tenant-1',
          ),
          pendingRevocationStore: _MemoryPendingRevocationStore(),
        );

    await build().inspect();
    expect(events.take(3).toList(),
        ['open', 'http.catalog', 'catalog.apply.test.null']);
    expect(session.appliedCatalog, isNull);

    events.clear();
    catalogApi.unavailable = true;
    await build().inspect();
    expect(events.take(2).toList(), ['open', 'http.catalog']);
    expect(events.where((e) => e.startsWith('catalog.apply')), isEmpty);
    expect(events.last, 'close');
  });

  test('install: detect → plan → execute → get… → detect final', () async {
    final events = <String>[];
    final session = _FakeSession(events: events)
      ..installPlanResponse = const LocalCodingInstallPlan(
        planId: 'plan-1',
        target: LocalCodingTarget.codexCli,
        mode: LocalCodingInstallMode.install,
        version: '0.153.4',
        source: 'official_openai',
        downloadHost: 'github.com',
        downloadSizeBytes: 87323149,
        sha256: 'deadbeef',
        expiresAt: '2026-09-08T10:05:00Z',
      )
      ..installExecuteResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'preflight',
        kind: LocalCodingOperationKind.install,
      );
    session.operationScripts['op-1'] = [
      _op(
        state: LocalCodingOperationState.running,
        stage: 'downloading',
        kind: LocalCodingOperationKind.install,
        progressKind: LocalCodingProgressKind.determinate,
        progressValue: 40,
      ),
      _op(
        state: LocalCodingOperationState.succeeded,
        stage: 'detecting',
        kind: LocalCodingOperationKind.install,
      ),
    ];
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    events.clear();
    final started = await service.startInstall(LocalCodingTarget.codexCli);
    expect(started.stage, 'preflight');
    expect(started.operationId, 'op-1');
    // detect + plan + execute happened; session stays open for polling.
    expect(events, [
      'open',
      'detect.codex_cli',
      'install.plan.codex_cli.install',
      'install.execute',
    ]);

    events.clear();
    final tick1 = await service.pollOperation('op-1');
    expect(tick1.stage, 'downloading');
    expect(tick1.downloadPercent, 40);
    expect(events, ['operation.get']);

    events.clear();
    final terminal = await service.pollOperation('op-1');
    expect(terminal.isSucceeded, isTrue);
    // Session closed after terminal state.
    expect(events, ['operation.get', 'close']);
  });

  test('verify: execute → get… reaches succeeded and closes session', () async {
    final events = <String>[];
    final session = _FakeSession(events: events)
      ..verifyExecuteResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l1',
        kind: LocalCodingOperationKind.verify,
      );
    session.operationScripts['op-1'] = [
      _op(
        state: LocalCodingOperationState.running,
        stage: 'l2',
        kind: LocalCodingOperationKind.verify,
      ),
      _op(
        state: LocalCodingOperationState.succeeded,
        stage: 'l3',
        kind: LocalCodingOperationKind.verify,
      ),
    ];
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    events.clear();
    final started = await service.startVerify(LocalCodingTarget.codexCli);
    expect(started.stage, 'l1');
    // startVerify performs detect first so it can pass installation_id.
    expect(events, [
      'open',
      'detect.codex_cli',
      'verify.execute.codex_cli.overlay',
    ]);
    events.clear();
    await service.pollOperation('op-1');
    final terminal = await service.pollOperation('op-1');
    expect(terminal.isSucceeded, isTrue);
    expect(events, ['operation.get', 'operation.get', 'close']);
  });

  test('verify(global) · 配置仍是知办但设备授权没了(退出过知办 / 切过环境 / 重装)时先重新接入再换票', () async {
    final events = <String>[];
    final session = _FakeSession(events: events, authorizationPresent: false)
      ..verifyExecuteResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'l1',
        kind: LocalCodingOperationKind.verify,
      );
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(
        events: events,
        registration: const LocalCodingDeviceRegistration(
          credentialId: credentialId,
          deviceCredential: deviceCredential,
        ),
      ),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.2.0',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    await service.startVerify(
      LocalCodingTarget.codexCli,
      scope: LocalCodingVerifyScope.global,
    );
    expect(
        events,
        containsAllInOrder([
          'status',
          'prepare',
          'http.register',
          'commit',
          'detect.codex_cli',
          'verify.execute.codex_cli.global',
        ]));

    // 授权已在且与当前环境 / Profile 一致:不重复注册。
    events.clear();
    await service.startVerify(
      LocalCodingTarget.codexCli,
      scope: LocalCodingVerifyScope.global,
    );
    expect(events, isNot(contains('prepare')));
    expect(events, contains('verify.execute.codex_cli.global'));
  });

  test('cancelOperation reuses the same session envelope', () async {
    final events = <String>[];
    final session = _FakeSession(events: events)
      ..installPlanResponse = const LocalCodingInstallPlan(
        planId: 'plan-1',
        target: LocalCodingTarget.codexCli,
        mode: LocalCodingInstallMode.install,
        version: '0.153.4',
        source: 'official_openai',
        downloadHost: 'github.com',
        downloadSizeBytes: 87323149,
        sha256: 'deadbeef',
        expiresAt: '2026-09-08T10:05:00Z',
      )
      ..installExecuteResponse = _op(
        state: LocalCodingOperationState.running,
        stage: 'downloading',
        kind: LocalCodingOperationKind.install,
        progressKind: LocalCodingProgressKind.determinate,
        progressValue: 10,
      )
      ..cancelResponse = _op(
        state: LocalCodingOperationState.cancelled,
        stage: 'downloading',
        kind: LocalCodingOperationKind.install,
        errorCode: 'LCT-CODEX_CLI-INSTALL-SYSTEM_CANCELLED',
      );
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    await service.startInstall(LocalCodingTarget.codexCli);
    events.clear();
    final cancelled = await service.cancelOperation('op-1');
    expect(cancelled.isCancelled, isTrue);
    expect(cancelled.errorCode, 'LCT-CODEX_CLI-INSTALL-SYSTEM_CANCELLED');
    expect(events, ['operation.cancel', 'close']);
  });

  test('domain error on install.plan propagates LCT code to caller', () async {
    final events = <String>[];
    final session = _FakeSession(events: events)
      ..nextInstallPlanError = 'LCT-CODEX_CLI-INSTALL-ALREADY_INSTALLED';
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.7',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    await expectLater(
      service.startInstall(LocalCodingTarget.codexCli),
      throwsA(isA<LocalCodingToolsException>().having(
        (e) => e.code,
        'LCT code',
        'LCT-CODEX_CLI-INSTALL-ALREADY_INSTALLED',
      )),
    );
  });

  test('switchToZhiban · 计划后配置被其他程序改动时另开会话重试,不把失败抛给用户', () async {
    // Windows 12012 真机:Codex 桌面端运行时持续改写 ~/.codex/config.toml,
    // 写入前置条件不符 → 契约 §2.7.2 CONFIG-PRECONDITION_CHANGED。
    final events = <String>[];
    final session = _FakeSession(events: events)..failSwitchExecuteTimes = 1;
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.2.0',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
      configWriteRetryDelay: Duration.zero,
    );

    final snapshot = await service.switchToZhiban(LocalCodingTarget.codexCli);
    expect(
      snapshot.configurationFor(LocalCodingTarget.codexCli).switchedToZhiban,
      isTrue,
    );
    // 域错误后会话已关闭:重试必须另开一条(两次 open、两次 config.execute)。
    expect(events.where((event) => event == 'open').length,
        greaterThanOrEqualTo(2));
    expect(events.where((event) => event == 'config.execute').length, 2);
    expect(session.failSwitchExecuteTimes, 0);
  });

  test('switchToZhiban · 一直被改动则把原因抛给用户,不无限重试', () async {
    final events = <String>[];
    final session = _FakeSession(events: events)..failSwitchExecuteTimes = 5;
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.2.0',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
      configWriteRetryDelay: Duration.zero,
    );

    await expectLater(
      service.switchToZhiban(LocalCodingTarget.codexCli),
      throwsA(isA<LocalCodingToolsException>().having(
        (e) => e.code,
        'LCT code',
        'LCT-CODEX_CLI-CONFIG-PRECONDITION_CHANGED',
      )),
    );
    expect(events.where((event) => event == 'config.execute').length, 3);
  });

  test(
      'switchToZhiban · Bridge 对共用配置的第二次 switch_global 回 action=none 视为已切换,不报计划无效',
      () async {
    final events = <String>[];
    final session = _FakeSession(events: events);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.9',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    // CLI 已切:Codex 桌面端与 CLI 共用 ~/.codex/config.toml,Bridge 回 none。
    session.switchedGlobalTargets.add(LocalCodingTarget.codexDesktop);
    session.switchPlanAction = LocalCodingConfigurationAction.none;
    final snapshot =
        await service.switchToZhiban(LocalCodingTarget.codexDesktop);
    expect(events, contains('config.plan.codex_desktop.switch_global'));
    expect(events, contains('config.execute'));
    expect(
      snapshot
          .configurationFor(LocalCodingTarget.codexDesktop)
          .switchedToZhiban,
      isTrue,
    );

    // 其它 action 仍然拒绝。
    session.switchPlanAction = LocalCodingConfigurationAction.create;
    await expectLater(
      service.switchToZhiban(LocalCodingTarget.codexDesktop),
      throwsA(isA<LocalCodingToolsException>()
          .having((e) => e.code, 'code', 'configuration_plan_invalid')),
    );
  });

  test(
      'restoreOfficial · Bridge 回 CONFIG-NOT_SWITCHED(共用配置已被 CLI 恢复)按已恢复处理,已切换的正常恢复',
      () async {
    final events = <String>[];
    final session = _FakeSession(events: events);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.9',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    // 桌面端未切换(CLI 已先恢复了共用的 config.toml)→ 不报错,回官方状态;
    // 域错误已让第一条会话 abort,快照必须在新开的会话上读(11913 真机踩到)。
    final snapshot =
        await service.restoreOfficial(LocalCodingTarget.codexDesktop);
    expect(events, contains('config.plan.codex_desktop.restore_global'));
    expect(events, isNot(contains('config.execute')));
    expect(events.where((e) => e == 'open').length, 2);
    expect(
      snapshot
          .configurationFor(LocalCodingTarget.codexDesktop)
          .switchedToZhiban,
      isFalse,
    );

    // 已切换的 CLI 正常走 plan → execute。
    session.switchedGlobalTargets.add(LocalCodingTarget.codexCli);
    events.clear();
    final restored = await service.restoreOfficial(LocalCodingTarget.codexCli);
    expect(events, contains('config.plan.codex_cli.restore_global'));
    expect(events, contains('config.execute'));
    expect(
      restored.configurationFor(LocalCodingTarget.codexCli).switchedToZhiban,
      isFalse,
    );
  });

  test('restoreOfficial · NOT_SWITCHED 但文件仍指向知办(切换记录丢失)时报失败,不假报已恢复', () async {
    final events = <String>[];
    final session = _FakeSession(events: events);
    final service = LocalCodingToolsService(
      bridgeFactory: _FakeSessionFactory(session, events),
      api: _FakeApi(events: events),
      deviceIdLoader: () async => deviceId,
      appVersionLoader: () async => '1.1.9',
      environmentLoader: () => 'prod',
      profileVersions: profiles,
      identityLoader: () async => const LocalCodingSessionIdentity(
        accountId: 'account-1',
        tenantId: 'tenant-1',
      ),
      pendingRevocationStore: _MemoryPendingRevocationStore(),
    );

    session.unownedZhibanTargets.add(LocalCodingTarget.codexCli);
    await expectLater(
      service.restoreOfficial(LocalCodingTarget.codexCli),
      throwsA(isA<LocalCodingToolsException>()
          .having((e) => e.code, 'code', 'restore_not_switched')),
    );
    expect(events, isNot(contains('config.execute')));
  });

  group('F31 · 重新登录后自动重新接入(2026-09-18)', () {
    ({
      LocalCodingToolsService service,
      _FakeSession session,
      _MemoryReconnectStore store,
      List<String> events,
    }) build({
      required bool authorizationPresent,
      String accountId = 'account-1',
      String tenantId = 'tenant-1',
      _MemoryReconnectStore? store,
    }) {
      final events = <String>[];
      final session =
          _FakeSession(events: events, authorizationPresent: authorizationPresent);
      final reconnectStore = store ?? _MemoryReconnectStore();
      final service = LocalCodingToolsService(
        bridgeFactory: _FakeSessionFactory(session, events),
        api: _FakeApi(
          events: events,
          registration: const LocalCodingDeviceRegistration(
            credentialId: credentialId,
            deviceCredential: deviceCredential,
          ),
        ),
        deviceIdLoader: () async => deviceId,
        appVersionLoader: () async => '1.3.0',
        environmentLoader: () => 'prod',
        profileVersions: profiles,
        identityLoader: () async => LocalCodingSessionIdentity(
          accountId: accountId,
          tenantId: tenantId,
        ),
        pendingRevocationStore: _MemoryPendingRevocationStore(),
        reconnectStore: reconnectStore,
      );
      return (
        service: service,
        session: session,
        store: reconnectStore,
        events: events,
      );
    }

    const sameIdentity = LocalCodingReconnectRecord(
      deviceId: deviceId,
      accountId: 'account-1',
      tenantId: 'tenant-1',
      environment: 'prod',
    );

    test('接入成功记下是谁接入的;退出登录保留记录,主动移除清掉', () async {
      final t = build(authorizationPresent: false);
      await t.service.registerOrRotate();
      expect(t.store.value?.matches(sameIdentity), isTrue);

      await t.service.removeAuthorizationOnLogout();
      expect(t.events, containsAll(['http.revoke', 'clear']));
      expect(t.store.value?.matches(sameIdentity), isTrue);

      await t.service.removeAuthorization();
      expect(t.store.value, isNull);
    });

    test('同一个人回来、授权没了、配置仍指向知办:静默重新接入,不读整份快照', () async {
      final t = build(
        authorizationPresent: false,
        store: _MemoryReconnectStore()..value = sameIdentity,
      );
      t.session.switchedGlobalTargets.add(LocalCodingTarget.claudeCli);

      expect(await t.service.reconnectIfSameIdentity(), isTrue);
      expect(t.events.where((e) => e == 'http.register'), hasLength(1));
      expect(t.events, containsAllInOrder(['prepare', 'http.register', 'commit']));
      expect(t.events.where((e) => e.startsWith('detect.')), isEmpty);
    });

    test('换了账号或企业登录:不替他接入', () async {
      for (final other in [
        (account: 'account-2', tenant: 'tenant-1'),
        (account: 'account-1', tenant: 'tenant-2'),
      ]) {
        final t = build(
          authorizationPresent: false,
          accountId: other.account,
          tenantId: other.tenant,
          store: _MemoryReconnectStore()..value = sameIdentity,
        );
        t.session.switchedGlobalTargets.add(LocalCodingTarget.codexCli);

        expect(await t.service.reconnectIfSameIdentity(), isFalse);
        expect(t.events, isNot(contains('http.register')));
        // 连 Bridge 都不必打开。
        expect(t.events, isNot(contains('open')));
      }
    });

    test('没有接入记录、授权还在、或已恢复官方配置:都不接入', () async {
      final noRecord = build(authorizationPresent: false);
      noRecord.session.switchedGlobalTargets.add(LocalCodingTarget.codexCli);
      expect(await noRecord.service.reconnectIfSameIdentity(), isFalse);
      expect(noRecord.events, isNot(contains('http.register')));

      final stillAuthorized = build(
        authorizationPresent: true,
        store: _MemoryReconnectStore()..value = sameIdentity,
      );
      stillAuthorized.session.switchedGlobalTargets
          .add(LocalCodingTarget.codexCli);
      expect(await stillAuthorized.service.reconnectIfSameIdentity(), isFalse);
      expect(stillAuthorized.events, isNot(contains('http.register')));

      final official = build(
        authorizationPresent: false,
        store: _MemoryReconnectStore()..value = sameIdentity,
      );
      expect(await official.service.reconnectIfSameIdentity(), isFalse);
      expect(official.events, isNot(contains('http.register')));
    });

    test('后台与页面同时触发:合并为一次注册(服务端注册会顶掉旧凭证)', () async {
      final t = build(
        authorizationPresent: false,
        store: _MemoryReconnectStore()..value = sameIdentity,
      );
      t.session.switchedGlobalTargets.add(LocalCodingTarget.codexCli);

      final results = await Future.wait([
        t.service.reconnectIfSameIdentity(),
        t.service.reconnectIfSameIdentity(),
      ]);
      expect(results, [isTrue, isTrue]);
      expect(t.events.where((e) => e == 'http.register'), hasLength(1));
    });

    test('升级前接入的设备没有记录:退出登录时授权还在,按当前登录身份补记', () async {
      final t = build(authorizationPresent: true);
      expect(t.store.value, isNull);

      await t.service.removeAuthorizationOnLogout();
      expect(t.store.value?.matches(sameIdentity), isTrue);

      // 授权本来就没了(从没接入过)的设备不补记。
      final never = build(authorizationPresent: false);
      await never.service.removeAuthorizationOnLogout();
      expect(never.store.value, isNull);
    });

    test('注册失败静默放弃,不抛错', () async {
      final events = <String>[];
      final session = _FakeSession(events: events, authorizationPresent: false)
        ..switchedGlobalTargets.add(LocalCodingTarget.codexCli);
      final service = LocalCodingToolsService(
        bridgeFactory: _FakeSessionFactory(session, events),
        // registration 为空:registerDevice 会抛。
        api: _FakeApi(events: events),
        deviceIdLoader: () async => deviceId,
        appVersionLoader: () async => '1.3.0',
        environmentLoader: () => 'prod',
        profileVersions: profiles,
        identityLoader: () async => const LocalCodingSessionIdentity(
          accountId: 'account-1',
          tenantId: 'tenant-1',
        ),
        pendingRevocationStore: _MemoryPendingRevocationStore(),
        reconnectStore: _MemoryReconnectStore()..value = sameIdentity,
      );
      expect(await service.reconnectIfSameIdentity(), isFalse);
    });
  });
}

LocalCodingOperation _op({
  required LocalCodingOperationState state,
  required String stage,
  required LocalCodingOperationKind kind,
  LocalCodingProgressKind progressKind = LocalCodingProgressKind.indeterminate,
  int? progressValue,
  bool cancellable = true,
  String errorCode = '',
}) {
  return LocalCodingOperation(
    operationId: 'op-1',
    target: LocalCodingTarget.codexCli,
    kind: kind,
    state: state,
    stage: stage,
    progressKind: progressKind,
    progressValue: progressValue,
    cancellable: cancellable,
    errorCode: errorCode,
    nextActions: state == LocalCodingOperationState.running
        ? const ['cancel']
        : const [],
    result: state == LocalCodingOperationState.succeeded ? const {} : null,
  );
}

class _FakeSessionFactory implements LocalCodingBridgeSessionFactory {
  const _FakeSessionFactory(this.session, this.events);

  final LocalCodingBridgeSession session;
  final List<String> events;

  @override
  Future<LocalCodingBridgeSession> open() async {
    events.add('open');
    final fake = session;
    if (fake is _FakeSession) fake.aborted = false;
    return session;
  }
}

class _FakeSession implements LocalCodingBridgeSession {
  _FakeSession({
    required this.events,
    this.failCommit = false,
    this.failClear = false,
    this.authorizationPresent = true,
  })  : configuredTargets = <LocalCodingTarget>{},
        authorizationProfileVersions = authorizationPresent
            ? <String, String>{
                'codex_cli': 'codex-v1',
                'claude_cli': 'claude-v1',
              }
            : <String, String>{};

  final List<String> events;
  final bool failCommit;
  bool failClear;
  bool authorizationPresent;
  final Set<LocalCodingTarget> configuredTargets;
  final Set<LocalCodingTarget> conflictTargets = {};
  final Set<LocalCodingTarget> unsafeTargets = {};
  final Set<LocalCodingTarget> unreadableTargets = {};
  final Map<LocalCodingTarget, String> configurationProfileVersions = {};
  final Map<String, String> authorizationProfileVersions;
  LocalCodingTarget? plannedTarget;
  Map<String, String>? committedProfiles;
  String? committedCredential;
  String? createdBookmark;
  String? launchInstallationId;
  String? launchProfileVersion;
  String? launchProjectGrantId;
  String? lastConfigInstallationId;
  LocalCodingVerifyScope? lastVerifyScope;

  @override
  Future<void> clearCredential() async {
    events.add('clear');
    if (failClear) {
      throw const LocalCodingBridgeException(
        'credential_clear_failed',
        '设备授权清理失败，请重试',
      );
    }
  }

  @override
  Future<LocalCodingProjectGrant> createProjectGrant(
    String bookmarkData,
  ) async {
    events.add('project.grant.create');
    createdBookmark = bookmarkData;
    return const LocalCodingProjectGrant(
      projectGrantId: 'opaque-project-grant',
      displayName: 'private-project',
      expiresAt: '2026-09-07T12:05:00Z',
    );
  }

  @override
  Future<void> close() async {
    events.add('close');
  }

  @override
  Future<void> commitRegistration({
    required String credentialId,
    required String deviceCredential,
    required Map<String, String> profileVersions,
  }) async {
    events.add('commit');
    if (failCommit) {
      throw const LocalCodingBridgeException(
        'credential_store_failed',
        '设备授权保存失败，请重新接入',
      );
    }
    committedCredential = deviceCredential;
    committedProfiles = Map<String, String>.from(profileVersions);
    authorizationProfileVersions
      ..clear()
      ..addAll(profileVersions);
    authorizationPresent = true;
  }

  /// 真实客户端在 RPC error 后 fail closed;之后任何调用都报 session_closed。
  bool aborted = false;

  void _requireOpen() {
    if (aborted) {
      throw const LocalCodingBridgeException(
          'session_closed', '本地连接组件会话已结束，请重试');
    }
  }

  @override
  Future<LocalCodingCredentialStatus> credentialStatus() async {
    _requireOpen();
    events.add('status');
    return LocalCodingCredentialStatus(
      identityPresent: true,
      authorizationPresent: authorizationPresent,
      deviceId: '11111111-1111-4111-8111-111111111111',
      environment: authorizationPresent ? 'prod' : '',
      profileVersions: authorizationPresent
          ? Map<String, String>.unmodifiable(authorizationProfileVersions)
          : const {},
      targets: authorizationPresent
          ? const {LocalCodingTarget.codexCli, LocalCodingTarget.claudeCli}
          : const {},
    );
  }

  @override
  Future<LocalCodingToolState> detect(LocalCodingTarget target) async {
    _requireOpen();
    events.add('detect.${target.id}');
    if (unreadableTargets.contains(target)) {
      throw const LocalCodingBridgeUnreadableResultException();
    }
    return LocalCodingToolState(
      target: target,
      generation: 1,
      uiState: LocalCodingToolUiState.installedUnmanaged,
      installationId: 'opaque-${target.id}',
      installedVersion: '1.2.3',
      installSource: 'official',
      verificationLevel: 'l0',
      nextActions: const ['detect'],
      supportsEnable: true,
    );
  }

  @override
  Future<LocalCodingCredentialPreparation> prepareRegistration({
    required String deviceId,
    required String environment,
  }) async {
    events.add('prepare');
    return LocalCodingCredentialPreparation(
      deviceId: deviceId,
      devicePublicJwk: const {
        'kty': 'OKP',
        'crv': 'Ed25519',
        'x': 'public-key',
      },
      dpopProof: 'proof-secret',
    );
  }

  @override
  Future<LocalCodingConfigurationStatus> configurationStatus(
    LocalCodingTarget target,
  ) async {
    events.add('config.status.${target.id}');
    if (unsafeTargets.contains(target)) {
      return LocalCodingConfigurationStatus.fromJson({
        'target_id': target.id,
        'state': 'conflict',
        'verification_level': 'l0',
        'current_service': 'unknown',
        'error_code': 'LCT-${target.id.toUpperCase()}-CONFIG-UNSAFE_PATH',
        'next_actions': ['inspect'],
      });
    }
    return _configurationStatus(target);
  }

  @override
  Future<LocalCodingConfigurationPlan> planConfiguration({
    required LocalCodingTarget target,
    String installationId = '',
    LocalCodingConfigurationType? type,
  }) async {
    events
        .add('config.plan.${target.id}${type == null ? '' : '.${type.value}'}');
    plannedTarget = target;
    lastConfigType = type;
    lastConfigInstallationId = installationId;
    if (type == LocalCodingConfigurationType.restoreGlobal &&
        !switchedGlobalTargets.contains(target)) {
      // 契约 §2.7.2:未切换过 → -32000 LCT-*-CONFIG-NOT_SWITCHED。真实客户端收到
      // RPC error 会 abort 会话,之后再调用报 session_closed。
      aborted = true;
      throw LocalCodingBridgeDomainException(
        'LCT-${target.id.toUpperCase()}-CONFIG-NOT_SWITCHED',
        '当前未切换到知办模型 API，无需恢复',
      );
    }
    return LocalCodingConfigurationPlan(
      planId: 'plan-token',
      target: target,
      action: type == LocalCodingConfigurationType.switchGlobal
          ? (switchPlanAction ?? LocalCodingConfigurationAction.switchGlobal)
          : type == LocalCodingConfigurationType.restoreGlobal
              ? LocalCodingConfigurationAction.restoreGlobal
              : type == LocalCodingConfigurationType.repair
                  ? LocalCodingConfigurationAction.repair
                  : LocalCodingConfigurationAction.create,
      profileVersion: _profileVersion(target),
      expiresAt: '2026-09-07T12:00:00Z',
    );
  }

  LocalCodingConfigurationType? lastConfigType;

  /// switch_global 计划要回的 action(默认 switch_global;契约 §2.7.2 已切换
  /// 且受管区域一致时 Bridge 回 none)。
  LocalCodingConfigurationAction? switchPlanAction;

  /// 前 N 次 switch_global 的 config.execute 以「计划后文件被改动」失败
  /// (Codex 桌面端运行时改写 config.toml,契约 §2.7.2)。
  int failSwitchExecuteTimes = 0;
  final Set<LocalCodingTarget> switchedGlobalTargets = {};
  final Set<LocalCodingTarget> unownedZhibanTargets = {};

  @override
  Future<LocalCodingConfigurationStatus> executeConfiguration(
    String planId,
  ) async {
    events.add('config.execute');
    final target = plannedTarget!;
    if (lastConfigType == LocalCodingConfigurationType.switchGlobal) {
      if (failSwitchExecuteTimes > 0) {
        failSwitchExecuteTimes -= 1;
        aborted = true;
        throw LocalCodingBridgeDomainException(
          'LCT-${target.id.toUpperCase()}-CONFIG-PRECONDITION_CHANGED',
          '配置文件刚被其他程序改动，请重新检测后重试',
        );
      }
      switchedGlobalTargets.add(target);
      return _configurationStatus(target);
    }
    if (lastConfigType == LocalCodingConfigurationType.restoreGlobal) {
      switchedGlobalTargets.remove(target);
      return _configurationStatus(target);
    }
    configuredTargets.add(target);
    configurationProfileVersions[target] = _profileVersion(target);
    return _configurationStatus(target);
  }

  @override
  Future<LocalCodingLaunchResult> executeLaunch(String planId) async {
    events.add('launch.execute');
    return LocalCodingLaunchResult(
      target: plannedTarget!,
      state: 'launched',
      projectName: 'private-project',
    );
  }

  @override
  Future<LocalCodingLaunchPlan> planLaunch({
    required LocalCodingTarget target,
    required String installationId,
    String projectGrantId = '',
    String profileVersion = '',
    LocalCodingLaunchMode mode = LocalCodingLaunchMode.managed,
  }) async {
    events.add('launch.plan.${target.id}');
    plannedTarget = target;
    launchInstallationId = installationId;
    launchProjectGrantId = projectGrantId;
    launchProfileVersion = profileVersion;
    launchMode = mode;
    return LocalCodingLaunchPlan(
      launchPlanId: 'opaque-launch-plan',
      target: target,
      projectName: 'private-project',
      expiresAt: '2026-09-07T12:02:00Z',
    );
  }

  LocalCodingLaunchMode? launchMode;

  @override
  Set<String> get supportedMethods => supported;

  Set<String> supported = const {
    'tool.detect',
    'credential.registration.prepare',
    'credential.registration.commit',
    'credential.status',
    'credential.clear',
    'config.status',
    'config.plan',
    'config.execute',
    'config.restore',
    'project.grant.create',
    'launch.plan',
    'launch.execute',
    'requirements.get',
    'install.plan',
    'install.execute',
    'operation.get',
    'operation.cancel',
    'verify.execute',
    'diagnostics.get_latest',
  };

  // M1G scripted long operations. Tests seed [operations] with the sequence
  // of envelopes each poll should return; [cancelResponse] answers cancel.
  final Map<String, List<LocalCodingOperation>> operationScripts = {};
  LocalCodingOperation? cancelResponse;
  LocalCodingRequirements? requirementsResponse;
  LocalCodingInstallPlan? installPlanResponse;
  LocalCodingOperation? installExecuteResponse;
  LocalCodingOperation? verifyExecuteResponse;
  LocalCodingDiagnostics? diagnosticsResponse;
  String? nextRequirementsError;
  String? nextInstallPlanError;
  String? nextInstallExecuteError;
  String? nextVerifyExecuteError;

  @override
  Future<LocalCodingRequirements> requirementsGet(
    LocalCodingTarget target,
  ) async {
    events.add('requirements.${target.id}');
    if (nextRequirementsError != null) {
      throw LocalCodingBridgeDomainException(nextRequirementsError!, 'x');
    }
    return requirementsResponse!;
  }

  @override
  Future<LocalCodingInstallPlan> installPlan({
    required LocalCodingTarget target,
    LocalCodingInstallMode mode = LocalCodingInstallMode.install,
    String? component,
  }) async {
    events.add(
        'install.plan.${target.id}.${component == null ? mode.value : 'component=$component'}');
    if (nextInstallPlanError != null) {
      throw LocalCodingBridgeDomainException(nextInstallPlanError!, 'x');
    }
    return installPlanResponse!;
  }

  @override
  Future<LocalCodingOperation> installExecute(String planId) async {
    events.add('install.execute');
    if (nextInstallExecuteError != null) {
      throw LocalCodingBridgeDomainException(nextInstallExecuteError!, 'x');
    }
    return installExecuteResponse!;
  }

  @override
  Future<LocalCodingOperation> operationGet(String operationId) async {
    events.add('operation.get');
    final script = operationScripts[operationId];
    if (script == null || script.isEmpty) {
      throw StateError('no more scripted responses for $operationId');
    }
    return script.removeAt(0);
  }

  @override
  Future<LocalCodingOperation> operationCancel(String operationId) async {
    events.add('operation.cancel');
    return cancelResponse!;
  }

  @override
  Future<LocalCodingOperation> verifyExecute({
    required LocalCodingTarget target,
    required String installationId,
    LocalCodingVerifyScope scope = LocalCodingVerifyScope.overlay,
  }) async {
    events.add('verify.execute.${target.id}.${scope.value}');
    lastVerifyScope = scope;
    if (nextVerifyExecuteError != null) {
      throw LocalCodingBridgeDomainException(nextVerifyExecuteError!, 'x');
    }
    return verifyExecuteResponse!;
  }

  @override
  Future<LocalCodingDiagnostics> diagnosticsGetLatest(
    LocalCodingTarget target,
  ) async {
    events.add('diagnostics.${target.id}');
    return diagnosticsResponse!;
  }

  String? nextCatalogApplyError;
  LocalCodingSignedCatalog? appliedCatalog;
  String? appliedEnvironment;
  int catalogApplyCalls = 0;

  @override
  Future<LocalCodingProxyStatus> networkProxyStatus() async =>
      const LocalCodingProxyStatus(
          supported: true,
          systemProxyEnabled: false,
          needsFix: false,
          directReachable: true);

  @override
  Future<LocalCodingProxyStatus> networkProxyApply() => networkProxyStatus();

  @override
  Future<LocalCodingCatalogApplyResult> catalogApply({
    required String environment,
    LocalCodingSignedCatalog? catalog,
  }) async {
    catalogApplyCalls++;
    events.add('catalog.apply.$environment.${catalog?.kid ?? 'null'}');
    appliedEnvironment = environment;
    appliedCatalog = catalog;
    if (nextCatalogApplyError != null) {
      throw LocalCodingBridgeDomainException(nextCatalogApplyError!, 'x');
    }
    return LocalCodingCatalogApplyResult(applied: catalog != null);
  }

  @override
  Future<LocalCodingConfigurationStatus> restoreConfiguration(
    LocalCodingTarget target,
  ) async {
    events.add('config.restore.${target.id}');
    configuredTargets.remove(target);
    return _configurationStatus(target);
  }

  LocalCodingConfigurationStatus _configurationStatus(
    LocalCodingTarget target,
  ) {
    if (conflictTargets.contains(target)) {
      return LocalCodingConfigurationStatus(
        target: target,
        state: LocalCodingConfigurationState.conflict,
        verificationLevel: 'l0',
        errorCode: 'LCT-${target.id.toUpperCase()}-CONFIG-CONFLICT',
        nextActions: const ['inspect'],
      );
    }
    final configured = configuredTargets.contains(target);
    final switched = switchedGlobalTargets.contains(target);
    if (!switched && unownedZhibanTargets.contains(target)) {
      // 文件指向知办,但 Bridge 没有(或读不出)切换记录。
      return LocalCodingConfigurationStatus(
        target: target,
        state: LocalCodingConfigurationState.notConfigured,
        verificationLevel: 'l0',
        nextActions: const ['switch_global'],
        currentService: LocalCodingCurrentService.zhiban,
      );
    }
    return LocalCodingConfigurationStatus(
      target: target,
      state: configured
          ? LocalCodingConfigurationState.configured
          : LocalCodingConfigurationState.notConfigured,
      profileVersion: configured
          ? configurationProfileVersions[target] ?? _profileVersion(target)
          : '',
      verificationLevel: configured ? 'l1' : 'l0',
      nextActions: configured ? const ['verify'] : const ['configure'],
      currentService: switched
          ? LocalCodingCurrentService.zhiban
          : LocalCodingCurrentService.official,
      globalSwitched: switched,
      globalBackupAvailable: switched,
    );
  }

  String _profileVersion(LocalCodingTarget target) =>
      target == LocalCodingTarget.codexCli ? 'codex-v1' : 'claude-v1';
}

class _FakeCatalogApi implements LocalCodingCatalogApi {
  _FakeCatalogApi({required this.events, this.catalog});

  final List<String> events;
  LocalCodingSignedCatalog? catalog;
  bool unavailable = false;
  int calls = 0;
  String? lastPlatform;
  String? lastArch;

  @override
  Future<LocalCodingSignedCatalog?> fetchCatalog({
    required String platform,
    required String arch,
  }) async {
    calls++;
    lastPlatform = platform;
    lastArch = arch;
    events.add('http.catalog');
    if (unavailable) throw const LocalCodingCatalogUnavailable('boom');
    return catalog;
  }
}

class _FakeApi implements LocalCodingToolsApi {
  const _FakeApi({
    required this.events,
    this.registration,
    this.failRevoke = false,
  });

  final List<String> events;
  final LocalCodingDeviceRegistration? registration;
  final bool failRevoke;

  @override
  Future<LocalCodingDeviceRegistration> registerDevice({
    required String deviceId,
    required String platform,
    required Map<String, dynamic> devicePublicJwk,
    required String appVersion,
    required String dpopProof,
  }) async {
    events.add('http.register');
    return registration!;
  }

  @override
  Future<void> revokeDevice(String deviceId) async {
    events.add('http.revoke');
    if (failRevoke) throw StateError('network failed');
  }
}

class _MemoryPendingRevocationStore
    implements LocalCodingPendingRevocationStore {
  LocalCodingPendingRevocation? value;

  @override
  Future<void> clear() async {
    value = null;
  }

  @override
  Future<LocalCodingPendingRevocation?> load() async => value;

  @override
  Future<void> save(LocalCodingPendingRevocation pending) async {
    value = pending;
  }
}

class _MemoryReconnectStore implements LocalCodingReconnectStore {
  LocalCodingReconnectRecord? value;

  @override
  Future<void> clear() async {
    value = null;
  }

  @override
  Future<LocalCodingReconnectRecord?> load() async => value;

  @override
  Future<void> save(LocalCodingReconnectRecord record) async {
    value = record;
  }
}
