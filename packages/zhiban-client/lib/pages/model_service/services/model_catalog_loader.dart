import 'package:zhiban_client/config/client_assets.dart';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/ai_endpoint_type.dart';
import '../models/ai_provider_config.dart';
import '../models/catalog_entry.dart';

/// 内置模型目录（厂商 + 模型），只读，来自打包的 assets JSON。
class ModelCatalog {
  const ModelCatalog({
    required this.providers,
    required this.modelsByProviderId,
  });

  final List<CatalogProviderEntry> providers;
  final Map<String, List<CatalogModelEntry>> modelsByProviderId;

  List<CatalogModelEntry> modelsFor(String providerId) =>
      modelsByProviderId[providerId] ?? const <CatalogModelEntry>[];

  /// 协议类型只来自内置目录；自定义 Provider 在协议配置功能恢复前固定使用
  /// OpenAI-compatible。它不是用户配置，也不写入 [AiProviderConfig]。
  AiEndpointType endpointTypeFor(AiProviderConfig provider) {
    final catalogId = provider.catalogId;
    if (catalogId == null) return AiEndpointType.openaiCompatible;
    for (final entry in providers) {
      if (entry.id == catalogId) return entry.endpointType;
    }
    return AiEndpointType.openaiCompatible;
  }
}

class ModelCatalogLoader {
  const ModelCatalogLoader();

  static const _providersAssetPath = 'assets/model_catalog/providers.json';
  static const _modelsAssetPath = 'assets/model_catalog/models.json';

  Future<ModelCatalog> load() async {
    final providersRaw = await rootBundle.loadString(ClientAssets.path(_providersAssetPath),
    );
    final modelsRaw = await rootBundle.loadString(ClientAssets.path(_modelsAssetPath),
    );

    final providersJson = jsonDecode(providersRaw) as Map<String, dynamic>;
    final modelsJson = jsonDecode(modelsRaw) as Map<String, dynamic>;

    final providers = (providersJson['providers'] as List)
        .whereType<Map<String, dynamic>>()
        .map(CatalogProviderEntry.fromJson)
        .toList();

    final modelsByProviderId = <String, List<CatalogModelEntry>>{};
    for (final raw in (modelsJson['models'] as List)) {
      if (raw is! Map<String, dynamic>) continue;
      final model = CatalogModelEntry.fromJson(raw);
      modelsByProviderId.putIfAbsent(model.providerId, () => []).add(model);
    }

    return ModelCatalog(
      providers: providers,
      modelsByProviderId: modelsByProviderId,
    );
  }
}
