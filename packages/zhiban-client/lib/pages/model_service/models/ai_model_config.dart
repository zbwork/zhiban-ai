import 'ai_model_capability.dart';

/// 单个 Provider 下的一个模型条目，只是配置数据，不含任何调用逻辑。
class AiModelConfig {
  const AiModelConfig({
    required this.id,
    required this.modelId,
    required this.displayName,
    this.groupName = '',
    this.capabilities = const <AiModelCapability>{},
    this.enabled = true,
  });

  /// 本地唯一 id（uuid），与厂商侧的模型标识 [modelId] 分开，便于改名不丢配置。
  final String id;

  /// 实际请求时使用的模型标识，例如 `deepseek-chat`。
  final String modelId;

  final String displayName;

  /// 分组名，用于列表里按厂商模型系列折叠展示（参考 Cherry Studio 的 "deepseek" 分组）。
  final String groupName;

  final Set<AiModelCapability> capabilities;

  final bool enabled;

  AiModelConfig copyWith({
    String? modelId,
    String? displayName,
    String? groupName,
    Set<AiModelCapability>? capabilities,
    bool? enabled,
  }) {
    return AiModelConfig(
      id: id,
      modelId: modelId ?? this.modelId,
      displayName: displayName ?? this.displayName,
      groupName: groupName ?? this.groupName,
      capabilities: capabilities ?? this.capabilities,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'modelId': modelId,
        'displayName': displayName,
        'groupName': groupName,
        'capabilities': capabilities.map((c) => c.name).toList(),
        'enabled': enabled,
      };

  factory AiModelConfig.fromJson(Map<String, dynamic> json) {
    final rawCapabilities = json['capabilities'];
    return AiModelConfig(
      id: json['id'] as String,
      modelId: json['modelId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      groupName: json['groupName'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
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
