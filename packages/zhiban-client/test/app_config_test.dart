import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/config/app_config.dart';

void main() {
  tearDown(() => AppConfig.applyEnvOverride(null));

  test('production environment uses the public service endpoints', () {
    AppConfig.applyEnvOverride(AppEnv.prod);

    expect(
      AppConfig.apiUrl(),
      'https://zb.qkfintech.cn/api/agent-bus/v1'
    );
    expect(
      AppConfig.adminWebUrl(),
      'https://zb-console.qkfintech.cn'
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
