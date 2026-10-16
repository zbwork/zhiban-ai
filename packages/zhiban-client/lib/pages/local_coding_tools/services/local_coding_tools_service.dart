import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_bridge_client.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_catalog_api.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_project_access.dart';
import 'package:zhiban_client/services/device_info_service.dart';
import 'package:zhiban_client/services/session_service.dart';

class LocalCodingToolsException implements Exception {
  const LocalCodingToolsException(
    this.code,
    this.userMessage, {
    this.requiresReregistration = false,
    this.remoteRevocationPending = false,
  });

  final String code;
  final String userMessage;
  final bool requiresReregistration;
  final bool remoteRevocationPending;

  @override
  String toString() => userMessage;
}

class LocalCodingDeviceRegistration {
  const LocalCodingDeviceRegistration({
    required this.credentialId,
    required this.deviceCredential,
  });

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final RegExp _credentialPattern = RegExp(
    r'^lctd\.([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\.[A-Za-z0-9]{48}$',
  );

  final String credentialId;
  final String deviceCredential;

  bool get isValid {
    final credentialMatch = _credentialPattern.firstMatch(deviceCredential);
    return _uuidPattern.hasMatch(credentialId) &&
        credentialMatch != null &&
        credentialMatch.group(1) == credentialId;
  }

  factory LocalCodingDeviceRegistration.fromJson(Map<String, dynamic> json) {
    final credentialId = json['credential_id'];
    final deviceCredential = json['device_credential'];
    if (credentialId is! String || deviceCredential is! String) {
      throw const LocalCodingToolsException(
        'invalid_registration_response',
        '设备授权响应无效，请重试或更新知办',
        requiresReregistration: true,
      );
    }
    final result = LocalCodingDeviceRegistration(
      credentialId: credentialId,
      deviceCredential: deviceCredential,
    );
    if (!result.isValid) {
      throw const LocalCodingToolsException(
        'invalid_registration_response',
        '设备授权响应无效，请重试或更新知办',
        requiresReregistration: true,
      );
    }
    return result;
  }
}

abstract interface class LocalCodingToolsApi {
  Future<LocalCodingDeviceRegistration> registerDevice({
    required String deviceId,
    required String platform,
    required Map<String, dynamic> devicePublicJwk,
    required String appVersion,
    required String dpopProof,
  });

  Future<void> revokeDevice(String deviceId);
}

class DioLocalCodingToolsApi implements LocalCodingToolsApi {
  DioLocalCodingToolsApi({Dio? dio}) : _dio = dio ?? sensitiveRequest;

  final Dio _dio;

  @override
  Future<LocalCodingDeviceRegistration> registerDevice({
    required String deviceId,
    required String platform,
    required Map<String, dynamic> devicePublicJwk,
    required String appVersion,
    required String dpopProof,
  }) async {
    final response = await _dio.post<dynamic>(
      '/local-coding-tools/devices',
      data: {
        'device_id': deviceId,
        'platform': platform,
        'device_public_jwk': devicePublicJwk,
        'app_version': appVersion,
      },
      options: Options(
        headers: {'DPoP': dpopProof},
        extra: const {'silent': true, 'sensitive': true},
      ),
    );
    final data = response.data;
    if (data is! Map) {
      throw const LocalCodingToolsException(
        'invalid_registration_response',
        '设备授权响应无效，请重试或更新知办',
        requiresReregistration: true,
      );
    }
    return LocalCodingDeviceRegistration.fromJson(
      Map<String, dynamic>.from(data),
    );
  }

  @override
  Future<void> revokeDevice(String deviceId) async {
    await _dio.delete<dynamic>(
      '/local-coding-tools/devices/${Uri.encodeComponent(deviceId)}',
      options: Options(extra: const {'silent': true, 'sensitive': true}),
    );
  }
}

class LocalCodingSessionIdentity {
  const LocalCodingSessionIdentity({
    required this.accountId,
    required this.tenantId,
  });

  final String accountId;
  final String tenantId;
}

class LocalCodingPendingRevocation {
  const LocalCodingPendingRevocation({
    required this.deviceId,
    required this.accountId,
    required this.tenantId,
    required this.environment,
    this.remoteRevocationPending = true,
    this.localCleanupPending = false,
  });

  final String deviceId;
  final String accountId;
  final String tenantId;
  final String environment;
  final bool remoteRevocationPending;
  final bool localCleanupPending;

  LocalCodingPendingRevocation copyWith({
    bool? remoteRevocationPending,
    bool? localCleanupPending,
  }) {
    return LocalCodingPendingRevocation(
      deviceId: deviceId,
      accountId: accountId,
      tenantId: tenantId,
      environment: environment,
      remoteRevocationPending:
          remoteRevocationPending ?? this.remoteRevocationPending,
      localCleanupPending: localCleanupPending ?? this.localCleanupPending,
    );
  }

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'account_id': accountId,
        'tenant_id': tenantId,
        'environment': environment,
        'remote_revocation_pending': remoteRevocationPending,
        'local_cleanup_pending': localCleanupPending,
      };

  factory LocalCodingPendingRevocation.fromJson(Map<String, dynamic> json) {
    String read(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('invalid pending revocation');
      }
      return value;
    }

    return LocalCodingPendingRevocation(
      deviceId: read('device_id'),
      accountId: read('account_id'),
      tenantId: read('tenant_id'),
      environment: read('environment'),
      remoteRevocationPending: json['remote_revocation_pending'] is bool
          ? json['remote_revocation_pending'] as bool
          : true,
      localCleanupPending: json['local_cleanup_pending'] is bool
          ? json['local_cleanup_pending'] as bool
          : false,
    );
  }
}

abstract interface class LocalCodingPendingRevocationStore {
  Future<LocalCodingPendingRevocation?> load();
  Future<void> save(LocalCodingPendingRevocation pending);
  Future<void> clear();
}

class SharedPreferencesLocalCodingPendingRevocationStore
    implements LocalCodingPendingRevocationStore {
  const SharedPreferencesLocalCodingPendingRevocationStore();

  @override
  Future<LocalCodingPendingRevocation?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded =
        prefs.getString(AppConfig.storageLocalCodingPendingRevocationKey);
    if (encoded == null || encoded.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return null;
      return LocalCodingPendingRevocation.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      await clear();
      return null;
    }
  }

  @override
  Future<void> save(LocalCodingPendingRevocation pending) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppConfig.storageLocalCodingPendingRevocationKey,
      jsonEncode(pending.toJson()),
    );
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConfig.storageLocalCodingPendingRevocationKey);
  }
}

/// 重新登录后自动重新接入的依据(2026-09-18):谁在这台设备上接入过。不含凭证。
class LocalCodingReconnectRecord {
  const LocalCodingReconnectRecord({
    required this.deviceId,
    required this.accountId,
    required this.tenantId,
    required this.environment,
  });

  final String deviceId;
  final String accountId;
  final String tenantId;
  final String environment;

  bool matches(LocalCodingReconnectRecord other) =>
      deviceId == other.deviceId &&
      accountId == other.accountId &&
      tenantId == other.tenantId &&
      environment == other.environment;

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'account_id': accountId,
        'tenant_id': tenantId,
        'environment': environment,
      };

  static LocalCodingReconnectRecord? tryParse(Object? decoded) {
    if (decoded is! Map) return null;
    String? read(String key) {
      final value = decoded[key];
      return value is String && value.trim().isNotEmpty ? value : null;
    }

    final deviceId = read('device_id');
    final accountId = read('account_id');
    final tenantId = read('tenant_id');
    final environment = read('environment');
    if (deviceId == null ||
        accountId == null ||
        tenantId == null ||
        environment == null) {
      return null;
    }
    return LocalCodingReconnectRecord(
      deviceId: deviceId,
      accountId: accountId,
      tenantId: tenantId,
      environment: environment,
    );
  }
}

abstract interface class LocalCodingReconnectStore {
  Future<LocalCodingReconnectRecord?> load();
  Future<void> save(LocalCodingReconnectRecord record);
  Future<void> clear();
}

class SharedPreferencesLocalCodingReconnectStore
    implements LocalCodingReconnectStore {
  const SharedPreferencesLocalCodingReconnectStore();

  @override
  Future<LocalCodingReconnectRecord?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(AppConfig.storageLocalCodingReconnectKey);
    if (encoded == null || encoded.trim().isEmpty) return null;
    try {
      return LocalCodingReconnectRecord.tryParse(jsonDecode(encoded));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(LocalCodingReconnectRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppConfig.storageLocalCodingReconnectKey,
      jsonEncode(record.toJson()),
    );
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConfig.storageLocalCodingReconnectKey);
  }
}

abstract interface class LocalCodingToolsOperations {
  /// [onProgress]:每完成一步检测回调一次(2026-09-15 检测过程可视化)。
  Future<LocalCodingToolsSnapshot> inspect({
    void Function(LocalCodingInspectProgress progress)? onProgress,
  });
  Future<LocalCodingToolsSnapshot> registerOrRotate();

  /// 重新登录后自动重新接入(F31 §3.1,2026-09-18):本机接入记录与当前登录的账号 +
  /// 企业 + 环境 + 设备全部一致、设备授权缺失、且仍有形态的配置指向知办时,静默重新
  /// 接入设备。不改配置、不发模型请求;不满足条件或失败都返回 false,从不抛错。
  Future<bool> reconnectIfSameIdentity();
  Future<LocalCodingToolsSnapshot> enable(LocalCodingTarget target);
  Future<LocalCodingLaunchResult?> launch(
    LocalCodingTarget target, {
    LocalCodingLaunchMode mode,
  });
  Future<void> removeAuthorization();

  // M1G · 一键安装 / 验证 / 诊断 / 移除接入
  Future<LocalCodingRequirements> requirements(LocalCodingTarget target);
  Future<LocalCodingOperation> startInstall(
    LocalCodingTarget target, {
    LocalCodingInstallMode mode,
    // M3 Task 8 · 预置运行组件(如 Claude Desktop 的 Claude Code 宿主包)。
    String? component,
  });
  Future<LocalCodingOperation> startVerify(
    LocalCodingTarget target, {
    LocalCodingVerifyScope scope,
  });
  Future<LocalCodingOperation> pollOperation(String operationId);
  Future<LocalCodingOperation> cancelOperation(String operationId);
  // config.restore(target);若结束后两张卡都 not_configured 会顺带 credential.clear
  // 并撤销服务端设备授权(与 removeAuthorization 相同的两阶段策略)。
  Future<LocalCodingToolsSnapshot> removeConfiguration(
    LocalCodingTarget target,
  );
  // v1.7 · 冲突态修复:config.plan(type=repair) → config.execute → 快照。
  Future<LocalCodingToolsSnapshot> repairConfiguration(
    LocalCodingTarget target,
  );
  Future<LocalCodingDiagnostics> diagnostics(LocalCodingTarget target);

  /// 把诊断现场交给支持(2026-09-16)，返回反馈编号；失败返回 null。
  Future<String?> reportDiagnostics({
    required String title,
    required String description,
    required Map<String, dynamic> clientInfo,
  });

  // CC Switch 式全局切换(切换为知办模型 API / 恢复官方配置)与「打开应用」。
  Future<LocalCodingToolsSnapshot> switchToZhiban(LocalCodingTarget target);
  Future<LocalCodingToolsSnapshot> restoreOfficial(LocalCodingTarget target);
  Future<LocalCodingLaunchResult> openApp(LocalCodingTarget target);

  // 契约 §2.7 network.* · 一键为知办中转站设置代理例外。
  Future<LocalCodingToolsSnapshot> applyProxyFix();
}

class LocalCodingToolsService implements LocalCodingToolsOperations {
  LocalCodingToolsService({
    LocalCodingBridgeSessionFactory? bridgeFactory,
    LocalCodingToolsApi? api,
    LocalCodingCatalogApi? catalogApi,
    ({String platform, String arch})? catalogRuntime,
    Future<String> Function()? deviceIdLoader,
    Future<String> Function()? appVersionLoader,
    String Function()? environmentLoader,
    Map<String, String>? profileVersions,
    Future<LocalCodingSessionIdentity> Function()? identityLoader,
    LocalCodingPendingRevocationStore? pendingRevocationStore,
    LocalCodingReconnectStore? reconnectStore,
    LocalCodingProjectDirectoryPicker? projectDirectoryPicker,
    LocalCodingProjectBookmarkCreator? projectBookmarkCreator,
    Duration? configWriteRetryDelay,
  })  : _configWriteRetryDelay =
            configWriteRetryDelay ?? const Duration(milliseconds: 400),
        _bridgeFactory =
            bridgeFactory ?? ProcessLocalCodingBridgeSessionFactory(),
        _api = api ?? DioLocalCodingToolsApi(),
        _catalogApi = catalogApi ?? DioLocalCodingCatalogApi(),
        _catalogRuntime = catalogRuntime ?? localCodingCatalogRuntime(),
        _deviceIdLoader = deviceIdLoader ?? collectDeviceFingerprint,
        _appVersionLoader = appVersionLoader ?? _loadAppVersion,
        _environmentLoader = environmentLoader ?? (() => AppConfig.env.name),
        _profileVersions = Map<String, String>.unmodifiable(
          profileVersions ?? AppConfig.localCodingProfileVersions(),
        ),
        _identityLoader = identityLoader ?? _loadSessionIdentity,
        _pendingRevocationStore = pendingRevocationStore ??
            const SharedPreferencesLocalCodingPendingRevocationStore(),
        _reconnectStore =
            reconnectStore ?? const SharedPreferencesLocalCodingReconnectStore(),
        _projectDirectoryPicker =
            projectDirectoryPicker ?? pickLocalCodingProjectDirectory,
        _projectBookmarkCreator =
            projectBookmarkCreator ?? createLocalCodingProjectBookmark;

  final LocalCodingBridgeSessionFactory _bridgeFactory;
  final LocalCodingToolsApi _api;
  final LocalCodingCatalogApi _catalogApi;
  final ({String platform, String arch})? _catalogRuntime;
  final Future<String> Function() _deviceIdLoader;
  final Future<String> Function() _appVersionLoader;
  final String Function() _environmentLoader;
  final Map<String, String> _profileVersions;
  final Future<LocalCodingSessionIdentity> Function() _identityLoader;
  final LocalCodingPendingRevocationStore _pendingRevocationStore;
  final LocalCodingReconnectStore _reconnectStore;
  final LocalCodingProjectDirectoryPicker _projectDirectoryPicker;
  final LocalCodingProjectBookmarkCreator _projectBookmarkCreator;
  final Duration _configWriteRetryDelay;

  /// 契约 §2.7.2「写入失败的错误码与自动重试」:这三种失败只说明写入那一刻本机
  /// 状态变了(Codex 桌面端运行时持续改写 ~/.codex/config.toml、Windows 上文件
  /// 被占用、计划过期),重走一遍就好。域错误会让 Bridge 会话关闭,所以重试必须
  /// 另开会话、从检测开始。
  static const Set<String> _configWriteRetrySuffixes = {
    '-CONFIG-PRECONDITION_CHANGED',
    '-CONFIG-PLAN_EXPIRED',
    '-CONFIG-FILE_IN_USE',
  };
  static const int _configWriteAttempts = 3;

  Future<T> _retryConfigWrite<T>(Future<T> Function() attempt) async {
    for (var round = 1;; round++) {
      try {
        return await attempt();
      } on LocalCodingToolsException catch (error) {
        final retryable = _configWriteRetrySuffixes
            .any((suffix) => error.code.endsWith(suffix));
        if (!retryable || round >= _configWriteAttempts) rethrow;
        await Future<void>.delayed(
          error.code.endsWith('-CONFIG-FILE_IN_USE')
              ? _configWriteRetryDelay * 3
              : _configWriteRetryDelay,
        );
      }
    }
  }

  bool get _profilesReady {
    if (_profileVersions.keys.toSet().difference({
          LocalCodingTarget.codexCli.id,
          LocalCodingTarget.claudeCli.id,
        }).isNotEmpty ||
        _profileVersions.length != 2) {
      return false;
    }
    return _profileVersions.values.every(_isSafeProfileVersion);
  }

  @override
  Future<LocalCodingToolsSnapshot> inspect({
    void Function(LocalCodingInspectProgress progress)? onProgress,
  }) async {
    final deviceId = await _requireDeviceId();
    await _retryPendingRevocation(deviceId);
    final session = await _bridgeFactory.open();
    try {
      final tracker = _InspectTracker(
        onProgress,
        LocalCodingInspectStep.plan(
          network: session.supportedMethods.contains('network.proxy_status'),
        ),
      )..emit();
      await _applyCatalog(session);
      tracker.advance();
      return await _readSnapshot(session, deviceId, tracker: tracker);
    } finally {
      await session.close();
    }
  }

  // 契约 §2.7.4 · 目录短缓存(Bus 侧 max-age=300):同一进程内 5 分钟只拉一次,
  // 后台静默刷新与批处理收尾的 inspect 不再打 Bus。
  static const Duration _catalogCacheTtl = Duration(minutes: 5);
  _CatalogFetch? _catalogFetch;

  /// 进页面 / 每次检测前把 Bus 的签名目录交给 Bridge。目录接口失败不影响页面:
  /// 暂时取不到 → Bridge 沿用自己落盘的目录;Bus 明确没有目录 → 让 Bridge 清除;
  /// Bridge 验签拒绝 → 忽略,detect 里就没有升级项。
  Future<void> _applyCatalog(LocalCodingBridgeSession session) async {
    if (!session.supportedMethods.contains('catalog.apply')) return;
    final runtime = _catalogRuntime;
    if (runtime == null) return;
    final cached = _catalogFetch;
    _CatalogFetch fetch;
    if (cached != null &&
        DateTime.now().difference(cached.at) < _catalogCacheTtl) {
      fetch = cached;
    } else {
      try {
        final catalog = await _catalogApi.fetchCatalog(
          platform: runtime.platform,
          arch: runtime.arch,
        );
        fetch = _CatalogFetch(catalog: catalog, present: catalog != null);
      } catch (_) {
        // LocalCodingCatalogUnavailable 或其它异常:暂时取不到,保留 Bridge 落盘的目录。
        return;
      }
      _catalogFetch = fetch;
    }
    try {
      await session.catalogApply(
        environment: _environmentLoader(),
        catalog: fetch.present ? fetch.catalog : null,
      );
    } on LocalCodingBridgeException {
      // CATALOG-INVALID / UNTRUSTED_KEY(domain)或会话级故障:回落内置清单,
      // 不吞掉整次 inspect,后面的 detect 该报什么报什么。
    }
  }

  @override
  Future<LocalCodingToolsSnapshot> registerOrRotate() async {
    if (!_profilesReady) {
      throw const LocalCodingToolsException(
        'profiles_unavailable',
        '当前环境尚未开放设备接入，可先查看本机安装状态',
      );
    }
    final deviceId = await _requireDeviceId();
    await _retryPendingRevocation(
      deviceId,
      requireRemoteCompletion: true
    );
    final session = await _bridgeFactory.open();
    try {
      await _registerInSession(session, deviceId);
      return await _readSnapshot(session, deviceId);
    } finally {
      await session.close();
    }
  }

  /// 后台(登录后几秒、后台维护)与页面(首次检测前)都会调;服务端注册是"顶掉旧凭证",
  /// 并发的两次会互相顶掉,所以进程内合并为一次。main 与 provider 各持一个服务实例,
  /// 用 static。
  static Future<bool>? _reconnectInFlight;

  @override
  Future<bool> reconnectIfSameIdentity() {
    final running = _reconnectInFlight;
    if (running != null) return running;
    final started = _reconnectIfSameIdentity().whenComplete(() {
      _reconnectInFlight = null;
    });
    _reconnectInFlight = started;
    return started;
  }

  Future<bool> _reconnectIfSameIdentity() async {
    try {
      if (!_profilesReady) return false;
      final record = await _reconnectStore.load();
      if (record == null) return false;
      final deviceId = await _requireDeviceId();
      final identity = await _identityLoader();
      final current = LocalCodingReconnectRecord(
        deviceId: deviceId,
        accountId: identity.accountId,
        tenantId: identity.tenantId,
        environment: _environmentLoader(),
      );
      // 换了账号 / 企业 / 环境:授权绑定的是这个人的额度,不替他接入。
      if (!record.matches(current)) return false;
      final probe = await _bridgeFactory.open();
      try {
        final credential = await probe.credentialStatus();
        if (credential.authorizationPresent &&
            credential.deviceId == deviceId &&
            credential.environment == current.environment) {
          return false;
        }
        var pointsToZhiban = false;
        for (final target in LocalCodingTarget.values) {
          final status = await probe.configurationStatus(target);
          if (status.switchedToZhiban) {
            pointsToZhiban = true;
            break;
          }
        }
        // 已恢复官方配置:没有东西需要这份授权。
        if (!pointsToZhiban) return false;
      } finally {
        await probe.close();
      }
      // 与 registerOrRotate 同序:先结清上次没撤销掉的欠账,再开会话注册。不读整份
      // 快照(那要把四个形态检测一遍),后台与页面随后各自会检测。
      await _retryPendingRevocation(deviceId, requireRemoteCompletion: true);
      final session = await _bridgeFactory.open();
      try {
        await _registerInSession(session, deviceId);
        return true;
      } finally {
        await session.close();
      }
    } catch (_) {
      // 静默放弃:页面仍是「需要处理 · 授权已失效」,用户可以自己点修复。
      return false;
    }
  }

  Future<void> _saveReconnectRecord(String deviceId) async {
    try {
      final identity = await _identityLoader();
      await _reconnectStore.save(LocalCodingReconnectRecord(
        deviceId: deviceId,
        accountId: identity.accountId,
        tenantId: identity.tenantId,
        environment: _environmentLoader(),
      ));
    } catch (_) {
      // 记录只影响"下次登录要不要自动接入",写不进去不算接入失败。
    }
  }

  Future<void> _clearReconnectRecordQuietly() async {
    try {
      await _reconnectStore.clear();
    } catch (_) {}
  }

  Future<void> _backfillReconnectRecord(
    LocalCodingBridgeSession session,
    String deviceId,
    LocalCodingSessionIdentity identity,
  ) async {
    try {
      if (await _reconnectStore.load() != null) return;
      final credential = await session.credentialStatus();
      final environment = _environmentLoader();
      if (!credential.authorizationPresent ||
          credential.deviceId != deviceId ||
          credential.environment != environment) {
        return;
      }
      await _reconnectStore.save(LocalCodingReconnectRecord(
        deviceId: deviceId,
        accountId: identity.accountId,
        tenantId: identity.tenantId,
        environment: environment,
      ));
    } catch (_) {}
  }

  @override
  Future<LocalCodingToolsSnapshot> enable(LocalCodingTarget target) async {
    if (target.isDesktop) {
      // 桌面端没有知办隔离 overlay(契约 §2.7.3),只有全局切换。
      throw const LocalCodingToolsException(
        'desktop_overlay_unsupported',
        '桌面端不支持隔离配置，请使用「切换为知办模型 API」',
      );
    }
    if (!_profilesReady) {
      throw const LocalCodingToolsException(
        'profiles_unavailable',
        '当前环境尚未开放 AI 编程工具接入',
      );
    }
    final deviceId = await _requireDeviceId();
    await _retryPendingRevocation(
      deviceId,
      requireRemoteCompletion: true
    );
    final session = await _bridgeFactory.open();
    try {
      final credential = await session.credentialStatus();
      final current = await session.configurationStatus(target);
      if (current.state == LocalCodingConfigurationState.conflict) {
        throw const LocalCodingToolsException(
          'configuration_conflict',
          '检测到已有配置。为避免覆盖你的设置，知办已停止操作。',
        );
      }
      final needsConfiguration = !current.configured ||
          current.profileVersion != _profileVersions[target.id];
      LocalCodingToolState? installation;
      String? effectiveInstallationId;
      if (needsConfiguration) {
        installation = await session.detect(target);
        if (installation.uiState == LocalCodingToolUiState.notInstalled) {
          throw const LocalCodingToolsException(
            'tool_not_installed',
            '尚未发现可信安装，请先安装对应的 AI 编程工具',
          );
        }
        effectiveInstallationId = installation.installationId;
        if (installation.uiState == LocalCodingToolUiState.unsupported ||
            effectiveInstallationId.isEmpty) {
          throw const LocalCodingToolsException(
            'tool_unsupported',
            '当前安装来源或版本暂不支持知办接入',
          );
        }
      }
      if (!_authorizationConnected(credential, deviceId)) {
        await _registerInSession(session, deviceId);
      }
      if (needsConfiguration) {
        final plan = await session.planConfiguration(
          target: target,
          installationId: effectiveInstallationId!,
        );
        if (plan.action == LocalCodingConfigurationAction.conflict) {
          throw const LocalCodingToolsException(
            'configuration_conflict',
            '检测到已有配置。为避免覆盖你的设置，知办已停止操作。',
          );
        }
        if (plan.planId.isEmpty) {
          throw const LocalCodingToolsException(
            'configuration_plan_invalid',
            '本地配置计划无效，请重新检测后重试',
          );
        }
        final configured = await session.executeConfiguration(plan.planId);
        if (!configured.configured) {
          throw const LocalCodingToolsException(
            'configuration_validation_failed',
            '知办线路配置未通过本地验证；知办没有覆盖检测到的已有设置',
          );
        }
      }
      return await _readSnapshot(session, deviceId);
    } on LocalCodingToolsException {
      rethrow;
    } on LocalCodingBridgeException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } catch (_) {
      throw const LocalCodingToolsException(
        'configuration_failed',
        'AI 编程工具接入失败，请重新检测后重试',
      );
    } finally {
      await session.close();
    }
  }

  @override
  Future<LocalCodingLaunchResult?> launch(
    LocalCodingTarget target, {
    LocalCodingLaunchMode mode = LocalCodingLaunchMode.managed,
  }) async {
    if (target.isDesktop) {
      // 桌面端只有「打开桌面端」(openApp,不选项目、不带 profile)。
      throw const LocalCodingToolsException(
        'desktop_project_launch_unsupported',
        '桌面端不支持选择项目启动，请使用「打开桌面端」',
      );
    }
    if (mode == LocalCodingLaunchMode.managed && !_profilesReady) {
      throw const LocalCodingToolsException(
        'profiles_unavailable',
        '当前环境尚未开放 AI 编程工具启动',
      );
    }

    String? projectPath;
    try {
      projectPath = await _projectDirectoryPicker();
      if (projectPath == null) return null;
      if (projectPath.trim().isEmpty) {
        throw const LocalCodingToolsException(
          'project_selection_invalid',
          '项目目录选择无效，请重新选择',
        );
      }
      final bookmark = await _projectBookmarkCreator(projectPath);
      final deviceId = await _requireDeviceId();
      await _retryPendingRevocation(
        deviceId,
        requireRemoteCompletion: true
      );
      final session = await _bridgeFactory.open();
      try {
        final credential = await session.credentialStatus();
        if (mode == LocalCodingLaunchMode.managed &&
            !_authorizationConnected(credential, deviceId)) {
          throw const LocalCodingToolsException(
            'authorization_not_current',
            '知办设备授权已变化，请先重新启用知办线路',
          );
        }

        final configuration = await session.configurationStatus(target);
        final expectedProfile = _profileVersions[target.id] ?? '';
        if (mode == LocalCodingLaunchMode.managed) {
          if (configuration.state == LocalCodingConfigurationState.conflict) {
            throw const LocalCodingToolsException(
              'configuration_conflict',
              '检测到已有配置。为避免覆盖你的设置，知办已停止操作。',
            );
          }
          if (!configuration.configured ||
              configuration.profileVersion != expectedProfile) {
            throw const LocalCodingToolsException(
              'configuration_not_current',
              '知办线路配置已变化，请先重新启用',
            );
          }
        }

        final installation = await session.detect(target);
        final launchInstallationId = installation.installationId;
        if (launchInstallationId.isEmpty ||
            installation.uiState == LocalCodingToolUiState.notInstalled ||
            installation.uiState == LocalCodingToolUiState.unsupported ||
            installation.uiState == LocalCodingToolUiState.repairable) {
          throw const LocalCodingToolsException(
            'tool_unsupported',
            '当前安装来源或版本暂不支持启动',
          );
        }

        final grant = await session.createProjectGrant(bookmark);
        final plan = await session.planLaunch(
          target: target,
          installationId: launchInstallationId,
          projectGrantId: grant.projectGrantId,
          profileVersion: expectedProfile,
          mode: mode,
        );
        if (plan.target != target || plan.projectName != grant.displayName) {
          throw const LocalCodingToolsException(
            'launch_plan_invalid',
            '本地启动计划无效，请重新选择项目',
          );
        }
        final launched = await session.executeLaunch(plan.launchPlanId);
        if (launched.target != target ||
            launched.state != 'launched' ||
            launched.projectName != plan.projectName) {
          throw const LocalCodingToolsException(
            'launch_result_invalid',
            '系统终端启动响应无效，请重试',
          );
        }
        return launched;
      } finally {
        await session.close();
      }
    } on LocalCodingToolsException {
      rethrow;
    } on LocalCodingBridgeException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } catch (_) {
      throw const LocalCodingToolsException(
        'launch_failed',
        '启动 AI 编程工具失败，请重新选择项目后重试',
      );
    }
  }

  @override
  Future<void> removeAuthorization() => _removeAuthorization(logout: false);

  /// 退出登录时的清理:与 [removeAuthorization] 同样撤销服务端授权、清本机凭证,
  /// 但保留接入记录,同一个人回来时凭它静默重新接入([reconnectIfSameIdentity])。
  /// 升级到带接入记录的版本之前接入的设备没有记录:本机授权仍在时按当前登录身份补记。
  Future<void> removeAuthorizationOnLogout() => _removeAuthorization(logout: true);

  Future<void> _removeAuthorization({required bool logout}) async {
    final deviceId = await _requireDeviceId();
    final identity = await _identityLoader();
    // 主动移除(含恢复官方配置后顺带撤销):先清记录,后面哪一步失败都不会被自动接回。
    if (!logout) await _clearReconnectRecordQuietly();
    var pending = LocalCodingPendingRevocation(
      deviceId: deviceId,
      accountId: identity.accountId,
      tenantId: identity.tenantId,
      environment: _environmentLoader(),
      localCleanupPending: true,
    );
    // 先持久化整个两阶段意图，保证 App 崩溃或任一阶段失败后都能安全续做。
    await _pendingRevocationStore.save(pending);
    Object? remoteError;
    try {
      await _api.revokeDevice(deviceId);
      pending = pending.copyWith(remoteRevocationPending: false);
      await _persistPendingRevocation(pending);
    } catch (error) {
      remoteError = error;
    }

    LocalCodingBridgeSession? session;
    try {
      session = await _bridgeFactory.open();
      if (logout) await _backfillReconnectRecord(session, deviceId, identity);
      await session.clearCredential();
      pending = pending.copyWith(localCleanupPending: false);
      await _persistPendingRevocation(pending);
    } on LocalCodingBridgeException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } catch (_) {
      throw const LocalCodingToolsException(
        'local_clear_failed',
        '本地设备授权清理失败，请重试',
      );
    } finally {
      await session?.close();
    }

    if (remoteError != null) {
      throw const LocalCodingToolsException(
        'remote_revoke_pending',
        '本地授权已清理；服务端撤销将在网络恢复后重试',
        remoteRevocationPending: true,
      );
    }
  }

  Future<LocalCodingToolsSnapshot> _readSnapshot(
    LocalCodingBridgeSession session,
    String deviceId, {
    _InspectTracker? tracker,
  }) async {
    final status = await session.credentialStatus();
    final revocationPending = await _hasMatchingPendingRevocation(deviceId);
    // M3 · 四个 target(两厂商 × CLI / 桌面端)各自检测;桌面端的配置视图由
    // Bridge 负责映射(Codex 共用 CLI 配置,Claude 走 3P 配置库)。
    final tools = <LocalCodingTarget, LocalCodingToolState>{};
    final configurations =
        <LocalCodingTarget, LocalCodingConfigurationStatus>{};
    LocalCodingProxyStatus? proxyStatus;
    LocalCodingToolsSnapshot snapshot() => LocalCodingToolsSnapshot(
          deviceId: deviceId,
          environment: _environmentLoader(),
          credentialStatus: status,
          tools:
              Map<LocalCodingTarget, LocalCodingToolState>.unmodifiable(tools),
          configurations: Map<LocalCodingTarget,
              LocalCodingConfigurationStatus>.unmodifiable(configurations),
          // 桌面端沿用同厂商 CLI 的 Profile 版本(Bridge ScopeTarget)。
          expectedProfileVersions: Map<LocalCodingTarget, String>.unmodifiable({
            for (final target in LocalCodingTarget.values)
              target: _profileVersions[target.scopeTarget.id] ?? '',
          }),
          registrationAvailable: _profilesReady,
          remoteRevocationPending: revocationPending,
          supportedMethods: Set<String>.unmodifiable(session.supportedMethods),
          proxyStatus: proxyStatus,
        );
    // 2026-09-15 · 按厂商检测:一张卡的安装与配置读完再读下一张,页面逐行填充。
    for (final vendor in LocalCodingVendor.values) {
      for (final target in vendor.targets) {
        try {
          tools[target] = await session.detect(target);
        } on LocalCodingBridgeUnreadableResultException {
          // 契约 §2.7 · 单张卡的检测结果读不懂只把这张卡标"检测异常",不拖垮整页。
          tools[target] = LocalCodingToolState.unreadable(target);
        }
        tracker?.advance();
      }
      for (final target in vendor.targets) {
        configurations[target] = await session.configurationStatus(target);
      }
      tracker?.advance(snapshot());
    }
    // 放在最后:探测失败会让会话 fail closed,前面的读取已经完成。
    if (session.supportedMethods.contains('network.proxy_status')) {
      try {
        proxyStatus = await session.networkProxyStatus();
      } catch (_) {
        proxyStatus = null;
      }
      tracker?.advance(snapshot());
    }
    return snapshot();
  }

  @override
  Future<LocalCodingToolsSnapshot> applyProxyFix() async {
    final deviceId = await _requireDeviceId();
    final session = await _bridgeFactory.open();
    try {
      if (!session.supportedMethods.contains('network.proxy_apply')) {
        throw const LocalCodingToolsException(
          'proxy_fix_unsupported',
          '当前版本不支持设置代理例外，请更新知办',
        );
      }
      try {
        await session.networkProxyApply();
      } on LocalCodingBridgeDomainException catch (error) {
        throw LocalCodingToolsException(
          error.code,
          error.code.endsWith('-NETWORK-DIRECT_UNREACHABLE')
              ? '当前网络不开代理就连不上知办中转站，没法自动修复，请检查网络后重试'
              : '代理例外设置失败，请重试',
        );
      }
      return await _readSnapshot(session, deviceId);
    } on LocalCodingToolsException {
      rethrow;
    } on LocalCodingBridgeException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } finally {
      await session.close();
    }
  }

  Future<void> _registerInSession(
    LocalCodingBridgeSession session,
    String deviceId,
  ) async {
    var serverRotated = false;
    try {
      final prepared = await session.prepareRegistration(
        deviceId: deviceId,
        environment: _environmentLoader(),
      );
      if (prepared.deviceId != deviceId) {
        throw const LocalCodingToolsException(
          'device_mismatch',
          '本地设备身份不一致，请更新知办后重试',
        );
      }
      final registration = await _api.registerDevice(
        deviceId: deviceId,
        platform: Platform.isWindows ? 'windows' : 'macos',
        devicePublicJwk: prepared.devicePublicJwk,
        appVersion: await _appVersionLoader(),
        dpopProof: prepared.dpopProof,
      );
      serverRotated = true;
      if (!registration.isValid) {
        throw const LocalCodingToolsException(
          'invalid_registration_response',
          '设备授权响应无效，请重试或更新知办',
          requiresReregistration: true,
        );
      }
      await session.commitRegistration(
        credentialId: registration.credentialId,
        deviceCredential: registration.deviceCredential,
        profileVersions: _profileVersions,
      );
      // 服务端这一步是 Rotate:同一个 device_id 换了新凭证,上次没撤销掉的旧授权
      // 已被顶掉,欠账就此结清,记录不必再留(否则每次操作都会白跑一次撤销请求)。
      // 只清本机 + 本账号 + 本环境的那条,别动别人的。
      if (await _matchingPendingRevocation(deviceId) != null) {
        await _pendingRevocationStore.clear();
      }
      await _saveReconnectRecord(deviceId);
    } on LocalCodingToolsException catch (error) {
      if (serverRotated && !error.requiresReregistration) {
        throw LocalCodingToolsException(
          error.code,
          error.userMessage,
          requiresReregistration: true,
          remoteRevocationPending: error.remoteRevocationPending,
        );
      }
      rethrow;
    } on LocalCodingBridgeException catch (error) {
      if (serverRotated) {
        throw LocalCodingToolsException(
          'registration_commit_failed',
          '服务端授权已轮转，但本机保存失败，请立即重新接入：${error.userMessage}',
          requiresReregistration: true,
        );
      }
      throw LocalCodingToolsException(error.code, error.userMessage);
    } catch (_) {
      throw LocalCodingToolsException(
        serverRotated ? 'registration_commit_failed' : 'registration_failed',
        serverRotated ? '服务端授权已轮转，但本机保存失败，请立即重新接入' : '设备接入失败，请检查网络后重试',
        requiresReregistration: serverRotated,
      );
    }
  }

  bool _authorizationConnected(
    LocalCodingCredentialStatus status,
    String deviceId,
  ) {
    // 服务端授权只覆盖两个 CLI target;桌面端借同厂商 CLI 的授权换票。
    return status.authorizationPresent &&
        status.deviceId == deviceId &&
        status.environment == _environmentLoader() &&
        status.targets.containsAll(LocalCodingTarget.cliTargets) &&
        _profileVersions.entries.every(
          (entry) => status.profileVersions[entry.key] == entry.value,
        );
  }

  Future<void> _retryPendingRevocation(
    String deviceId, {
    bool requireRemoteCompletion = false,
  }) async {
    final matching = await _matchingPendingRevocation(deviceId);
    if (matching == null) return;
    var pending = matching;

    if (pending.remoteRevocationPending) {
      try {
        await _api.revokeDevice(deviceId);
        pending = pending.copyWith(remoteRevocationPending: false);
        await _persistPendingRevocation(pending);
      } catch (_) {
        // 留着下次再试,见本方法末尾说明。
      }
    }

    if (pending.localCleanupPending) {
      LocalCodingBridgeSession? session;
      try {
        session = await _bridgeFactory.open();
        await session.clearCredential();
        pending = pending.copyWith(localCleanupPending: false);
        await _persistPendingRevocation(pending);
      } on LocalCodingBridgeException catch (error) {
        throw LocalCodingToolsException(error.code, error.userMessage);
      } catch (_) {
        throw const LocalCodingToolsException(
          'local_clear_failed',
          '本地设备授权清理失败，请重试',
        );
      } finally {
        await session?.close();
      }
    }

    // 2026-09-16 · 服务端撤销没做完不再拦住用户。这条记录是"清理欠账",不是安全
    // 边界:本机凭证已经删了,而设备授权与本机私钥绑定(DPoP),那份旧授权谁也用
    // 不了;更何况接下来的重新接入本身就是 Rotate,服务端会把旧凭证换掉,这笔欠账
    // 自然结清。以前一次网络抖动就能让用户永久卡死在"请恢复网络后重试",而他的
    // 网络早就好了(测试用户实测:两个工具全是最新版,切换仍被拦)。
    // 记录留着,下次操作继续顺手重试;requireRemoteCompletion 只影响要不要重试,
    // 不再影响放不放行。
  }

  Future<bool> _hasMatchingPendingRevocation(String deviceId) async {
    final pending = await _matchingPendingRevocation(deviceId);
    return pending?.remoteRevocationPending ?? false;
  }

  Future<LocalCodingPendingRevocation?> _matchingPendingRevocation(
    String deviceId,
  ) async {
    final pending = await _pendingRevocationStore.load();
    if (pending == null || pending.deviceId != deviceId) return null;
    try {
      final identity = await _identityLoader();
      if (pending.accountId != identity.accountId ||
          pending.tenantId != identity.tenantId ||
          pending.environment != _environmentLoader()) {
        return null;
      }
      return pending;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistPendingRevocation(
    LocalCodingPendingRevocation pending,
  ) async {
    if (!pending.remoteRevocationPending && !pending.localCleanupPending) {
      await _pendingRevocationStore.clear();
      return;
    }
    await _pendingRevocationStore.save(pending);
  }

  Future<String> _requireDeviceId() async {
    final deviceId = (await _deviceIdLoader()).trim();
    if (deviceId.isEmpty) {
      throw const LocalCodingToolsException(
        'device_id_unavailable',
        '无法读取本机设备身份，请重新打开知办',
      );
    }
    return deviceId;
  }

  static Future<String> _loadAppVersion() async {
    return (await PackageInfo.fromPlatform()).version;
  }

  static Future<LocalCodingSessionIdentity> _loadSessionIdentity() async {
    const session = SessionService();
    final accountId = await session.getAccountId();
    final tenantId = await session.getTenantId();
    if (accountId == null ||
        accountId.trim().isEmpty ||
        tenantId == null ||
        tenantId.trim().isEmpty) {
      throw const LocalCodingToolsException(
        'session_identity_unavailable',
        '当前登录身份无效，请重新登录',
      );
    }
    return LocalCodingSessionIdentity(
      accountId: accountId,
      tenantId: tenantId
    );
  }

  // ─── M1G · 长操作(install / verify)的会话租借 ─────────────────────────
  //
  // 一次长操作的完整生命周期(Bridge 侧)只活在同一个 stdio 会话里,会话结束
  // 即取消并清理临时文件。这里维护 operation_id → 会话的映射:startInstall /
  // startVerify 打开会话并暂存;pollOperation / cancelOperation 复用同一会话;
  // 终态时关闭并从表中移除。dispose() 兜底关闭全部残留会话(App 退出走这条)。
  final Map<String, LocalCodingBridgeSession> _activeSessions = {};

  @override
  Future<LocalCodingRequirements> requirements(LocalCodingTarget target) async {
    final session = await _bridgeFactory.open();
    try {
      if (!session.supportedMethods.contains('requirements.get')) {
        throw const LocalCodingToolsException(
          'requirements_unsupported',
          '当前版本不支持查看系统要求',
        );
      }
      return await session.requirementsGet(target);
    } on LocalCodingBridgeDomainException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } on LocalCodingBridgeException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } finally {
      await session.close();
    }
  }

  @override
  Future<LocalCodingOperation> startInstall(
    LocalCodingTarget target, {
    LocalCodingInstallMode mode = LocalCodingInstallMode.install,
    String? component,
  }) async {
    final session = await _bridgeFactory.open();
    try {
      if (!session.supportedMethods.contains('install.execute')) {
        throw const LocalCodingToolsException(
          'install_unsupported',
          '当前版本不支持一键安装',
        );
      }
      // fresh detect 让 Bridge 与 App 看到同一份现场,并让 install.plan 拒绝
      // "已安装还想装"的错请求。
      await session.detect(target);
      final plan = await session.installPlan(
        target: target,
        mode: mode,
        component: component,
      );
      final op = await session.installExecute(plan.planId);
      _activeSessions[op.operationId] = session;
      return op;
    } on LocalCodingBridgeDomainException catch (error) {
      await session.close();
      throw LocalCodingToolsException(error.code, error.userMessage);
    } on LocalCodingBridgeException catch (error) {
      await session.close();
      throw LocalCodingToolsException(error.code, error.userMessage);
    } catch (_) {
      await session.close();
      throw const LocalCodingToolsException(
        'install_start_failed',
        '安装启动失败，请重试',
      );
    }
  }

  @override
  Future<LocalCodingOperation> startVerify(
    LocalCodingTarget target, {
    LocalCodingVerifyScope scope = LocalCodingVerifyScope.overlay,
  }) async {
    // 全局切换的配置文件不随退出登录 / 切环境 / 重装而消失,设备授权却会:
    // 先把授权补上再换票,否则「重新检测」必然 AUTH-DEVICE_MISSING
    // (2026-09-14 开发机实测)。与「切换为知办模型 API」同一套接入逻辑。
    final ensureAuthorization =
        scope == LocalCodingVerifyScope.global && _profilesReady;
    String? deviceId;
    if (ensureAuthorization) {
      deviceId = await _requireDeviceId();
      await _retryPendingRevocation(
        deviceId,
        requireRemoteCompletion: true
      );
    }
    final session = await _bridgeFactory.open();
    try {
      if (!session.supportedMethods.contains('verify.execute')) {
        throw const LocalCodingToolsException(
          'verify_unsupported',
          '当前版本不支持真实请求验证',
        );
      }
      if (deviceId != null &&
          !_authorizationConnected(
              await session.credentialStatus(), deviceId)) {
        await _registerInSession(session, deviceId);
      }
      final installation = await session.detect(target);
      final verifyInstallationId = installation.installationId;
      if (verifyInstallationId.isEmpty) {
        throw const LocalCodingToolsException(
          'tool_unsupported',
          '当前安装不可验证，请重新检测',
        );
      }
      final op = await session.verifyExecute(
        target: target,
        installationId: verifyInstallationId,
        scope: scope,
      );
      _activeSessions[op.operationId] = session;
      return op;
    } on LocalCodingToolsException {
      await session.close();
      rethrow;
    } on LocalCodingBridgeDomainException catch (error) {
      await session.close();
      throw LocalCodingToolsException(error.code, error.userMessage);
    } on LocalCodingBridgeException catch (error) {
      await session.close();
      throw LocalCodingToolsException(error.code, error.userMessage);
    } catch (_) {
      await session.close();
      throw const LocalCodingToolsException(
        'verify_start_failed',
        '验证启动失败，请重试',
      );
    }
  }

  @override
  Future<LocalCodingOperation> pollOperation(String operationId) async {
    final session = _activeSessions[operationId];
    if (session == null) {
      throw const LocalCodingToolsException(
        'operation_not_tracked',
        '当前操作未在跟踪中，请重新发起',
      );
    }
    try {
      final op = await session.operationGet(operationId);
      if (op.isTerminal) {
        await _closeSessionFor(operationId);
      }
      return op;
    } on LocalCodingBridgeDomainException catch (error) {
      await _closeSessionFor(operationId);
      throw LocalCodingToolsException(error.code, error.userMessage);
    } on LocalCodingBridgeException catch (error) {
      await _closeSessionFor(operationId);
      throw LocalCodingToolsException(error.code, error.userMessage);
    }
  }

  @override
  Future<LocalCodingOperation> cancelOperation(String operationId) async {
    final session = _activeSessions[operationId];
    if (session == null) {
      throw const LocalCodingToolsException(
        'operation_not_tracked',
        '当前操作未在跟踪中',
      );
    }
    try {
      final op = await session.operationCancel(operationId);
      if (op.isTerminal) {
        await _closeSessionFor(operationId);
      }
      return op;
    } on LocalCodingBridgeDomainException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } on LocalCodingBridgeException catch (error) {
      await _closeSessionFor(operationId);
      throw LocalCodingToolsException(error.code, error.userMessage);
    }
  }

  Future<void> _closeSessionFor(String operationId) async {
    final session = _activeSessions.remove(operationId);
    if (session == null) return;
    try {
      await session.close();
    } catch (_) {
      // 会话已崩溃或超时,忽略。
    }
  }

  @override
  Future<LocalCodingToolsSnapshot> removeConfiguration(
    LocalCodingTarget target,
  ) async {
    final deviceId = await _requireDeviceId();
    LocalCodingBridgeSession session = await _bridgeFactory.open();
    LocalCodingToolsSnapshot snap;
    try {
      await session.restoreConfiguration(target);
      snap = await _readSnapshot(session, deviceId);
    } on LocalCodingBridgeDomainException catch (error) {
      await session.close();
      throw LocalCodingToolsException(error.code, error.userMessage);
    } on LocalCodingBridgeException catch (error) {
      await session.close();
      throw LocalCodingToolsException(error.code, error.userMessage);
    }
    await session.close();

    // 两张卡都恢复为 not_configured 时,顺带撤销本机设备授权。
    // 复用 removeAuthorization 的两阶段(远端撤销 + 本地清除),失败即入队重试。
    final allCleared = snap.configurations.values.every(
      (c) => c.state == LocalCodingConfigurationState.notConfigured,
    );
    if (!allCleared) return snap;

    // 若已经没有本地 authorization,不需要再撤。
    if (!snap.credentialStatus.authorizationPresent) return snap;

    try {
      await removeAuthorization();
    } on LocalCodingToolsException catch (error) {
      // 远端撤销失败(网络等)——本地已入队 pending revocation,把快照的 flag 打上。
      if (!error.remoteRevocationPending) rethrow;
    }
    // 再取一次最新快照,确保 UI 反映授权已撤销。
    final finalSession = await _bridgeFactory.open();
    try {
      return await _readSnapshot(finalSession, deviceId);
    } finally {
      await finalSession.close();
    }
  }

  @override
  Future<LocalCodingToolsSnapshot> repairConfiguration(
    LocalCodingTarget target,
  ) async {
    final deviceId = await _requireDeviceId();
    final session = await _bridgeFactory.open();
    try {
      final status = await session.configurationStatus(target);
      if (status.state != LocalCodingConfigurationState.conflict) {
        throw const LocalCodingToolsException(
          'repair_not_applicable',
          '当前不是冲突态,请重新检测',
        );
      }
      final installation = await session.detect(target);
      final repairInstallationId = installation.installationId;
      if (repairInstallationId.isEmpty) {
        throw const LocalCodingToolsException(
          'tool_unsupported',
          '当前安装暂不支持修复'
        );
      }
      final plan = await session.planConfiguration(
        target: target,
        installationId: repairInstallationId,
        type: LocalCodingConfigurationType.repair,
      );
      if (plan.action != LocalCodingConfigurationAction.repair ||
          plan.planId.isEmpty) {
        throw const LocalCodingToolsException(
          'configuration_plan_invalid',
          '本地修复计划无效,请重新检测后重试',
        );
      }
      final result = await session.executeConfiguration(plan.planId);
      if (!result.configured) {
        throw const LocalCodingToolsException(
          'configuration_validation_failed',
          '知办线路配置未通过本地验证',
        );
      }
      return await _readSnapshot(session, deviceId);
    } on LocalCodingToolsException {
      rethrow;
    } on LocalCodingBridgeDomainException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } on LocalCodingBridgeException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } finally {
      await session.close();
    }
  }

  @override
  Future<LocalCodingToolsSnapshot> switchToZhiban(
    LocalCodingTarget target,
  ) async {
    if (!_profilesReady) {
      throw const LocalCodingToolsException(
        'profiles_unavailable',
        '当前环境尚未开放 AI 编程工具接入',
      );
    }
    final deviceId = await _requireDeviceId();
    await _retryPendingRevocation(
      deviceId,
      requireRemoteCompletion: true
    );
    return _retryConfigWrite(() => _switchToZhibanInSession(target, deviceId));
  }

  Future<LocalCodingToolsSnapshot> _switchToZhibanInSession(
    LocalCodingTarget target,
    String deviceId,
  ) async {
    final session = await _bridgeFactory.open();
    try {
      final credential = await session.credentialStatus();
      final installation = await session.detect(target);
      if (installation.uiState == LocalCodingToolUiState.notInstalled) {
        throw const LocalCodingToolsException(
          'tool_not_installed',
          '尚未发现可信安装，请先安装对应的 AI 编程工具',
        );
      }
      final installationId = installation.installationId;
      if (installation.uiState == LocalCodingToolUiState.unsupported ||
          installationId.isEmpty) {
        throw const LocalCodingToolsException(
          'tool_unsupported',
          '当前安装来源或版本暂不支持切换',
        );
      }
      if (!installation.supportsEnable) {
        // 版本过旧同样让 supports_enable 变 false(契约 §2.7 `DETECT-VERSION_TOO_OLD`),
        // 但原因和出路完全不同:命令行也会命中,套用桌面端那句话会让用户莫名其妙
        // (2026-09-16 测试反馈:Codex 命令行 0.133.0 修复时提示"该桌面端暂不支持")。
        if (installation.versionTooOld) {
          final minimum = installation.minimumVersion.isEmpty
              ? ''
              : '，需升级到 ${installation.minimumVersion} 或更高版本';
          throw LocalCodingToolsException(
            'tool_version_too_old',
            '当前版本（${installation.installedVersion}）过旧$minimum',
          );
        }
        // 契约 §2.7.3 supports_enable=false:该桌面端没有可写的第三方推理配置。
        throw const LocalCodingToolsException(
          'desktop_enable_unsupported',
          '该桌面端暂不支持知办模型 API，仍可使用官方服务',
        );
      }
      if (!_authorizationConnected(credential, deviceId)) {
        await _registerInSession(session, deviceId);
      }
      final plan = await session.planConfiguration(
        target: target,
        installationId: installationId,
        type: LocalCodingConfigurationType.switchGlobal,
      );
      // 契约 §2.7.2:受管区域已经是本 profile 会写的内容时 Bridge 回 action=none
      // (带 plan_id,execute 只复核前置条件并回当前状态)。Codex 桌面端与 CLI
      // 共用 ~/.codex/config.toml,CLI 切完再切桌面端就是这种情形,不是错误。
      if ((plan.action != LocalCodingConfigurationAction.switchGlobal &&
              plan.action != LocalCodingConfigurationAction.none) ||
          plan.planId.isEmpty) {
        throw const LocalCodingToolsException(
          'configuration_plan_invalid',
          '本地切换计划无效，请重新检测后重试',
        );
      }
      final result = await session.executeConfiguration(plan.planId);
      if (!result.switchedToZhiban) {
        throw const LocalCodingToolsException(
          'switch_validation_failed',
          '切换未通过本地校验，已恢复原有配置',
        );
      }
      return await _readSnapshot(session, deviceId);
    } on LocalCodingToolsException {
      rethrow;
    } on LocalCodingBridgeException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } catch (_) {
      throw const LocalCodingToolsException(
        'switch_failed',
        '切换为知办模型 API 失败，请重新检测后重试',
      );
    } finally {
      await session.close();
    }
  }

  @override
  Future<LocalCodingToolsSnapshot> restoreOfficial(
    LocalCodingTarget target,
  ) async {
    final deviceId = await _requireDeviceId();
    return _retryConfigWrite(() => _restoreOfficialInSession(target, deviceId));
  }

  Future<LocalCodingToolsSnapshot> _restoreOfficialInSession(
    LocalCodingTarget target,
    String deviceId,
  ) async {
    final session = await _bridgeFactory.open();
    try {
      LocalCodingConfigurationPlan plan;
      try {
        plan = await session.planConfiguration(
          target: target,
          type: LocalCodingConfigurationType.restoreGlobal,
        );
      } on LocalCodingBridgeDomainException catch (error) {
        // 契约 §2.7.2:未被知办切换过 → LCT-*-CONFIG-NOT_SWITCHED。Codex 桌面端
        // 与 CLI 共用 ~/.codex/config.toml,卡级恢复先恢复 CLI 再到桌面端时就是
        // 这种情形:没有可恢复的东西 = 已经是官方配置,按成功处理。
        // 客户端收到 RPC error 后已经 abort 掉这条会话(fail closed),读快照要
        // 另开一条,否则报 session_closed(11913 真机"本地连接组件会话已结束")。
        if (error.code.endsWith('-CONFIG-NOT_SWITCHED')) {
          final fresh = await _bridgeFactory.open();
          final LocalCodingToolsSnapshot snapshot;
          try {
            snapshot = await _readSnapshot(fresh, deviceId);
          } finally {
            await fresh.close();
          }
          // 文件仍指向知办却没有切换记录(被清理 / 重装过):Bridge 无从恢复,
          // 不能假报"已恢复"。
          if (snapshot.configurationFor(target).switchedToZhiban) {
            throw const LocalCodingToolsException(
              'restore_not_switched',
              '本机配置缺少知办的切换记录，无法自动恢复官方配置',
            );
          }
          return snapshot;
        }
        rethrow;
      }
      if (plan.action != LocalCodingConfigurationAction.restoreGlobal ||
          plan.planId.isEmpty) {
        throw const LocalCodingToolsException(
          'configuration_plan_invalid',
          '本地恢复计划无效，请重新检测后重试',
        );
      }
      final result = await session.executeConfiguration(plan.planId);
      if (result.switchedToZhiban) {
        throw const LocalCodingToolsException(
          'restore_validation_failed',
          '恢复官方配置未通过本地校验',
        );
      }
      return await _readSnapshot(session, deviceId);
    } on LocalCodingToolsException {
      rethrow;
    } on LocalCodingBridgeException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } catch (_) {
      throw const LocalCodingToolsException(
        'restore_failed',
        '恢复官方配置失败，请重新检测后重试',
      );
    } finally {
      await session.close();
    }
  }

  @override
  Future<LocalCodingLaunchResult> openApp(LocalCodingTarget target) async {
    final session = await _bridgeFactory.open();
    try {
      final installation = await session.detect(target);
      final installationId = installation.installationId;
      if (installationId.isEmpty ||
          installation.uiState == LocalCodingToolUiState.notInstalled ||
          installation.uiState == LocalCodingToolUiState.unsupported ||
          installation.uiState == LocalCodingToolUiState.repairable) {
        throw const LocalCodingToolsException(
          'tool_unsupported',
          '当前安装来源或版本暂不支持启动',
        );
      }
      // 不选项目、不带 profile:Bridge 在用户主目录按用户自己的全局配置启动。
      final plan = await session.planLaunch(
        target: target,
        installationId: installationId,
        mode: LocalCodingLaunchMode.official,
      );
      if (plan.target != target) {
        throw const LocalCodingToolsException(
          'launch_plan_invalid',
          '本地启动计划无效，请重新检测后重试',
        );
      }
      final launched = await session.executeLaunch(plan.launchPlanId);
      if (launched.target != target || launched.state != 'launched') {
        throw LocalCodingToolsException(
          'launch_result_invalid',
          target.isDesktop ? '打开桌面端响应无效，请重试' : '系统终端启动响应无效，请重试',
        );
      }
      return launched;
    } on LocalCodingToolsException {
      rethrow;
    } on LocalCodingBridgeException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } catch (_) {
      throw LocalCodingToolsException(
        'launch_failed',
        target.isDesktop ? '打开桌面端失败，请重试' : '启动 AI 编程工具失败，请重试',
      );
    } finally {
      await session.close();
    }
  }

  /// 一键上报诊断（契约 §2.7"诊断上报"）：现场只含本机状态与我们自己的错误信息，
  /// 不含配置内容、令牌与用户文件；失败不打扰用户，返回 null 由调用方提示。
  @override
  Future<String?> reportDiagnostics({
    required String title,
    required String description,
    required Map<String, dynamic> clientInfo,
  }) async {
    final info = await PackageInfo.fromPlatform();
    final payload = <String, dynamic>{
      ...clientInfo,
      'app_version': '${info.version}+${info.buildNumber}',
      'platform': Platform.operatingSystem,
      'platform_version': Platform.operatingSystemVersion,
      'environment': AppConfig.env.name,
      'reported_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      final response = await sensitiveRequest.post<dynamic>(
        '/support-feedback',
        data: {
          'category': 'bug',
          'title': title,
          'description': description,
          'client_info': payload,
        },
        options: Options(extra: const {'silent': true, 'sensitive': true}),
      );
      final data = response.data;
      if (data is! Map) return null;
      final item = data['item'];
      if (item is! Map) return null;
      final uuid = item['uuid'];
      return uuid is String && uuid.isNotEmpty ? uuid : null;
    } on DioException {
      return null;
    }
  }

  @override
  Future<LocalCodingDiagnostics> diagnostics(LocalCodingTarget target) async {
    final session = await _bridgeFactory.open();
    try {
      if (!session.supportedMethods.contains('diagnostics.get_latest')) {
        throw const LocalCodingToolsException(
          'diagnostics_unsupported',
          '当前版本不支持诊断详情',
        );
      }
      return await session.diagnosticsGetLatest(target);
    } on LocalCodingBridgeDomainException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } on LocalCodingBridgeException catch (error) {
      throw LocalCodingToolsException(error.code, error.userMessage);
    } finally {
      await session.close();
    }
  }
}

bool _isSafeProfileVersion(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > 64) return false;
  return RegExp(r'^[A-Za-z0-9_.+-]+$').hasMatch(trimmed);
}

class _CatalogFetch {
  _CatalogFetch({required this.catalog, required this.present})
      : at = DateTime.now();

  final LocalCodingSignedCatalog? catalog;

  /// false = Bus 明确没有目录(404);true = 拿到了目录。
  final bool present;
  final DateTime at;
}

/// 全量检测的进度上报(2026-09-15 检测过程可视化)。只在有人监听时产生开销;
/// 快照沿用最近一次读完配置时的那份,避免中间步骤把已填好的卡片清空。
class _InspectTracker {
  _InspectTracker(this._onProgress, this._steps);

  final void Function(LocalCodingInspectProgress progress)? _onProgress;
  final List<LocalCodingInspectStep> _steps;
  int _completed = 0;
  LocalCodingToolsSnapshot? _snapshot;

  void emit() {
    _onProgress?.call(LocalCodingInspectProgress(
      steps: _steps,
      completed: _completed,
      snapshot: _snapshot,
    ));
  }

  void advance([LocalCodingToolsSnapshot? snapshot]) {
    if (_onProgress == null) return;
    _completed++;
    if (snapshot != null) _snapshot = snapshot;
    emit();
  }
}
