import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/config/app_config.dart';

void main() {
  test('two environment files preserve shared settings and runtime switching',
      () {
    const expectedName = String.fromEnvironment(
      'CONFIG_MIGRATION_EXPECTED_ENV',
      defaultValue: 'test',
    );
    final expectedEnv = expectedName == 'prod' ? AppEnv.prod : AppEnv.test;
    expect(AppConfig.env, expectedEnv);

    void expectEndpoints(AppEnv env) {
      final name = env == AppEnv.prod ? 'production' : 'test';
      expect(AppConfig.apiUrl(),
          'https://$name.example.invalid/a?x=hello world&y=\$literal#fragment');
      expect(AppConfig.adminWebUrl(), 'https://$name-admin.example.invalid');
    }

    expectEndpoints(expectedEnv);
    expect(AppConfig.privacyPolicyUrl, 'https://example.invalid/privacy');
    expect(AppConfig.userAgreementUrl, 'https://example.invalid/terms');
    expect(AppConfig.paymentAgreementUrl, 'https://example.invalid/payment');
    expect(AppConfig.oauthAppId, 'quoted app');
    expect(AppConfig.oauthAppSecret,
        r'$(touch /tmp/never-create-zhiban-p0) `echo inert` = & #');
    expect(AppConfig.oauthRedirectUri, 'fixture://login');
    expect(AppConfig.wechatAppId, isEmpty);
    expect(AppConfig.wechatUniversalLink, 'https://example.invalid/app/');
    expect(AppConfig.umengAndroidAppKey, 'fixture-android-key');
    expect(AppConfig.umengAndroidMessageSecret, 'fixture-message-secret');
    expect(AppConfig.umengIosAppKey, 'fixture-ios-key');

    for (final env in [AppEnv.test, AppEnv.prod]) {
      AppConfig.applyEnvOverride(env);
      expect(AppConfig.env, env);
      expectEndpoints(env);
    }
    AppConfig.applyEnvOverride(AppEnv.dev);
    expect(AppConfig.env, AppEnv.dev);
    AppConfig.applyEnvOverride(null);
    expect(AppConfig.env, expectedEnv);
    expectEndpoints(expectedEnv);
  }, skip: !const bool.fromEnvironment('CONFIG_MIGRATION_TEST'));
}
