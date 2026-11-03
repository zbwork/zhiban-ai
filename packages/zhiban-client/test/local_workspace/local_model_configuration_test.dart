import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/catalog_entry.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';
import 'package:zhiban_client/pages/model_service/services/provider_model_fetcher.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';

class FailingModelFetcher extends ProviderModelFetcher {
  @override
  Future<ProviderModelFetchResult> fetch({
    required AiEndpointType endpointType,
    required String baseUrl,
    required String apiKey,
    Map<String, String> customHeaders = const {},
    String? catalogId,
  }) async =>
      throw StateError('discovery unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(ModelServiceStore.clearApiKeyMemoryCache);
  tearDown(ModelServiceStore.clearApiKeyMemoryCache);
  setUp(() async {
    final root = await Directory.systemTemp.createTemp('model-key-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => root.path);
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'), null);
      await root.delete(recursive: true);
    });
  });
  test('key migrates to local file, API key enables catalog chat model',
      () async {
    SharedPreferences.setMockInitialValues({
      'model_service.api_key.community-local.p': 'old-key',
      'model_service.providers.v1.anon': '[]',
    });
    FlutterSecureStorage.setMockInitialValues({});
    const store = ModelServiceStore();
    expect(await store.getApiKey('p'), 'old-key');
    expect(
        (await SharedPreferences.getInstance())
            .getString('model_service.api_key.community-local.p'),
        isNull);
    ModelServiceStore.clearApiKeyMemoryCache();
    expect(await store.getApiKey('p'), 'old-key');
    expect(
        await const FlutterSecureStorage()
            .read(key: 'model_service.api_key.community-local.p'),
        isNull);
    final container = ProviderContainer(overrides: [
      modelCatalogProvider.overrideWith((ref) async => const ModelCatalog(
            providers: [
              CatalogProviderEntry(
                  id: 'test',
                  name: '测试',
                  endpointType: AiEndpointType.openaiCompatible,
                  baseUrl: 'https://example.com/v1')
            ],
            modelsByProviderId: {
              'test': [
                CatalogModelEntry(
                    providerId: 'test',
                    modelId: 'embed',
                    displayName: '向量',
                    groupName: '',
                    capabilities: {}),
                CatalogModelEntry(
                    providerId: 'test',
                    modelId: 'chat',
                    displayName: '对话',
                    groupName: '',
                    capabilities: {}),
              ]
            },
          )),
    ]);
    await container.read(modelProvidersProvider.future);
    final notifier = container.read(modelProvidersProvider.notifier);
    final p = await notifier.addProvider(
        name: '测试', baseUrl: 'https://example.com/v1', catalogId: 'test');
    await notifier.setApiKey(p.id, 'new-key');
    final saved = (await store.loadProviders()).single;
    expect(saved.enabled, isTrue);
    expect(saved.models.single.modelId, 'chat');
    expect(await store.getApiKey(p.id), 'new-key');
    expect(saved.toJson().toString(), isNot(contains('new-key')));
    await notifier.updateProvider(saved.copyWith(enabled: false, models: [
      saved.models.single.copyWith(enabled: false),
    ]));
    await notifier.setApiKey(p.id, 'replacement-key');
    final reenabled = (await store.loadProviders()).single;
    expect(reenabled.enabled, isTrue);
    expect(reenabled.models.single.enabled, isTrue);
    expect(reenabled.models.single.id, saved.models.single.id);
    await store.deleteApiKey(p.id);
    expect(await store.getApiKey(p.id), isNull);
    container.dispose();
  });

  testWidgets(
      'failed discovery preserves saved key and enables provider without reordering',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(builder: BotToastInit(), home: const Scaffold()));
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final container = ProviderContainer(overrides: [
      providerModelFetcherProvider.overrideWith((ref) => FailingModelFetcher()),
      modelCatalogProvider.overrideWith((ref) async => const ModelCatalog(
            providers: [],
            modelsByProviderId: {},
          )),
    ]);
    addTearDown(container.dispose);
    await container.read(modelProvidersProvider.future);
    await container.read(providerOrderProvider.future);
    final notifier = container.read(modelProvidersProvider.notifier);
    final p =
        await notifier.addProvider(name: '自定义', baseUrl: 'https://example.com');
    await container
        .read(providerOrderProvider.notifier)
        .setOrder(['first', p.id]);
    await notifier.setApiKey(p.id, 'saved-key');
    await tester.pumpAndSettle();
    expect(find.textContaining('服务商已启用'), findsOneWidget);
    final saved = (await const ModelServiceStore().loadProviders()).single;
    expect(saved.enabled, isTrue);
    expect(saved.models, isEmpty);
    expect(await const ModelServiceStore().getApiKey(p.id), 'saved-key');
    expect(container.read(providerOrderProvider).value, ['first', p.id]);
    await notifier.updateProvider(saved.copyWith(models: [
      const AiModelConfig(
          id: 'm', modelId: 'chat', displayName: '对话', enabled: false),
    ]));
    await notifier.setApiKey(p.id, 'new-key');
    expect(
        (await const ModelServiceStore().loadProviders())
            .single
            .models
            .single
            .enabled,
        isTrue);
    BotToast.cleanAll();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
  });
}
