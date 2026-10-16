import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';
import 'package:zhiban_client/pages/model_service/services/model_modality_classifier.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_capability.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';
import 'package:zhiban_client/services/local_agent_service.dart';

/// A single captured account snapshot; keys never enter model options or messages.
class RefreshedManagedCatalog {
  const RefreshedManagedCatalog(this.models, this.items);
  final List<AiModelConfig> models;
  final List<LlmModelOption> items;
}

class ConversationModelSources {
  static final managedRevision = ValueNotifier<int>(0);

  /// Both manual refresh buttons use the same member-scoped server operation.
  /// No device can replace another device's provider snapshot through refresh.
  Future<RefreshedManagedCatalog> refreshManaged() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(AppConfig.storageTokenKey) ?? '';
    final store = const ModelServiceStore();
    final scope = await store.managedScope();
    if (token.isEmpty || scope == null) {
      throw StateError('请重新登录');
    }
    final response = await sensitiveRequest.post(
        '/model-service/beebridge/refresh',
        options: Options(
            headers: {'Authorization': 'Bearer $token'},
            extra: {'authRetried': true, 'silent': true}));
    if (prefs.getString(AppConfig.storageTokenKey) != token ||
        await store.managedScope() != scope) {
      throw StateError('登录身份已变化');
    }
    // ResponseInterceptor has already validated and unwrapped the envelope.
    final data = response.data;
    if (response.statusCode != 200 || data is! Map) {
      throw StateError('模型列表刷新失败，请重试');
    }
    if (data['models'] is! List ||
        data['items'] is! List ||
        data['enabled'] is! bool) {
      throw StateError('模型列表响应无效');
    }
    final catalog = await const ModelCatalogLoader().load();
    final entry = catalog.providers.firstWhere((p) => p.id == 'beebridge');
    final current = await store.loadProviders();
    final existing =
        current.where((p) => p.catalogId == 'beebridge').firstOrNull;
    final provider = existing ??
        AiProviderConfig(
            id: 'managed:beebridge',
            name: entry.name,
            baseUrl: entry.baseUrl,
            catalogId: entry.id);
    final old = {for (final m in provider.models) m.modelId: m};
    final models = (data['models'] as List).map((raw) {
      if (raw is! Map ||
          raw['id'] is! String ||
          (raw['id'] as String).isEmpty ||
          raw['enabled'] is! bool) {
        throw StateError('模型列表响应无效');
      }
      final id = raw['id'] as String;
      final previous = old[id];
      final capabilities = {
        ...?previous?.capabilities,
        ...guessModelCapabilities(id)
      };
      if (raw['tool_use'] == true) {
        capabilities.add(AiModelCapability.toolUse);
      } else {
        capabilities.remove(AiModelCapability.toolUse);
      }
      return AiModelConfig(
          id: previous?.id ?? 'beebridge:$id',
          modelId: id,
          displayName:
              raw['label'] is String && (raw['label'] as String).isNotEmpty
                  ? raw['label'] as String
                  : id,
          enabled: raw['enabled'] as bool,
          groupName: previous?.groupName ?? guessVendorGroup(id) ?? '',
          capabilities: capabilities);
    }).toList();
    final entries = {for (final c in catalog.providers) c.id: c};
    final items = (data['items'] as List).map((raw) {
      final m = LlmModelOption.fromJson(Map<String, dynamic>.from(raw as Map));
      return LlmModelOption(
          id: m.id,
          label: m.label,
          modelId: m.modelId,
          isDefault: m.isDefault,
          providerId: m.providerId,
          providerName: m.providerName,
          providerIconAssetPath: entries[m.providerId]?.iconAssetPath);
    }).toList();
    final updated = provider.copyWith(
        models: models,
        enabled: data['enabled'] as bool,
        managedSetupScopes: {...provider.managedSetupScopes, scope});
    if (prefs.getString(AppConfig.storageTokenKey) != token ||
        !await store.saveManagedSetup([
          for (final p in current)
            if (p.catalogId == 'beebridge') updated else p,
          if (existing == null) updated,
        ], scope)) {
      throw StateError('登录身份已变化或模型配置保存失败');
    }
    managedRevision.value++;
    return RefreshedManagedCatalog(models, items);
  }

  Future<List<LlmModelOption>> sync(
      {bool publishLocalConfiguration = false,
      List<AiProviderConfig>? changes,
      String? expectedToken}) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(AppConfig.storageTokenKey) ?? '';
    if (expectedToken != null && expectedToken != token) {
      throw StateError('登录身份已变化');
    }
    final identity = LocalAgentService.identity(token);
    if (identity == null) throw StateError('请重新登录');
    final account = modelConfigurationAccount(token);
    if (account == null) throw StateError('请重新登录');
    final raw = prefs.getString('model_service.providers.v1.$account');
    // Remote dispatch consumes the desktop's member catalog. A fresh device also
    // has no configuration to replace the member's saved sources.
    if (!publishLocalConfiguration || (raw == null && changes == null)) {
      final response = await sensitiveRequest.get('/conversation-models',
          options: Options(
              headers: {'Authorization': 'Bearer $token'},
              extra: {'authRetried': true, 'silent': true}));
      final data = response.data;
      final map = data is Map && data['data'] is Map
          ? data['data'] as Map
          : data as Map;
      final catalog = await const ModelCatalogLoader().load();
      final entries = {for (final c in catalog.providers) c.id: c};
      return (map['items'] as List).map((item) {
        final m = LlmModelOption.fromJson(Map<String, dynamic>.from(item));
        return LlmModelOption(
            id: m.id,
            label: m.label,
            modelId: m.modelId,
            providerId: m.providerId,
            providerName: m.providerName,
            providerIconAssetPath: entries[m.providerId]?.iconAssetPath);
      }).toList();
    }
    final providers = changes ??
        (jsonDecode(raw!) as List)
            .map((p) => AiProviderConfig.fromJson(Map<String, dynamic>.from(p)))
            .toList();
    final keys = {
      for (final p in providers)
        p.id: prefs.getString('model_service.api_key.$account.${p.id}') ?? ''
    };
    final catalog = await const ModelCatalogLoader().load();
    final entries = {for (final c in catalog.providers) c.id: c};
    final payload = providers.map((p) {
      final endpoint =
          entries[p.catalogId]?.endpointType ?? AiEndpointType.openaiCompatible;
      final protocol = switch (endpoint) {
        AiEndpointType.openaiCompatible => 'openai-compatible',
        AiEndpointType.anthropicMessages => 'anthropic-messages',
        AiEndpointType.googleGenerativeAi => 'google-generative-ai',
        AiEndpointType.custom => 'custom',
      };
      return {
        'id': p.id,
        'catalog_id': p.catalogId ?? '',
        'name': p.name,
        'enabled': p.enabled,
        'protocol': protocol,
        'base_url': p.baseUrl,
        'api_key': p.catalogId == 'beebridge' ? '' : keys[p.id],
        'headers': p.customHeaders,
        'models': [
          for (final m in p.models)
            {
              'id': m.modelId,
              'label': m.displayName,
              'enabled': m.enabled,
              'tool_use': m.capabilities.contains(AiModelCapability.toolUse),
              'modality': m.capabilities.contains(AiModelCapability.embedding)
                  ? 'embedding'
                  : '',
            }
        ],
      };
    }).toList();
    if (prefs.getString(AppConfig.storageTokenKey) != token) {
      throw StateError('登录身份已变化');
    }
    final response = await sensitiveRequest.post(
        '/model-service/providers/sync',
        data: {'providers': payload, if (changes != null) 'partial': true},
        // Never replay this secret-bearing account snapshot with a different token.
        options: Options(
            headers: {'Authorization': 'Bearer $token'},
            extra: {'authRetried': true}));
    if (prefs.getString(AppConfig.storageTokenKey) != token) {
      throw StateError('登录身份已变化');
    }
    final data = response.data;
    final map =
        data is Map && data['data'] is Map ? data['data'] as Map : data as Map;
    final items = map['items'] as List;
    return items.map((item) {
      final m = LlmModelOption.fromJson(Map<String, dynamic>.from(item));
      return LlmModelOption(
          id: m.id,
          label: m.label,
          modelId: m.modelId,
          isDefault: m.isDefault,
          providerId: m.providerId,
          providerName: m.providerName,
          providerIconAssetPath: entries[m.providerId]?.iconAssetPath);
    }).toList();
  }
}

/// ModelServiceStore uses JWT aid (numeric account ID), while the device
/// capability uses sub (account UUID). Never mix their preference partitions.
String? modelConfigurationAccount(String token) {
  try {
    final payload = jsonDecode(utf8.decode(
      base64Url.decode(base64Url.normalize(token.split('.')[1]))),
    );
    final aid = payload is Map ? payload['aid'] : null;
    if (aid is int && aid > 0) return '$aid';
    if (aid is String && RegExp(r'^[1-9][0-9]*$').hasMatch(aid)) return aid;
  } catch (_) {/* invalid identity must not select a credential partition */}
  return null;
}
