import 'dart:io';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only connection metadata is saved here; sessions and local content stay out.
class ServerConnection {
  static const addressKey = 'community_server_address_v1';
  static const apiPath = '/api/agent-bus/v1';

  static String normalize(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException('请输入完整的 HTTP 或 HTTPS 服务器地址，不要包含账号、参数或片段');
    }
    if (uri.scheme == 'http' && !_privateHost(uri.host)) {
      throw const FormatException('公网服务器请使用 HTTPS；HTTP 仅用于本机或局域网调试');
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.isNotEmpty && path != apiPath) {
      throw const FormatException('请填写服务器根地址，或以 /api/agent-bus/v1 结尾的地址');
    }
    return uri.replace(path: apiPath).toString();
  }

  static bool _privateHost(String host) {
    if (host.toLowerCase() == 'localhost' || host == '::1' || host == '[::1]') {
      return true;
    }
    final ip = InternetAddress.tryParse(host);
    if (ip == null || ip.type != InternetAddressType.IPv4) return false;
    final b = ip.rawAddress;
    return b[0] == 127 ||
        b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }

  static Future<String?> savedAddress() async {
    final raw = (await SharedPreferences.getInstance()).getString(addressKey);
    if (raw == null) return null;
    try {
      return normalize(raw);
    } on FormatException {
      return null;
    }
  }

  static Future<void> save(String address) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(addressKey, normalize(address))) {
      throw const FormatException('服务器地址保存失败，请重试');
    }
  }

  /// Independent anonymous client: never use the authenticated Request singleton.
  static Future<String> probe(String input, {Dio? client}) async {
    final address = normalize(input);
    final dio = client ?? Dio();
    try {
      final response = await dio
          .get<Object?>('$address/auth/captcha',
              options: Options(
                followRedirects: false,
                receiveTimeout: const Duration(seconds: 8),
                sendTimeout: const Duration(seconds: 8),
                validateStatus: (_) => true,
              ))
          .timeout(const Duration(seconds: 8));
      final body = response.data;
      final data = body is Map ? body['data'] : null;
      if (response.statusCode != 200 ||
          body is! Map ||
          body['success'] != true ||
          data is! Map ||
          data['captchaId'] is! String ||
          (data['captchaId'] as String).isEmpty ||
          ![data['captchaImage'], data['captchaBase64']]
              .any((value) => value is String && value.isNotEmpty)) {
        throw const FormatException('未识别到兼容的登录接口，请检查 Bus 地址与服务部署');
      }
      return address;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('无法连接服务器，请检查地址、网络或证书后重试');
    } finally {
      dio.close(force: true);
    }
  }
}
