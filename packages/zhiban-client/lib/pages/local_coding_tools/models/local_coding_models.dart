/// 厂商 = 页面上的一张卡(F31 §1.2 / §3.1,2026-09-09 定案)。
enum LocalCodingVendor {
  codex('Codex'),
  claude('Claude');

  const LocalCodingVendor(this.displayName);

  final String displayName;

  List<LocalCodingTarget> get targets =>
      LocalCodingTarget.values.where((t) => t.vendor == this).toList();

  LocalCodingTarget get cliTarget =>
      targets.firstWhere((t) => t.formFactor == LocalCodingFormFactor.cli);

  LocalCodingTarget get desktopTarget =>
      targets.firstWhere((t) => t.formFactor == LocalCodingFormFactor.desktop);
}

/// 形态 = 卡内的一行:命令行 (CLI) / 桌面端 (App)。
enum LocalCodingFormFactor {
  cli('cli', '命令行 (CLI)'),
  desktop('desktop', '桌面端 (App)');

  const LocalCodingFormFactor(this.value, this.label);

  final String value;
  final String label;

  static LocalCodingFormFactor parse(Object? value) {
    if (value == null || value == '') return LocalCodingFormFactor.cli;
    return values.firstWhere(
      (f) => f.value == value,
      orElse: () => throw const FormatException('unsupported form factor'),
    );
  }
}

enum LocalCodingTarget {
  codexCli('codex_cli', LocalCodingVendor.codex, LocalCodingFormFactor.cli),
  claudeCli('claude_cli', LocalCodingVendor.claude, LocalCodingFormFactor.cli),
  // M3 · 桌面端(macOS app bundle)。与同厂商 CLI 共用设备授权与 Profile。
  codexDesktop(
      'codex_desktop', LocalCodingVendor.codex, LocalCodingFormFactor.desktop),
  claudeDesktop('claude_desktop', LocalCodingVendor.claude,
      LocalCodingFormFactor.desktop);

  const LocalCodingTarget(this.id, this.vendor, this.formFactor);

  final String id;
  final LocalCodingVendor vendor;
  final LocalCodingFormFactor formFactor;

  bool get isDesktop => formFactor == LocalCodingFormFactor.desktop;
  bool get isCli => formFactor == LocalCodingFormFactor.cli;

  /// 设备授权 / Profile 的归属 target:桌面端映射到同厂商 CLI(契约 §3.1,
  /// Bridge `credential.ScopeTarget`)。服务端只认 codex_cli / claude_cli。
  LocalCodingTarget get scopeTarget => isDesktop ? vendor.cliTarget : this;

  /// 服务端授权覆盖的两个 CLI target。
  static List<LocalCodingTarget> get cliTargets =>
      values.where((t) => t.isCli).toList();

  static LocalCodingTarget parse(Object? value) {
    return values.firstWhere(
      (target) => target.id == value,
      orElse: () => throw const FormatException('unsupported target'),
    );
  }
}

enum LocalCodingToolUiState {
  notInstalled('not_installed'),
  installedUnmanaged('installed_unmanaged'),
  configuredUnverified('configured_unverified'),
  ready('ready'),
  repairable('repairable'),
  unsupported('unsupported'),
  busy('busy');

  const LocalCodingToolUiState(this.value);

  final String value;

  static LocalCodingToolUiState parse(Object? value) {
    return values.firstWhere(
      (state) => state.value == value,
      orElse: () => throw const FormatException('unsupported UI state'),
    );
  }
}

/// 契约 §2.7.3 · 桌面端运行组件状态(M3 Task 8:Claude Desktop 的 Claude Code
/// 宿主包)。`unknown` = Bridge 读不出 app 内嵌 manifest,不阻塞使用。
enum LocalCodingComponentState {
  present('present'),
  missing('missing'),
  stale('stale'),
  unknown('unknown');

  const LocalCodingComponentState(this.value);

  final String value;

  static LocalCodingComponentState parse(Object? value) {
    return values.firstWhere(
      (state) => state.value == value,
      orElse: () => LocalCodingComponentState.unknown,
    );
  }
}

class LocalCodingComponent {
  const LocalCodingComponent({
    required this.id,
    required this.state,
    this.version = '',
  });

  /// 目前只有 `claude_code_host`。
  static const String claudeCodeHost = 'claude_code_host';

  final String id;
  final String version;
  final LocalCodingComponentState state;

  /// 缺失或与 app 当前锁定版本不一致:需要(重新)预置。
  bool get needsProvisioning =>
      state == LocalCodingComponentState.missing ||
      state == LocalCodingComponentState.stale;

  factory LocalCodingComponent.fromJson(Map<String, dynamic> json) {
    return LocalCodingComponent(
      id: _requiredString(json['id']),
      version: _optionalString(json['version']),
      state: LocalCodingComponentState.parse(json['state']),
    );
  }
}

class LocalCodingToolState {
  const LocalCodingToolState({
    required this.target,
    required this.generation,
    required this.uiState,
    required this.verificationLevel,
    required this.nextActions,
    this.installationId = '',
    this.installedVersion = '',
    this.installSource = '',
    this.errorCode = '',
    LocalCodingFormFactor? formFactor,
    this.supportsEnable = true,
    this.components = const [],
    this.availableVersion = '',
    this.rollbackVersion = '',
    this.updateAvailable = false,
    this.releaseNotes = '',
    this.adoptVersion = '',
    this.minimumVersion = '',
  }) : _formFactor = formFactor;

  final LocalCodingTarget target;
  final int generation;
  final LocalCodingToolUiState uiState;
  final String installationId;
  final String installedVersion;
  final String installSource;
  final String verificationLevel;
  final String errorCode;
  final List<String> nextActions;

  final LocalCodingFormFactor? _formFactor;

  /// 契约 §2.7.3 · Bridge 回传的形态;老 Bridge 不带时按 target 推断。
  LocalCodingFormFactor get formFactor => _formFactor ?? target.formFactor;

  /// 契约 §2.7.3 · 桌面端是否有可写的第三方推理配置;为 false 时该行只能
  /// 用官方服务,显示"桌面端暂不支持知办模型 API"。CLI 恒为 true。
  final bool supportsEnable;

  /// 契约 §2.7.3 · 已安装桌面端的运行组件(M3 Task 8)。
  final List<LocalCodingComponent> components;

  /// 契约 §2.7.4 · 版本目录:可升级到的版本(目录 current 高于已装时)、可回退到
  /// 的版本(本机保留的旧版本或目录 previous)、随目录带出的更新说明。
  /// 老 Bridge / 没有目录时全部为空。
  final String availableVersion;
  final String rollbackVersion;
  final bool updateAvailable;
  final String releaseNotes;

  /// 2026-09-16 · 接管安装:这份不是装在发行方标准位置的(npm / Homebrew),知办
  /// 可以在标准位置装这个版本并接管。升级按钮对这类安装给不出来,以前这类用户
  /// 卡在旧版本上没有任何可点的东西。
  final String adoptVersion;

  /// 2026-09-15 · 与 `DETECT-VERSION_TOO_OLD` 一起出现:能切换为知办模型 API 的
  /// 最低版本(此时 supportsEnable 为 false,官方服务照常可用)。
  final String minimumVersion;

  bool get versionTooOld => errorCode.endsWith('-DETECT-VERSION_TOO_OLD');

  /// 2026-09-15 · 桌面端太老,读不了知办写入的第三方模型配置(不给切换)。
  bool get thirdPartyUnsupported =>
      errorCode.endsWith('-DETECT-THIRD_PARTY_UNSUPPORTED');

  /// 2026-09-15 · App 读不懂 Bridge 回的检测结果(版本错位),见 [unreadable]。
  bool get resultUnreadable =>
      errorCode.endsWith('-DETECT-RESULT_UNREADABLE');

  /// 契约 §2.7 · 单个 target 的 tool.detect 结果读不懂时由 App 合成的状态:
  /// 不知道装没装、装的是什么,一律按"暂不支持"只读(不打开、不切换、不升级)。
  factory LocalCodingToolState.unreadable(LocalCodingTarget target) =>
      LocalCodingToolState(
        target: target,
        generation: 0,
        uiState: LocalCodingToolUiState.unsupported,
        verificationLevel: 'l0',
        errorCode: 'LCT-${target.id.toUpperCase()}-DETECT-RESULT_UNREADABLE',
        nextActions: const ['detect'],
        supportsEnable: false,
      );

  /// 目录给出了更高版本,且本安装可被升级。
  bool get canUpgrade => updateAvailable && availableVersion.isNotEmpty;

  /// 可以被知办接管(装在标准位置并接管 codex / claude 命令)。
  bool get canAdopt => adoptVersion.isNotEmpty;

  /// 有可回退的版本。
  bool get canRollback => rollbackVersion.isNotEmpty;

  /// Claude Code 宿主组件(只有 claude_desktop 会带)。
  LocalCodingComponent? get hostComponent {
    for (final component in components) {
      if (component.id == LocalCodingComponent.claudeCodeHost) return component;
    }
    return null;
  }

  /// 有组件缺失或过期,需要先预置才能真正使用。
  bool get componentNeedsProvisioning =>
      components.any((component) => component.needsProvisioning);

  factory LocalCodingToolState.fromJson(Map<String, dynamic> json) {
    final generation = json['generation'];
    final actions = json['next_actions'];
    if (generation is! int ||
        generation < 0 ||
        actions is! List ||
        actions.any((value) => value is! String)) {
      throw const FormatException('invalid tool state');
    }
    final supportsEnable = json['supports_enable'];
    if (supportsEnable != null && supportsEnable is! bool) {
      throw const FormatException('invalid supports_enable');
    }
    final updateAvailable = json['update_available'];
    if (updateAvailable != null && updateAvailable is! bool) {
      throw const FormatException('invalid update_available');
    }
    final target = LocalCodingTarget.parse(json['target_id']);
    final formFactor = LocalCodingFormFactor.parse(json['form_factor']);
    if (json['form_factor'] != null && formFactor != target.formFactor) {
      throw const FormatException('form factor does not match target');
    }
    List<LocalCodingComponent> components = const [];
    final rawComponents = json['components'];
    if (rawComponents is List) {
      components = List<LocalCodingComponent>.unmodifiable(
        rawComponents.whereType<Map>().map(
            (c) => LocalCodingComponent.fromJson(Map<String, dynamic>.from(c))),
      );
    } else if (rawComponents != null) {
      throw const FormatException('invalid components');
    }
    return LocalCodingToolState(
      target: target,
      generation: generation,
      uiState: LocalCodingToolUiState.parse(json['ui_state']),
      installationId: _optionalString(json['installation_id']),
      installedVersion: _optionalString(json['installed_version']),
      installSource: _optionalString(json['install_source']),
      verificationLevel: _requiredString(json['verification_level']),
      errorCode: _optionalString(json['error_code']),
      nextActions: List<String>.unmodifiable(actions.cast<String>()),
      formFactor: formFactor,
      supportsEnable: supportsEnable is bool ? supportsEnable : true,
      components: components,
      availableVersion: _optionalString(json['available_version']),
      rollbackVersion: _optionalString(json['rollback_version']),
      updateAvailable: updateAvailable is bool ? updateAvailable : false,
      releaseNotes: _optionalString(json['release_notes']),
      adoptVersion: _optionalString(json['adopt_version']),
      minimumVersion: _optionalString(json['minimum_version']),
    );
  }
}

class LocalCodingCredentialPreparation {
  const LocalCodingCredentialPreparation({
    required this.deviceId,
    required this.devicePublicJwk,
    required this.dpopProof,
  });

  final String deviceId;
  final Map<String, dynamic> devicePublicJwk;
  final String dpopProof;

  factory LocalCodingCredentialPreparation.fromJson(
    Map<String, dynamic> json
  ) {
    final rawJwk = json['device_public_jwk'];
    if (rawJwk is! Map) {
      throw const FormatException('invalid public JWK');
    }
    final jwk = Map<String, dynamic>.from(rawJwk);
    if (jwk.keys.toSet().difference({'kty', 'crv', 'x'}).isNotEmpty ||
        jwk['kty'] != 'OKP' ||
        jwk['crv'] != 'Ed25519' ||
        _requiredString(jwk['x']).isEmpty) {
      throw const FormatException('invalid public JWK');
    }
    return LocalCodingCredentialPreparation(
      deviceId: _requiredString(json['device_id']),
      devicePublicJwk: Map<String, dynamic>.unmodifiable(jwk),
      dpopProof: _requiredString(json['dpop_proof']),
    );
  }
}

class LocalCodingCredentialStatus {
  const LocalCodingCredentialStatus({
    required this.identityPresent,
    required this.authorizationPresent,
    required this.targets,
    this.deviceId = '',
    this.environment = '',
    this.profileVersions = const {},
  });

  final bool identityPresent;
  final bool authorizationPresent;
  final String deviceId;
  final String environment;
  final Set<LocalCodingTarget> targets;
  final Map<String, String> profileVersions;

  factory LocalCodingCredentialStatus.fromJson(Map<String, dynamic> json) {
    final identityPresent = json['identity_present'];
    final authorizationPresent = json['authorization_present'];
    final rawTargets = json['targets'];
    final rawProfileVersions = json['profile_versions'];
    if (identityPresent is! bool ||
        authorizationPresent is! bool ||
        rawTargets is! List ||
        rawProfileVersions is! Map) {
      throw const FormatException('invalid credential status');
    }
    final targets = rawTargets.map(LocalCodingTarget.parse).toSet();
    final profileVersions = <String, String>{};
    for (final entry in rawProfileVersions.entries) {
      if (entry.key is! String ||
          entry.value is! String ||
          !_safeProfileVersion(entry.value as String)) {
        throw const FormatException('invalid credential profile versions');
      }
      final target = LocalCodingTarget.parse(entry.key);
      profileVersions[target.id] = entry.value as String;
    }
    if (profileVersions.length != targets.length ||
        targets.any((target) => !profileVersions.containsKey(target.id))) {
      throw const FormatException('credential targets and profiles differ');
    }
    return LocalCodingCredentialStatus(
      identityPresent: identityPresent,
      authorizationPresent: authorizationPresent,
      deviceId: _optionalString(json['device_id']),
      environment: _optionalString(json['environment']),
      targets: Set<LocalCodingTarget>.unmodifiable(targets),
      profileVersions: Map<String, String>.unmodifiable(profileVersions),
    );
  }
}

enum LocalCodingConfigurationState {
  notConfigured('not_configured'),
  configured('configured'),
  conflict('conflict');

  const LocalCodingConfigurationState(this.value);

  final String value;

  static LocalCodingConfigurationState parse(Object? value) {
    return values.firstWhere(
      (state) => state.value == value,
      orElse: () =>
          throw const FormatException('unsupported configuration state'),
    );
  }
}

class LocalCodingConfigurationStatus {
  const LocalCodingConfigurationStatus({
    required this.target,
    required this.state,
    required this.verificationLevel,
    required this.nextActions,
    this.profileVersion = '',
    this.errorCode = '',
    this.lastVerifiedAt = '',
    this.policyConflict = false,
    this.currentService = LocalCodingCurrentService.official,
    this.globalSwitched = false,
    this.globalBackupAvailable = false,
    this.globalDrifted = false,
    this.globalVerificationLevel = '',
    this.globalLastVerifiedAt = '',
    this.globalUpgradeAvailable = false,
  });

  final LocalCodingTarget target;
  final LocalCodingConfigurationState state;
  final String profileVersion;
  final String verificationLevel;
  final String errorCode;
  final String lastVerifiedAt;
  final List<String> nextActions;
  final bool policyConflict;

  /// 全局切换视图(CC Switch 式):用户自己的全局配置当前指向谁。
  final LocalCodingCurrentService currentService;
  final bool globalSwitched;
  final bool globalBackupAvailable;
  final bool globalDrifted;
  final String globalVerificationLevel;
  final String globalLastVerifiedAt;

  /// 契约 §2.7.2「模型选择」:已切换且未改动,但当前 Bridge 会写的内容更新了
  /// (模型发现开关缺失,或 Codex 模型目录需按本机 Codex 重新校验)。
  /// 页面进入 / 重新检测后后台静默重切,不打扰用户。
  final bool globalUpgradeAvailable;

  bool get configured => state == LocalCodingConfigurationState.configured;

  bool get pathUnsafe => errorCode.endsWith('-CONFIG-UNSAFE_PATH');

  bool get verifiedL3 => verificationLevel == 'l3';

  bool get switchedToZhiban =>
      currentService == LocalCodingCurrentService.zhiban;

  bool get globalVerifiedL3 => globalVerificationLevel == 'l3';

  /// 桌面端上限(契约 §1.2 / §2.7.3):L2 = 配置可解析、helper 可执行、换票成功。
  /// Bridge 对桌面端 target 会把共用 manifest 上的 L3 收口为 l2,这里两者都算。
  bool get globalVerifiedL2 =>
      globalVerificationLevel == 'l2' || globalVerificationLevel == 'l3';

  factory LocalCodingConfigurationStatus.fromJson(Map<String, dynamic> json) {
    final actions = json['next_actions'];
    if (actions is! List || actions.any((value) => value is! String)) {
      throw const FormatException('invalid configuration status');
    }
    final policyConflict = json['policy_conflict'];
    if (policyConflict != null && policyConflict is! bool) {
      throw const FormatException('invalid policy_conflict');
    }
    for (final key in [
      'global_switched',
      'global_backup_available',
      'global_drifted',
      'global_upgrade_available',
    ]) {
      final value = json[key];
      if (value != null && value is! bool) {
        throw FormatException('invalid $key');
      }
    }
    return LocalCodingConfigurationStatus(
      target: LocalCodingTarget.parse(json['target_id']),
      state: LocalCodingConfigurationState.parse(json['state']),
      profileVersion: _optionalString(json['profile_version']),
      verificationLevel: _requiredString(json['verification_level']),
      errorCode: _optionalString(json['error_code']),
      lastVerifiedAt: _optionalString(json['last_verified_at']),
      nextActions: List<String>.unmodifiable(actions.cast<String>()),
      policyConflict: policyConflict is bool ? policyConflict : false,
      currentService: LocalCodingCurrentService.parse(json['current_service']),
      globalSwitched: json['global_switched'] == true,
      globalBackupAvailable: json['global_backup_available'] == true,
      globalDrifted: json['global_drifted'] == true,
      globalVerificationLevel:
          _optionalString(json['global_verification_level']),
      globalLastVerifiedAt: _optionalString(json['global_last_verified_at']),
      globalUpgradeAvailable: json['global_upgrade_available'] == true,
    );
  }
}

/// 「当前服务」:官方服务 / 知办模型 API / 无法判断(用户自行改过、配置不可解析)。
/// 旧 Bridge 不带 current_service 字段时按官方服务处理。
enum LocalCodingCurrentService {
  official('official'),
  zhiban('zhiban'),
  unknown('unknown');

  const LocalCodingCurrentService(this.value);

  final String value;

  static LocalCodingCurrentService parse(Object? value) {
    if (value == null || value == '') return LocalCodingCurrentService.official;
    return values.firstWhere(
      (service) => service.value == value,
      orElse: () => LocalCodingCurrentService.unknown,
    );
  }
}

enum LocalCodingConfigurationAction {
  create('create'),
  update('update'),
  repair('repair'),
  none('none'),
  conflict('conflict'),
  switchGlobal('switch_global'),
  restoreGlobal('restore_global');

  const LocalCodingConfigurationAction(this.value);

  final String value;

  static LocalCodingConfigurationAction parse(Object? value) {
    return values.firstWhere(
      (action) => action.value == value,
      orElse: () =>
          throw const FormatException('unsupported configuration action'),
    );
  }
}

enum LocalCodingConfigurationType {
  enable('enable'),
  repair('repair'),
  // CC Switch 式全局切换:改写用户自己的全局配置(先备份),以及按备份恢复。
  switchGlobal('switch_global'),
  restoreGlobal('restore_global');

  const LocalCodingConfigurationType(this.value);

  final String value;
}

/// verify.execute 的 scope:overlay 走知办隔离配置,global 走用户全局配置
/// (「切换为知办模型 API」之后的真实请求验证)。
enum LocalCodingVerifyScope {
  overlay('overlay'),
  global('global');

  const LocalCodingVerifyScope(this.value);

  final String value;
}

class LocalCodingConfigurationPlan {
  const LocalCodingConfigurationPlan({
    required this.target,
    required this.action,
    this.planId = '',
    this.profileVersion = '',
    this.expiresAt = '',
  });

  final String planId;
  final LocalCodingTarget target;
  final LocalCodingConfigurationAction action;
  final String profileVersion;
  final String expiresAt;

  factory LocalCodingConfigurationPlan.fromJson(Map<String, dynamic> json) {
    return LocalCodingConfigurationPlan(
      planId: _optionalString(json['plan_id']),
      target: LocalCodingTarget.parse(json['target_id']),
      action: LocalCodingConfigurationAction.parse(json['action']),
      profileVersion: _optionalString(json['profile_version']),
      expiresAt: _optionalString(json['expires_at']),
    );
  }
}

class LocalCodingProjectGrant {
  const LocalCodingProjectGrant({
    required this.projectGrantId,
    required this.displayName,
    required this.expiresAt,
  });

  final String projectGrantId;
  final String displayName;
  final String expiresAt;

  factory LocalCodingProjectGrant.fromJson(Map<String, dynamic> json) {
    return LocalCodingProjectGrant(
      projectGrantId: _requiredString(json['project_grant_id']),
      displayName: _safeDisplayName(json['display_name']),
      expiresAt: _requiredString(json['expires_at']),
    );
  }
}

class LocalCodingLaunchPlan {
  const LocalCodingLaunchPlan({
    required this.launchPlanId,
    required this.target,
    required this.projectName,
    required this.expiresAt,
  });

  final String launchPlanId;
  final LocalCodingTarget target;
  final String projectName;
  final String expiresAt;

  factory LocalCodingLaunchPlan.fromJson(Map<String, dynamic> json) {
    // 桌面端「打开桌面端」不在任何项目里启动,Bridge 回 project_name:"";
    // CLI 的主目录启动回 "~"。非空时仍按显示名校验。
    return LocalCodingLaunchPlan(
      launchPlanId: _requiredString(json['launch_plan_id']),
      target: LocalCodingTarget.parse(json['target_id']),
      projectName: _optionalDisplayName(json['project_name']),
      expiresAt: _requiredString(json['expires_at']),
    );
  }
}

class LocalCodingLaunchResult {
  const LocalCodingLaunchResult({
    required this.target,
    required this.state,
    required this.projectName,
  });

  final LocalCodingTarget target;
  final String state;
  final String projectName;

  factory LocalCodingLaunchResult.fromJson(Map<String, dynamic> json) {
    final state = _requiredString(json['state']);
    if (state != 'launched') {
      throw const FormatException('unsupported launch state');
    }
    return LocalCodingLaunchResult(
      target: LocalCodingTarget.parse(json['target_id']),
      state: state,
      projectName: _optionalDisplayName(json['project_name']),
    );
  }
}

/// 契约 §2.7 network.* · 系统代理会不会拦截 Codex 到知办中转站的请求。
/// 老 Bridge 不支持时整份为 null。
class LocalCodingProxyStatus {
  const LocalCodingProxyStatus({
    required this.supported,
    required this.systemProxyEnabled,
    required this.needsFix,
    required this.directReachable,
    this.endpoint = '',
    bool? envNeedsFix,
    this.bypassNeedsFix = false,
  }) : envNeedsFix = envNeedsFix ?? needsFix;

  final bool supported;
  final bool systemProxyEnabled;
  final String endpoint;

  /// 开着系统代理、直连中转站可达、还有没覆盖的项(NO_PROXY 或系统绕过名单)。
  final bool needsFix;
  final bool directReachable;

  /// 只看 NO_PROXY 各项:读环境变量的客户端(Codex、命令行)会被代理拦截。
  /// 老 Bridge 不回这一项时等于 [needsFix](当时 needs_fix 就是这个口径)。
  final bool envNeedsFix;

  /// 系统代理的绕过名单没覆盖中转站(2026-09-18):走系统网络栈的客户端
  /// (Claude 桌面端取模型列表)会被代理拦截。老 Bridge 不回这一项时为 false。
  final bool bypassNeedsFix;

  factory LocalCodingProxyStatus.fromJson(Map<String, dynamic> json) {
    final proxy = json['system_proxy'];
    final proxyMap =
        proxy is Map ? Map<String, dynamic>.from(proxy) : const <String, dynamic>{};
    return LocalCodingProxyStatus(
      supported: json['supported'] == true,
      systemProxyEnabled: proxyMap['enabled'] == true,
      endpoint: _optionalString(proxyMap['endpoint']),
      needsFix: json['needs_fix'] == true,
      directReachable: json['direct_reachable'] == true,
      envNeedsFix:
          json['env_needs_fix'] is bool ? json['env_needs_fix'] as bool : null,
      bypassNeedsFix: proxyMap['enabled'] == true &&
          json['direct_reachable'] == true &&
          json['covered'] is Map &&
          (json['covered'] as Map)['system_bypass'] == false,
    );
  }
}

/// 全量检测的步骤(2026-09-15 检测过程可视化)。
enum LocalCodingInspectStepKind {
  prepare('获取版本目录'),
  detectCli('检查命令行'),
  detectDesktop('检查桌面端'),
  readConfig('读取配置'),
  network('检查网络与代理'),

  /// 卡片「重新检测」对已切换形态的验证:命令行发一次真实请求,桌面端校验配置
  /// 与凭证(由 App 在读完本机状态后追加,不在 [LocalCodingInspectStep.plan] 里)。
  verify('验证服务连接');

  const LocalCodingInspectStepKind(this.label);

  final String label;
}

class LocalCodingInspectStep {
  const LocalCodingInspectStep(this.kind, [this.vendor, this.target]);

  final LocalCodingInspectStepKind kind;

  /// 该步属于哪张卡;准备步骤为 null。网络与代理检查归 Codex(只有它会被系统
  /// 代理拦截)。
  final LocalCodingVendor? vendor;

  /// 验证步骤针对的形态。
  final LocalCodingTarget? target;

  String get label =>
      kind == LocalCodingInspectStepKind.verify && (target?.isDesktop ?? false)
          ? '校验桌面端配置'
          : kind.label;

  /// 检测顺序:准备 → 每个厂商 检查命令行 → 检查桌面端 → 读取配置 → 最后检查网络
  /// 与代理。网络检查可能拖满超时让 Bridge 会话 fail closed,不能排在 Claude 之前。
  static List<LocalCodingInspectStep> plan({required bool network}) => [
        const LocalCodingInspectStep(LocalCodingInspectStepKind.prepare),
        for (final vendor in LocalCodingVendor.values) ...[
          LocalCodingInspectStep(LocalCodingInspectStepKind.detectCli, vendor),
          LocalCodingInspectStep(
              LocalCodingInspectStepKind.detectDesktop, vendor),
          LocalCodingInspectStep(LocalCodingInspectStepKind.readConfig, vendor),
        ],
        if (network)
          const LocalCodingInspectStep(
              LocalCodingInspectStepKind.network, LocalCodingVendor.codex),
      ];
}

/// 一次全量检测的进度:计划、已完成几步、到目前为止读到的快照(只含已读完配置的
/// 形态)。页面据此保留卡片、逐行填充;检测结束后由页面数据接管。
class LocalCodingInspectProgress {
  const LocalCodingInspectProgress({
    required this.steps,
    required this.completed,
    this.snapshot,
  });

  /// 还没打开 Bridge、不知道计划时的占位。
  factory LocalCodingInspectProgress.starting() => LocalCodingInspectProgress(
        steps: LocalCodingInspectStep.plan(network: true),
        completed: 0,
      );

  final List<LocalCodingInspectStep> steps;
  final int completed;
  final LocalCodingToolsSnapshot? snapshot;

  /// 正在进行的步骤;全部完成时为 null。
  LocalCodingInspectStep? get current =>
      completed < steps.length ? steps[completed] : null;

  List<LocalCodingInspectStep> stepsFor(LocalCodingVendor vendor) =>
      steps.where((s) => s.vendor == vendor).toList();

  int doneCountFor(LocalCodingVendor vendor) => steps
      .take(completed.clamp(0, steps.length))
      .where((s) => s.vendor == vendor)
      .length;

  bool vendorDone(LocalCodingVendor vendor) =>
      doneCountFor(vendor) == stepsFor(vendor).length;

  /// 该厂商两个形态的安装与配置都已读完:软件状态 / 版本 / 当前服务可以填上。
  bool configRead(LocalCodingVendor vendor) => steps
      .take(completed.clamp(0, steps.length))
      .any((s) =>
          s.vendor == vendor && s.kind == LocalCodingInspectStepKind.readConfig);
}

class LocalCodingToolsSnapshot {
  const LocalCodingToolsSnapshot({
    required this.deviceId,
    required this.environment,
    required this.credentialStatus,
    required this.tools,
    required this.configurations,
    required this.expectedProfileVersions,
    required this.registrationAvailable,
    this.remoteRevocationPending = false,
    this.supportedMethods = const {},
    this.proxyStatus,
  });

  final String deviceId;
  final String environment;
  final LocalCodingCredentialStatus credentialStatus;
  final Map<LocalCodingTarget, LocalCodingToolState> tools;
  final Map<LocalCodingTarget, LocalCodingConfigurationStatus> configurations;
  final Map<LocalCodingTarget, String> expectedProfileVersions;
  final bool registrationAvailable;
  final bool remoteRevocationPending;
  final Set<String> supportedMethods;

  bool get canInstall => supportedMethods.contains('install.execute');
  bool get canVerify => supportedMethods.contains('verify.execute');
  bool get canDiagnose => supportedMethods.contains('diagnostics.get_latest');
  bool get canRequirements => supportedMethods.contains('requirements.get');

  /// 契约 §2.7 network.*;老 Bridge 为 null。
  final LocalCodingProxyStatus? proxyStatus;
  bool get proxyNeedsFix => proxyStatus?.needsFix ?? false;
  bool get proxyEnvNeedsFix => proxyStatus?.envNeedsFix ?? false;
  bool get proxyBypassNeedsFix => proxyStatus?.bypassNeedsFix ?? false;

  /// 服务端授权只覆盖两个 CLI target;桌面端共用同厂商 CLI 的授权(契约 §3.1)。
  bool get authorizationConnected =>
      !remoteRevocationPending &&
      credentialStatus.authorizationPresent &&
      credentialStatus.deviceId == deviceId &&
      credentialStatus.environment == environment &&
      credentialStatus.targets.containsAll(LocalCodingTarget.cliTargets);

  /// 契约 §2.7.2「模型选择」· 已切换、未改动、但 Bridge 报 global_upgrade_available
  /// (本机 Codex / Claude 程序变了,知办写入的派生配置需要重做):可以静默重写一遍
  /// 知办配置。进页面自动流程与 App 启动后台维护共用这条判断。
  bool configRefreshEligible(LocalCodingTarget target) {
    if (!registrationAvailable) return false;
    final tool = tools[target];
    final config = configurations[target];
    if (tool == null || config == null) return false;
    if (tool.uiState != LocalCodingToolUiState.installedUnmanaged &&
        tool.uiState != LocalCodingToolUiState.ready) {
      return false;
    }
    if (!tool.supportsEnable || config.policyConflict) return false;
    return config.switchedToZhiban &&
        config.globalSwitched &&
        config.globalUpgradeAvailable &&
        !config.globalDrifted;
  }

  /// 快照里有没有该 target 的检测结果(老 Bridge 不回桌面端时为 false)。
  bool hasTarget(LocalCodingTarget target) =>
      tools.containsKey(target) && configurations.containsKey(target);

  LocalCodingToolState stateFor(LocalCodingTarget target) {
    final state = tools[target];
    if (state == null) throw StateError('local coding target state missing');
    return state;
  }

  LocalCodingConfigurationStatus configurationFor(LocalCodingTarget target) {
    final status = configurations[target];
    if (status == null) {
      throw StateError('local coding target configuration missing');
    }
    return status;
  }

  bool configurationCurrent(LocalCodingTarget target) {
    final expected = expectedProfileVersions[target];
    final status = configurations[target];
    return expected != null &&
        expected.isNotEmpty &&
        status != null &&
        status.configured &&
        status.profileVersion == expected;
  }
}

enum LocalCodingLaunchMode {
  managed('managed'),
  official('official');

  const LocalCodingLaunchMode(this.value);

  final String value;
}

enum LocalCodingInstallMode {
  install('install'),
  repair('repair'),
  // M3 Task 8 · 预置运行组件(install.plan 带 component,不带 mode)。
  component('component'),
  // 契约 §2.7.4 · 版本目录:升级到目录 current / 回退到 rollback_version。
  upgrade('upgrade'),
  rollback('rollback'),
  // 2026-09-16 · 接管安装:把 npm / Homebrew 装的那份换成标准位置的知办版本。
  adopt('adopt');

  const LocalCodingInstallMode(this.value);

  final String value;
}

enum LocalCodingOperationKind {
  install('install'),
  verify('verify');

  const LocalCodingOperationKind(this.value);

  final String value;

  static LocalCodingOperationKind parse(Object? value) {
    return values.firstWhere(
      (k) => k.value == value,
      orElse: () => throw const FormatException('unsupported operation kind'),
    );
  }
}

enum LocalCodingOperationState {
  running('running'),
  succeeded('succeeded'),
  failed('failed'),
  cancelled('cancelled');

  const LocalCodingOperationState(this.value);

  final String value;

  bool get isTerminal =>
      this == LocalCodingOperationState.succeeded ||
      this == LocalCodingOperationState.failed ||
      this == LocalCodingOperationState.cancelled;

  static LocalCodingOperationState parse(Object? value) {
    return values.firstWhere(
      (s) => s.value == value,
      orElse: () => throw const FormatException('unsupported operation state'),
    );
  }
}

enum LocalCodingProgressKind {
  determinate('determinate'),
  indeterminate('indeterminate');

  const LocalCodingProgressKind(this.value);

  final String value;

  static LocalCodingProgressKind parse(Object? value) {
    return values.firstWhere(
      (k) => k.value == value,
      orElse: () => throw const FormatException('unsupported progress kind'),
    );
  }
}

class LocalCodingOperation {
  const LocalCodingOperation({
    required this.operationId,
    required this.target,
    required this.kind,
    required this.state,
    required this.stage,
    required this.progressKind,
    required this.cancellable,
    required this.nextActions,
    this.progressValue,
    this.errorCode = '',
    this.errorDetail = '',
    this.traceId = '',
    this.result,
  });

  final String operationId;
  final LocalCodingTarget target;
  final LocalCodingOperationKind kind;
  final LocalCodingOperationState state;
  final String stage;
  final LocalCodingProgressKind progressKind;
  final int? progressValue;
  final bool cancellable;
  final String errorCode;

  /// 检测失败时知办中转站自己的回答("HTTP 503 · <中转站原话>",Bridge 已打码;
  /// 契约 §2.7 verify.execute error_detail)。其它失败为空。
  final String errorDetail;
  final String traceId;
  final List<String> nextActions;
  final Map<String, dynamic>? result;

  bool get isTerminal => state.isTerminal;
  bool get isRunning => state == LocalCodingOperationState.running;
  bool get isSucceeded => state == LocalCodingOperationState.succeeded;

  /// 检测通过、但当前配置的模型没答上来(由备用模型通过)时的说明;其余为 null。
  LocalCodingModelWarning? get modelWarning =>
      kind == LocalCodingOperationKind.verify && isSucceeded
          ? LocalCodingModelWarning.fromResult(result)
          : null;
  bool get isFailed => state == LocalCodingOperationState.failed;
  bool get isCancelled => state == LocalCodingOperationState.cancelled;

  /// 已下载字节百分比(仅 downloading 阶段有值),否则返回 null。
  int? get downloadPercent =>
      progressKind == LocalCodingProgressKind.determinate
          ? progressValue
          : null;

  factory LocalCodingOperation.fromJson(Map<String, dynamic> json) {
    final actions = json['next_actions'];
    if (actions is! List || actions.any((value) => value is! String)) {
      throw const FormatException('invalid operation next_actions');
    }
    final cancellable = json['cancellable'];
    if (cancellable is! bool) {
      throw const FormatException('invalid operation cancellable');
    }
    final progressKind = LocalCodingProgressKind.parse(json['progress_kind']);
    int? progressValue;
    if (progressKind == LocalCodingProgressKind.determinate) {
      final raw = json['progress_value'];
      if (raw is! int || raw < 0 || raw > 100) {
        throw const FormatException(
            'invalid operation progress_value for determinate stage');
      }
      progressValue = raw;
    }
    final rawResult = json['result'];
    Map<String, dynamic>? result;
    if (rawResult is Map) {
      result = Map<String, dynamic>.from(rawResult);
    } else if (rawResult != null) {
      throw const FormatException('invalid operation result');
    }
    return LocalCodingOperation(
      operationId: _requiredString(json['operation_id']),
      target: LocalCodingTarget.parse(json['target_id']),
      kind: LocalCodingOperationKind.parse(json['kind']),
      state: LocalCodingOperationState.parse(json['state']),
      stage: _requiredString(json['stage']),
      progressKind: progressKind,
      progressValue: progressValue,
      cancellable: cancellable,
      errorCode: _optionalString(json['error_code']),
      errorDetail: _optionalString(json['error_detail']),
      traceId: _optionalString(json['trace_id']),
      nextActions: List<String>.unmodifiable(actions.cast<String>()),
      result: result,
    );
  }
}

class LocalCodingRequirementIssue {
  const LocalCodingRequirementIssue(this.code);

  final String code;

  static const unsupportedOs = LocalCodingRequirementIssue('UNSUPPORTED_OS');
  static const unsupportedArch =
      LocalCodingRequirementIssue('UNSUPPORTED_ARCH');
  static const insufficientDisk =
      LocalCodingRequirementIssue('INSUFFICIENT_DISK');
  static const targetDirNotWritable =
      LocalCodingRequirementIssue('TARGET_DIR_NOT_WRITABLE');
  static const targetConflict = LocalCodingRequirementIssue('TARGET_CONFLICT');
}

class LocalCodingRequirements {
  const LocalCodingRequirements({
    required this.target,
    required this.version,
    required this.platform,
    required this.arch,
    required this.minOs,
    required this.downloadSizeBytes,
    required this.requiredFreeBytes,
    required this.downloadHost,
    required this.installLocationKind,
    required this.satisfied,
    required this.issues,
    this.osVersion = '',
    this.availableFreeBytes,
  });

  final LocalCodingTarget target;
  final String version;
  final String platform;
  final String arch;
  final String minOs;
  final String osVersion;
  final int downloadSizeBytes;
  final int requiredFreeBytes;
  final int? availableFreeBytes;
  final String downloadHost;
  final String installLocationKind;
  final bool satisfied;
  final List<String> issues;

  factory LocalCodingRequirements.fromJson(Map<String, dynamic> json) {
    final downloadSize = json['download_size_bytes'];
    final requiredFree = json['required_free_bytes'];
    final available = json['available_free_bytes'];
    final satisfied = json['satisfied'];
    final issues = json['issues'];
    if (downloadSize is! int ||
        requiredFree is! int ||
        (available != null && available is! int) ||
        satisfied is! bool ||
        issues is! List ||
        issues.any((value) => value is! String)) {
      throw const FormatException('invalid requirements payload');
    }
    return LocalCodingRequirements(
      target: LocalCodingTarget.parse(json['target_id']),
      version: _requiredString(json['version']),
      platform: _requiredString(json['platform']),
      arch: _requiredString(json['arch']),
      minOs: _requiredString(json['min_os']),
      osVersion: _optionalString(json['os_version']),
      downloadSizeBytes: downloadSize,
      requiredFreeBytes: requiredFree,
      availableFreeBytes: available is int ? available : null,
      downloadHost: _requiredString(json['download_host']),
      installLocationKind: _requiredString(json['install_location_kind']),
      satisfied: satisfied,
      issues: List<String>.unmodifiable(issues.cast<String>()),
    );
  }
}

class LocalCodingInstallPlan {
  const LocalCodingInstallPlan({
    required this.planId,
    required this.target,
    required this.mode,
    required this.version,
    required this.source,
    required this.downloadHost,
    required this.downloadSizeBytes,
    required this.sha256,
    required this.expiresAt,
    this.component = '',
    this.origin = '',
    this.fromVersion = '',
    this.local = false,
    this.publisherAutoUpdateMayOverride = false,
  });

  final String planId;
  final LocalCodingTarget target;
  final LocalCodingInstallMode mode;

  /// mode=component 时的组件 id(目前只有 `claude_code_host`)。
  final String component;
  final String version;
  final String source;
  final String downloadHost;
  final int downloadSizeBytes;
  final String sha256;
  final String expiresAt;

  /// 契约 §2.7.4 · 版本来源:builtin(内置清单)/ catalog(签名目录)/ local(本机
  /// 保留版本,回退时不下载)。老 Bridge 为空。
  final String origin;

  /// 升级 / 回退前的已装版本。
  final String fromVersion;

  /// 不需要下载(回退到本机保留版本)。
  final bool local;

  /// 桌面端升级 / 回退:发行方的自动更新之后可能再次改变版本。
  final bool publisherAutoUpdateMayOverride;

  factory LocalCodingInstallPlan.fromJson(Map<String, dynamic> json) {
    final local = json['local'];
    if (local != null && local is! bool) {
      throw const FormatException('invalid install plan local flag');
    }
    final isLocal = local is bool && local;
    final override = json['publisher_auto_update_may_override'];
    if (override != null && override is! bool) {
      throw const FormatException('invalid install plan override flag');
    }
    final downloadSize = json['download_size_bytes'];
    // 本机回退不下载:大小为 0、无下载主机与哈希;其余计划仍必须有下载量。
    if (downloadSize is! int ||
        downloadSize < 0 ||
        (downloadSize == 0 && !isLocal)) {
      throw const FormatException('invalid install plan download size');
    }
    final rawMode = _optionalString(json['mode']);
    final mode = rawMode.isEmpty
        ? LocalCodingInstallMode.install
        : LocalCodingInstallMode.values.firstWhere(
            (m) => m.value == rawMode,
            orElse: () =>
                throw const FormatException('unsupported install mode'),
          );
    final component = _optionalString(json['component']);
    if ((mode == LocalCodingInstallMode.component) != component.isNotEmpty) {
      throw const FormatException('install plan component does not match mode');
    }
    return LocalCodingInstallPlan(
      planId: _requiredString(json['plan_id']),
      target: LocalCodingTarget.parse(json['target_id']),
      mode: mode,
      component: component,
      version: _requiredString(json['version']),
      source: _requiredString(json['source']),
      downloadHost: isLocal
          ? _optionalString(json['download_host'])
          : _requiredString(json['download_host']),
      downloadSizeBytes: downloadSize,
      sha256: isLocal
          ? _optionalString(json['sha256'])
          : _requiredString(json['sha256']),
      expiresAt: _requiredString(json['expires_at']),
      origin: _optionalString(json['origin']),
      fromVersion: _optionalString(json['from_version']),
      local: isLocal,
      publisherAutoUpdateMayOverride: override is bool && override,
    );
  }
}

/// 契约 §4.5 / §2.7.4 · Bus 下发的签名版本目录信封。App 不解释 catalog 内容,
/// 只原样转交 Bridge 验签(`catalog.apply`);这里只校验三个字段的形状。
class LocalCodingSignedCatalog {
  const LocalCodingSignedCatalog({
    required this.catalog,
    required this.kid,
    required this.signature,
  });

  final Map<String, dynamic> catalog;
  final String kid;
  final String signature;

  static final RegExp _kidPattern = RegExp(r'^[0-9A-Za-z._+-]{1,64}$');
  static final RegExp _signaturePattern = RegExp(r'^[0-9A-Za-z_-]+={0,2}$');

  Map<String, dynamic> toJson() => {
        'catalog': catalog,
        'kid': kid,
        'signature': signature,
      };

  factory LocalCodingSignedCatalog.fromJson(Map<String, dynamic> json) {
    final catalog = json['catalog'];
    final kid = json['kid'];
    final signature = json['signature'];
    if (catalog is! Map ||
        kid is! String ||
        !_kidPattern.hasMatch(kid) ||
        signature is! String ||
        signature.isEmpty ||
        signature.length > 128 ||
        !_signaturePattern.hasMatch(signature)) {
      throw const FormatException('invalid signed catalog');
    }
    return LocalCodingSignedCatalog(
      catalog:
          Map<String, dynamic>.unmodifiable(Map<String, dynamic>.from(catalog)),
      kid: kid,
      signature: signature,
    );
  }
}

/// `catalog.apply` 的结果:是否采用了目录,以及每个目标的 current / previous。
class LocalCodingCatalogApplyResult {
  const LocalCodingCatalogApplyResult({
    required this.applied,
    this.issuedAt = '',
    this.expiresAt = '',
    this.targets = const {},
  });

  final bool applied;
  final String issuedAt;
  final String expiresAt;
  final Map<LocalCodingTarget, LocalCodingCatalogTargetStatus> targets;

  factory LocalCodingCatalogApplyResult.fromJson(Map<String, dynamic> json) {
    final applied = json['applied'];
    if (applied is! bool) {
      throw const FormatException('invalid catalog apply result');
    }
    final rawTargets = json['targets'];
    final targets = <LocalCodingTarget, LocalCodingCatalogTargetStatus>{};
    if (rawTargets is Map) {
      for (final entry in rawTargets.entries) {
        final target = LocalCodingTarget.values
            .where((t) => t.id == entry.key)
            .firstOrNull;
        final value = entry.value;
        // 目录里 Bridge 可能列出 App 不认识的目标(如 claude_code_host):跳过。
        if (target == null || value is! Map) continue;
        targets[target] = LocalCodingCatalogTargetStatus.fromJson(
            Map<String, dynamic>.from(value));
      }
    } else if (rawTargets != null) {
      throw const FormatException('invalid catalog apply targets');
    }
    return LocalCodingCatalogApplyResult(
      applied: applied,
      issuedAt: _optionalString(json['issued_at']),
      expiresAt: _optionalString(json['expires_at']),
      targets:
          Map<LocalCodingTarget, LocalCodingCatalogTargetStatus>.unmodifiable(
              targets),
    );
  }
}

class LocalCodingCatalogTargetStatus {
  const LocalCodingCatalogTargetStatus({
    required this.currentVersion,
    this.previousVersion = '',
    this.canary = false,
  });

  final String currentVersion;
  final String previousVersion;
  final bool canary;

  factory LocalCodingCatalogTargetStatus.fromJson(Map<String, dynamic> json) {
    final canary = json['canary'];
    if (canary != null && canary is! bool) {
      throw const FormatException('invalid catalog target status');
    }
    return LocalCodingCatalogTargetStatus(
      currentVersion: _requiredString(json['current_version']),
      previousVersion: _optionalString(json['previous_version']),
      canary: canary is bool && canary,
    );
  }
}

class LocalCodingDiagnostics {
  const LocalCodingDiagnostics({
    required this.target,
    required this.bridgeVersion,
    required this.suggestions,
    this.occurredAt = '',
    this.kind = '',
    this.stage = '',
    this.errorCode = '',
    this.errorDetail = '',
  });

  final LocalCodingTarget target;
  final String bridgeVersion;
  final String occurredAt;
  final String kind;
  final String stage;
  final String errorCode;

  /// 检测失败时中转站返回的原话(契约 §2.7 error_detail),诊断详情里原样给出。
  final String errorDetail;
  final List<String> suggestions;

  bool get isEmpty => errorCode.isEmpty && kind.isEmpty && stage.isEmpty;

  factory LocalCodingDiagnostics.fromJson(Map<String, dynamic> json) {
    final suggestions = json['suggestions'];
    if (suggestions is! List || suggestions.any((v) => v is! String)) {
      throw const FormatException('invalid diagnostics suggestions');
    }
    return LocalCodingDiagnostics(
      target: LocalCodingTarget.parse(json['target_id']),
      bridgeVersion: _requiredString(json['bridge_version']),
      occurredAt: _optionalString(json['occurred_at']),
      kind: _optionalString(json['kind']),
      stage: _optionalString(json['stage']),
      errorCode: _optionalString(json['error_code']),
      errorDetail: _optionalString(json['error_detail']),
      suggestions: List<String>.unmodifiable(suggestions.cast<String>()),
    );
  }
}

/// 检测通过但当前配置的模型线路不可用(契约 §2.7 L3 备用模型,2026-09-20):
/// 中转站上单个模型的线路出问题时,Bridge 用备用模型补测通过,服务本身可用。
class LocalCodingModelWarning {
  const LocalCodingModelWarning({
    required this.errorCode,
    required this.errorDetail,
    required this.workingModel,
  });

  final String errorCode;
  final String errorDetail;

  /// 补测时答上来的那个模型。
  final String workingModel;

  static LocalCodingModelWarning? fromResult(Map<String, dynamic>? result) {
    final raw = result?['model_warning'];
    if (raw is! Map) return null;
    final working = raw['working_model'];
    if (working is! String || working.trim().isEmpty) return null;
    final code = raw['error_code'];
    final detail = raw['error_detail'];
    return LocalCodingModelWarning(
      errorCode: code is String ? code : '',
      errorDetail: detail is String ? detail : '',
      workingModel: working.trim(),
    );
  }
}

/// 一句话:服务可用,只是当前配置的模型暂时用不了,换一个就行。
String localCodingModelWarningText(LocalCodingModelWarning warning) {
  final status = localCodingRelayStatus(warning.errorDetail);
  final paren = status.isEmpty ? '' : '（$status）';
  return '当前配置的模型线路暂时不可用$paren，其它模型可用（如 ${warning.workingModel}），可在工具里换一个模型';
}

/// 检测失败里"知办中转站自己拒绝了请求"的几类(2026-09-15):一键修复修不好,
/// 卡片要说清是中转站的问题,原话放诊断详情。其它失败(网络、授权、进程)为 null。
enum LocalCodingRelayFailure {
  upstreamUnavailable, // HTTP 5xx / 上游过载
  quotaExhausted, // HTTP 429 / 用量或频率
  modelDenied, // 模型没有可用线路
  rejected, // 其它 HTTP 错误
  // 代理软件把工具的流量转去了代理节点(按进程名分流 / 全局模式 / TUN,2026-09-18):
  // 同样是「修复并重试」修不好的一类,只能用户在代理软件里放行后重新检测。
  proxyDiverted,
  // 换票时知办停发了这位成员的模型 Key(契约「换票被拒要说真话」,2026-09-20):
  // 设备授权是好的,重新接入没用。此前一律报成"设备授权已撤销",生产上一位
  // 欠费用户被引导去点一键修复,20 分钟重试了 191 次。
  insufficientCredit, // 积分用完,充值到账即恢复
  memberKeyDisabled, // 成员 / 企业被停用,或被管理员停用
}

LocalCodingRelayFailure? localCodingRelayFailure(
    String errorCode, String errorDetail) {
  if (errorCode.endsWith('-GATEWAY-PROXY_DIVERTED')) {
    return LocalCodingRelayFailure.proxyDiverted;
  }
  if (errorCode.endsWith('-AUTH-INSUFFICIENT_CREDIT')) {
    return LocalCodingRelayFailure.insufficientCredit;
  }
  if (errorCode.endsWith('-AUTH-MEMBER_KEY_DISABLED')) {
    return LocalCodingRelayFailure.memberKeyDisabled;
  }
  if (errorCode.endsWith('-GATEWAY-UPSTREAM_UNAVAILABLE')) {
    return LocalCodingRelayFailure.upstreamUnavailable;
  }
  if (errorCode.endsWith('-GATEWAY-QUOTA_EXHAUSTED')) {
    return LocalCodingRelayFailure.quotaExhausted;
  }
  if (errorCode.endsWith('-GATEWAY-MODEL_DENIED')) {
    return LocalCodingRelayFailure.modelDenied;
  }
  if (errorCode.endsWith('-GATEWAY-PROTOCOL_MISMATCH') &&
      errorDetail.isNotEmpty) {
    return LocalCodingRelayFailure.rejected;
  }
  return null;
}

/// "HTTP 503 · …" 里的 "HTTP 503";没有中转站回答时为空。
String localCodingRelayStatus(String errorDetail) =>
    RegExp(r'^HTTP \d{3}').firstMatch(errorDetail)?.group(0) ?? '';

/// 失败详情那一行的标签:详情是中转站的 HTTP 回答("HTTP 503 · …")才叫"中转站返回";
/// 其余是命令行自己的话或"探测超时"(契约 §2.7 `GATEWAY-UNREACHABLE` 的
/// `error_detail`,2026-09-17),标成中转站的话会把人引到错误的方向。
String localCodingErrorDetailLabel(String errorDetail) =>
    localCodingRelayStatus(errorDetail).isEmpty ? '失败详情' : '中转站返回';

/// 一句话说清中转站拒绝的原因(卡片提示与浮动通知共用)。
String localCodingRelayFailureSummary(
    LocalCodingRelayFailure failure, String errorDetail) {
  final status = localCodingRelayStatus(errorDetail);
  final paren = status.isEmpty ? '' : '（$status）';
  return switch (failure) {
    LocalCodingRelayFailure.upstreamUnavailable =>
      '知办中转站暂时不可用$paren，不是本机问题，稍后再检测',
    LocalCodingRelayFailure.quotaExhausted =>
      '知办中转站拒绝了请求$paren，可能是用量已用完或请求过于频繁，稍后再检测',
    LocalCodingRelayFailure.modelDenied =>
      '知办中转站没有为当前模型开放可用线路$paren，需要管理员处理',
    LocalCodingRelayFailure.rejected => '知办中转站返回错误$paren，不是本机问题',
    LocalCodingRelayFailure.proxyDiverted =>
      '请求知办中转站失败，可能受代理软件的分流规则影响；在代理软件里把 airick.cn 设为直连，或暂时关闭 TUN / 增强模式后再检测',
    LocalCodingRelayFailure.insufficientCredit =>
      '积分已用完，知办暂停了模型服务；在「设置 → 套餐与积分」充值（成员请联系企业管理员），到账后再检测即可，不需要重新接入',
    LocalCodingRelayFailure.memberKeyDisabled =>
      '你的模型服务已被停用，设备授权没有问题、重新接入没用；请联系企业管理员，恢复后再检测',
  };
}

String _requiredString(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('required string missing');
  }
  return value;
}

String _optionalString(Object? value) {
  if (value == null) return '';
  if (value is! String) throw const FormatException('invalid string');
  return value;
}

bool _safeProfileVersion(String value) {
  if (value.isEmpty || value.length > 64) return false;
  return RegExp(r'^[A-Za-z0-9_.+\-]+$').hasMatch(value);
}

/// 允许缺省 / 空串(桌面端启动没有项目名),非空时按 [_safeDisplayName] 校验。
String _optionalDisplayName(Object? value) {
  if (value == null) return '';
  if (value is! String) throw const FormatException('invalid display name');
  if (value.trim().isEmpty) return '';
  return _safeDisplayName(value);
}

String _safeDisplayName(Object? value) {
  final name = _requiredString(value);
  if (name.length > 128 ||
      name.contains('/') ||
      name.contains('\\') ||
      name.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    throw const FormatException('invalid display name');
  }
  return name;
}
