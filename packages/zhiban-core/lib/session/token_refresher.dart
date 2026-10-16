import 'dart:async';

import 'package:dio/dio.dart';
import '../network/request_interceptor.dart';

/// 续期结果三态：ok=换到新对; invalid=refresh token 已失效/撤销(判定性, 该清凭证);
/// networkError=网络/服务端 5xx(非判定性, 保留凭证下次再试, 不能据此登出)。
enum RefreshOutcome { ok, invalid, networkError }

/// access token 静默续期(单飞)。
///
/// - 服务端 /auth/token/refresh 会旋转 refresh token(带 60s 宽限窗, 迁移 000134):
///   持久化新对必须在返回 ok 之前完成, 避免"续期成功但没存上"。
/// - 用独立 Dio 实例(不挂业务拦截器): 共享实例的 401 处理/响应外壳解析会造成递归。
/// - 单飞: 并发多个请求同时撞 401 时只发一次续期, 其余等同一结果。
class TokenRefresher {
  TokenRefresher({
    required this.apiUrl,
    required this.readRefreshToken,
    required this.persistTokens,
    this.log,
    Dio Function(BaseOptions)? createDio,
  }) : _createDio = createDio ?? Dio.new;

  final String Function() apiUrl;
  final Future<String?> Function() readRefreshToken;
  final Future<void> Function(String accessToken, String? refreshToken)
  persistTokens;
  final void Function(String message)? log;
  final Dio Function(BaseOptions) _createDio;
  Future<RefreshOutcome>? _inflight;

  Future<RefreshOutcome> refresh() {
    return _inflight ??= _doRefresh().whenComplete(() => _inflight = null);
  }

  Future<RefreshOutcome> _doRefresh() async {
    final refreshToken = await readRefreshToken() ?? '';
    if (refreshToken.isEmpty) return RefreshOutcome.invalid;
    try {
      final dio = _createDio(
        BaseOptions(
          baseUrl: apiUrl(),
          headers: {'X-API-Version': '2.0'},
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 15),
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final resp = await dio.post(
        '/auth/token/refresh',
        data: <String, dynamic>{'refreshToken': refreshToken},
      );
      final map = resp.data is Map
          ? (resp.data as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      final data =
          (map['data'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final access = (data['accessToken'] ?? '').toString();
      final newRefresh = (data['refreshToken'] ?? '').toString();
      if (resp.statusCode == 200 &&
          map['success'] == true &&
          access.isNotEmpty) {
        await persistTokens(access, newRefresh.isEmpty ? null : newRefresh);
        RequestInterceptor.clearTokenCache();
        RequestInterceptor.primeToken(access);
        return RefreshOutcome.ok;
      }
      // 4xx / success:false = refresh token 无效/过期/已撤销。
      log?.call('[auth] token refresh rejected: http=${resp.statusCode}');
      return RefreshOutcome.invalid;
    } on DioException catch (e) {
      final status = e.response?.statusCode ?? 0;
      if (status >= 400 && status < 500) return RefreshOutcome.invalid;
      log?.call('[auth] token refresh network error: ${e.type}');
      return RefreshOutcome.networkError;
    } catch (e) {
      log?.call('[auth] token refresh unexpected error: ${e.runtimeType}');
      return RefreshOutcome.networkError;
    }
  }
}
