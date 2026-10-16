import 'package:dio/dio.dart';

import '../models/ai_endpoint_type.dart';

class ProviderKeyTestResult {
  const ProviderKeyTestResult.ok(this.message) : ok = true;
  const ProviderKeyTestResult.fail(this.message) : ok = false;

  final bool ok;
  final String message;
}

/// 用 API Key 直连服务商探测一次连通性/密钥有效性。
///
/// 只是"能不能连上、Key 对不对"的轻量探测，不代表完整可用（比如某些自定义
/// 协议没有稳定可探测的端点）。**故意不用 [Request.instance.dio]**——那个单例
/// 挂了发给 agent-bus 平台自己的 Authorization 拦截器，直接拿去打第三方厂商
/// 会把平台会话 token 泄漏出去；这里用一个干净、无拦截器的临时 Dio 实例。
class ProviderKeyTester {
  const ProviderKeyTester();

  Future<ProviderKeyTestResult> test({
    required AiEndpointType endpointType,
    required String baseUrl,
    required String apiKey,
  }) async {
    final trimmedBase = baseUrl.trim();
    final trimmedKey = apiKey.trim();
    if (trimmedBase.isEmpty) {
      return const ProviderKeyTestResult.fail('请先填写 API 地址');
    }
    if (trimmedKey.isEmpty) {
      return const ProviderKeyTestResult.fail('请先填写 API 密钥');
    }

    switch (endpointType) {
      case AiEndpointType.openaiCompatible:
        return _get(
          url: '${_stripSlash(trimmedBase)}/models',
          headers: {'Authorization': 'Bearer $trimmedKey'},
        );
      case AiEndpointType.anthropicMessages:
        final base = _stripSlash(trimmedBase);
        final url = base.endsWith('/v1') ? '$base/models' : '$base/v1/models';
        return _get(
          url: url,
          headers: {
            'x-api-key': trimmedKey,
            'anthropic-version': '2023-06-01'
          },
        );
      case AiEndpointType.googleGenerativeAi:
        final base = _stripSlash(trimmedBase);
        final url = base.endsWith('/v1beta') ? '$base/models' : '$base/v1beta/models';
        return _get(url: url, queryParameters: {'key': trimmedKey});
      case AiEndpointType.custom:
        return const ProviderKeyTestResult.fail('自定义协议暂不支持自动检测，请手动确认密钥可用');
    }
  }

  Future<ProviderKeyTestResult> _get({
    required String url,
    Map<String, String>? headers,
    Map<String, String>? queryParameters,
  }) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
        validateStatus: (status) => true,
      ),
    );
    try {
      final response = await dio.get<dynamic>(
        url,
        queryParameters: queryParameters,
        options: Options(headers: headers),
      );
      final status = response.statusCode ?? 0;
      if (status >= 200 && status < 300) {
        return const ProviderKeyTestResult.ok('检测成功，密钥可用');
      }
      if (status == 401 || status == 403) {
        return ProviderKeyTestResult.fail('密钥无效或未授权（HTTP $status）');
      }
      return ProviderKeyTestResult.fail('请求失败（HTTP $status）');
    } on DioException catch (error) {
      return ProviderKeyTestResult.fail('网络请求失败：${error.message ?? error.type.name}');
    } finally {
      dio.close();
    }
  }

  String _stripSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
