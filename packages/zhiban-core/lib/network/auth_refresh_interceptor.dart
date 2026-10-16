import 'package:dio/dio.dart';
import 'request_interceptor.dart';
import 'public_auth_paths.dart';
import '../session/token_refresher.dart';

/// 401 静默续期重试。挂在 ResponseInterceptor 之后:
/// ResponseInterceptor 在 onResponse 里把两类未授权(HTTP 401 / 外壳 code=4010)标记进
/// extra['unauthorized'] 后抛错, 错误流到这里统一处理——续期成功重放原请求,
/// 判定性失败(refresh token 也无效)才走强制登出。
class AuthRefreshInterceptor extends Interceptor {
  AuthRefreshInterceptor(
    this._dio, {
    required this.refresh,
    required this.forceLogout,
  });

  final Future<RefreshOutcome> Function() refresh;
  final void Function() forceLogout;

  final Dio _dio;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final opts = err.requestOptions;
    final was401 =
        err.response?.statusCode == 401 || opts.extra['unauthorized'] == true;
    if (!was401 ||
        isPublicAuthRequestPath(opts.path) ||
        opts.path.endsWith('/auth/token/refresh') ||
        opts.extra['authRetried'] == true) {
      handler.next(err);
      return;
    }
    final outcome = await refresh();
    if (outcome == RefreshOutcome.invalid) {
      forceLogout();
      handler.next(err);
      return;
    }
    if (outcome != RefreshOutcome.ok) {
      // 网络性失败: 不登出, 原错误透传(调用方按普通失败处理)。
      handler.next(err);
      return;
    }
    // FormData / 流式请求体不可重放: 续期已成功(token 已换新), 原错误透传, 用户重试即成功。
    if (opts.data is FormData || opts.responseType == ResponseType.stream) {
      handler.next(err);
      return;
    }
    try {
      opts.extra['authRetried'] = true;
      final token = RequestInterceptor.cachedToken;
      if (token != null && token.isNotEmpty) {
        // RequestInterceptor 合并 headers 时 options.headers 优先, 必须显式覆盖旧 Authorization。
        opts.headers['Authorization'] = 'Bearer $token';
      }
      final resp = await _dio.fetch<dynamic>(opts);
      handler.resolve(resp);
    } on DioException catch (retryErr) {
      handler.next(retryErr);
    } catch (_) {
      handler.next(err);
    }
  }
}
