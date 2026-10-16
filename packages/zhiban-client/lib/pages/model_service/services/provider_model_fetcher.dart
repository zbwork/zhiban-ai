import 'package:dio/dio.dart';

import '../models/ai_endpoint_type.dart';

/// 从服务商拉回来的一条模型条目，只是展示用的原始数据，不是 [AiModelConfig]——
/// 用户勾选之后才会在 dialog 里转成真正落地的 [AiModelConfig]。
class FetchedModel {
  const FetchedModel({required this.modelId, required this.displayName});

  final String modelId;
  final String displayName;

  /// 聚合网关（OpenRouter/CherryIN/302.AI 之类）常用 `vendor/model` 命名
  /// 模型标识，取 "/" 前的部分做分组。取不到就是空字符串（不分组，平铺展示）
  /// ——不是厂商接口本身返回的分组元数据，是从真实 modelId 结构里老实推出来
  /// 的，不编造 CherryIN 那种客户端专属分类（比如它的 "agent" 分组）。
  String get group {
    final idx = modelId.indexOf('/');
    return idx > 0 ? modelId.substring(0, idx) : '';
  }
}

class ProviderModelFetchResult {
  const ProviderModelFetchResult.ok(this.models)
      : ok = true,
        message = null;
  const ProviderModelFetchResult.fail(this.message)
      : ok = false,
        models = const <FetchedModel>[];

  final bool ok;
  final List<FetchedModel> models;
  final String? message;
}

/// 直连服务商拉取其支持的模型列表，用于「获取模型列表」批量勾选添加。
///
/// 跟 [ProviderKeyTester] 一样，故意用无拦截器的临时 Dio 实例——不能用
/// `Request.instance.dio`，那个单例会把平台自己的 Authorization 一起发给
/// 第三方厂商，泄漏平台会话 token。
class ProviderModelFetcher {
  const ProviderModelFetcher();

  /// 该协议是否支持自动拉取模型列表。`custom` 协议里目前只认识 Ollama
  /// （目录里 `endpointType` 就是 `custom`，走它自己的原生 `/api/tags`），
  /// 其他自定义厂商没有统一约定的列表接口，交给用户手动添加。
  bool supports(AiEndpointType endpointType, {String? catalogId}) {
    if (endpointType != AiEndpointType.custom) return true;
    return catalogId == 'ollama';
  }

  Future<ProviderModelFetchResult> fetch({
    required AiEndpointType endpointType,
    required String baseUrl,
    required String apiKey,
    Map<String, String> customHeaders = const <String, String>{},
    String? catalogId,
  }) async {
    final trimmedBase = baseUrl.trim();
    if (trimmedBase.isEmpty) {
      return const ProviderModelFetchResult.fail('请先填写 API 地址');
    }
    final trimmedKey = apiKey.trim();

    switch (endpointType) {
      case AiEndpointType.openaiCompatible:
        return _fetch(
          url: '${_stripSlash(trimmedBase)}/models',
          headers: {
            if (trimmedKey.isNotEmpty) 'Authorization': 'Bearer $trimmedKey',
            ...customHeaders,
          },
          parse: _parseOpenAi,
        );
      case AiEndpointType.anthropicMessages:
        final base = _stripSlash(trimmedBase);
        final url = base.endsWith('/v1') ? '$base/models' : '$base/v1/models';
        return _fetch(
          url: url,
          headers: {
            if (trimmedKey.isNotEmpty) 'x-api-key': trimmedKey,
            'anthropic-version': '2023-06-01',
            ...customHeaders,
          },
          parse: _parseAnthropic,
          cursorParameter: 'after_id',
        );
      case AiEndpointType.googleGenerativeAi:
        final base = _stripSlash(trimmedBase);
        final url =
            base.endsWith('/v1beta') ? '$base/models' : '$base/v1beta/models';
        return _fetch(
          url: url,
          headers: customHeaders,
          queryParameters: trimmedKey.isEmpty ? null : {'key': trimmedKey},
          parse: _parseGoogle,
          cursorParameter: 'pageToken',
        );
      case AiEndpointType.custom:
        if (catalogId == 'ollama') {
          return _fetch(
            url: '${_stripSlash(trimmedBase)}/api/tags',
            headers: customHeaders,
            parse: _parseOllama,
          );
        }
        return const ProviderModelFetchResult.fail('自定义协议暂不支持自动拉取，请手动添加模型');
    }
  }

  Future<ProviderModelFetchResult> _fetch({
    required String url,
    required Map<String, String> headers,
    Map<String, String>? queryParameters,
    required List<FetchedModel> Function(dynamic body) parse,
    String cursorParameter = 'after',
  }) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 10),
        validateStatus: (status) => true,
      ),
    );
    try {
      final models = <FetchedModel>[];
      final seenModels = <String>{};
      final seenCursors = <String>{};
      var query = {...?queryParameters};
      for (var page = 0; page < 100; page++) {
        final response = await dio.get<dynamic>(
          url,
          queryParameters: query,
          options: Options(headers: headers),
        );
        final status = response.statusCode ?? 0;
        if (status < 200 || status >= 300) {
          if (status == 401 || status == 403) {
            return ProviderModelFetchResult.fail('密钥无效或未授权（HTTP $status）');
          }
          return ProviderModelFetchResult.fail('请求失败（HTTP $status）');
        }
        final batch = parse(response.data);
        models.addAll(batch.where((m) => seenModels.add(m.modelId)));
        final body = response.data as Map;
        String? cursor;
        if (cursorParameter == 'pageToken') {
          final value = body['nextPageToken'];
          if (value != null && value is! String) {
            throw const FormatException('invalid pagination');
          }
          cursor = value as String?;
        } else if (body['has_more'] == true) {
          final value = body['last_id'];
          if (value is! String || value.isEmpty) {
            throw const FormatException('invalid pagination');
          }
          cursor = value;
        } else if (body['has_more'] != null && body['has_more'] != false) {
          throw const FormatException('invalid pagination');
        }
        if (cursor == null || cursor.isEmpty) {
          return ProviderModelFetchResult.ok(models);
        }
        if (!seenCursors.add(cursor)) {
          throw const FormatException('repeated pagination');
        }
        query = {...?queryParameters, cursorParameter: cursor};
      }
      return const ProviderModelFetchResult.fail('模型列表分页未完成，请重试');
    } on DioException catch (error) {
      return ProviderModelFetchResult.fail(
          '网络请求失败：${error.message ?? error.type.name}');
    } catch (_) {
      return const ProviderModelFetchResult.fail('响应格式无法识别');
    } finally {
      dio.close();
    }
  }

  List<FetchedModel> _parseOpenAi(dynamic body) {
    final data = _modelRows(body, 'data', 'id');
    return data
        .whereType<Map>()
        .map((m) => m['id'])
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .map((id) => FetchedModel(modelId: id, displayName: id))
        .toList();
  }

  List<FetchedModel> _parseAnthropic(dynamic body) {
    final data = _modelRows(body, 'data', 'id');
    return data.whereType<Map>().where((m) => m['id'] is String).map((m) {
      final id = m['id'] as String;
      final displayName = m['display_name'];
      return FetchedModel(
        modelId: id,
        displayName:
            displayName is String && displayName.isNotEmpty ? displayName : id,
      );
    }).toList();
  }

  List<FetchedModel> _parseGoogle(dynamic body) {
    final data = _modelRows(body, 'models', 'name');
    return data.whereType<Map>().where((m) => m['name'] is String).map((m) {
      final rawName = m['name'] as String;
      // Google 返回的是 `models/gemini-1.5-pro` 这种带前缀的资源名，本地
      // 存储跟其它协议一样只存裸模型 id，调用时再按需要拼回前缀。
      final id = rawName.startsWith('models/') ? rawName.substring(7) : rawName;
      final displayName = m['displayName'];
      return FetchedModel(
        modelId: id,
        displayName:
            displayName is String && displayName.isNotEmpty ? displayName : id,
      );
    }).toList();
  }

  List<FetchedModel> _parseOllama(dynamic body) {
    final data = body is Map ? body['models'] : null;
    if (data is! List) throw const FormatException('invalid model list');
    for (final row in data) {
      final id = row is Map ? row['name'] ?? row['model'] : null;
      if (id is! String || id.trim().isEmpty) {
        throw const FormatException('invalid model id');
      }
    }
    return data
        .whereType<Map>()
        .map((m) {
          final name = m['name'] ?? m['model'];
          if (name is! String || name.isEmpty) return null;
          return FetchedModel(modelId: name, displayName: name);
        })
        .whereType<FetchedModel>()
        .toList();
  }

  String _stripSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  List<dynamic> _modelRows(dynamic body, String field, String idField) {
    final data = body is Map ? body[field] : null;
    if (data is! List) throw const FormatException('invalid model list');
    for (final row in data) {
      final id = row is Map ? row[idField] : null;
      if (id is! String || id.trim().isEmpty) {
        throw const FormatException('invalid model id');
      }
    }
    return data;
  }
}
