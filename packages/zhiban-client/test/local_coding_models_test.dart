import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';

void main() {
  test('M3 · 四个 target 按厂商 / 形态分组,桌面端映射到同厂商 CLI 的授权', () {
    expect(LocalCodingTarget.values.length, 4);
    expect(LocalCodingVendor.codex.targets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.codexDesktop]);
    expect(LocalCodingVendor.claude.targets,
        [LocalCodingTarget.claudeCli, LocalCodingTarget.claudeDesktop]);
    expect(LocalCodingVendor.codex.cliTarget, LocalCodingTarget.codexCli);
    expect(LocalCodingVendor.claude.desktopTarget,
        LocalCodingTarget.claudeDesktop);
    expect(LocalCodingTarget.codexDesktop.isDesktop, isTrue);
    expect(
        LocalCodingTarget.codexDesktop.scopeTarget, LocalCodingTarget.codexCli);
    expect(LocalCodingTarget.claudeDesktop.scopeTarget,
        LocalCodingTarget.claudeCli);
    expect(
        LocalCodingTarget.claudeCli.scopeTarget, LocalCodingTarget.claudeCli);
    expect(LocalCodingTarget.cliTargets,
        [LocalCodingTarget.codexCli, LocalCodingTarget.claudeCli]);
    expect(LocalCodingTarget.parse('claude_desktop'),
        LocalCodingTarget.claudeDesktop);
    expect(() => LocalCodingTarget.parse('codex_web'), throwsFormatException);
  });

  test('tool.detect · form_factor / supports_enable 解析,老 Bridge 缺省按 target 推断',
      () {
    final desktop = LocalCodingToolState.fromJson({
      'target_id': 'claude_desktop',
      'generation': 3,
      'form_factor': 'desktop',
      'supports_enable': false,
      'ui_state': 'installed_unmanaged',
      'installation_id': 'AP7i',
      'installed_version': '1.46388.4',
      'install_source': 'official',
      'verification_level': 'l0',
      'next_actions': ['detect'],
    });
    expect(desktop.formFactor, LocalCodingFormFactor.desktop);
    expect(desktop.supportsEnable, isFalse);
    expect(desktop.target.vendor, LocalCodingVendor.claude);

    final legacy = LocalCodingToolState.fromJson({
      'target_id': 'codex_cli',
      'generation': 1,
      'ui_state': 'not_installed',
      'verification_level': 'l0',
      'next_actions': ['detect'],
    });
    expect(legacy.formFactor, LocalCodingFormFactor.cli);
    expect(legacy.supportsEnable, isTrue);

    expect(
      () => LocalCodingToolState.fromJson({
        'target_id': 'codex_cli',
        'generation': 1,
        'form_factor': 'desktop',
        'ui_state': 'not_installed',
        'verification_level': 'l0',
        'next_actions': ['detect'],
      }),
      throwsFormatException,
    );
    expect(
      () => LocalCodingToolState.fromJson({
        'target_id': 'codex_desktop',
        'generation': 1,
        'supports_enable': 'yes',
        'ui_state': 'not_installed',
        'verification_level': 'l0',
        'next_actions': ['detect'],
      }),
      throwsFormatException,
    );
  });

  test('M3 Task 8 · tool.detect components 与 install.plan component 解析', () {
    final tool = LocalCodingToolState.fromJson({
      'target_id': 'claude_desktop',
      'generation': 1,
      'form_factor': 'desktop',
      'supports_enable': true,
      'ui_state': 'installed_unmanaged',
      'installation_id': 'x',
      'installed_version': '1.46388.4',
      'install_source': 'official',
      'verification_level': 'l0',
      'next_actions': ['detect'],
      'components': [
        {'id': 'claude_code_host', 'version': '2.1.260', 'state': 'missing'},
      ],
    });
    expect(tool.hostComponent?.version, '2.1.260');
    expect(tool.hostComponent?.state, LocalCodingComponentState.missing);
    expect(tool.componentNeedsProvisioning, isTrue);

    final present = LocalCodingComponent.fromJson(
        {'id': 'claude_code_host', 'version': '2.1.260', 'state': 'present'});
    expect(present.needsProvisioning, isFalse);
    final unknown = LocalCodingComponent.fromJson(
        {'id': 'claude_code_host', 'state': 'whatever'});
    expect(unknown.state, LocalCodingComponentState.unknown);
    expect(unknown.needsProvisioning, isFalse);
    expect(
      () => LocalCodingToolState.fromJson({
        'target_id': 'claude_desktop',
        'generation': 1,
        'ui_state': 'not_installed',
        'verification_level': 'l0',
        'next_actions': ['detect'],
        'components': 'nope',
      }),
      throwsFormatException,
    );

    final plan = LocalCodingInstallPlan.fromJson({
      'plan_id': 'p1',
      'target_id': 'claude_desktop',
      'mode': 'component',
      'component': 'claude_code_host',
      'version': '2.1.260',
      'source': 'official_anthropic',
      'download_host': 'downloads.claude.ai',
      'download_size_bytes': 65759778,
      'sha256': '7639b52c',
      'expires_at': '2026-09-09T07:15:55Z',
    });
    expect(plan.mode, LocalCodingInstallMode.component);
    expect(plan.component, 'claude_code_host');
    expect(
      () => LocalCodingInstallPlan.fromJson({
        'plan_id': 'p1',
        'target_id': 'claude_desktop',
        'mode': 'install',
        'component': 'claude_code_host',
        'version': '2.1.260',
        'source': 'official_anthropic',
        'download_host': 'downloads.claude.ai',
        'download_size_bytes': 1,
        'sha256': 'x',
        'expires_at': 'now',
      }),
      throwsFormatException,
    );
  });

  test('契约 §2.7.4 · tool.detect 目录字段、install.plan 升级 / 回退计划、签名目录信封解析', () {
    final tool = LocalCodingToolState.fromJson({
      'target_id': 'codex_cli',
      'generation': 3,
      'ui_state': 'installed_unmanaged',
      'installed_version': '0.153.4',
      'install_source': 'official',
      'verification_level': 'l0',
      'next_actions': ['detect'],
      'available_version': '0.154.0',
      'rollback_version': '0.152.0',
      'update_available': true,
      'release_notes': '修复若干问题',
    });
    expect(tool.canUpgrade, isTrue);
    expect(tool.availableVersion, '0.154.0');
    expect(tool.canRollback, isTrue);
    expect(tool.rollbackVersion, '0.152.0');
    expect(tool.releaseNotes, '修复若干问题');
    // 老 Bridge 不带这些字段:没有升级项。
    final legacy = LocalCodingToolState.fromJson({
      'target_id': 'codex_cli',
      'generation': 3,
      'ui_state': 'installed_unmanaged',
      'verification_level': 'l0',
      'next_actions': ['detect'],
    });
    expect(legacy.canUpgrade, isFalse);
    expect(legacy.canRollback, isFalse);
    expect(
      () => LocalCodingToolState.fromJson({
        'target_id': 'codex_cli',
        'generation': 3,
        'ui_state': 'installed_unmanaged',
        'verification_level': 'l0',
        'next_actions': ['detect'],
        'update_available': 'yes',
      }),
      throwsFormatException,
    );

    final upgrade = LocalCodingInstallPlan.fromJson({
      'plan_id': 'p1',
      'target_id': 'codex_cli',
      'mode': 'upgrade',
      'version': '0.154.0',
      'source': 'official_openai',
      'origin': 'catalog',
      'from_version': '0.153.4',
      'download_host': 'bus.example.com',
      'download_size_bytes': 87323149,
      'sha256': 'deadbeef',
      'expires_at': '2026-09-10T10:05:00Z',
    });
    expect(upgrade.mode, LocalCodingInstallMode.upgrade);
    expect(upgrade.origin, 'catalog');
    expect(upgrade.fromVersion, '0.153.4');
    expect(upgrade.local, isFalse);
    // 回退到本机保留版本:不下载,大小 0、无主机与哈希也合法。
    final rollback = LocalCodingInstallPlan.fromJson({
      'plan_id': 'p2',
      'target_id': 'codex_cli',
      'mode': 'rollback',
      'version': '0.152.0',
      'source': 'official_openai',
      'origin': 'local',
      'from_version': '0.153.4',
      'local': true,
      'download_host': '',
      'download_size_bytes': 0,
      'sha256': '',
      'expires_at': '2026-09-10T10:05:00Z',
    });
    expect(rollback.mode, LocalCodingInstallMode.rollback);
    expect(rollback.local, isTrue);
    expect(rollback.downloadSizeBytes, 0);
    // 不是本机回退却没有下载量:仍然拒绝。
    expect(
      () => LocalCodingInstallPlan.fromJson({
        'plan_id': 'p3',
        'target_id': 'codex_cli',
        'mode': 'upgrade',
        'version': '0.154.0',
        'source': 'official_openai',
        'download_host': 'bus.example.com',
        'download_size_bytes': 0,
        'sha256': 'x',
        'expires_at': 'now',
      }),
      throwsFormatException,
    );
    final desktop = LocalCodingInstallPlan.fromJson({
      'plan_id': 'p4',
      'target_id': 'claude_desktop',
      'mode': 'upgrade',
      'version': '1.50000.0',
      'source': 'official_anthropic',
      'publisher_auto_update_may_override': true,
      'download_host': 'dl.example.cn',
      'download_size_bytes': 10,
      'sha256': 'x',
      'expires_at': 'now',
    });
    expect(desktop.publisherAutoUpdateMayOverride, isTrue);

    final signed = LocalCodingSignedCatalog.fromJson({
      'catalog': {'schema': 1, 'targets': {}},
      'kid': 'lc-catalog-test',
      'signature': 'YWJj',
    });
    expect(signed.kid, 'lc-catalog-test');
    expect(signed.toJson()['catalog'], {'schema': 1, 'targets': {}});
    expect(
      () => LocalCodingSignedCatalog.fromJson({
        'catalog': {'schema': 1},
        'kid': 'lc-catalog-test',
        'signature': 'not base64url!',
      }),
      throwsFormatException,
    );
    expect(
      () => LocalCodingSignedCatalog.fromJson({
        'catalog': 'nope',
        'kid': 'k',
        'signature': 'YWJj',
      }),
      throwsFormatException,
    );
    final applied = LocalCodingCatalogApplyResult.fromJson({
      'applied': true,
      'issued_at': '2026-09-10T00:00:00Z',
      'expires_at': '2026-09-17T00:00:00Z',
      'targets': {
        'codex_cli': {
          'current_version': '0.154.0',
          'previous_version': '0.153.4',
          'canary': true
        },
        'claude_code_host': {'current_version': '2.1.270'},
      },
    });
    expect(applied.applied, isTrue);
    expect(
        applied.targets[LocalCodingTarget.codexCli]?.currentVersion, '0.154.0');
    expect(applied.targets[LocalCodingTarget.codexCli]?.canary, isTrue);
    // App 不认识的目录目标(宿主组件)被跳过。
    expect(applied.targets.length, 1);
  });

  test('config.status · 桌面端 L2 与 CLI L3 的判定', () {
    final l2 = LocalCodingConfigurationStatus.fromJson({
      'target_id': 'codex_desktop',
      'state': 'not_configured',
      'verification_level': 'l0',
      'next_actions': ['switch_global'],
      'current_service': 'zhiban',
      'global_switched': true,
      'global_verification_level': 'l2',
    });
    expect(l2.switchedToZhiban, isTrue);
    expect(l2.globalVerifiedL2, isTrue);
    expect(l2.globalVerifiedL3, isFalse);

    final l3 = LocalCodingConfigurationStatus.fromJson({
      'target_id': 'codex_cli',
      'state': 'not_configured',
      'verification_level': 'l0',
      'next_actions': ['switch_global'],
      'current_service': 'zhiban',
      'global_verification_level': 'l3',
    });
    expect(l3.globalVerifiedL2, isTrue);
    expect(l3.globalVerifiedL3, isTrue);
    expect(l3.globalUpgradeAvailable, isFalse);
  });

  test('config.status · 契约 §2.7.2「模型选择」global_upgrade_available', () {
    final status = LocalCodingConfigurationStatus.fromJson({
      'target_id': 'claude_cli',
      'state': 'not_configured',
      'verification_level': 'l0',
      'next_actions': ['switch_global'],
      'current_service': 'zhiban',
      'global_switched': true,
      'global_upgrade_available': true,
    });
    expect(status.globalUpgradeAvailable, isTrue);
    expect(
      () => LocalCodingConfigurationStatus.fromJson({
        'target_id': 'claude_cli',
        'state': 'not_configured',
        'verification_level': 'l0',
        'next_actions': <String>[],
        'global_upgrade_available': 'yes',
      }),
      throwsFormatException,
    );
  });

  test('snapshot · 授权只要求两个 CLI target;桌面端沿用 CLI 的 Profile', () {
    const deviceId = '11111111-1111-4111-8111-111111111111';
    final snapshot = LocalCodingToolsSnapshot(
      deviceId: deviceId,
      environment: 'prod',
      credentialStatus: const LocalCodingCredentialStatus(
        identityPresent: true,
        authorizationPresent: true,
        deviceId: deviceId,
        environment: 'prod',
        targets: {LocalCodingTarget.codexCli, LocalCodingTarget.claudeCli},
      ),
      tools: {
        for (final target in LocalCodingTarget.values)
          target: LocalCodingToolState(
            target: target,
            generation: 1,
            uiState: LocalCodingToolUiState.installedUnmanaged,
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
            nextActions: const ['switch_global'],
          ),
      },
      expectedProfileVersions: const {},
      registrationAvailable: true,
    );
    expect(snapshot.authorizationConnected, isTrue);
    expect(snapshot.hasTarget(LocalCodingTarget.claudeDesktop), isTrue);
  });

  test(
      'launch.plan / launch.execute · 桌面端 project_name 为空串也能解码(11909 真机「打开桌面端」报不兼容数据)',
      () {
    // Bridge 对桌面端 official 启动回 project_name:"",CLI 主目录启动回 "~"。
    final plan = LocalCodingLaunchPlan.fromJson({
      'launch_plan_id': 'plan-1',
      'target_id': 'codex_desktop',
      'project_name': '',
      'expires_at': '2026-09-09T12:00:00Z',
    });
    expect(plan.target, LocalCodingTarget.codexDesktop);
    expect(plan.projectName, '');
    final launched = LocalCodingLaunchResult.fromJson({
      'target_id': 'codex_desktop',
      'state': 'launched',
      'project_name': '',
    });
    expect(launched.state, 'launched');
    expect(launched.projectName, '');
    // 缺省字段同样视为空;CLI 的 "~" 照常通过。
    expect(
      LocalCodingLaunchResult.fromJson({
        'target_id': 'codex_cli',
        'state': 'launched',
      }).projectName,
      '',
    );
    expect(
      LocalCodingLaunchPlan.fromJson({
        'launch_plan_id': 'plan-2',
        'target_id': 'codex_cli',
        'project_name': '~',
        'expires_at': '2026-09-09T12:00:00Z',
      }).projectName,
      '~',
    );
    // 非空时仍不放过路径样的显示名。
    expect(
      () => LocalCodingLaunchPlan.fromJson({
        'launch_plan_id': 'plan-3',
        'target_id': 'codex_cli',
        'project_name': '/Users/me/project',
        'expires_at': '2026-09-09T12:00:00Z',
      }),
      throwsFormatException,
    );
  });

  test('2026-09-15 · 检测失败带中转站原话:解析 error_detail,按错误码归类并给出一句话原因', () {
    const detail = 'HTTP 503 · auth_unavailable: no auth available';
    final op = LocalCodingOperation.fromJson({
      'operation_id': 'op-1',
      'target_id': 'codex_cli',
      'kind': 'verify',
      'state': 'failed',
      'stage': 'l3',
      'progress_kind': 'indeterminate',
      'progress_value': null,
      'cancellable': false,
      'error_code': 'LCT-CODEX_CLI-GATEWAY-UPSTREAM_UNAVAILABLE',
      'error_detail': detail,
      'trace_id': null,
      'next_actions': ['retry', 'diagnostics'],
    });
    expect(op.errorDetail, detail);
    final diagnostics = LocalCodingDiagnostics.fromJson({
      'target_id': 'codex_cli',
      'bridge_version': '0.5.0',
      'error_code': op.errorCode,
      'error_detail': detail,
      'suggestions': <String>[],
    });
    expect(diagnostics.errorDetail, detail);

    expect(localCodingRelayFailure(op.errorCode, op.errorDetail),
        LocalCodingRelayFailure.upstreamUnavailable);
    expect(
        localCodingRelayFailureSummary(
            LocalCodingRelayFailure.upstreamUnavailable, detail),
        '知办中转站暂时不可用（HTTP 503），不是本机问题，稍后再检测');
    expect(
        localCodingRelayFailure('LCT-CLAUDE_CLI-GATEWAY-QUOTA_EXHAUSTED', ''),
        LocalCodingRelayFailure.quotaExhausted);
    expect(
        localCodingRelayFailureSummary(
            LocalCodingRelayFailure.quotaExhausted, ''),
        '知办中转站拒绝了请求，可能是用量已用完或请求过于频繁，稍后再检测');
    // 协议不一致只有带着中转站回答时才算中转站的问题;网络、授权失败不算。
    expect(
        localCodingRelayFailure('LCT-CODEX_CLI-GATEWAY-PROTOCOL_MISMATCH', ''),
        isNull);
    expect(
        localCodingRelayFailure(
            'LCT-CODEX_CLI-GATEWAY-PROTOCOL_MISMATCH', 'HTTP 400 · bad'),
        LocalCodingRelayFailure.rejected);
    expect(localCodingRelayFailure('LCT-CODEX_CLI-GATEWAY-UNREACHABLE', ''),
        isNull);
    expect(
        localCodingRelayFailure(
            'LCT-CODEX_CLI-AUTH-TOKEN_EXPIRED', 'HTTP 401 · invalid'),
        isNull);
  });

  // 契约 §2.7 · GATEWAY-UNREACHABLE 的 error_detail(2026-09-17):命令行原话和
  // "探测超时"不是中转站说的,不能标成"中转站返回"。
  test('失败详情只有中转站的 HTTP 回答才标"中转站返回"', () {
    expect(localCodingErrorDetailLabel('HTTP 503 · upstream overloaded'),
        '中转站返回');
    expect(
        localCodingErrorDetailLabel(
            'API Error: Unable to connect to API: SSL certificate verification failed. Check your proxy or corporate SSL certificates'),
        '失败详情');
    expect(localCodingErrorDetailLabel('探测超时（90 秒内没有任何回答）'), '失败详情');
  });

  test('2026-09-18 · 代理状态:区分 NO_PROXY 与系统绕过名单;老 Bridge 不回新字段时行为不变', () {
    final current = LocalCodingProxyStatus.fromJson({
      'supported': true,
      'system_proxy': {'enabled': true, 'endpoint': '127.0.0.1:7897'},
      'covered': {'user_env': true, 'system_bypass': false},
      'direct_reachable': true,
      'needs_fix': true,
      'env_needs_fix': false,
    });
    expect(current.needsFix, isTrue);
    expect(current.envNeedsFix, isFalse);
    expect(current.bypassNeedsFix, isTrue);

    // 老 Bridge:needs_fix 当时就是 NO_PROXY 口径,没有 system_bypass 这一项。
    final legacy = LocalCodingProxyStatus.fromJson({
      'supported': true,
      'system_proxy': {'enabled': true, 'endpoint': '127.0.0.1:7897'},
      'covered': {'user_env': false},
      'direct_reachable': true,
      'needs_fix': true,
    });
    expect(legacy.envNeedsFix, isTrue);
    expect(legacy.bypassNeedsFix, isFalse);

    // 系统代理没开 / 直连不通(企业强制走代理):不提示绕过名单。
    for (final json in [
      {
        'system_proxy': {'enabled': false},
        'covered': {'system_bypass': false},
        'direct_reachable': true,
      },
      {
        'system_proxy': {'enabled': true},
        'covered': {'system_bypass': false},
        'direct_reachable': false,
      },
    ]) {
      expect(LocalCodingProxyStatus.fromJson(json).bypassNeedsFix, isFalse);
    }
  });

  test('2026-09-18 · PROXY_DIVERTED 归到"修复并重试修不好"的一类,文案点名代理软件', () {
    final failure = localCodingRelayFailure(
        'LCT-CLAUDE_CLI-GATEWAY-PROXY_DIVERTED', '探测超时（90 秒内没有任何回答）');
    expect(failure, LocalCodingRelayFailure.proxyDiverted);
    expect(localCodingRelayFailureSummary(failure!, ''), contains('代理软件'));
    expect(localCodingRelayFailure('LCT-CODEX_CLI-GATEWAY-UNREACHABLE', ''), isNull);
  });

  test('2026-09-20 · 换票被拒要说真话:积分用完 / 模型服务停用不是"授权失效",也不劝人重新接入', () {
    final credit =
        localCodingRelayFailure('LCT-CODEX_CLI-AUTH-INSUFFICIENT_CREDIT', '');
    expect(credit, LocalCodingRelayFailure.insufficientCredit);
    final creditText = localCodingRelayFailureSummary(credit!, '');
    expect(creditText, contains('积分已用完'));
    expect(creditText, contains('套餐与积分'));
    expect(creditText, contains('不需要重新接入'));

    final disabled =
        localCodingRelayFailure('LCT-CLAUDE_CLI-AUTH-MEMBER_KEY_DISABLED', '');
    expect(disabled, LocalCodingRelayFailure.memberKeyDisabled);
    final disabledText = localCodingRelayFailureSummary(disabled!, '');
    expect(disabledText, contains('已被停用'));
    expect(disabledText, contains('管理员'));

    // 真的设备授权失效仍走原来的路(修复并重试能修好)。
    expect(localCodingRelayFailure('LCT-CODEX_CLI-AUTH-DEVICE_REVOKED', ''),
        isNull);
  });
  test('2026-09-20 · 备用模型通过:检测算通过,但要说清当前配置的模型线路不可用', () {
    final op = LocalCodingOperation.fromJson({
      'operation_id': 'op-1',
      'target_id': 'claude_cli',
      'kind': 'verify',
      'state': 'succeeded',
      'stage': 'l3',
      'progress_kind': 'indeterminate',
      'cancellable': false,
      'next_actions': <String>[],
      'result': {
        'verification_level': 'l3',
        'verified_at': '2026-09-20T10:00:00Z',
        'model_warning': {
          'error_code': 'LCT-CLAUDE_CLI-GATEWAY-UPSTREAM_UNAVAILABLE',
          'error_detail': 'HTTP 502 · Upstream request failed',
          'working_model': 'claude-sonnet-5',
        },
      },
    });
    final warning = op.modelWarning;
    expect(warning, isNotNull);
    expect(warning!.workingModel, 'claude-sonnet-5');
    final text = localCodingModelWarningText(warning);
    expect(text, contains('当前配置的模型线路暂时不可用（HTTP 502）'));
    expect(text, contains('claude-sonnet-5'));
    expect(text, contains('换一个模型'));

    // 没有提示、或提示残缺(缺可用模型)时不显示。
    final plain = LocalCodingOperation.fromJson({
      'operation_id': 'op-2',
      'target_id': 'claude_cli',
      'kind': 'verify',
      'state': 'succeeded',
      'stage': 'l3',
      'progress_kind': 'indeterminate',
      'cancellable': false,
      'next_actions': <String>[],
      'result': {
        'verification_level': 'l3',
        'model_warning': {'error_code': 'LCT-CLAUDE_CLI-GATEWAY-UPSTREAM_UNAVAILABLE'},
      },
    });
    expect(plain.modelWarning, isNull);
  });
}
