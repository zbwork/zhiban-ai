import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/config/app_config.dart';

void main() {
  tearDown(() => AppConfig.applyEnvOverride(null));

  test('production environment uses explicitly configured endpoints', () {
    AppConfig.applyEnvOverride(AppEnv.prod);

    expect(
      AppConfig.apiUrl(),
      const String.fromEnvironment('API_BASE_URL_PROD'),
    );
    expect(
      AppConfig.adminWebUrl(),
      const String.fromEnvironment('ADMIN_WEB_URL_PROD'),
    );
  });

  test('local coding tools entry and profile versions are on by default', () {
    // 常规构建（不传 dart-define）也要显示 F31 入口并能注册（2026-09-11）。
    expect(AppConfig.localCodingToolsEnabled, isTrue);
    expect(AppConfig.localCodingProfileVersions(), {
      'codex_cli': AppConfig.localCodingProfileVersionDefault,
      'claude_cli': AppConfig.localCodingProfileVersionDefault,
    });
  });
}
