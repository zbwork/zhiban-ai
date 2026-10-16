import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';

const int localCodingBridgeMaxFrameBytes = 1 << 20;
const String _protocolVersion = '1.0';
const String _helperIdentifier = 'cn.qkfintech.zhiban.local-bridge';
const String _developerTeamId = 'NUHSLZ4RU4';
const String _defaultSearchPath =
    '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin';

class LocalCodingBridgeException implements Exception {
  const LocalCodingBridgeException(this.code, this.userMessage);

  final String code;
  final String userMessage;

  @override
  String toString() => userMessage;
}

/// Bridge 通过 JSON-RPC error code `-32000` 汇报的领域错误。
/// `code` 是形如 `LCT-CODEX_CLI-INSTALL-HASH_MISMATCH` 的稳定标识,
/// 由 App 直接用来分支与诊断展示。
class LocalCodingBridgeDomainException extends LocalCodingBridgeException {
  const LocalCodingBridgeDomainException(super.code, super.userMessage);
}

/// 帧与信封都合法、只是某个 target 的 tool.detect 结果 App 读不懂(Bridge 与 App
/// 版本错位)。会话仍可继续使用,读快照时只把这张卡降级(契约 §2.7,2026-09-15)。
class LocalCodingBridgeUnreadableResultException
    extends LocalCodingBridgeException {
  const LocalCodingBridgeUnreadableResultException()
      : super('invalid_result', '本地连接组件返回了不兼容的数据，请更新知办');
}

abstract interface class LocalCodingBridgeExecutableLocator {
  Future<String> locate();
}

abstract interface class LocalCodingBridgeSignatureVerifier {
  Future<void> verify(String executablePath);
}

abstract interface class LocalCodingBridgeProcess {
  IOSink get stdin;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;
  bool kill();
}

abstract interface class LocalCodingBridgeProcessLauncher {
  Future<LocalCodingBridgeProcess> start(
    String executablePath, {
    required Map<String, String> environment,
  });
}

abstract interface class LocalCodingBridgeSession {
  /// Bridge 在 initialize 里公布的方法列表(去重后)。用于按能力位开关新按钮。
  Set<String> get supportedMethods;

  Future<LocalCodingToolState> detect(LocalCodingTarget target);

  Future<LocalCodingCredentialPreparation> prepareRegistration({
    required String deviceId,
    required String environment,
  });

  Future<void> commitRegistration({
    required String credentialId,
    required String deviceCredential,
    required Map<String, String> profileVersions,
  });

  Future<LocalCodingCredentialStatus> credentialStatus();

  Future<void> clearCredential();

  Future<LocalCodingConfigurationStatus> configurationStatus(
    LocalCodingTarget target,
  );

  Future<LocalCodingConfigurationPlan> planConfiguration({
    required LocalCodingTarget target,
    String installationId,
    LocalCodingConfigurationType? type,
  });

  Future<LocalCodingConfigurationStatus> executeConfiguration(String planId);

  Future<LocalCodingConfigurationStatus> restoreConfiguration(
    LocalCodingTarget target,
  );

  Future<LocalCodingProjectGrant> createProjectGrant(String bookmarkData);

  Future<LocalCodingLaunchPlan> planLaunch({
    required LocalCodingTarget target,
    required String installationId,
    String projectGrantId,
    String profileVersion,
    LocalCodingLaunchMode mode,
  });

  Future<LocalCodingLaunchResult> executeLaunch(String planId);

  Future<LocalCodingRequirements> requirementsGet(LocalCodingTarget target);

  Future<LocalCodingInstallPlan> installPlan({
    required LocalCodingTarget target,
    LocalCodingInstallMode mode,
    // M3 Task 8 · 运行组件预置:传 component 时不带 mode(契约 §2.7.3)。
    String? component,
  });

  Future<LocalCodingOperation> installExecute(String planId);

  Future<LocalCodingOperation> operationGet(String operationId);

  Future<LocalCodingOperation> operationCancel(String operationId);

  Future<LocalCodingOperation> verifyExecute({
    required LocalCodingTarget target,
    required String installationId,
    LocalCodingVerifyScope scope,
  });

  Future<LocalCodingDiagnostics> diagnosticsGetLatest(
    LocalCodingTarget target
  );

  /// 契约 §2.7.4 · 把 Bus 下发的签名目录交给 Bridge 验签采用;[catalog] 为 null
  /// 表示 Bus 没有目录,Bridge 清除已采用的目录回落内置清单。
  Future<LocalCodingCatalogApplyResult> catalogApply({
    required String environment,
    LocalCodingSignedCatalog? catalog,
  });

  /// 契约 §2.7 network.* · 系统代理拦截检测 / 一键设置代理例外。
  Future<LocalCodingProxyStatus> networkProxyStatus();
  Future<LocalCodingProxyStatus> networkProxyApply();

  Future<void> close();
}

abstract interface class LocalCodingBridgeSessionFactory {
  Future<LocalCodingBridgeSession> open();
}

class BundledLocalCodingBridgeExecutableLocator
    implements LocalCodingBridgeExecutableLocator {
  const BundledLocalCodingBridgeExecutableLocator({this.appExecutablePath});

  final String? appExecutablePath;

  static const String _debugOverride = String.fromEnvironment(
    'LOCAL_CODING_BRIDGE_PATH',
    defaultValue: '',
  );

  @override
  Future<String> locate() async {
    if (!Platform.isMacOS && !Platform.isWindows) {
      throw const LocalCodingBridgeException(
        'unsupported_platform',
        '当前系统暂不支持 AI 编程工具接入',
      );
    }
    if (!kReleaseMode && _debugOverride.trim().isNotEmpty) {
      if (!_isAbsolutePath(_debugOverride)) {
        throw const LocalCodingBridgeException(
          'invalid_debug_path',
          '本地连接组件开发路径无效',
        );
      }
      return _validatedExecutablePath(_debugOverride);
    }

    if (Platform.isWindows) {
      return _locateWindows();
    }

    final appExecutable =
        File(appExecutablePath ?? Platform.resolvedExecutable);
    try {
      final resolvedAppExecutable = await appExecutable.resolveSymbolicLinks();
      final resolvedMacOSDirectory = await File(
        resolvedAppExecutable,
      ).parent.resolveSymbolicLinks();
      final resolvedContentsDirectory = await Directory(
        resolvedMacOSDirectory,
      ).parent.resolveSymbolicLinks();
      final resolvedHelpersDirectory = await _resolveFixedDirectory(
        resolvedContentsDirectory,
        'Helpers',
      );
      final resolvedBundle = await _resolveFixedDirectory(
        resolvedHelpersDirectory,
        'ZhibanLocalBridge.app',
      );
      final resolvedHelperContents = await _resolveFixedDirectory(
        resolvedBundle,
        'Contents',
      );
      final resolvedHelperMacOS = await _resolveFixedDirectory(
        resolvedHelperContents,
        'MacOS',
      );
      final resolved = await _validatedExecutablePath(
        Directory(resolvedHelperMacOS)
            .uri
            .resolve('zhiban-local-bridge')
            .toFilePath(),
      );
      final expectedExecutable = Directory(
        resolvedHelperMacOS,
      ).uri.resolve('zhiban-local-bridge').toFilePath();
      if (resolved != expectedExecutable) {
        throw const LocalCodingBridgeException(
          'helper_path_mismatch',
          '本地连接组件校验失败，请更新或重新安装知办',
        );
      }
      return resolved;
    } on LocalCodingBridgeException {
      rethrow;
    } catch (_) {
      throw const LocalCodingBridgeException(
        'helper_missing',
        '未找到本地连接组件，请更新或重新安装知办',
      );
    }
  }

  Future<String> _resolveFixedDirectory(String parent, String name) async {
    final expected = '$parent/$name';
    final directory = Directory(expected);
    final stat = await directory.stat();
    if (stat.type != FileSystemEntityType.directory) {
      throw const LocalCodingBridgeException(
        'helper_missing',
        '未找到本地连接组件，请更新或重新安装知办',
      );
    }
    final resolved = await directory.resolveSymbolicLinks();
    if (resolved != expected) {
      throw const LocalCodingBridgeException(
        'helper_path_mismatch',
        '本地连接组件校验失败，请更新或重新安装知办',
      );
    }
    return resolved;
  }

  // On Windows the bundled helper (zhiban-local-bridge.exe) sits next to the
  // app executable (ZhiBanAI.exe) in the install directory, rather than inside
  // a .app bundle. There is no code-signature-based path lockdown yet
  // (Authenticode is a later milestone); the exe is validated as a real file
  // in the app's own directory.
  Future<String> _locateWindows() async {
    final appExecutable =
        File(appExecutablePath ?? Platform.resolvedExecutable);
    try {
      final resolvedAppExecutable = await appExecutable.resolveSymbolicLinks();
      final directory = File(resolvedAppExecutable).parent;
      final bridge =
          directory.uri.resolve('zhiban-local-bridge.exe').toFilePath();
      return _validatedExecutablePath(bridge);
    } on LocalCodingBridgeException {
      rethrow;
    } catch (_) {
      throw const LocalCodingBridgeException(
        'helper_missing',
        '未找到本地连接组件，请更新或重新安装知办',
      );
    }
  }

  bool _isAbsolutePath(String path) {
    final trimmed = path.trim();
    if (trimmed.startsWith('/')) return true;
    if (trimmed.startsWith(r'\\')) return true; // UNC
    if (trimmed.length >= 3 &&
        trimmed[1] == ':' &&
        (trimmed[2] == '\\' || trimmed[2] == '/')) {
      return true; // Windows drive-absolute
    }
    return false;
  }

  Future<String> _validatedExecutablePath(String path) async {
    try {
      final file = File(path);
      final stat = await file.stat();
      // Windows has no Unix executable bit; a real file suffices there.
      final notExecutable = !Platform.isWindows && (stat.mode & 0x49) == 0;
      if (stat.type != FileSystemEntityType.file || notExecutable) {
        throw const LocalCodingBridgeException(
          'helper_not_executable',
          '本地连接组件不可用，请更新或重新安装知办',
        );
      }
      return file.resolveSymbolicLinks();
    } on LocalCodingBridgeException {
      rethrow;
    } catch (_) {
      throw const LocalCodingBridgeException(
        'helper_missing',
        '未找到本地连接组件，请更新或重新安装知办',
      );
    }
  }
}

class MacOSLocalCodingBridgeSignatureVerifier
    implements LocalCodingBridgeSignatureVerifier {
  const MacOSLocalCodingBridgeSignatureVerifier({
    this.timeout = const Duration(seconds: 5),
  });

  static const bool _allowUnsignedDebug = bool.fromEnvironment(
    'LOCAL_CODING_BRIDGE_ALLOW_UNSIGNED',
    defaultValue: false,
  );

  final Duration timeout;

  @override
  Future<void> verify(String executablePath) async {
    if (!kReleaseMode && _allowUnsignedDebug) return;
    const requirement = '=anchor apple generic and '
        'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
        'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
        'certificate leaf[subject.OU] = "$_developerTeamId" and '
        'identifier "$_helperIdentifier"';
    final helperBundlePath = _helperBundlePath(executablePath);
    await _runCodesign(
      ['--verify', '--strict', helperBundlePath]
    );
    await _runCodesign(
      [
        '--verify',
        '--strict',
        '--test-requirement',
        requirement,
        executablePath,
      ]
    );
  }

  String _helperBundlePath(String executablePath) {
    final executable = File(executablePath);
    final macOSDirectory = executable.parent;
    final contentsDirectory = macOSDirectory.parent;
    final helperBundle = contentsDirectory.parent;
    if (_entityName(executable) != 'zhiban-local-bridge' ||
        _entityName(macOSDirectory) != 'MacOS' ||
        _entityName(contentsDirectory) != 'Contents' ||
        _entityName(helperBundle) != 'ZhibanLocalBridge.app') {
      throw const LocalCodingBridgeException(
        'helper_path_mismatch',
        '本地连接组件校验失败，请更新或重新安装知办',
      );
    }
    return helperBundle.path;
  }

  String _entityName(FileSystemEntity entity) =>
      entity.uri.pathSegments.where((segment) => segment.isNotEmpty).last;

  Future<void> _runCodesign(List<String> arguments) async {
    Process? process;
    StreamSubscription<List<int>>? stdoutSubscription;
    StreamSubscription<List<int>>? stderrSubscription;
    try {
      process = await Process.start(
        '/usr/bin/codesign',
        arguments,
        includeParentEnvironment: false,
        runInShell: false,
      );
      stdoutSubscription = process.stdout.listen((_) {});
      stderrSubscription = process.stderr.listen((_) {});
      final exitCode = await process.exitCode.timeout(timeout);
      if (exitCode != 0) {
        throw const LocalCodingBridgeException(
          'signature_mismatch',
          '本地连接组件签名校验失败，请更新或重新安装知办',
        );
      }
    } on LocalCodingBridgeException {
      rethrow;
    } on TimeoutException {
      process?.kill();
      throw const LocalCodingBridgeException(
        'signature_timeout',
        '本地连接组件签名校验超时，请重试',
      );
    } catch (_) {
      throw const LocalCodingBridgeException(
        'signature_check_failed',
        '无法校验本地连接组件，请更新或重新安装知办',
      );
    } finally {
      await stdoutSubscription?.cancel();
      await stderrSubscription?.cancel();
    }
  }
}

class DartLocalCodingBridgeProcessLauncher
    implements LocalCodingBridgeProcessLauncher {
  const DartLocalCodingBridgeProcessLauncher();

  @override
  Future<LocalCodingBridgeProcess> start(
    String executablePath, {
    required Map<String, String> environment,
  }) async {
    final process = await Process.start(
      executablePath,
      const [],
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    return _DartLocalCodingBridgeProcess(process);
  }
}

class _DartLocalCodingBridgeProcess implements LocalCodingBridgeProcess {
  const _DartLocalCodingBridgeProcess(this.process);

  final Process process;

  @override
  Future<int> get exitCode => process.exitCode;

  @override
  IOSink get stdin => process.stdin;

  @override
  Stream<List<int>> get stderr => process.stderr;

  @override
  Stream<List<int>> get stdout => process.stdout;

  @override
  bool kill() => process.kill(ProcessSignal.sigterm);
}

// The bundled helper is code-signature verified on macOS (Developer ID). On
// Windows there is no Authenticode signing yet, so verification is skipped —
// the helper is instead pinned to the app's own install directory by the
// locator. Wiring an Authenticode check here is a later milestone.
LocalCodingBridgeSignatureVerifier _defaultBridgeSignatureVerifier() {
  if (Platform.isMacOS) {
    return const MacOSLocalCodingBridgeSignatureVerifier();
  }
  return const NoopLocalCodingBridgeSignatureVerifier();
}

/// Signature verifier that performs no check. Used on platforms without a
/// wired code-signature verification path (currently Windows).
class NoopLocalCodingBridgeSignatureVerifier
    implements LocalCodingBridgeSignatureVerifier {
  const NoopLocalCodingBridgeSignatureVerifier();

  @override
  Future<void> verify(String executablePath) async {}
}

class ProcessLocalCodingBridgeSessionFactory
    implements LocalCodingBridgeSessionFactory {
  ProcessLocalCodingBridgeSessionFactory({
    LocalCodingBridgeExecutableLocator? executableLocator,
    LocalCodingBridgeSignatureVerifier? signatureVerifier,
    LocalCodingBridgeProcessLauncher? processLauncher,
    Future<String> Function()? appVersionLoader,
    this.runtimeArch,
    this.requestTimeout = const Duration(seconds: 15),
    this.closeTimeout = const Duration(seconds: 2),
  })  : _executableLocator = executableLocator ??
            const BundledLocalCodingBridgeExecutableLocator(),
        _signatureVerifier =
            signatureVerifier ?? _defaultBridgeSignatureVerifier(),
        _processLauncher =
            processLauncher ?? const DartLocalCodingBridgeProcessLauncher(),
        _appVersionLoader = appVersionLoader ?? _loadAppVersion;

  final LocalCodingBridgeExecutableLocator _executableLocator;
  final LocalCodingBridgeSignatureVerifier _signatureVerifier;
  final LocalCodingBridgeProcessLauncher _processLauncher;
  final Future<String> Function() _appVersionLoader;
  final String? runtimeArch;
  final Duration requestTimeout;
  final Duration closeTimeout;

  @override
  Future<LocalCodingBridgeSession> open() async {
    LocalCodingBridgeProcess? process;
    try {
      final path = await _executableLocator.locate();
      await _signatureVerifier.verify(path);
      process = await _processLauncher.start(
        path,
        environment: _bridgeEnvironment(),
      );
      final session = _ProcessLocalCodingBridgeSession(
        process,
        requestTimeout: requestTimeout,
        closeTimeout: closeTimeout,
      );
      await session.initialize(
        appVersion: await _appVersionLoader(),
        arch: runtimeArch ?? _currentArch(),
      );
      return session;
    } on LocalCodingBridgeException {
      process?.kill();
      rethrow;
    } catch (_) {
      process?.kill();
      throw const LocalCodingBridgeException(
        'bridge_start_failed',
        '本地连接组件启动失败，请重试或更新知办',
      );
    }
  }

  static Future<String> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  static String _currentMacOSArch() {
    if (Abi.current() == Abi.macosArm64) return 'arm64';
    if (Abi.current() == Abi.macosX64) return 'x64';
    throw const LocalCodingBridgeException(
      'unsupported_architecture',
      '当前 Mac 架构暂不支持 AI 编程工具接入',
    );
  }

  static String _currentArch() {
    if (Platform.isWindows) {
      if (Abi.current() == Abi.windowsX64) return 'x64';
      throw const LocalCodingBridgeException(
        'unsupported_architecture',
        '当前 Windows 架构暂不支持 AI 编程工具接入',
      );
    }
    return _currentMacOSArch();
  }

  // The bundled helper runs with a replacement environment
  // (includeParentEnvironment is false), so every variable it needs must be
  // supplied explicitly. On macOS that is HOME plus a sanitized POSIX PATH; on
  // Windows the helper needs the real Windows system/profile variables
  // (USERPROFILE, SystemRoot, ComSpec, PATHEXT, APPDATA, LOCALAPPDATA, …) or it
  // cannot resolve the user home, run cmd-based CLIs, or reach DPAPI storage.
  static Map<String, String> _bridgeEnvironment() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final userProfile = (env['USERPROFILE'] ?? '').trim();
      if (userProfile.isEmpty) {
        throw const LocalCodingBridgeException(
          'home_unavailable',
          '无法确定本机用户目录，请重新打开知办',
        );
      }
      // Node-based CLIs (Claude Code / Codex) need a full Windows environment
      // to start — trimming it to a fixed allow-list makes them hang or exit
      // without output. Pass through the user's environment (which the app
      // itself runs under, so nothing external is added), minus the model
      // credential variables that must never leak into a managed launch.
      const blocked = {
        'OPENAI_API_KEY',
        'CODEX_API_KEY',
        'OPENAI_BASE_URL',
        'ANTHROPIC_API_KEY',
        'ANTHROPIC_AUTH_TOKEN',
        'ANTHROPIC_BASE_URL',
        'CLAUDE_CODE_OAUTH_TOKEN',
      };
      final result = <String, String>{};
      env.forEach((key, value) {
        if (value.isEmpty || blocked.contains(key)) return;
        result[key] = value;
      });
      return result;
    }
    final home = (env['HOME'] ?? '').trim();
    if (home.isEmpty) {
      throw const LocalCodingBridgeException(
        'home_unavailable',
        '无法确定本机用户目录，请重新打开知办',
      );
    }
    return {
      'HOME': home,
      'PATH': _defaultSearchPath,
      'LANG': 'zh_CN.UTF-8',
      'LC_ALL': 'zh_CN.UTF-8',
    };
  }
}

class _ProcessLocalCodingBridgeSession implements LocalCodingBridgeSession {
  _ProcessLocalCodingBridgeSession(
    this._process, {
    required this.requestTimeout,
    required this.closeTimeout,
  })  : _stdin = _process.stdin,
        _frames = StreamIterator<String>(_decodeFrames(_process.stdout)) {
    _stderrSubscription = _process.stderr.listen((_) {});
  }

  static const Set<String> _requiredMethods = {
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
  };

  final LocalCodingBridgeProcess _process;
  final IOSink _stdin;
  final StreamIterator<String> _frames;
  final Duration requestTimeout;
  final Duration closeTimeout;
  late final StreamSubscription<List<int>> _stderrSubscription;
  var _nextId = 0;
  var _closed = false;
  var _initialized = false;
  Set<String> _supportedMethods = const {};

  @override
  Set<String> get supportedMethods => _supportedMethods;

  Future<void> initialize({
    required String appVersion,
    required String arch,
  }) async {
    final result = await _call('initialize', {
      'protocol_version': _protocolVersion,
      'app_version': appVersion,
      'platform': Platform.isWindows ? 'windows' : 'macos',
      'arch': arch,
      'locale': 'zh-CN',
    });
    try {
      if (result['protocol_version'] != _protocolVersion ||
          result['bridge_version'] is! String ||
          (result['bridge_version'] as String).trim().isEmpty) {
        throw const FormatException('invalid initialization result');
      }
      final methods = result['supported_methods'];
      if (methods is! List || methods.any((value) => value is! String)) {
        throw const FormatException('invalid supported methods');
      }
      final supported = methods.cast<String>().toSet();
      if (!supported.containsAll(_requiredMethods)) {
        throw const FormatException('required method missing');
      }
      _supportedMethods = Set.unmodifiable(supported);
      _initialized = true;
    } on FormatException {
      await _abort();
      throw const LocalCodingBridgeException(
        'protocol_mismatch',
        '本地连接组件版本不兼容，请更新知办',
      );
    }
  }

  @override
  Future<LocalCodingToolState> detect(LocalCodingTarget target) async {
    _requireInitialized();
    final result = await _call('tool.detect', {'target_id': target.id});
    try {
      return LocalCodingToolState.fromJson(result);
    } on FormatException {
      // 这一帧已完整读完,会话不中止:只读的检测结果读不懂只影响这张卡。
      throw const LocalCodingBridgeUnreadableResultException();
    }
  }

  @override
  Future<LocalCodingCredentialPreparation> prepareRegistration({
    required String deviceId,
    required String environment,
  }) async {
    _requireInitialized();
    return _decodeTyped(
      await _call('credential.registration.prepare', {
        'device_id': deviceId,
        'environment': environment,
      }),
      LocalCodingCredentialPreparation.fromJson,
    );
  }

  @override
  Future<void> commitRegistration({
    required String credentialId,
    required String deviceCredential,
    required Map<String, String> profileVersions,
  }) async {
    _requireInitialized();
    final result = await _call('credential.registration.commit', {
      'credential_id': credentialId,
      'device_credential': deviceCredential,
      'profile_versions': profileVersions,
    });
    if (result['stored'] != true) {
      await _abort();
      throw const LocalCodingBridgeException(
        'credential_store_failed',
        '设备授权保存失败，请重新接入',
      );
    }
  }

  @override
  Future<LocalCodingCredentialStatus> credentialStatus() async {
    _requireInitialized();
    return _decodeTyped(
      await _call('credential.status', const {}),
      LocalCodingCredentialStatus.fromJson,
    );
  }

  @override
  Future<void> clearCredential() async {
    _requireInitialized();
    final result = await _call('credential.clear', const {});
    if (result['cleared'] != true) {
      await _abort();
      throw const LocalCodingBridgeException(
        'credential_clear_failed',
        '本地设备授权清理失败，请重试',
      );
    }
  }

  @override
  Future<LocalCodingConfigurationStatus> configurationStatus(
    LocalCodingTarget target,
  ) async {
    _requireInitialized();
    return _decodeTyped(
      await _call('config.status', {'target_id': target.id}),
      LocalCodingConfigurationStatus.fromJson,
    );
  }

  @override
  Future<LocalCodingConfigurationPlan> planConfiguration({
    required LocalCodingTarget target,
    String installationId = '',
    LocalCodingConfigurationType? type,
  }) async {
    _requireInitialized();
    final params = <String, dynamic>{
      'target_id': target.id,
      // restore_global 不需要安装;其它类型必须带 installation_id。
      if (installationId.isNotEmpty) 'installation_id': installationId,
    };
    if (type != null) {
      // 只在显式指定时透传;缺省(即 enable)不发字段,保持与旧 Bridge 兼容。
      params['type'] = type.value;
    }
    return _decodeTyped(
      await _call('config.plan', params),
      LocalCodingConfigurationPlan.fromJson,
    );
  }

  @override
  Future<LocalCodingConfigurationStatus> executeConfiguration(
    String planId,
  ) async {
    _requireInitialized();
    return _decodeTyped(
      await _call('config.execute', {'plan_id': planId}),
      LocalCodingConfigurationStatus.fromJson,
    );
  }

  @override
  Future<LocalCodingConfigurationStatus> restoreConfiguration(
    LocalCodingTarget target,
  ) async {
    _requireInitialized();
    return _decodeTyped(
      await _call('config.restore', {'target_id': target.id}),
      LocalCodingConfigurationStatus.fromJson,
    );
  }

  @override
  Future<LocalCodingProjectGrant> createProjectGrant(
    String bookmarkData,
  ) async {
    _requireInitialized();
    return _decodeTyped(
      await _call('project.grant.create', {'bookmark_data': bookmarkData}),
      LocalCodingProjectGrant.fromJson,
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
    _requireInitialized();
    final params = <String, dynamic>{
      'target_id': target.id,
      'installation_id': installationId,
      // 「打开应用」= official 模式且不选项目:两个字段都不发,Bridge 在用户主目录启动。
      if (projectGrantId.isNotEmpty) 'project_grant_id': projectGrantId,
      if (profileVersion.isNotEmpty) 'profile_version': profileVersion,
    };
    if (mode != LocalCodingLaunchMode.managed) {
      params['mode'] = mode.value;
    }
    return _decodeTyped(
      await _call('launch.plan', params),
      LocalCodingLaunchPlan.fromJson,
    );
  }

  @override
  Future<LocalCodingLaunchResult> executeLaunch(String planId) async {
    _requireInitialized();
    return _decodeTyped(
      await _call('launch.execute', {'plan_id': planId}),
      LocalCodingLaunchResult.fromJson,
    );
  }

  @override
  Future<LocalCodingRequirements> requirementsGet(
    LocalCodingTarget target,
  ) async {
    _requireInitialized();
    return _decodeTyped(
      await _call('requirements.get', {'target_id': target.id}),
      LocalCodingRequirements.fromJson,
    );
  }

  @override
  Future<LocalCodingInstallPlan> installPlan({
    required LocalCodingTarget target,
    LocalCodingInstallMode mode = LocalCodingInstallMode.install,
    String? component,
  }) async {
    _requireInitialized();
    final params = <String, dynamic>{'target_id': target.id};
    if (component != null && component.isNotEmpty) {
      params['component'] = component;
    } else {
      params['mode'] = mode.value;
    }
    return _decodeTyped(
      await _call('install.plan', params),
      LocalCodingInstallPlan.fromJson,
    );
  }

  @override
  Future<LocalCodingOperation> installExecute(String planId) async {
    _requireInitialized();
    return _decodeTyped(
      await _call('install.execute', {'plan_id': planId}),
      LocalCodingOperation.fromJson,
    );
  }

  @override
  Future<LocalCodingCatalogApplyResult> catalogApply({
    required String environment,
    LocalCodingSignedCatalog? catalog,
  }) async {
    _requireInitialized();
    final params = <String, dynamic>{
      'environment': environment,
      'catalog': catalog?.catalog,
    };
    if (catalog != null) {
      params['kid'] = catalog.kid;
      params['signature'] = catalog.signature;
    }
    return _decodeTyped(
      await _call('catalog.apply', params),
      LocalCodingCatalogApplyResult.fromJson,
    );
  }

  @override
  Future<LocalCodingOperation> operationGet(String operationId) async {
    _requireInitialized();
    return _decodeTyped(
      await _call(
        'operation.get',
        {'operation_id': operationId},
        // 轮询用短超时,长操作本身由信封表达。
        timeout: const Duration(seconds: 5),
      ),
      LocalCodingOperation.fromJson,
    );
  }

  @override
  Future<LocalCodingOperation> operationCancel(String operationId) async {
    _requireInitialized();
    return _decodeTyped(
      await _call(
        'operation.cancel',
        {'operation_id': operationId},
        timeout: const Duration(seconds: 5)
      ),
      LocalCodingOperation.fromJson,
    );
  }

  @override
  Future<LocalCodingOperation> verifyExecute({
    required LocalCodingTarget target,
    required String installationId,
    LocalCodingVerifyScope scope = LocalCodingVerifyScope.overlay,
  }) async {
    _requireInitialized();
    return _decodeTyped(
      await _call('verify.execute', {
        'target_id': target.id,
        'installation_id': installationId,
        // 缺省 overlay 不发字段,保持与旧 Bridge 兼容。
        if (scope != LocalCodingVerifyScope.overlay) 'scope': scope.value,
      }),
      LocalCodingOperation.fromJson,
    );
  }

  @override
  Future<LocalCodingDiagnostics> diagnosticsGetLatest(
    LocalCodingTarget target,
  ) async {
    _requireInitialized();
    return _decodeTyped(
      await _call('diagnostics.get_latest', {'target_id': target.id}),
      LocalCodingDiagnostics.fromJson,
    );
  }

  @override
  Future<LocalCodingProxyStatus> networkProxyStatus() => _networkProxy('network.proxy_status');

  @override
  Future<LocalCodingProxyStatus> networkProxyApply() => _networkProxy('network.proxy_apply');

  Future<LocalCodingProxyStatus> _networkProxy(String method) async {
    _requireInitialized();
    return _decodeTyped(
      await _call(method, const <String, dynamic>{}),
      LocalCodingProxyStatus.fromJson,
    );
  }

  Future<T> _decodeTyped<T>(
    Map<String, dynamic> result,
    T Function(Map<String, dynamic>) decode,
  ) async {
    try {
      return decode(result);
    } on FormatException {
      await _abort();
      throw const LocalCodingBridgeException(
        'invalid_result',
        '本地连接组件返回了不兼容的数据，请更新知办',
      );
    }
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> params, {
    Duration? timeout,
  }) async {
    if (_closed) {
      throw const LocalCodingBridgeException(
        'session_closed',
        '本地连接组件会话已结束，请重试',
      );
    }
    final id = '${++_nextId}';
    final effectiveTimeout = timeout ?? requestTimeout;
    try {
      final request = utf8.encode('${jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'method': method,
              'params': params
            })}\n',);
      if (request.length > localCodingBridgeMaxFrameBytes) {
        throw const LocalCodingBridgeException(
          'request_too_large',
          '本地连接请求超过安全限制',
        );
      }
      _stdin.add(request);
      await _stdin.flush().timeout(effectiveTimeout);
      final hasFrame = await _frames.moveNext().timeout(effectiveTimeout);
      if (!hasFrame) {
        throw const LocalCodingBridgeException(
          'bridge_exited',
          '本地连接组件意外退出，请重试',
        );
      }
      final decoded = jsonDecode(_frames.current);
      if (decoded is! Map) {
        throw const FormatException('response is not an object');
      }
      final response = Map<String, dynamic>.from(decoded);
      final allowed = {'jsonrpc', 'id', 'result', 'error'};
      if (response.keys.toSet().difference(allowed).isNotEmpty ||
          response['jsonrpc'] != '2.0' ||
          response['id'] != id ||
          (response.containsKey('result') == response.containsKey('error'))) {
        throw const FormatException('invalid response envelope');
      }
      if (response.containsKey('error')) {
        final error = response['error'];
        final code = error is Map ? error['code'] : null;
        final message = error is Map ? error['message'] : null;
        // -32000 = Bridge 汇报的领域错误（LCT-* 稳定码），App 按码分支。
        if (code == -32000 && message is String && message.startsWith('LCT-')) {
          throw LocalCodingBridgeDomainException(
            message,
            _friendlyDomainMessage(message),
          );
        }
        throw LocalCodingBridgeException(
          'rpc_${code is int ? code : 'error'}',
          '本地连接组件未能完成操作，请重试',
        );
      }
      final result = response['result'];
      if (result is! Map) {
        throw const FormatException('result is not an object');
      }
      return Map<String, dynamic>.from(result);
    } on LocalCodingBridgeException {
      await _abort();
      rethrow;
    } on TimeoutException {
      await _abort();
      throw const LocalCodingBridgeException(
        'rpc_timeout',
        '本地连接组件响应超时，请重试'
      );
    } catch (_) {
      await _abort();
      throw const LocalCodingBridgeException(
        'protocol_error',
        '本地连接组件通信异常，请重试或更新知办',
      );
    }
  }

  void _requireInitialized() {
    if (!_initialized) {
      throw const LocalCodingBridgeException(
        'not_initialized',
        '本地连接组件尚未初始化'
      );
    }
  }

  Future<void> _abort() async {
    if (_closed) return;
    _closed = true;
    _process.kill();
    try {
      await _stdin.close();
    } catch (_) {}
    await _frames.cancel();
    await _stderrSubscription.cancel();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _stdin.close();
      await _process.exitCode.timeout(closeTimeout);
    } on TimeoutException {
      _process.kill();
    } catch (_) {
      _process.kill();
    } finally {
      await _frames.cancel();
      await _stderrSubscription.cancel();
    }
  }
}

/// 稳定码 → 用户可读文案。异步 operation 失败时进度弹框也用它(provider
/// `_awaitOperationOutcome`),否则用户只看得到一行错误码。
String localCodingErrorMessage(String code) => _friendlyDomainMessage(code);

/// 将 `LCT-{TARGET}-{阶段}-{原因}` 稳定码映射到用户可读的中文文案。
/// 不识别的码返回通用兜底,原始码由调用方通过 [LocalCodingBridgeDomainException.code] 读取。
String _friendlyDomainMessage(String code) {
  // 阶段片段 = code 里第三段(去掉可选目标段)。
  final parts = code.split('-');
  if (parts.length < 3) return '本地连接组件未能完成操作，请重试';
  final tail = parts.last;
  // 占用类错误必须指名道姓:泛指"该工具"时,用户退了 Codex 却不知道真正在跑
  // 的进程叫 ChatGPT(2026-09-16 测试反馈)。CLI 不会走到这里——命令行装的是
  // 版本化目录,升级不碰正在跑的那份。
  if (tail == 'TARGET_IN_USE') {
    return switch (parts.length >= 4 ? parts[1] : '') {
      'CODEX_DESKTOP' =>
        '请先完全退出 Codex 桌面端再升级（新版应用名是 ChatGPT，退出后再点一次）',
      'CLAUDE_DESKTOP' || 'CLAUDE_CODE_HOST' =>
        '请先完全退出 Claude 桌面端再升级（退出后再点一次）',
      _ => '该工具正在运行，请先完全退出后再试',
    };
  }
  switch (tail) {
    case 'OPERATION-BUSY':
    case 'BUSY':
      return '当前工具正在处理其它操作，请稍后再试';
    case 'ALREADY_INSTALLED':
      return '已检测到该工具，无需重复安装';
    case 'RUNNING_CHECK_FAILED':
      // Bridge 没能判断应用是否在运行(枚举进程超时、被安全软件拦),不是发现了占用。
      return '知办没能确认该应用是否正在运行（不是发现了占用），请稍后再试；反复出现请上传诊断';
    case 'NOT_INSTALLED':
      return '未检测到该工具，请重新检测';
    case 'UNSUPPORTED_ARCH':
      return '当前电脑架构暂不支持一键安装';
    case 'NOT_UPGRADABLE':
      return '当前安装不满足升级条件，请重新检测';
    case 'UPGRADE_FAILED':
      return '升级未完成，已保留原版本，请查看诊断详情';
    case 'NOT_REPAIRABLE':
      return '当前状态不满足一键修复条件';
    case 'REQUIREMENTS_UNMET':
      return '本机不满足安装要求，请查看系统要求';
    case 'NOT_CONFIGURED':
      return '尚未接入知办，先完成一键接入再验证';
    case 'PRECONDITION_CHANGED':
      return '配置文件刚被其他程序改动，请重新检测后重试';
    case 'PLAN_EXPIRED':
      return '本次操作已过期，请重新检测后重试';
    case 'FILE_IN_USE':
      return '配置文件正被其他程序占用，请稍后重试';
    case 'VALIDATION_FAILED':
      return '写入后本地校验未通过，已恢复原有配置';
    case 'ROLLBACK_FAILED':
      return '写入失败且未能恢复原有配置，请查看诊断详情';
    case 'INSTALLATION_CHANGED':
      return '安装已发生变化，请重新检测后再验证';
    case 'NOT_FOUND':
      return '操作已过期或未知，请重新检测';
    case 'HASH_MISMATCH':
      return '安装包校验未通过，已停止安装';
    case 'SIZE_MISMATCH':
      return '安装包大小与官方不符，已停止安装';
    case 'PUBLISHER_MISMATCH':
      return '安装包签名或内容校验未通过，已停止安装';
    case 'SOURCE_NOT_ALLOWED':
      return '下载地址不在允许的来源（非 https 或主机不在白名单），已停止安装';
    case 'DOWNLOAD_FAILED':
      return '下载失败，请检查网络后重试';
    case 'SYSTEM_CANCELLED':
      return '操作已取消';
    case 'AUTHORIZATION_CANCELLED':
      return '已取消 Windows 管理员授权，尚未下载安装。重新点击安装后，在系统提示中选择“是”';
    case 'AUTHORIZATION_TIMEOUT':
      return '等待 Windows 管理员授权超时，尚未下载安装。请重试并处理系统授权提示';
    case 'AUTHORIZATION_FAILED':
      return '未能申请 Windows 管理员授权，尚未下载安装。请重试或联系管理员';
    case 'REGISTRATION_FAILED':
      return 'Windows 未能完成应用安装，请查看诊断详情或联系支持';
    case 'COMPONENT_IN_USE':
      return '运行组件文件仍被其他进程占用，请稍后重试；持续失败时请发送诊断给支持';
    case 'CONFLICT':
      return '检测到冲突，为避免覆盖你的设置，知办已停止操作';
    case 'UNSAFE_PATH':
      return '配置目录的权限或链接不满足安全要求，知办暂时无法访问配置，请检查后重新检测';
    case 'DETECT_MISMATCH':
      return '安装完成但未通过检测，请查看诊断详情';
    case 'DEVICE_MISSING':
    case 'DEVICE_REVOKED':
    case 'SCOPE_DENIED':
    case 'TOKEN_EXPIRED':
      return '设备授权不可用，请重新接入知办';
    case 'UNREACHABLE':
      return '无法连接知办网关，请检查网络后重试';
    case 'PROTOCOL_MISMATCH':
      return '网关或工具响应不一致，请重试或联系客服';
    case 'MODEL_DENIED':
      // 多半是用户在工具里选了自己分组没开放的模型(2026-09-17 真机):下一步是换模型,不是找人。
      return '当前选的模型在你的分组里没有开放，在工具里换一个模型再试';
    case 'QUOTA_EXHAUSTED':
      return '当前模型用量已用完，请稍后再试';
    case 'PROCESS_FAILED':
      return '工具进程启动失败，请查看诊断详情';
    case 'NOT_SWITCHED':
      return '当前未切换到知办模型 API，无需恢复';
    default:
      return '本地连接组件未能完成操作，请重试';
  }
}

Stream<String> _decodeFrames(Stream<List<int>> input) async* {
  var builder = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in input) {
    for (final byte in chunk) {
      if (byte == 10) {
        var frame = builder.takeBytes();
        if (frame.isNotEmpty && frame.last == 13) {
          frame = Uint8List.sublistView(frame, 0, frame.length - 1);
        }
        yield utf8.decode(frame, allowMalformed: false);
        builder = BytesBuilder(copy: false);
        length = 0;
        continue;
      }
      length++;
      if (length > localCodingBridgeMaxFrameBytes) {
        throw const LocalCodingBridgeException(
          'frame_too_large',
          '本地连接组件响应超过安全限制',
        );
      }
      builder.addByte(byte);
    }
  }
  if (length != 0) {
    throw const LocalCodingBridgeException(
      'truncated_frame',
      '本地连接组件响应不完整，请重试',
    );
  }
}
