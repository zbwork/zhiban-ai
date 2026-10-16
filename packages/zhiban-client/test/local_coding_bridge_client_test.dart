import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_bridge_client.dart';

void main() {
  test('locates the executable inside the fixed app-like helper bundle',
      () async {
    if (!Platform.isMacOS) return;
    final root = await Directory.systemTemp.createTemp(
      'zhiban-local-coding-locator-',
    );
    addTearDown(() => root.delete(recursive: true));
    final appExecutable = File(
      '${root.path}/ZhibanTest.app/Contents/MacOS/ZhibanTest',
    );
    final helperExecutable = File(
      '${root.path}/ZhibanTest.app/Contents/Helpers/'
      'ZhibanLocalBridge.app/Contents/MacOS/zhiban-local-bridge',
    );
    await appExecutable.parent.create(recursive: true);
    await appExecutable.writeAsString('app');
    await helperExecutable.parent.create(recursive: true);
    await helperExecutable.writeAsString('#!/bin/sh\nexit 0\n');
    final chmod =
        await Process.run('/bin/chmod', ['0755', helperExecutable.path]);
    expect(chmod.exitCode, 0);

    final located = await BundledLocalCodingBridgeExecutableLocator(
      appExecutablePath: appExecutable.path,
    ).locate();

    expect(located, await helperExecutable.resolveSymbolicLinks());
  });

  test('rejects an app-like helper bundle symlink that escapes Helpers',
      () async {
    if (!Platform.isMacOS) return;
    final root = await Directory.systemTemp.createTemp(
      'zhiban-local-coding-locator-escape-',
    );
    addTearDown(() => root.delete(recursive: true));
    final appExecutable = File(
      '${root.path}/ZhibanTest.app/Contents/MacOS/ZhibanTest',
    );
    final helpersDirectory = Directory(
      '${root.path}/ZhibanTest.app/Contents/Helpers',
    );
    final escapedBundle = Directory('${root.path}/EscapedBridge.app');
    final escapedExecutable = File(
      '${escapedBundle.path}/Contents/MacOS/zhiban-local-bridge',
    );
    await appExecutable.parent.create(recursive: true);
    await appExecutable.writeAsString('app');
    await helpersDirectory.create(recursive: true);
    await escapedExecutable.parent.create(recursive: true);
    await escapedExecutable.writeAsString('#!/bin/sh\nexit 0\n');
    final chmod = await Process.run('/bin/chmod', [
      '0755',
      escapedExecutable.path,
    ]);
    expect(chmod.exitCode, 0);
    await Link('${helpersDirectory.path}/ZhibanLocalBridge.app').create(
      escapedBundle.path
    );

    await expectLater(
      BundledLocalCodingBridgeExecutableLocator(
        appExecutablePath: appExecutable.path,
      ).locate(),
      throwsA(
        isA<LocalCodingBridgeException>().having(
          (error) => error.code,
          'error code',
          'helper_path_mismatch',
        ),
      ),
    );
  });

  test('rejects a Helpers directory symlink that escapes the app bundle',
      () async {
    if (!Platform.isMacOS) return;
    final root = await Directory.systemTemp.createTemp(
      'zhiban-local-coding-helpers-escape-',
    );
    addTearDown(() => root.delete(recursive: true));
    final appExecutable = File(
      '${root.path}/ZhibanTest.app/Contents/MacOS/ZhibanTest',
    );
    final escapedHelpers = Directory('${root.path}/EscapedHelpers');
    final escapedExecutable = File(
      '${escapedHelpers.path}/ZhibanLocalBridge.app/Contents/MacOS/'
      'zhiban-local-bridge',
    );
    await appExecutable.parent.create(recursive: true);
    await appExecutable.writeAsString('app');
    await escapedExecutable.parent.create(recursive: true);
    await escapedExecutable.writeAsString('#!/bin/sh\nexit 0\n');
    final chmod = await Process.run('/bin/chmod', [
      '0755',
      escapedExecutable.path,
    ]);
    expect(chmod.exitCode, 0);
    await Link('${appExecutable.parent.parent.path}/Helpers').create(
      escapedHelpers.path
    );

    await expectLater(
      BundledLocalCodingBridgeExecutableLocator(
        appExecutablePath: appExecutable.path,
      ).locate(),
      throwsA(
        isA<LocalCodingBridgeException>().having(
          (error) => error.code,
          'error code',
          'helper_path_mismatch',
        ),
      ),
    );
  });

  test('rejects a MacOS directory symlink that escapes the helper bundle',
      () async {
    if (!Platform.isMacOS) return;
    final root = await Directory.systemTemp.createTemp(
      'zhiban-local-coding-macos-escape-',
    );
    addTearDown(() => root.delete(recursive: true));
    final appExecutable = File(
      '${root.path}/ZhibanTest.app/Contents/MacOS/ZhibanTest',
    );
    final helperContents = Directory(
      '${root.path}/ZhibanTest.app/Contents/Helpers/'
      'ZhibanLocalBridge.app/Contents',
    );
    final escapedMacOS = Directory('${root.path}/EscapedMacOS');
    final escapedExecutable = File(
      '${escapedMacOS.path}/zhiban-local-bridge',
    );
    await appExecutable.parent.create(recursive: true);
    await appExecutable.writeAsString('app');
    await helperContents.create(recursive: true);
    await escapedMacOS.create(recursive: true);
    await escapedExecutable.writeAsString('#!/bin/sh\nexit 0\n');
    final chmod = await Process.run('/bin/chmod', [
      '0755',
      escapedExecutable.path,
    ]);
    expect(chmod.exitCode, 0);
    await Link('${helperContents.path}/MacOS').create(escapedMacOS.path);

    await expectLater(
      BundledLocalCodingBridgeExecutableLocator(
        appExecutablePath: appExecutable.path,
      ).locate(),
      throwsA(
        isA<LocalCodingBridgeException>().having(
          (error) => error.code,
          'error code',
          'helper_path_mismatch',
        ),
      ),
    );
  });

  test('signature verifier rejects the obsolete bare helper path', () async {
    await expectLater(
      const MacOSLocalCodingBridgeSignatureVerifier().verify(
        '/Applications/Zhiban.app/Contents/Helpers/zhiban-local-bridge',
      ),
      throwsA(
        isA<LocalCodingBridgeException>().having(
          (error) => error.code,
          'error code',
          'helper_path_mismatch',
        ),
      ),
    );
  });

  test('signature verifier rejects an ad-hoc app-like helper', () async {
    if (!Platform.isMacOS) return;
    final root = await Directory.systemTemp.createTemp(
      'zhiban-local-coding-adhoc-signature-',
    );
    addTearDown(() => root.delete(recursive: true));
    final helperBundle = Directory(
      '${root.path}/ZhibanLocalBridge.app'
    );
    final helperExecutable = File(
      '${helperBundle.path}/Contents/MacOS/zhiban-local-bridge',
    );
    final infoPlist = File('${helperBundle.path}/Contents/Info.plist');
    await helperExecutable.parent.create(recursive: true);
    await helperExecutable.writeAsString('#!/bin/sh\nexit 0\n');
    await infoPlist.writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>zhiban-local-bridge</string>
<key>CFBundleIdentifier</key><string>cn.qkfintech.zhiban.local-bridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
''');
    final chmod = await Process.run('/bin/chmod', [
      '0755',
      helperExecutable.path,
    ]);
    expect(chmod.exitCode, 0);
    final sign = await Process.run('/usr/bin/codesign', [
      '--force',
      '--sign',
      '-',
      '--timestamp=none',
      '--options',
      'runtime',
      '--identifier',
      'cn.qkfintech.zhiban.local-bridge',
      helperBundle.path,
    ]);
    expect(sign.exitCode, 0, reason: '${sign.stderr}');

    await expectLater(
      const MacOSLocalCodingBridgeSignatureVerifier().verify(
        helperExecutable.path,
      ),
      throwsA(
        isA<LocalCodingBridgeException>().having(
          (error) => error.code,
          'error code',
          'signature_mismatch',
        ),
      ),
    );
  });

  test('initializes before typed calls and maps credential/detect state',
      () async {
    final process = _FakeBridgeProcess((request) {
      switch (request['method']) {
        case 'initialize':
          return _success(request, {
            'protocol_version': '1.0',
            'bridge_version': '0.2.0-test',
            'supported_methods': const [
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
            ],
          });
        case 'credential.status':
          return _success(request, {
            'identity_present': true,
            'authorization_present': true,
            'device_id': '11111111-1111-4111-8111-111111111111',
            'environment': 'prod',
            'targets': const ['claude_cli', 'codex_cli'],
            'profile_versions': const {
              'codex_cli': 'codex-v1',
              'claude_cli': 'claude-v1',
            },
          });
        case 'tool.detect':
          return _success(request, {
            'target_id': (request['params'] as Map)['target_id'],
            'installation_id': 'opaque-id',
            'generation': 1,
            'ui_state': 'installed_unmanaged',
            'installed_version': '1.2.3',
            'install_source': 'official',
            'verification_level': 'l0',
            'next_actions': const ['detect'],
          });
      }
      throw StateError('unexpected method');
    });
    final factory = ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
    );

    final session = await factory.open();
    final status = await session.credentialStatus();
    final codex = await session.detect(LocalCodingTarget.codexCli);
    await session.close();

    expect(process.methods.first, 'initialize');
    expect(status.authorizationPresent, isTrue);
    expect(status.targets, contains(LocalCodingTarget.claudeCli));
    expect(codex.uiState, LocalCodingToolUiState.installedUnmanaged);
    expect(codex.installedVersion, '1.2.3');
    expect(process.closed, isTrue);
  });

  test('registration prepare and commit stay in one initialized process',
      () async {
    const secret = 'lctd.22222222-2222-4222-8222-222222222222.'
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV';
    final process = _FakeBridgeProcess((request) {
      switch (request['method']) {
        case 'initialize':
          return _success(request, {
            'protocol_version': '1.0',
            'bridge_version': '0.2.0-test',
            'supported_methods': const [
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
            ],
          });
        case 'credential.registration.prepare':
          return _success(request, {
            'device_id': '11111111-1111-4111-8111-111111111111',
            'device_public_jwk': const {
              'kty': 'OKP',
              'crv': 'Ed25519',
              'x': 'public-key',
            },
            'dpop_proof': 'proof-secret',
          });
        case 'credential.registration.commit':
          return _success(request, {'stored': true});
      }
      throw StateError('unexpected method');
    });
    final session = await ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
    ).open();

    final prepared = await session.prepareRegistration(
      deviceId: '11111111-1111-4111-8111-111111111111',
      environment: 'prod',
    );
    await session.commitRegistration(
      credentialId: '22222222-2222-4222-8222-222222222222',
      deviceCredential: secret,
      profileVersions: const {
        'codex_cli': 'codex-v1',
        'claude_cli': 'claude-v1',
      },
    );
    await session.close();

    expect(prepared.dpopProof, 'proof-secret');
    expect(process.methods, [
      'initialize',
      'credential.registration.prepare',
      'credential.registration.commit',
    ]);
  });

  test('configuration calls use typed isolated plan and status contracts',
      () async {
    final process = _FakeBridgeProcess((request) {
      switch (request['method']) {
        case 'initialize':
          return _success(request, {
            'protocol_version': '1.0',
            'bridge_version': '0.2.0-test',
            'supported_methods': const [
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
            ],
          });
        case 'config.plan':
          expect(request['params'], {
            'target_id': 'codex_cli',
            'installation_id': 'opaque-installation',
          });
          return _success(request, {
            'plan_id': 'opaque-plan',
            'target_id': 'codex_cli',
            'action': 'create',
            'profile_version': 'codex-v1',
            'expires_at': '2026-09-07T12:00:00Z',
          });
        case 'config.execute':
          expect(request['params'], {'plan_id': 'opaque-plan'});
          return _success(request, _configuredStatus('codex_cli'));
        case 'config.status':
          expect(request['params'], {'target_id': 'codex_cli'});
          return _success(request, _configuredStatus('codex_cli'));
        case 'config.restore':
          expect(request['params'], {'target_id': 'codex_cli'});
          return _success(request, {
            'target_id': 'codex_cli',
            'state': 'not_configured',
            'verification_level': 'l0',
            'next_actions': const ['configure'],
          });
      }
      throw StateError('unexpected method');
    });
    final session = await ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
    ).open();

    final plan = await session.planConfiguration(
      target: LocalCodingTarget.codexCli,
      installationId: 'opaque-installation',
    );
    final executed = await session.executeConfiguration(plan.planId);
    final status =
        await session.configurationStatus(LocalCodingTarget.codexCli);
    final restored =
        await session.restoreConfiguration(LocalCodingTarget.codexCli);
    await session.close();

    expect(plan.action, LocalCodingConfigurationAction.create);
    expect(executed.configured, isTrue);
    expect(status.profileVersion, 'codex-v1');
    expect(restored.state, LocalCodingConfigurationState.notConfigured);
  });

  test('project launch calls expose only opaque typed parameters', () async {
    final process = _FakeBridgeProcess((request) {
      switch (request['method']) {
        case 'initialize':
          return _success(request, {
            'protocol_version': '1.0',
            'bridge_version': '0.2.0-test',
            'supported_methods': const [
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
            ],
          });
        case 'project.grant.create':
          expect(request['params'], {'bookmark_data': 'Ym9va21hcms='});
          return _success(request, {
            'project_grant_id': 'opaque-project-grant',
            'display_name': 'private-project',
            'expires_at': '2026-09-07T12:05:00Z',
          });
        case 'launch.plan':
          expect(request['params'], {
            'target_id': 'claude_cli',
            'installation_id': 'opaque-installation',
            'project_grant_id': 'opaque-project-grant',
            'profile_version': 'claude-v1',
          });
          return _success(request, {
            'launch_plan_id': 'opaque-launch-plan',
            'target_id': 'claude_cli',
            'project_name': 'private-project',
            'expires_at': '2026-09-07T12:02:00Z',
          });
        case 'launch.execute':
          expect(request['params'], {'plan_id': 'opaque-launch-plan'});
          return _success(request, {
            'state': 'launched',
            'target_id': 'claude_cli',
            'project_name': 'private-project',
          });
      }
      throw StateError('unexpected method');
    });
    final session = await ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
    ).open();

    final grant = await session.createProjectGrant('Ym9va21hcms=');
    final plan = await session.planLaunch(
      target: LocalCodingTarget.claudeCli,
      installationId: 'opaque-installation',
      projectGrantId: grant.projectGrantId,
      profileVersion: 'claude-v1',
    );
    final launched = await session.executeLaunch(plan.launchPlanId);
    await session.close();

    expect(grant.displayName, 'private-project');
    expect(plan.target, LocalCodingTarget.claudeCli);
    expect(launched.state, 'launched');
    expect(process.methods, [
      'initialize',
      'project.grant.create',
      'launch.plan',
      'launch.execute',
    ]);
  });

  test('mismatched response id fails closed without exposing frame', () async {
    const leaked = 'do-not-leak-secret';
    final process = _FakeBridgeProcess((request) => {
          'jsonrpc': '2.0',
          'id': 'wrong-id',
          'result': {'value': leaked},
        });
    final factory = ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
    );

    await expectLater(
      factory.open(),
      throwsA(isA<LocalCodingBridgeException>().having(
        (error) => error.toString(),
        'sanitized error',
        isNot(contains(leaked)),
      )),
    );
    expect(process.killed, isTrue);
  });

  test('oversized stdout frame terminates bridge', () async {
    late final _FakeBridgeProcess process;
    process = _FakeBridgeProcess((request) {
      process.writeRaw(
        List<int>.filled(localCodingBridgeMaxFrameBytes + 1, 65),
      );
      return null;
    });

    final factory = ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
    );

    await expectLater(
        factory.open(), throwsA(isA<LocalCodingBridgeException>()));
    expect(process.killed, isTrue);
  });

  test('RPC error is sanitized and closes process', () async {
    const leaked = 'proof-secret-must-not-leak';
    final process = _FakeBridgeProcess((request) => {
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {'code': -32603, 'message': leaked},
        });
    final factory = ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
    );

    await expectLater(
      factory.open(),
      throwsA(isA<LocalCodingBridgeException>().having(
        (error) => error.toString(),
        'sanitized error',
        isNot(contains(leaked)),
      )),
    );
    expect(process.killed, isTrue);
  });

  test('request timeout fails closed and terminates bridge', () async {
    final process = _FakeBridgeProcess((request) => null);
    final factory = ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
      requestTimeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      factory.open(),
      throwsA(isA<LocalCodingBridgeException>().having(
        (error) => error.code,
        'error code',
        'rpc_timeout',
      )),
    );
    expect(process.killed, isTrue);
  });

  test('premature process exit fails closed', () async {
    late final _FakeBridgeProcess process;
    process = _FakeBridgeProcess((request) {
      process.exitUnexpectedly();
      return null;
    });
    final factory = ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
    );

    await expectLater(
      factory.open(),
      throwsA(isA<LocalCodingBridgeException>().having(
        (error) => error.code,
        'error code',
        'bridge_exited',
      )),
    );
    expect(process.killed, isTrue);
  });

  test('-32000 domain error surfaces as LocalCodingBridgeDomainException',
      () async {
    const lctCode = 'LCT-CODEX_CLI-INSTALL-HASH_MISMATCH';
    final process = _FakeBridgeProcess((request) {
      if (request['method'] == 'initialize') {
        return _success(request, {
          'protocol_version': '1.0',
          'bridge_version': '0.3.0-test',
          'supported_methods': _fullSupportedMethods,
        });
      }
      return {
        'jsonrpc': '2.0',
        'id': request['id'],
        'error': {'code': -32000, 'message': lctCode},
      };
    });
    final session = await ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
    ).open();

    await expectLater(
      session.installPlan(target: LocalCodingTarget.codexCli),
      throwsA(isA<LocalCodingBridgeDomainException>().having(
        (e) => e.code,
        'LCT code',
        lctCode,
      )),
    );
    expect(process.killed, isTrue);
  });

  test('install domain errors that need the user to act are not "请重试"',
      () async {
    // 2026-09-15 开发机:升级 Claude 桌面端报 TARGET_IN_USE,却只显示
    // "本地连接组件未能完成操作，请重试",用户不知道要先退出应用。
    const expected = {
      // 2026-09-16 测试反馈:泛指"该工具"没用——Codex 桌面端真正在跑的进程
      // 叫 ChatGPT,用户退了 Codex 还是升不了,文案必须指名道姓。
      'LCT-CLAUDE_DESKTOP-INSTALL-TARGET_IN_USE':
          '请先完全退出 Claude 桌面端再升级（退出后再点一次）',
      'LCT-CODEX_DESKTOP-INSTALL-TARGET_IN_USE':
          '请先完全退出 Codex 桌面端再升级（新版应用名是 ChatGPT，退出后再点一次）',
      // 2026-09-20:没能确认应用是否在运行,不能说成"请先退出"——用户会去找一个
      // 不存在的进程。
      'LCT-CLAUDE_DESKTOP-INSTALL-RUNNING_CHECK_FAILED':
          '知办没能确认该应用是否正在运行（不是发现了占用），请稍后再试；反复出现请上传诊断',
      'LCT-CLAUDE_DESKTOP-INSTALL-NOT_INSTALLED': '未检测到该工具，请重新检测',
      'LCT-CODEX_DESKTOP-INSTALL-AUTHORIZATION_CANCELLED':
          '已取消 Windows 管理员授权，尚未下载安装。重新点击安装后，在系统提示中选择“是”',
      'LCT-CODEX_DESKTOP-INSTALL-AUTHORIZATION_TIMEOUT':
          '等待 Windows 管理员授权超时，尚未下载安装。请重试并处理系统授权提示',
      'LCT-CODEX_DESKTOP-INSTALL-AUTHORIZATION_FAILED':
          '未能申请 Windows 管理员授权，尚未下载安装。请重试或联系管理员',
      'LCT-CODEX_DESKTOP-INSTALL-REGISTRATION_FAILED':
          'Windows 未能完成应用安装，请查看诊断详情或联系支持',
      'LCT-CODEX_CLI-INSTALL-UNSUPPORTED_ARCH': '当前电脑架构暂不支持一键安装',
      'LCT-CODEX_CLI-INSTALL-NOT_UPGRADABLE': '当前安装不满足升级条件，请重新检测',
      'LCT-CODEX_CLI-INSTALL-UPGRADE_FAILED': '升级未完成，已保留原版本，请查看诊断详情',
    };
    for (final entry in expected.entries) {
      final process = _FakeBridgeProcess((request) {
        if (request['method'] == 'initialize') {
          return _success(request, {
            'protocol_version': '1.0',
            'bridge_version': '0.3.0-test',
            'supported_methods': _fullSupportedMethods,
          });
        }
        return {
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {'code': -32000, 'message': entry.key},
        };
      });
      final session = await ProcessLocalCodingBridgeSessionFactory(
        executableLocator: _FakeLocator('/fixed/bridge'),
        signatureVerifier: _FakeVerifier(),
        processLauncher: _FakeLauncher(process),
        appVersionLoader: () async => '1.1.7',
        runtimeArch: 'arm64',
      ).open();

      await expectLater(
        session.installPlan(target: LocalCodingTarget.claudeDesktop),
        throwsA(isA<LocalCodingBridgeDomainException>().having(
          (e) => e.userMessage,
          entry.key,
          entry.value,
        )),
      );
    }
  });

  test('unreadable tool.detect result keeps the session open for other targets',
      () async {
    final process = _FakeBridgeProcess((request) {
      switch (request['method']) {
        case 'initialize':
          return _success(request, {
            'protocol_version': '1.0',
            'bridge_version': '1.2.0-test',
            'supported_methods': _fullSupportedMethods,
          });
        case 'tool.detect':
          final target = (request['params'] as Map)['target_id'];
          if (target == 'codex_cli') {
            // 12003 真机:老 Bridge 的并存安装候选缺 installed_version 等字段。
            return _success(request, {
              'target_id': target,
              'generation': 1,
              'ui_state': 'shape_from_newer_bridge',
              'verification_level': 'l0',
              'next_actions': const ['detect'],
            });
          }
          return _success(request, {
            'target_id': target,
            'installation_id': 'opaque-id',
            'generation': 2,
            'ui_state': 'installed_unmanaged',
            'installed_version': '2.1.263',
            'install_source': 'official',
            'verification_level': 'l0',
            'next_actions': const ['detect'],
          });
      }
      throw StateError('unexpected method');
    });
    final session = await ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.2.0',
      runtimeArch: 'arm64',
    ).open();

    await expectLater(
      session.detect(LocalCodingTarget.codexCli),
      throwsA(isA<LocalCodingBridgeUnreadableResultException>()
          .having((e) => e.code, 'code', 'invalid_result')),
    );
    expect(process.killed, isFalse);
    final claude = await session.detect(LocalCodingTarget.claudeCli);
    expect(claude.installedVersion, '2.1.263');
    await session.close();
    expect(process.killed, isFalse);
  });

  test('install → operation.get flow decodes typed envelope', () async {
    const opId = 'op-A';
    var call = 0;
    final process = _FakeBridgeProcess((request) {
      switch (request['method']) {
        case 'initialize':
          return _success(request, {
            'protocol_version': '1.0',
            'bridge_version': '0.3.0-test',
            'supported_methods': _fullSupportedMethods,
          });
        case 'install.plan':
          expect(
              request['params'], {'target_id': 'codex_cli', 'mode': 'install'});
          return _success(request, {
            'plan_id': 'plan-a',
            'target_id': 'codex_cli',
            'mode': 'install',
            'version': '0.153.4',
            'source': 'official_openai',
            'download_host': 'github.com',
            'download_size_bytes': 87323149,
            'sha256': 'deadbeef',
            'expires_at': '2026-09-08T10:05:00Z',
          });
        case 'install.execute':
          expect(request['params'], {'plan_id': 'plan-a'});
          return _success(request, {
            'operation_id': opId,
            'target_id': 'codex_cli',
            'kind': 'install',
            'state': 'running',
            'stage': 'preflight',
            'progress_kind': 'indeterminate',
            'progress_value': null,
            'cancellable': true,
            'error_code': null,
            'trace_id': null,
            'next_actions': const ['cancel'],
          });
        case 'operation.get':
          call++;
          expect(request['params'], {'operation_id': opId});
          return _success(request, {
            'operation_id': opId,
            'target_id': 'codex_cli',
            'kind': 'install',
            'state': call == 1 ? 'running' : 'succeeded',
            'stage': call == 1 ? 'downloading' : 'detecting',
            'progress_kind': call == 1 ? 'determinate' : 'indeterminate',
            'progress_value': call == 1 ? 42 : null,
            'cancellable': call == 1,
            'error_code': null,
            'trace_id': null,
            'next_actions': call == 1 ? const ['cancel'] : const ['detect'],
            'result': call == 1 ? null : const {'tool_state': null},
          });
      }
      throw StateError('unexpected method ${request['method']}');
    });
    final session = await ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
    ).open();

    final plan = await session.installPlan(target: LocalCodingTarget.codexCli);
    expect(plan.planId, 'plan-a');
    final started = await session.installExecute(plan.planId);
    expect(started.stage, 'preflight');
    final tick1 = await session.operationGet(opId);
    expect(tick1.downloadPercent, 42);
    final terminal = await session.operationGet(opId);
    expect(terminal.isSucceeded, isTrue);
    expect(terminal.stage, 'detecting');
    await session.close();
  });

  test(
      '契约 §2.7.4 · catalog.apply 原样转交 catalog / kid / signature;清除时只带 environment 与 null catalog',
      () async {
    final seen = <Map<String, dynamic>>[];
    final process = _FakeBridgeProcess((request) {
      switch (request['method']) {
        case 'initialize':
          return _success(request, {
            'protocol_version': '1.0',
            'bridge_version': '0.5.0-test',
            'supported_methods': [..._fullSupportedMethods, 'catalog.apply'],
          });
        case 'catalog.apply':
          seen.add(Map<String, dynamic>.from(request['params'] as Map));
          final present = request['params']['catalog'] != null;
          return _success(request, {
            'applied': present,
            'issued_at': present ? '2026-09-10T00:00:00Z' : null,
            'targets': present
                ? {
                    'codex_cli': {'current_version': '0.154.0', 'canary': true},
                    'claude_code_host': {'current_version': '2.1.270'},
                  }
                : const {},
          });
      }
      throw StateError('unexpected method ${request['method']}');
    });
    final session = await ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
    ).open();
    expect(session.supportedMethods, contains('catalog.apply'));

    final applied = await session.catalogApply(
      environment: 'test',
      catalog: const LocalCodingSignedCatalog(
        catalog: {'schema': 1, 'targets': {}},
        kid: 'lc-catalog-test',
        signature: 'c2ln',
      ),
    );
    expect(applied.applied, isTrue);
    expect(
        applied.targets[LocalCodingTarget.codexCli]?.currentVersion, '0.154.0');
    expect(applied.targets[LocalCodingTarget.codexCli]?.canary, isTrue);
    expect(applied.targets.length, 1);
    expect(seen.single, {
      'environment': 'test',
      'catalog': {'schema': 1, 'targets': {}},
      'kid': 'lc-catalog-test',
      'signature': 'c2ln',
    });

    final cleared = await session.catalogApply(environment: 'test');
    expect(cleared.applied, isFalse);
    expect(seen.last, {'environment': 'test', 'catalog': null});
    await session.close();
  });

  test('launch.plan with official mode passes through', () async {
    final process = _FakeBridgeProcess((request) {
      switch (request['method']) {
        case 'initialize':
          return _success(request, {
            'protocol_version': '1.0',
            'bridge_version': '0.3.0-test',
            'supported_methods': _fullSupportedMethods,
          });
        case 'launch.plan':
          expect(request['params'], {
            'target_id': 'claude_cli',
            'installation_id': 'opaque-installation',
            'project_grant_id': 'opaque-grant',
            'profile_version': 'claude-v1',
            'mode': 'official',
          });
          return _success(request, {
            'launch_plan_id': 'opaque-launch-plan',
            'target_id': 'claude_cli',
            'project_name': 'private-project',
            'expires_at': '2026-09-08T10:02:00Z',
          });
      }
      throw StateError('unexpected method ${request['method']}');
    });
    final session = await ProcessLocalCodingBridgeSessionFactory(
      executableLocator: _FakeLocator('/fixed/bridge'),
      signatureVerifier: _FakeVerifier(),
      processLauncher: _FakeLauncher(process),
      appVersionLoader: () async => '1.1.7',
      runtimeArch: 'arm64',
    ).open();
    final plan = await session.planLaunch(
      target: LocalCodingTarget.claudeCli,
      installationId: 'opaque-installation',
      projectGrantId: 'opaque-grant',
      profileVersion: 'claude-v1',
      mode: LocalCodingLaunchMode.official,
    );
    expect(plan.target, LocalCodingTarget.claudeCli);
    await session.close();
  });
}

const List<String> _fullSupportedMethods = [
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
];

Map<String, dynamic> _configuredStatus(String targetId) => {
      'target_id': targetId,
      'state': 'configured',
      'profile_version': 'codex-v1',
      'verification_level': 'l1',
      'next_actions': const ['verify'],
    };

Map<String, dynamic> _success(
  Map<String, dynamic> request,
  Map<String, dynamic> result,
) =>
    {'jsonrpc': '2.0', 'id': request['id'], 'result': result};

class _FakeLocator implements LocalCodingBridgeExecutableLocator {
  const _FakeLocator(this.path);

  final String path;

  @override
  Future<String> locate() async => path;
}

class _FakeVerifier implements LocalCodingBridgeSignatureVerifier {
  @override
  Future<void> verify(String executablePath) async {}
}

class _FakeLauncher implements LocalCodingBridgeProcessLauncher {
  const _FakeLauncher(this.process);

  final LocalCodingBridgeProcess process;

  @override
  Future<LocalCodingBridgeProcess> start(
    String executablePath, {
    required Map<String, String> environment,
  }) async =>
      process;
}

class _FakeBridgeProcess implements LocalCodingBridgeProcess {
  _FakeBridgeProcess(this._respond) {
    _stdin.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      methods.add(request['method'] as String);
      final response = _respond(request);
      if (response != null) {
        _stdout.add(utf8.encode('${jsonEncode(response)}\n'));
      }
    }, onDone: () {
      closed = true;
      if (!_exitCode.isCompleted) _exitCode.complete(0);
      _stdout.close();
      _stderr.close();
    });
  }

  final Map<String, dynamic>? Function(Map<String, dynamic>) _respond;
  final StreamController<List<int>> _stdin = StreamController<List<int>>();
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exitCode = Completer<int>();
  final List<String> methods = [];
  bool killed = false;
  bool closed = false;

  void writeRaw(List<int> bytes) => _stdout.add(bytes);

  void exitUnexpectedly() {
    if (!_exitCode.isCompleted) _exitCode.complete(1);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  IOSink get stdin => IOSink(_stdin.sink);

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  bool kill() {
    killed = true;
    if (!_exitCode.isCompleted) _exitCode.complete(1);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    return true;
  }
}
