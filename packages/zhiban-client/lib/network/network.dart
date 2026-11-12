import 'package:dio/dio.dart';
import '../config/app_config.dart';
// import 'package:pretty_dio_logger/pretty_dio_logger.dart';
import 'package:zhiban_core/network/auth_refresh_interceptor.dart';
import '../services/session_runtime.dart';
import 'interceptor/response_interceptor.dart';

class Request {
  static Request? _instance;
  static Request? _sensitiveInstance;
  static Request get instance => _instance ??= Request._internal();
  static Request get sensitiveInstance =>
      _sensitiveInstance ??= Request._internal();

  static void resetForConnection() {
    _instance?.dio.close(force: true);
    _sensitiveInstance?.dio.close(force: true);
    _instance = null;
    _sensitiveInstance = null;
    resetConnectionTokenRefresher();
  }

  Request._internal() {
    final epoch = AppConfig.connectionEpoch;
    final refresher = tokenRefresher;
    // dio.interceptors
    //     .add(PrettyDioLogger(requestBody: true, responseBody: true));
    dio.interceptors.add(createRequestInterceptor());
    dio.interceptors.add(ResponseInterceptor());
    // 必须在 ResponseInterceptor 之后: 它消费前者标记的 unauthorized 错误做静默续期重试。
    dio.interceptors.add(AuthRefreshInterceptor(
      dio,
      refresh: refresher.refresh,
      forceLogout: () {
        if (isCurrentConnection(epoch)) ResponseInterceptor.forceLogout();
      },
    ));
  }
  final dio = Dio(
    BaseOptions(
      headers: {"X-API-Version": "2.0"},
      // OpenClaw 流式回答场景：reasoning + 多张生图 + 上传 S3，单次响应里
      // 任何一段长 IO（>180s 模型 thinking、生图模型重试）都会卡 receiveTimeout。
      // 现实测的最差临界是 ~150s，留 5x 余量足够，又能在真死锁时报出来。
      // 后续若加 server-side SSE heartbeat（每 N 秒发心跳事件）可以把这值再调小。
      connectTimeout: const Duration(seconds: 180),
      receiveTimeout: const Duration(seconds: 900),
      sendTimeout: const Duration(seconds: 180),
      // Let 4xx responses enter onResponse for unified business handling.
      validateStatus: (status) => status != null && status < 500,
    ),
  );
}

Dio get request => Request.instance.dio;

/// 凭据、DPoP、JWK 等敏感请求专用。保留统一认证/错误/续期逻辑，但永不进入
/// 调试采集器，避免一次性 secret 留在进程内网络面板缓存。
Dio get sensitiveRequest => Request.sensitiveInstance.dio;
