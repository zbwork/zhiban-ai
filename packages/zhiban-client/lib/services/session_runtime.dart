import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_core/network/request_interceptor.dart';
import 'package:zhiban_core/session/token_refresher.dart';

import '../config/app_config.dart';

/// Platform storage/configuration is composed here, never imported by core.
RequestInterceptor createRequestInterceptor() => _ConnectionInterceptor();

bool isCurrentConnection(int epoch) =>
    epoch == AppConfig.connectionEpoch && !AppConfig.connectionChanging;

class _ConnectionInterceptor extends RequestInterceptor {
  _ConnectionInterceptor()
      : epoch = AppConfig.connectionEpoch,
        address = AppConfig.apiUrl(),
        super(apiUrl: AppConfig.apiUrl, readAccessToken: _readToken);
  final int epoch;
  final String address;

  @override
  Future<Map<String, dynamic>> getHeader() async {
    final token = await readAccessToken();
    if (!isCurrentConnection(epoch)) return {};
    RequestInterceptor.primeToken(token);
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token'
    };
  }

  static Future<String?> _readToken() async {
    final epoch = AppConfig.connectionEpoch;
    final prefs = await SharedPreferences.getInstance();
    return isCurrentConnection(epoch)
        ? prefs.getString(AppConfig.storageTokenKey)
        : null;
  }

  DioException _stale(RequestOptions options) => DioException(
      requestOptions: options,
      type: DioExceptionType.cancel,
      message: '工作区已切换');

  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    if (!isCurrentConnection(epoch)) {
      handler.reject(_stale(options));
      return;
    }
    final headers = await getHeader();
    if (!isCurrentConnection(epoch)) {
      handler.reject(_stale(options));
      return;
    }
    options.baseUrl = address;
    options.headers = {...headers, ...options.headers};
    if (options.extra['pageRead'] == true) {
      options.connectTimeout = const Duration(seconds: 15);
    }
    if (AppConfig.serverWorkspace) options.followRedirects = false;
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (!isCurrentConnection(epoch)) {
      handler.reject(_stale(response.requestOptions));
      return;
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    handler.next(isCurrentConnection(epoch) ? err : _stale(err.requestOptions));
  }
}

TokenRefresher _createTokenRefresher() {
  final epoch = AppConfig.connectionEpoch;
  final address = AppConfig.apiUrl();
  return TokenRefresher(
    isCurrent: () => isCurrentConnection(epoch),
    apiUrl: () => address,
    readRefreshToken: () async {
      final prefs = await SharedPreferences.getInstance();
      if (!isCurrentConnection(epoch)) return null;
      return prefs.getString(AppConfig.storageRefreshTokenKey);
    },
    persistTokens: (access, refresh) =>
        withConnectionCredentials(epoch, () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConfig.storageTokenKey, access);
      if (refresh != null) {
        await prefs.setString(AppConfig.storageRefreshTokenKey, refresh);
      }
      if (!isCurrentConnection(epoch)) throw StateError('工作区已切换');
    }),
    log: (message) => debugPrint(message),
    createDio: (options) => Dio(options..followRedirects = false),
  );
}

/// Reset on workspace changes; an old refresh cannot persist into a new session.
TokenRefresher? _tokenRefresher;
TokenRefresher get tokenRefresher =>
    _tokenRefresher ??= _createTokenRefresher();
void resetConnectionTokenRefresher() => _tokenRefresher = null;

Future<void> _credentialWrites = Future.value();

/// Switching fences new writes, then drains any write already in progress before
/// clearing storage. This includes SharedPreferences platform acknowledgements.
Future<T> withConnectionCredentials<T>(int epoch, Future<T> Function() write) {
  final result = _credentialWrites.then((_) {
    if (!isCurrentConnection(epoch)) throw StateError('工作区已切换');
    return write();
  });
  _credentialWrites = result.then<void>((_) {}, onError: (Object _) {});
  return result;
}

Future<void> drainConnectionCredentials() => _credentialWrites;

/// The entry point supplies mobile push; desktop sessions have no push effects.
class SessionPushLifecycle {
  const SessionPushLifecycle({this.start = _noop, this.revoke = _noop});
  final Future<void> Function() start;
  final Future<void> Function() revoke;
  static Future<void> _noop() async {}
}

SessionPushLifecycle sessionPushLifecycle = const SessionPushLifecycle();
