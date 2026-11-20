import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/login/services/auth_api.dart';
import 'package:zhiban_client/services/device_info_service.dart';

const _callbackPath = '/oauth/callback';
const _oidcPath = '/auth/login/oidc';

class DesktopIdentityProvider {
  const DesktopIdentityProvider(this.uuid, this.name);

  final String uuid;
  final String name;

  static Future<List<DesktopIdentityProvider>> list() async {
    final client = _newClient(AppConfig.apiUrl());
    try {
      final response = await client.get<Map<String, dynamic>>(
        '/auth/identity-providers/public',
      );
      final items = _data(response)['items'] as List<dynamic>;
      return [
        for (final item in items.whereType<Map<String, dynamic>>())
          if (item['kind'] == 'oidc' &&
              item['uuid'] is String &&
              item['name'] is String)
            DesktopIdentityProvider(
                item['uuid'] as String, item['name'] as String),
      ];
    } finally {
      client.close(force: true);
    }
  }
}

Dio _newClient(String baseUrl) => Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      followRedirects: false,
      validateStatus: (status) => status != null && status < 500,
    ));

Map<String, dynamic> _data(Response<Map<String, dynamic>> response) {
  final data = response.data;
  if (data?['success'] == true && data?['data'] is Map<String, dynamic>) {
    return data!['data'] as Map<String, dynamic>;
  }
  final message = data?['message'];
  throw DesktopEnterpriseLoginError(
    message is String && message.isNotEmpty ? message : '服务器未能完成企业登录',
  );
}

class DesktopEnterpriseLoginError implements Exception {
  const DesktopEnterpriseLoginError(this.message);
  final String message;
}

/// Each attempt owns its loopback socket and its short-lived same-origin cookies.
class DesktopEnterpriseLogin {
  DesktopEnterpriseLogin() : _client = _newClient(AppConfig.apiUrl());

  final Dio _client;
  final _callback = Completer<Uri?>();
  HttpServer? _server;

  Future<AuthLoginResult?> run(DesktopIdentityProvider provider) async {
    final epoch = AppConfig.connectionEpoch;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      if (_callback.isCompleted) return null;
      final authority = '127.0.0.1:${server.port}';
      final redirect = 'http://$authority$_callbackPath';
      final reply = await _client.post<Map<String, dynamic>>(
        '$_oidcPath/start',
        data: {'providerUuid': provider.uuid, 'desktopRedirect': redirect},
      );
      final start = _data(reply);
      final cookies = <String, String>{};
      for (final value
          in reply.headers[HttpHeaders.setCookieHeader] ?? <String>[]) {
        final cookie = Cookie.fromSetCookieValue(value);
        if (cookie.name == 'zhiban_oidc_state' ||
            cookie.name == 'zhiban_oidc_desktop') {
          cookies[cookie.name] = cookie.value;
        }
      }
      final authUrl = Uri.tryParse(start['authUrl'] as String? ?? '');
      final state = start['state'] as String? ?? '';
      if (authUrl == null ||
          !_allowedAuthURL(authUrl) ||
          authUrl.queryParameters['state'] != state ||
          authUrl.queryParameters['redirect_uri'] != redirect ||
          authUrl.queryParameters['code_challenge_method'] != 'S256' ||
          state.isEmpty ||
          cookies.length != 2 ||
          cookies['zhiban_oidc_state'] != state) {
        throw const DesktopEnterpriseLoginError('服务器返回的企业登录信息无效');
      }
      server.listen((request) {
        final params = request.uri.queryParameters;
        final valid = request.method == 'GET' &&
            request.headers.value(HttpHeaders.hostHeader) == authority &&
            request.uri.path == _callbackPath &&
            params['state'] == state &&
            (params['code']?.isNotEmpty == true || params.containsKey('error'));
        request.response
          ..statusCode = valid ? HttpStatus.ok : HttpStatus.notFound
          ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
          ..headers.set('Referrer-Policy', 'no-referrer')
          ..headers.contentType = ContentType.text
          ..write(valid ? '已返回知办AI，请切回桌面应用查看登录结果。' : '无效的登录回调。');
        unawaited(request.response.close());
        if (valid && !_callback.isCompleted) _callback.complete(request.uri);
      });
      if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
        throw const DesktopEnterpriseLoginError('无法打开系统浏览器');
      }
      final result = await _callback.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw const DesktopEnterpriseLoginError('企业登录已超时，请重试'),
      );
      if (result == null) return null;
      final code = result.queryParameters['code'];
      if (code == null || code.isEmpty) {
        throw const DesktopEnterpriseLoginError('企业登录已取消或被拒绝');
      }
      final device = await collectLoginDeviceInfo();
      final finish = await _client.post<Map<String, dynamic>>(
        '$_oidcPath/callback',
        data: {'code': code, 'state': state, 'device': device.toJson()},
        options: Options(headers: {
          HttpHeaders.cookieHeader:
              cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
        }),
      );
      final login = AuthLoginResult.fromJson(_data(finish));
      if (!_callback.isCompleted ||
          login.accessToken.isEmpty ||
          login.actScope.kind != 'tenant') {
        throw const DesktopEnterpriseLoginError('未取得企业会话');
      }
      if (_cancelled) return null;
      await persistEnterpriseLogin(login, expectedEpoch: epoch);
      return login;
    } finally {
      _client.close(force: true);
      await _server?.close(force: false);
    }
  }

  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    if (!_callback.isCompleted) _callback.complete(null);
    _client.close(force: true);
    unawaited(_server?.close(force: true));
  }

  static bool _allowedAuthURL(Uri uri) =>
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (uri.scheme == 'https' ||
          (uri.scheme == 'http' &&
              (uri.host == '127.0.0.1' ||
                  uri.host == 'localhost' ||
                  uri.host.endsWith('.localhost'))));
}
