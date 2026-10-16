import 'package:shared_preferences/shared_preferences.dart';

import 'package:zhiban_client/config/app_config.dart';

/// 关于页隐藏入口写入的环境覆盖持久化。
///
/// 流程：
///   1. main() 启动调用 [load]，把 SP 里的值灌进 [AppConfig.applyEnvOverride]，
///      让本次进程的 [AppConfig.env] / [AppConfig.apiUrl] 都跟随覆盖。
///   2. 关于页选完新环境，调用 [save] 持久化、再清登录态、提示用户重启。
class EnvOverrideService {
  const EnvOverrideService._();

  static const _codeToEnv = <String, AppEnv>{
    'dev': AppEnv.dev,
    'test': AppEnv.test,
    'prod': AppEnv.prod,
  };

  /// 从 SP 读出覆盖值。SP 损坏或值不在枚举里时返回 null（不抛）。
  static Future<AppEnv?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(AppConfig.storageEnvOverrideKey);
    if (code == null || code.isEmpty) return null;
    return _codeToEnv[code];
  }

  /// 启动时一次性应用：读 SP → 写 AppConfig 内存。
  static Future<void> applyAtBootstrap() async {
    final env = await load();
    AppConfig.applyEnvOverride(env);
  }

  static Future<void> save(AppEnv env) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConfig.storageEnvOverrideKey, env.name);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConfig.storageEnvOverrideKey);
  }
}

extension AppEnvDisplay on AppEnv {
  String get displayName {
    switch (this) {
      case AppEnv.dev:
        return '开发环境 (Dev)';
      case AppEnv.test:
        return '测试环境 (Test)';
      case AppEnv.prod:
        return '生产环境 (Prod)';
    }
  }
}
