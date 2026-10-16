import 'ai_endpoint_type.dart';
import 'ai_model_capability.dart';

/// 内置目录里的一个厂商条目（只读，来源见 assets/model_catalog/SOURCE.md）。
class CatalogProviderEntry {
  const CatalogProviderEntry({
    required this.id,
    required this.name,
    required this.endpointType,
    required this.baseUrl,
    this.defaultFirst = false,
    this.iconAssetPath,
    this.docsUrl,
  });

  final String id;
  final String name;
  final AiEndpointType endpointType;
  final String baseUrl;

  /// 新增目录项在用户尚未明确保存其位置前，是否优先展示在默认列表第一项。
  /// 一旦持久化顺序包含该条目，用户顺序始终优先。
  final bool defaultFirst;

  /// SVG 图标的 asset 路径，目录里没有对应 Logo 时为 null（UI 应回退到首字母头像）。
  final String? iconAssetPath;

  /// 厂商官方文档地址，目录里没有收录时为 null（UI 应隐藏文档入口）。
  final String? docsUrl;

  factory CatalogProviderEntry.fromJson(Map<String, dynamic> json) {
    final icon = json['icon'] as String?;
    return CatalogProviderEntry(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      endpointType: _parseEndpointType(json['endpointType'] as String?),
      baseUrl: json['baseUrl'] as String? ?? '',
      defaultFirst: json['defaultFirst'] == true,
      iconAssetPath: icon == null ? null : 'assets/icons/providers/$icon.svg',
      docsUrl: json['docsUrl'] as String?,
    );
  }

  static AiEndpointType _parseEndpointType(String? name) {
    for (final type in AiEndpointType.values) {
      if (type.name == name) return type;
    }
    return AiEndpointType.openaiCompatible;
  }
}

/// 内置目录里的一个模型条目，归属某个 [CatalogProviderEntry.id]。
class CatalogModelEntry {
  const CatalogModelEntry({
    required this.providerId,
    required this.modelId,
    required this.displayName,
    required this.groupName,
    required this.capabilities,
  });

  final String providerId;
  final String modelId;
  final String displayName;
  final String groupName;
  final Set<AiModelCapability> capabilities;

  factory CatalogModelEntry.fromJson(Map<String, dynamic> json) {
    final rawCapabilities = json['capabilities'];
    return CatalogModelEntry(
      providerId: json['providerId'] as String,
      modelId: json['modelId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      groupName: json['groupName'] as String? ?? '',
      capabilities: rawCapabilities is List
          ? _parseCapabilities(rawCapabilities)
          : const <AiModelCapability>{},
    );
  }

  static Set<AiModelCapability> _parseCapabilities(List<dynamic> raw) {
    final result = <AiModelCapability>{};
    for (final entry in raw) {
      if (entry is! String) continue;
      for (final capability in AiModelCapability.values) {
        if (capability.name == entry) {
          result.add(capability);
          break;
        }
      }
    }
    return result;
  }
}
