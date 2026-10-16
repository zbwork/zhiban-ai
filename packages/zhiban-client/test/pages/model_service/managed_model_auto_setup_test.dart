import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/models/catalog_entry.dart';
import 'package:zhiban_client/pages/model_service/providers/managed_model_service_provider.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';

const bee = CatalogProviderEntry(
    id: 'beebridge',
    name: 'BeeBridge',
    endpointType: AiEndpointType.openaiCompatible,
    baseUrl: 'https://api.beeaicloud.com/v1');
const ready = ManagedModelService(
    status: 'ready',
    keyReady: true,
    models: ['gpt-6-astra', 'gemini-3-flash', 'gpt-6-astra'],
    message: 'ready');

class MemoryStore extends ModelServiceStore {
  List<AiProviderConfig> providers = [];
  String? scope = '1:10';
  int setups = 0;
  @override
  Future<String?> managedScope() async => scope;
  @override
  Future<List<AiProviderConfig>> loadProviders() async => providers;
  @override
  Future<void> saveProviders(List<AiProviderConfig> next) async {
    providers = next.map((p) => AiProviderConfig.fromJson(p.toJson())).toList();
  }

  @override
  Future<bool> saveManagedSetup(
      List<AiProviderConfig> next, String expected) async {
    if (scope != expected) return false;
    setups++;
    await saveProviders(next);
    return true;
  }

  @override
  Future<List<String>> loadProviderOrder() async => [];
  @override
  Future<void> saveProviderOrder(List<String> order) async {}
}

ProviderContainer containerFor(MemoryStore store,
        {ManagedModelService Function()? status}) =>
    ProviderContainer(overrides: [
      modelServiceStoreProvider.overrideWithValue(store),
      managedModelServiceProvider
          .overrideWith((ref) async => status?.call() ?? ready),
      modelCatalogProvider.overrideWith((ref) async =>
          const ModelCatalog(providers: [bee], modelsByProviderId: {})),
    ]);
void main() {
  test('first setup enables BeeBridge and adds the current member models once',
      () async {
    final store = MemoryStore();
    final container = containerFor(store);
    addTearDown(container.dispose);
    await container.read(managedModelAutoSetupProvider.future);
    final p = store.providers.single;
    expect(p.enabled, isTrue);
    expect(p.models.map((m) => m.modelId), ['gpt-6-astra', 'gemini-3-flash']);
    expect(p.models.every((m) => m.enabled), isTrue);
    expect(p.managedSetupScopes, {'1:10'});
    expect(p.toJson().containsKey('api_key'), isFalse);
    final notifier = container.read(modelProvidersProvider.notifier);
    await notifier.setProviderEnabled(p.id, false);
    await notifier.removeModel(p.id, p.models.first.id);
    container.invalidate(managedModelAutoSetupProvider);
    await container.read(managedModelAutoSetupProvider.future);
    expect(store.setups, 1);
    expect(store.providers.single.enabled, isFalse);
    expect(store.providers.single.models.length, 1);
    final restarted = containerFor(store);
    addTearDown(restarted.dispose);
    await restarted.read(managedModelAutoSetupProvider.future);
    expect(store.setups, 1);
    expect(store.providers.single.enabled, isFalse);
    expect(store.providers.single.models.length, 1);
  });
  test('existing BeeBridge models are preserved and other providers untouched',
      () async {
    final store = MemoryStore()
      ..providers = [
        const AiProviderConfig(
            id: 'bee-original',
            name: 'BeeBridge',
            catalogId: 'beebridge',
            models: [
              AiModelConfig(
                  id: 'user-edited',
                  modelId: 'gpt-6-astra',
                  displayName: '我的模型')
            ]),
        const AiProviderConfig(id: 'silicon', name: '硅基流动', enabled: false),
      ];
    final container = containerFor(store);
    addTearDown(container.dispose);
    await container.read(managedModelAutoSetupProvider.future);
    expect(store.providers.length, 2);
    expect(store.providers.first.id, 'bee-original');
    expect(store.providers.first.enabled, isTrue);
    expect(store.providers.first.models.length, 2);
    expect(store.providers.first.models.first.id, 'user-edited');
    expect(store.providers.first.models.first.displayName, '我的模型');
    expect(store.providers.last.enabled, isFalse);
  });
  test('failed initialization does not mark setup and can retry', () async {
    final store = MemoryStore();
    var status = const ManagedModelService(
        status: 'unavailable', keyReady: true, models: [], message: 'failed');
    final container = containerFor(store, status: () => status);
    addTearDown(container.dispose);
    await container.read(managedModelAutoSetupProvider.future);
    expect(store.providers, isEmpty);
    status = ready;
    container.invalidate(managedModelServiceProvider);
    await container.read(managedModelAutoSetupProvider.future);
    expect(store.providers.single.enabled, isTrue);
  });
  test('no session cannot write automatic configuration', () async {
    final store = MemoryStore()..scope = null;
    final container = containerFor(store);
    addTearDown(container.dispose);
    await container.read(managedModelAutoSetupProvider.future);
    expect(store.providers, isEmpty);
  });
}
