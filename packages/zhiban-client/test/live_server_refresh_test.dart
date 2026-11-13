// Opt-in real Bus regression. Uses only the independent verification member.
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fixture = String.fromEnvironment('COMMUNITY_REFRESH_MEMBER_FIXTURE');
  test(
      'real scope switch preserves refresh; server 401 rotates and replays',
      () => HttpOverrides.runWithHttpOverrides(() async {
            SharedPreferences.setMockInitialValues({});
            final account =
                jsonDecode(await File(fixture).readAsString()) as Map;
            AppConfig.serverApiUrl = 'http://127.0.0.1:18080/api/agent-bus/v1';
            Request.resetForConnection();
            debugAuthConnectedUidOverride = () => null;
            debugAuthRealtimeLogoutOverride = () async {};
            debugAuthClearImTokensOverride = () async {};
            addTearDown(() {
              debugAuthConnectedUidOverride = null;
              debugAuthRealtimeLogoutOverride = null;
              debugAuthClearImTokensOverride = null;
              Request.resetForConnection();
              AppConfig.serverApiUrl = null;
            });
            await loginWithPasswordApi(
                identifier: account['Email'] as String,
                password: account['Password'] as String);
            final prefs = await SharedPreferences.getInstance();
            final before = prefs.getString(AppConfig.storageRefreshTokenKey);
            expect(before?.isNotEmpty, true);
            await switchToTenantApi(1);
            expect(prefs.getString(AppConfig.storageRefreshTokenKey) == before,
                true);
            var forced = false;
            var server401 = false;
            var requests = 0;
            final injection =
                InterceptorsWrapper(onRequest: (options, handler) {
              if (options.path == '/contacts/tree') {
                requests++;
                if (!forced) {
                  forced = true;
                  options.headers['Authorization'] =
                      'Bearer expired-test-access';
                }
              }
              handler.next(options);
            }, onResponse: (response, handler) {
              if (response.requestOptions.path == '/contacts/tree' &&
                  response.statusCode == 401) {
                server401 = true;
              }
              handler.next(response);
            });
            request.interceptors.insert(1, injection);
            final response = await request.get('/contacts/tree');
            request.interceptors.remove(injection);
            expect(response.statusCode, 200);
            expect(server401, true);
            expect(requests, 2);
            final after = prefs.getString(AppConfig.storageRefreshTokenKey);
            expect(after?.isNotEmpty, true);
            expect(after != before, true);
            final me = await request.get('/auth/me');
            expect(me.statusCode, 200);
          }, _RealHttp()),
      skip: fixture.isEmpty
          ? 'Requires an explicit private independent-member fixture'
          : false);
}
