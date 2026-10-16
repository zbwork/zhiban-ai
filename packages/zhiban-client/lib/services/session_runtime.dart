import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_core/network/request_interceptor.dart';
import 'package:zhiban_core/session/token_refresher.dart';

import '../config/app_config.dart';

/// Platform storage/configuration is composed here, never imported by core.
RequestInterceptor createRequestInterceptor() => RequestInterceptor(
      apiUrl: AppConfig.apiUrl,
      readAccessToken: () async {
        final prefs = await SharedPreferences.getInstance();
        return prefs.getString(AppConfig.storageTokenKey);
      },
    );

/// One refresh flight is shared by the regular and sensitive business clients.
final tokenRefresher = TokenRefresher(
  apiUrl: AppConfig.apiUrl,
  readRefreshToken: () async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(AppConfig.storageRefreshTokenKey);
  },
  persistTokens: (access, refresh) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConfig.storageTokenKey, access);
    if (refresh != null) {
      await prefs.setString(AppConfig.storageRefreshTokenKey, refresh);
    }
  },
  log: (message) => debugPrint(message),
);

/// The entry point supplies mobile push; desktop sessions have no push effects.
class SessionPushLifecycle {
  const SessionPushLifecycle({this.start = _noop, this.revoke = _noop});
  final Future<void> Function() start;
  final Future<void> Function() revoke;
  static Future<void> _noop() async {}
}

SessionPushLifecycle sessionPushLifecycle = const SessionPushLifecycle();
