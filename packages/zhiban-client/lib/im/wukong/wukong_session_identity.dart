import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:zhiban_client/config/app_config.dart';

class WukongSessionIdentity {
  const WukongSessionIdentity({
    required this.tenantId,
    required this.accountUuid,
  });

  final int tenantId;
  final String accountUuid;

  String get uid => 't_${tenantId}_u_$accountUuid';

  static Future<WukongSessionIdentity?> current() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(AppConfig.storageTokenKey);
    if (token == null || token.isEmpty) return null;
    return fromJwt(token);
  }

  static WukongSessionIdentity? fromJwt(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = utf8.decode(base64Url.decode(
        base64Url.normalize(parts[1])),
      );
      final json = jsonDecode(payload);
      if (json is! Map<String, dynamic>) return null;
      final tenantRaw = json['act_tid'];
      final tenant =
          tenantRaw is num ? tenantRaw.toInt() : int.tryParse('$tenantRaw');
      final accountUuid = (json['sub'] ?? '').toString().trim();
      if (tenant == null || tenant <= 0 || accountUuid.isEmpty) return null;
      return WukongSessionIdentity(
        tenantId: tenant,
        accountUuid: accountUuid
      );
    } catch (_) {
      return null;
    }
  }
}
