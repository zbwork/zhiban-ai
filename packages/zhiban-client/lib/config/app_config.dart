import 'package:flutter/foundation.dart';

enum AppEnv { dev, test, prod }

class AppConfig {
  /// Public export selects the backend capability set at build time.
  static const bool communityEdition = true;

  /// 社区版使用部署内运行环境；商业版沿用云端新建开关。
  static const cloudAgentCreationEnabled = communityEdition || bool.fromEnvironment(
    'CLOUD_AGENT_CREATION_ENABLED',
    defaultValue: false,
  );

  /// 当前产品阶段只启动本地 Agent；云端 runtime 预热实现保留，显式开启后恢复。
  static const cloudRuntimePrewarmEnabled = bool.fromEnvironment(
    'CLOUD_RUNTIME_PREWARM_ENABLED',
    defaultValue: false,
  );

  /// 关于页隐藏入口写入的运行时环境覆盖，优先级高于 dart-define `APP_ENV`。
  /// 由 main() 启动时从 SharedPreferences 读出 + applyEnvOverride 设置。
  static AppEnv? _runtimeEnv;

  static const String _appEnv =
      String.fromEnvironment('APP_ENV', defaultValue: '');

  // zhiban-app cutover (2026-05): API 全面切到 services/agent-bus，
  // 路径前缀固定 /api/agent-bus/v1。见 docs/contracts/agent-bus-client-contract.md §10。
  // 严禁再保留任何 ai-office (/api) 后端配置。
  static const String _devApiUrl = String.fromEnvironment(
    'API_BASE_URL_DEV',
    defaultValue: 'http://localhost:8080/api/agent-bus/v1',
  );
  static const String _testApiUrl = String.fromEnvironment(
    'API_BASE_URL_TEST',
    defaultValue: '',
  );
  // 商业发布通过 --dart-define=API_BASE_URL_PROD=... 注入；社区版必须显式提供自己的地址。
  static const String _prodApiUrl = String.fromEnvironment(
    'API_BASE_URL_PROD',
    defaultValue: '',
  );

  static AppEnv get env {
    if (_runtimeEnv != null) return _runtimeEnv!;
    switch (_appEnv.toLowerCase()) {
      case 'dev':
        return AppEnv.dev;
      case 'test':
        return AppEnv.test;
      case 'prod':
        return AppEnv.prod;
      default:
        return kReleaseMode ? AppEnv.prod : AppEnv.dev;
    }
  }

  static String apiUrl() {
    switch (env) {
      case AppEnv.dev:
        return _devApiUrl;
      case AppEnv.test:
        return _testApiUrl;
      case AppEnv.prod:
        return _prodApiUrl;
    }
  }

  // 管理后台 (agent-bus-admin) 前端地址，供侧栏头像弹框「管理后台」外链使用
  // (docs/contracts/agent-bus-client-contract.md §11.6)。
  // 空字符串 = 该环境没有可用的管理后台，客户端隐藏入口而不是给假链接；
  // 各环境仍可通过 --dart-define=ADMIN_WEB_URL_<ENV>=... 覆盖。
  static const String _devAdminWebUrl = String.fromEnvironment(
    'ADMIN_WEB_URL_DEV',
    defaultValue: 'http://127.0.0.1:5173',
  );
  static const String _testAdminWebUrl = String.fromEnvironment(
    'ADMIN_WEB_URL_TEST',
    defaultValue: '',
  );
  static const String _prodAdminWebUrl = String.fromEnvironment(
    'ADMIN_WEB_URL_PROD',
    defaultValue: '',
  );

  static String adminWebUrl() {
    switch (env) {
      case AppEnv.dev:
        return _devAdminWebUrl;
      case AppEnv.test:
        return _testAdminWebUrl;
      case AppEnv.prod:
        return _prodAdminWebUrl;
    }
  }

  /// 设置/清除运行时环境覆盖。仅修改内存值，调用方负责持久化与重启 App 才能让原生层（webview/插件）也跟着切。
  static void applyEnvOverride(AppEnv? env) {
    _runtimeEnv = env;
  }

  static const storageTokenKey = 'token';
  static const storageRefreshTokenKey = 'refresh_token';
  static const storageAccountInfoKey = 'account_info';
  static const storageDashboardTokenKey = 'dashboard_token';
  static const storageWorkbenchAppsKey = 'workbench_apps';
  // 通讯录本地快照(ContactsDirectoryStore)：部门树 + 全量 human/agent 成员。
  // 登出时随 session_service.clearSessionStorage 一并清掉，避免下个账号残留上个租户数据。
  static const storageContactsDirectoryKey = 'contacts_directory_snapshot_v1';
  // 关于页隐藏入口写入的环境覆盖：值为 AppEnv.name (dev/test/prod)。
  // 注意：session_service.clearSessionStorage 不会清此 key，切环境后下次启动仍生效。
  static const storageEnvOverrideKey = 'app_env_override';
  // 登录请求 device.deviceFingerprint 用的稳定设备标识：首次生成后永久存本地，
  // 不随重新登录/切账号变化。后端用它顶掉同一设备的旧 session（见
  // service/device_info_service.dart::collectLoginDeviceInfo）。
  // 注意：session_service.clearSessionStorage 不清此 key —— 跟 IM device_id 同一个
  // "设备身份稳定"哲学，登出不代表换了台机器。
  static const storageDeviceFingerprintKey = 'device_fingerprint';
  // F31 远端撤销失败时只保存非敏感重试元数据（设备/账号/租户/环境），不保存
  // DPoP、JWK 或 device credential。登出不清，等同一登录身份恢复后重试。
  static const storageLocalCodingPendingRevocationKey =
      'local_coding_pending_revocation_v1';
  // F31 重新登录后自动重新接入(2026-09-18):接入成功时记下"谁在这台设备上接入过"
  // (设备/账号/租户/环境,不含任何凭证)。登出不清——同一个人回来时凭它静默重新接入;
  // 主动移除授权会清掉。
  static const storageLocalCodingReconnectKey = 'local_coding_reconnect_v1';

  // F31 入口 2026-09-11 起默认开启：常规 flutter build 不传 dart-define 也显示，
  // 只在桌面端 macOS / Windows 出现（见 sidebar_profile_popover）；要隐藏时显式传
  // LOCAL_CODING_TOOLS_ENABLED=false。入口显示不代表 Bridge 已打进包：macOS Release
  // 仍需 LOCAL_CODING_BRIDGE_EMBED=YES 一组签名参数（README「本地编程工具 Bridge」），
  // 缺 helper 时页面提示"本地连接组件不可用"。
  static const localCodingToolsEnabled = bool.fromEnvironment(
        'LOCAL_CODING_TOOLS_ENABLED',
        defaultValue: true,
      );

  // 两个 profile version 必须与 Bus 的 AGBUS_LOCAL_CODING_{CODEX,CLAUDE}_PROFILE_VERSION
  // 一致（测试 / 生产当前都是 2026.09.07.1）。默认值就是这个锁定值，常规构建不传
  // dart-define 也能注册；Bus 侧改版本时同步改这里，或由流水线 dart-define 覆盖。
  // 任一为空时 App 只允许只读检测，禁止猜版本后注册。
  static const localCodingProfileVersionDefault = '2026.09.07.1';
  static const localCodingCodexProfileVersion = String.fromEnvironment(
    'LOCAL_CODING_CODEX_PROFILE_VERSION',
    defaultValue: localCodingProfileVersionDefault,
  );
  static const localCodingClaudeProfileVersion = String.fromEnvironment(
    'LOCAL_CODING_CLAUDE_PROFILE_VERSION',
    defaultValue: localCodingProfileVersionDefault,
  );

  static Map<String, String> localCodingProfileVersions() {
    final codex = localCodingCodexProfileVersion.trim();
    final claude = localCodingClaudeProfileVersion.trim();
    if (codex.isEmpty || claude.isEmpty) return const {};
    return {'codex_cli': codex, 'claude_cli': claude};
  }

  // 商业协议、OAuth、微信和推送配置只能经构建期 dart-define 提供；社区版可留空或提供自己的值。
  static const privacyPolicyUrl =
      String.fromEnvironment('PRIVACY_POLICY_URL', defaultValue: '');
  static const userAgreementUrl =
      String.fromEnvironment('USER_AGREEMENT_URL', defaultValue: '');
  static const paymentAgreementUrl =
      String.fromEnvironment('PAYMENT_AGREEMENT_URL', defaultValue: '');

  static const oauthAppId =
      String.fromEnvironment('OAUTH_APP_ID', defaultValue: '');
  static const oauthAppSecret =
      String.fromEnvironment('OAUTH_APP_SECRET', defaultValue: '');
  static const oauthRedirectUri =
      String.fromEnvironment('OAUTH_REDIRECT_URI', defaultValue: '');

  static const wechatAppId =
      String.fromEnvironment('WECHAT_APP_ID', defaultValue: '');
  static const wechatUniversalLink =
      String.fromEnvironment('WECHAT_UNIVERSAL_LINK', defaultValue: '');

  static const umengAndroidAppKey =
      String.fromEnvironment('UMENG_ANDROID_APP_KEY', defaultValue: '');
  static const umengAndroidMessageSecret =
      String.fromEnvironment('UMENG_ANDROID_MESSAGE_SECRET', defaultValue: '');
  static const umengIosAppKey =
      String.fromEnvironment('UMENG_IOS_APP_KEY', defaultValue: '');
}
