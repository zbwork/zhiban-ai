import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/im_credentials_storage.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_core/utils/error_utils.dart';
import 'package:zhiban_client/services/device_info_service.dart';


typedef IMDeviceInfoCollector = Future<LoginDeviceInfo> Function();

/// F09 IM 凭证：调 `POST /api/agent-bus/v1/im/credentials` 拿 WuKongIM 接入参数。
///
/// 详见 docs/contracts/agent-bus-client-contract.md。
class IMCredentials {
  IMCredentials({
    required this.imRefreshToken,
    required this.imRefreshExpires,
    required this.wukong,
  });

  final String imRefreshToken;
  final DateTime imRefreshExpires;
  final ImConnInfo? wukong;

  factory IMCredentials.fromJson(Map<String, dynamic> json) {
    final expires = DateTime.tryParse(
          (json['im_refresh_expires_at'] ?? '').toString(),
        )?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return IMCredentials(
      imRefreshToken: (json['im_refresh_token'] ?? '').toString(),
      imRefreshExpires: expires,
      wukong: ImConnInfo.fromCredentialsJson(json),
    );
  }

  bool get isRefreshFresh =>
      imRefreshExpires.isAfter(DateTime.now().toUtc().add(
            const Duration(minutes: 5)),
          );
}

/// IM 凭证调用过程中的业务异常 (HTTP 4xx/5xx 已被 Bus 包装成 encode.Error，
/// ResponseInterceptor 把它转成 DioException; 这里再做一层 wrap 让上层只看
/// 业务码而不必关心 transport 细节)。
class IMCredentialsException implements Exception {
  IMCredentialsException(this.code, [this.message]);

  /// 与后端 imCredErr code 对齐: imcred.rate_limited / imcred.refresh_expired /
  /// imcred.device_mismatch / imcred.refresh_invalid / imcred.cross_tenant /
  /// imcred.*_disabled / imcred.*_upstream / unknown.
  final String code;
  final String? message;

  bool get isRetryable => code.endsWith('_upstream');
  bool get needsReLogin =>
      code == 'imcred.refresh_expired' ||
      code == 'imcred.device_mismatch' ||
      code == 'imcred.refresh_invalid' ||
      code == 'imcred.cross_tenant';

  @override
  String toString() => 'IMCredentialsException($code, $message)';
}

/// 调用 Bus `/im/credentials` 颁发 / 刷新 IM refresh token 与 WuKong 连接信息。
///
/// 调用顺序：先尝试 refresh（带 im_refresh_token），未携带 refresh 或
/// refresh 报 401/refresh_invalid 时回落到 issue（不带 refresh，让后端用
/// authT 已校验过的 session 重新签发）。
///
/// **错误分类**：后端 401 / 403 / 429 由 ResponseInterceptor 抛 DioException，
/// 此处统一转 [IMCredentialsException]；其余网络层异常原样上抛。
class IMCredentialsClient {
  IMCredentialsClient({
    IMCredentialsStorage? storage,
    Dio? dio,
    IMDeviceInfoCollector? deviceInfoCollector,
  })  : _storage = storage ?? IMCredentialsStorage(),
        _dio = dio ?? request,
        _deviceInfoCollector = deviceInfoCollector ?? collectLoginDeviceInfo;

  final IMCredentialsStorage _storage;
  final Dio _dio;
  final IMDeviceInfoCollector _deviceInfoCollector;

  /// 当前进程内的最近一次凭证，避免登陆界面切换时反复调接口。
  IMCredentials? _cached;

  IMCredentials? get cachedCredentials => _cached;

  String _detectPlatform() {
    if (kIsWeb) return 'Web';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return 'Web';
  }

  /// 首次登录后调用：不传 refresh，让 Bus 直接颁发。
  Future<IMCredentials> issue() async {
    final deviceID = await _storage.getOrCreateDeviceId();
    final platform = _detectPlatform();
    return _post(
      deviceID: deviceID,
      platform: platform,
      refresh: false,
      refreshToken: null,
    );
  }

  /// 已有 refresh_token 时使用：服务端用 HMAC + Redis 索引校验后续签。
  /// 失败时（401 类）会清掉本地 refresh 并回退到 [issue]。
  Future<IMCredentials> refresh() async {
    final deviceID = await _storage.getOrCreateDeviceId();
    final platform = _detectPlatform();
    final refreshToken = await _storage.readRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      return issue();
    }
    try {
      return await _post(
        deviceID: deviceID,
        platform: platform,
        refresh: true,
        refreshToken: refreshToken,
      );
    } on IMCredentialsException catch (e) {
      if (e.needsReLogin) {
        await _storage.clearTokens();
        return issue();
      }
      rethrow;
    }
  }

  /// 高层调用：先看缓存 → 还在有效期内直接返；否则用 refresh 拿新一份。
  Future<IMCredentials> ensure() async {
    final cached = _cached;
    if (cached != null && cached.isRefreshFresh) return cached;
    return refresh();
  }

  Future<void> invalidateCache() async {
    _cached = null;
  }

  /// ADR-0026: 取 WuKong 连接信息(解析 /im/credentials 响应里的 `wukong` 段)。
  /// wukong 未启用(响应无该段)时抛 IMCredentialsException('wukong_disabled')。
  Future<ImConnInfo> fetchWukongConnInfo() async {
    final cred = await refresh();
    final info = cred.wukong;
    if (info == null) {
      throw IMCredentialsException(
        'wukong_disabled',
        'response has no wukong conn info (wukong.enabled?)',
      );
    }
    return info;
  }

  /// 清空全部本地状态（注销 / 切租户）。**不**额外调远端 revoke：
  /// 退登流程的 `/auth/logout` 已在后端触发 imcredSvc.Revoke。
  Future<void> clearLocal() async {
    _cached = null;
    await _storage.clearTokens();
  }

  Future<IMCredentials> _post({
    required String deviceID,
    required String platform,
    required bool refresh,
    required String? refreshToken,
  }) async {
    final deviceInfo = await _deviceInfoCollector();
    final body = <String, dynamic>{
      'device_id': deviceID,
      'platform': platform,
      if (deviceInfo.appVersion.trim().isNotEmpty)
        'client_version': deviceInfo.appVersion.trim(),
      if (deviceInfo.systemVersion.trim().isNotEmpty)
        'os_version': deviceInfo.systemVersion.trim(),
      if (refresh) 'refresh': true,
      if (refresh && refreshToken != null && refreshToken.isNotEmpty)
        'im_refresh_token': refreshToken,
    };
    final Response<dynamic> resp;
    try {
      resp = await _dio.post('/im/credentials',
          data: body,
          options: Options(
              receiveTimeout: const Duration(seconds: 15),
              extra: {'silent': true, 'pageRead': true}));
    } on DioException catch (e) {
      // 保留网络错误类型，供冷启动连接状态识别；业务错误仍映射业务码。
      if (isTransientNetworkError(e) ||
          e.type == DioExceptionType.cancel ||
          e.type == DioExceptionType.badCertificate ||
          (e.response?.statusCode ?? 0) >= 500) {
        rethrow;
      }
      throw _mapDioErr(e);
    }
    final raw = resp.data;
    if (raw is! Map<String, dynamic>) {
      throw IMCredentialsException(
        'unknown',
        'unexpected response shape: ${raw.runtimeType}',
      );
    }
    // ResponseInterceptor 已 unwrap business envelope; 这里直接当业务体处理。
    final cred = IMCredentials.fromJson(raw);
    _cached = cred;
    if (cred.imRefreshToken.isNotEmpty) {
      await _storage.writeRefreshToken(
        refreshToken: cred.imRefreshToken,
        expiresAt: cred.imRefreshExpires,
      );
    }
    return cred;
  }

  IMCredentialsException _mapDioErr(DioException err) {
    // ResponseInterceptor 把业务失败包成 DioException(error: message)，
    // 同时把 ResDataModel.data unwrap 到 response.data，所以业务码主要在 message。
    final msg = (err.error?.toString() ?? err.message ?? '').trim();
    String code = 'unknown';
    final m = RegExp(r'imcred\.[a-z_]+').firstMatch(msg);
    if (m != null) {
      code = m.group(0)!;
    } else {
      // 兜底：401 / 403 / 429 仍能让上层走 needsReLogin / 重试分支。
      final status = err.response?.statusCode;
      if (status == 401) code = 'imcred.refresh_invalid';
      if (status == 403) code = 'imcred.cross_tenant';
      if (status == 429) code = 'imcred.rate_limited';
    }
    return IMCredentialsException(code, msg.isEmpty ? null : msg);
  }
}
