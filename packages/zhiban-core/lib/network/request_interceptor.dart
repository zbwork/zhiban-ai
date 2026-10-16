import 'package:dio/dio.dart';

/// 请求拦截器
class RequestInterceptor extends Interceptor {
  RequestInterceptor({required this.apiUrl, required this.readAccessToken});

  final String Function() apiUrl;
  final Future<String?> Function() readAccessToken;
  static String? _tokenCache;

  /// 内存中的 token（首个请求后即有），供图片组件同步取认证头，避免 FutureBuilder 闪一帧 placeholder。
  static String? get cachedToken => _tokenCache;

  /// 启动 / 登录拿到 token 后主动预热，让首屏图片也能同步取头。
  static void primeToken(String? token) {
    if (token != null && token.isNotEmpty) _tokenCache = token;
  }

  static void clearTokenCache() {
    _tokenCache = null;
  }

  Future<Map<String, dynamic>> getHeader() async {
    String? token = _tokenCache;
    if (token == null || token.isEmpty) {
      token = await readAccessToken();
      if (token != null && token.isNotEmpty) {
        _tokenCache = token;
      }
    }

    return <String, dynamic>{
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    if (options.extra['pageRead'] == true) {
      options.connectTimeout = const Duration(seconds: 15);
    }
    var headers = await getHeader();
    options.headers = {...headers, ...options.headers};
    options.baseUrl = apiUrl();
    handler.next(options);
  }
}
