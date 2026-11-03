import 'package:dio/dio.dart';

import '../../model_service/models/ai_endpoint_type.dart';
import '../../model_service/models/ai_provider_config.dart';

class LocalModelException implements Exception {
  const LocalModelException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// No Bus interceptor, request logging, cookies or redirect credential forwarding.
class LocalModelClient {
  LocalModelClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));
  final Dio _dio;

  Future<String> complete({
    required AiProviderConfig provider,
    required AiEndpointType protocol,
    required String model,
    required String apiKey,
    required String system,
    required List<Map<String, String>> messages,
    required CancelToken cancelToken,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const LocalModelException('请先在模型服务中填写 API Key');
    }
    final uri = Uri.tryParse(provider.baseUrl);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(uri.host)))) {
      throw const LocalModelException('模型地址须使用 HTTPS；本机模型可使用 HTTP');
    }
    final base = provider.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final headers = <String, dynamic>{...provider.customHeaders};
    late String url;
    late Map<String, dynamic> body;
    switch (protocol) {
      case AiEndpointType.openaiCompatible:
        final apiBase = Uri.parse(base).path.isEmpty ? '$base/v1' : base;
        url = '$apiBase/chat/completions';
        headers['Authorization'] = 'Bearer $apiKey';
        body = {
          'model': model,
          'messages': [
            {'role': 'system', 'content': system},
            ...messages
          ],
          'stream': false
        };
      case AiEndpointType.anthropicMessages:
        url = '${base.endsWith('/v1') ? base : '$base/v1'}/messages';
        headers['x-api-key'] = apiKey;
        headers['anthropic-version'] = '2023-06-01';
        body = {
          'model': model,
          'system': system,
          'max_tokens': 4096,
          'messages': messages
        };
      case AiEndpointType.googleGenerativeAi:
        url =
            '${base.endsWith('/v1beta') ? base : '$base/v1beta'}/models/${Uri.encodeComponent(model)}:generateContent';
        headers['x-goog-api-key'] = apiKey;
        body = {
          'systemInstruction': {
            'parts': [
              {'text': system}
            ]
          },
          'contents': [
            for (final m in messages)
              {
                'role': m['role'] == 'assistant' ? 'model' : 'user',
                'parts': [
                  {'text': m['content']}
                ],
              }
          ],
        };
      case AiEndpointType.custom:
        throw const LocalModelException('该服务商协议暂不支持本地聊天，请选择兼容服务商');
    }
    try {
      final response = await _dio.post<dynamic>(url,
          data: body,
          cancelToken: cancelToken,
          options: Options(
              headers: headers,
              followRedirects: false,
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 5),
              validateStatus: (status) =>
                  status != null && status >= 200 && status < 300));
      final data = response.data as Map<String, dynamic>;
      final String content;
      switch (protocol) {
        case AiEndpointType.openaiCompatible:
          content = data['choices'][0]['message']['content'] as String? ?? '';
        case AiEndpointType.anthropicMessages:
          content = (data['content'] as List)
              .where((p) => p['type'] == 'text')
              .map((p) => p['text'])
              .join('\n');
        case AiEndpointType.googleGenerativeAi:
          content = (data['candidates'][0]['content']['parts'] as List)
              .map((p) => p['text'] ?? '')
              .join('\n');
        case AiEndpointType.custom:
          content = '';
      }
      if (content.trim().isEmpty) {
        throw const LocalModelException('模型未返回文本，请检查模型能力或重试');
      }
      return content;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) throw const LocalModelException('已停止生成');
      final status = e.response?.statusCode;
      throw LocalModelException(status == null
          ? '模型连接失败或超时，请检查网络与模型地址'
          : '模型请求失败（HTTP $status），请检查密钥、模型和额度');
    } on LocalModelException {
      rethrow;
    } catch (_) {
      throw const LocalModelException('模型响应格式不兼容，请检查所选服务商和模型');
    }
  }
}
