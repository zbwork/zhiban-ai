import 'package:zhiban_client/config/app_config.dart';
import '../models/ai_model_config.dart';
import '../services/model_modality_classifier.dart';
import 'model_service_providers.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/network/api_utils.dart';
import 'package:zhiban_client/network/network.dart';

class ManagedModelService {
  const ManagedModelService({
    required this.status,
    required this.keyReady,
    required this.models,
    required this.message,
  });

  factory ManagedModelService.fromJson(Map<String, dynamic> json) =>
      ManagedModelService(
        status: json['status'] as String? ?? 'needs_review',
        keyReady: json['key_ready'] == true,
        models:
            (json['models'] as List? ?? const []).whereType<String>().toList(),
        message: json['message'] as String? ?? '模型服务暂时不可用',
      );

  final String status;
  final bool keyReady;
  final List<String> models;
  final String message;
}

/// Cached only inside the current session ProviderScope, which is replaced on
/// logout/tenant switch. Never persist tenant credentials in account BYOK prefs.
final managedModelServiceProvider =
    FutureProvider<ManagedModelService>((ref) async {
  if (AppConfig.communityEdition) return const ManagedModelService(status: 'unavailable', keyReady: false, models: [], message: '社区模型由服务端配置');
  final response = await request.post('/model-service/initialize');
  return ManagedModelService.fromJson(responseAsMap(response));
});

/// Only watched by the detail page; never persisted or collected by Mana Dio.
final managedModelKeyProvider = FutureProvider.autoDispose<String>((ref) async {
  final status = await ref.watch(managedModelServiceProvider.future);
  if (!status.keyReady) return '';
  final response = await sensitiveRequest.post('/model-service/key');
  return responseAsMap(response)['api_key'] as String? ?? '';
});

/// Automatic first setup, driven by the same member-key model query as status.
/// Listening to status allows failed initialization to retry after detection.
final managedModelAutoSetupProvider = FutureProvider<void>((ref) async {
  final status = await ref.watch(managedModelServiceProvider.future);
  if (!ref.mounted || !status.keyReady || status.status != 'ready') return;
  final store = ref.read(modelServiceStoreProvider);
  final scope = await store.managedScope();
  if (!ref.mounted || scope == null) return;
  final providers = await ref.read(modelProvidersProvider.future);
  if (!ref.mounted) return;
  if (providers.any((p) =>
      p.catalogId == 'beebridge' && p.managedSetupScopes.contains(scope))) {
    return;
  }
  final catalog = await ref.read(modelCatalogProvider.future);
  if (!ref.mounted) return;
  final entries = catalog.providers.where((p) => p.id == 'beebridge');
  if (entries.isEmpty) return;
  await ref.read(modelProvidersProvider.notifier).initializeManagedProvider(
        entries.first,
        [
          for (final id
              in status.models.where((id) => id.trim().isNotEmpty).toSet())
            AiModelConfig(
              id: 'beebridge:$id',
              modelId: id,
              displayName: id,
              groupName: guessVendorGroup(id) ?? '',
              capabilities: guessModelCapabilities(id),
            )
        ],
        scope
      );
});
