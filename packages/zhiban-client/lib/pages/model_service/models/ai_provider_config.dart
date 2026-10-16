import 'ai_model_config.dart';

/// 一个模型服务商的本地配置。
///
/// 刻意不含 apiKey 字段——密钥单独存一份 key（见 `ModelServiceStore`），
/// 避免和这份配置一起被当作同一个 JSON blob 落盘或被日志/崩溃上报意外带出。
class AiProviderConfig {
  const AiProviderConfig({
    required this.id,
    required this.name,
    this.baseUrl = '',
    this.enabled = false,
    this.models = const <AiModelConfig>[],
    this.catalogId,
    this.imageGenerationBaseUrl = '',
    this.imageEditBaseUrl = '',
    this.customHeaders = const <String, String>{},
    this.managedSetupScopes = const <String>{},
  });

  final String id;
  final String name;
  final String baseUrl;
  final bool enabled;
  final List<AiModelConfig> models;

  /// 若该 Provider 是从内置目录（[ModelCatalog]）新建的，这里记录目录里的
  /// 厂商 id，用于回查 Logo 和目录内模型列表；用户完全自定义新建时为 null。
  final String? catalogId;

  final String imageGenerationBaseUrl;
  final String imageEditBaseUrl;

  /// 每次请求都会带上的自定义请求头。
  final Map<String, String> customHeaders;
  // Successful first import only; user edits must not trigger re-import.
  final Set<String> managedSetupScopes;

  AiProviderConfig copyWith({
    String? name,
    String? baseUrl,
    bool? enabled,
    List<AiModelConfig>? models,
    String? catalogId,
    String? imageGenerationBaseUrl,
    String? imageEditBaseUrl,
    Map<String, String>? customHeaders,
    Set<String>? managedSetupScopes,
  }) {
    return AiProviderConfig(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      enabled: enabled ?? this.enabled,
      models: models ?? this.models,
      catalogId: catalogId ?? this.catalogId,
      imageGenerationBaseUrl:
          imageGenerationBaseUrl ?? this.imageGenerationBaseUrl,
      imageEditBaseUrl: imageEditBaseUrl ?? this.imageEditBaseUrl,
      customHeaders: customHeaders ?? this.customHeaders,
      managedSetupScopes: managedSetupScopes ?? this.managedSetupScopes,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'enabled': enabled,
        'models': models.map((m) => m.toJson()).toList(),
        'catalogId': catalogId,
        'imageGenerationBaseUrl': imageGenerationBaseUrl,
        'imageEditBaseUrl': imageEditBaseUrl,
        'customHeaders': customHeaders,
        if (managedSetupScopes.isNotEmpty)
          'managedSetupScopes': managedSetupScopes.toList(),
      };

  factory AiProviderConfig.fromJson(Map<String, dynamic> json) {
    final rawModels = json['models'];
    final rawHeaders = json['customHeaders'];
    return AiProviderConfig(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      models: rawModels is List
          ? rawModels
              .whereType<Map<String, dynamic>>()
              .map(AiModelConfig.fromJson)
              .toList()
          : const <AiModelConfig>[],
      catalogId: json['catalogId'] as String?,
      managedSetupScopes: (json['managedSetupScopes'] as List? ?? const [])
          .whereType<String>()
          .toSet(),
      imageGenerationBaseUrl: json['imageGenerationBaseUrl'] as String? ?? '',
      imageEditBaseUrl: json['imageEditBaseUrl'] as String? ?? '',
      customHeaders: rawHeaders is Map
          ? rawHeaders.map((k, v) => MapEntry(k as String, v as String))
          : const <String, String>{},
    );
  }
}
