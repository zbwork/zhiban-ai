import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:zhiban_client/services/session_runtime.dart';

String _jwtWithIdentity({required int tenantId, required String accountUuid}) {
  String enc(Map<String, Object?> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${enc({'alg': 'none'})}.${enc({
        'act_tid': tenantId,
        'sub': accountUuid
      })}.sig';
}

AuthLoginResult _loginResult(String token) => AuthLoginResult(
      accessToken: token,
      refreshToken: 'refresh-next',
      account: const {'uuid': 'account-next'},
      actScope: const ScopeOption(kind: 'tenant', tenantId: 2),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    sessionPushLifecycle = const SessionPushLifecycle();
    configureSessionLogoutCleanup(null);
    debugRealtimeLogoutOverride = null;
    debugAuthRealtimeLogoutOverride = null;
    debugAuthClearImTokensOverride = null;
    debugAuthConnectedUidOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  test('clearSessionStorage logs out realtime IM state', () async {
    SharedPreferences.setMockInitialValues({
      AppConfig.storageTokenKey: 'token',
      AppConfig.storageRefreshTokenKey: 'refresh',
      AppConfig.storageAccountInfoKey: '{}',
      AppConfig.storageDashboardTokenKey: '{}',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    var realtimeLogoutCalls = 0;
    var deviceCleanupCalls = 0;
    var pushCleanupCalls = 0;
    sessionPushLifecycle = SessionPushLifecycle(revoke: () async {
      pushCleanupCalls++;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConfig.storageTokenKey), 'token');
      throw StateError('push revoke failed');
    });
    configureSessionLogoutCleanup(() async {
      deviceCleanupCalls++;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConfig.storageTokenKey), 'token');
    });
    debugRealtimeLogoutOverride = () async {
      realtimeLogoutCalls++;
    };

    await const SessionService().clearSessionStorage();

    expect(realtimeLogoutCalls, 1);
    expect(deviceCleanupCalls, 1);
    expect(pushCleanupCalls, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppConfig.storageTokenKey), isNull);
    expect(prefs.getString(AppConfig.storageAccountInfoKey), isNull);
  });

  test('device cleanup failure does not block clearing session tokens',
      () async {
    SharedPreferences.setMockInitialValues({
      AppConfig.storageTokenKey: 'token',
      AppConfig.storageRefreshTokenKey: 'refresh',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    configureSessionLogoutCleanup(() async {
      throw Exception('sanitized cleanup failure');
    });
    debugRealtimeLogoutOverride = () async {};

    await const SessionService().clearSessionStorage();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppConfig.storageTokenKey), isNull);
    expect(prefs.getString(AppConfig.storageRefreshTokenKey), isNull);
  });

  // v1.7 §8.1 · 登出必须先撤销本机设备授权、再清 token;失败也不能阻塞登出。
  // 这里断言:cleanup 在 prefs 被清之前调用(否则 Bus DELETE devices 就没 token 用了),
  // cleanup 抛错也不会向上传播,同时 token/refresh 都被清干净。
  test(
      'v1.7 §8.1 · local coding cleanup runs before token cleared and swallows errors',
      () async {
    SharedPreferences.setMockInitialValues({
      AppConfig.storageTokenKey: 'token-still-here',
      AppConfig.storageRefreshTokenKey: 'refresh-still-here',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    var cleanupCalls = 0;
    var cleanupHadToken = false;
    configureSessionLogoutCleanup(() async {
      cleanupCalls++;
      final prefs = await SharedPreferences.getInstance();
      cleanupHadToken =
          prefs.getString(AppConfig.storageTokenKey) == 'token-still-here';
      // 模拟 removeAuthorization 抛出(比如网络失败),不能阻塞登出。
      throw StateError('remote_revoke_pending');
    });
    debugRealtimeLogoutOverride = () async {};

    await const SessionService().clearSessionStorage();

    expect(cleanupCalls, 1);
    expect(cleanupHadToken, isTrue,
        reason: 'cleanup 必须先于 token 清除,否则撤销请求没凭据可用');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppConfig.storageTokenKey), isNull);
    expect(prefs.getString(AppConfig.storageRefreshTokenKey), isNull);
  });

  test('persistLoginResult logs out realtime IM before switching account uid',
      () async {
    final oldToken = _jwtWithIdentity(
      tenantId: 1,
      accountUuid: '796a2a0f-aa46-4c28-b788-8fc900862209',
    );
    final nextToken = _jwtWithIdentity(
      tenantId: 569,
      accountUuid: 'c2834fcd-0afa-4734-9c1a-e18e5fb24626',
    );
    SharedPreferences.setMockInitialValues({
      AppConfig.storageTokenKey: oldToken,
      AppConfig.storageRefreshTokenKey: 'refresh-old',
    });
    final prefs = await SharedPreferences.getInstance();
    final pushEvents = <String?>[];
    sessionPushLifecycle = SessionPushLifecycle(
      revoke: () async =>
          pushEvents.add(prefs.getString(AppConfig.storageTokenKey)),
      start: () async =>
          pushEvents.add(prefs.getString(AppConfig.storageTokenKey)),
    );
    var realtimeLogoutCalls = 0;
    var clearImTokenCalls = 0;
    debugAuthConnectedUidOverride =
        () => 't_1_u_796a2a0f-aa46-4c28-b788-8fc900862209';
    debugAuthRealtimeLogoutOverride = () async {
      realtimeLogoutCalls++;
    };
    debugAuthClearImTokensOverride = () async {
      clearImTokenCalls++;
    };

    await persistLoginResultForTest(_loginResult(nextToken));

    expect(realtimeLogoutCalls, 1);
    expect(clearImTokenCalls, 1);
    expect(pushEvents, [oldToken, nextToken]);
    expect(prefs.getString(AppConfig.storageTokenKey), nextToken);
    expect(prefs.getString(AppConfig.storageRefreshTokenKey), 'refresh-next');
  });

  test('persistLoginResult keeps realtime IM when account uid is unchanged',
      () async {
    final token = _jwtWithIdentity(
      tenantId: 1,
      accountUuid: '796a2a0f-aa46-4c28-b788-8fc900862209',
    );
    SharedPreferences.setMockInitialValues({
      AppConfig.storageTokenKey: token,
    });
    var realtimeLogoutCalls = 0;
    var clearImTokenCalls = 0;
    debugAuthConnectedUidOverride =
        () => 't_1_u_796a2a0f-aa46-4c28-b788-8fc900862209';
    debugAuthRealtimeLogoutOverride = () async {
      realtimeLogoutCalls++;
    };
    debugAuthClearImTokensOverride = () async {
      clearImTokenCalls++;
    };

    await persistLoginResultForTest(_loginResult(token));

    expect(realtimeLogoutCalls, 0);
    expect(clearImTokenCalls, 0);
  });
}
