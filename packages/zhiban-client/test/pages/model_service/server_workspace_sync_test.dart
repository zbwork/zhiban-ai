import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/services/conversation_models.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/services/conversation_model_sources.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/services/local_api_key_file_store.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';

class _CatalogAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  String response = '{"data":{"items":[]}}';
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(response, 200, headers: {
      Headers.contentTypeHeader: ['application/json']
    });
  }

  @override
  void close({bool force = false}) {}
}

class _PausedStore extends ModelServiceStore {
  final reading = Completer<void>();
  final key = Completer<String?>();
  @override
  Future<String?> getApiKey(String providerId) {
    reading.complete();
    return key.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ModelServiceStore store;
  late _CatalogAdapter adapter;
  ProviderContainer? container;
  const provider = AiProviderConfig(
    id: 'member-provider',
    name: 'Member provider',
    baseUrl: 'https://model.example.test/v1',
    enabled: true,
    models: [
      AiModelConfig(
          id: 'model', modelId: 'test-model', displayName: 'Test model')
    ],
  );
  setUp(() async {
    final claims = base64Url.encode(utf8.encode(jsonEncode({
      'aid': 4,
      'sub': 'member-uuid',
      'sid': 'test-session',
      'act_scope': 'tenant',
      'act_tid': 3,
    })));
    SharedPreferences.setMockInitialValues(
        {AppConfig.storageTokenKey: 'header.$claims.signature'});
    AppConfig.serverApiUrl = 'http://server-a.test/api/agent-bus/v1';
    AppConfig.connectionChanging = false;
    Request.resetForConnection();
    root = await Directory.systemTemp.createTemp('community-server-model-');
    store = ModelServiceStore(fileStore: LocalApiKeyFileStore(root: root));
    ModelServiceStore.clearApiKeyMemoryCache();
    adapter = _CatalogAdapter();
    sensitiveRequest.httpClientAdapter = adapter;
  });
  tearDown(() async {
    container?.dispose();
    container = null;
    Request.resetForConnection();
    AppConfig.serverApiUrl = null;
    ModelServiceStore.clearApiKeyMemoryCache();
    await root.delete(recursive: true);
  });
  Future<void> initialize() async {
    await store.saveProviders([provider]);
    await store.setApiKey(provider.id, 'fixture-file-key');
    container = ProviderContainer(
        overrides: [modelServiceStoreProvider.overrideWithValue(store)]);
    await container!.read(modelProvidersProvider.future);
  }

  test('connected community saves publish the file-backed key to this member',
      () async {
    await initialize();
    await container!
        .read(modelProvidersProvider.notifier)
        .updateProvider(provider.copyWith(name: 'Updated provider'));
    expect(adapter.requests, hasLength(1));
    final req = adapter.requests.single;
    expect(req.method, 'POST');
    expect(req.uri.host, 'server-a.test');
    expect(req.path, '/model-service/providers/sync');
    final body = req.data as Map;
    final config = (body['providers'] as List).single as Map;
    expect(config['api_key'], 'fixture-file-key');
    expect(body['partial'], isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(
        prefs
            .getKeys()
            .where((key) => key.startsWith('model_service.api_key.')),
        isEmpty);
  });
  test('saving a provider updates an already-open empty conversation catalog',
      () async {
    await initialize();
    final models = ConversationModels.instance;
    models.clear();
    addTearDown(models.clear);
    final agent =
        AgentItem.fromJson({'uuid': 'agent', 'supports_model_selection': true});
    await models.load(agent, 'draft');
    expect(models.state(agent.agentId, 'draft').models, isEmpty);
    adapter.response =
        '{"data":{"items":[{"id":"fixture-model","label":"Fixture model","model_id":"test-model"}]}}';
    await container!
        .read(modelProvidersProvider.notifier)
        .updateProvider(provider.copyWith(name: 'Updated'));
    expect(
        models.state(agent.agentId, 'draft').models.single.id, 'fixture-model');
    expect(models.state(agent.agentId, 'draft').ready, isTrue);
  });
  test('local community saves never publish credentials', () async {
    AppConfig.serverApiUrl = null;
    await initialize();
    await container!
        .read(modelProvidersProvider.notifier)
        .updateProvider(provider.copyWith(name: 'Local only'));
    expect(adapter.requests, isEmpty);
    expect((await store.loadProviders()).single.name, 'Local only');
  });
  test(
      'same numeric account on another server cannot read these providers or key',
      () async {
    await initialize();
    AppConfig.serverApiUrl = 'http://server-b.test/api/agent-bus/v1';
    expect(await store.loadProviders(), isEmpty);
    expect(await store.getApiKey(provider.id), isNull);
    AppConfig.serverApiUrl = null;
    expect(await store.loadProviders(), isEmpty);
    expect(await store.getApiKey(provider.id), isNull);
    AppConfig.serverApiUrl = 'http://server-a.test/api/agent-bus/v1';
    expect((await store.loadProviders()).single.id, provider.id);
    expect(await store.getApiKey(provider.id), 'fixture-file-key');
  });
  test('switching servers during a key read cancels the secret-bearing write',
      () async {
    final paused = _PausedStore();
    final pending = ConversationModelSources(store: paused).sync(
      publishLocalConfiguration: true,
      changes: [provider],
    );
    final rejected = expectLater(pending, throwsStateError);
    await paused.reading.future;
    AppConfig.serverApiUrl = 'http://server-b.test/api/agent-bus/v1';
    AppConfig.connectionEpoch++;
    paused.key.complete('fixture-late-key');
    await rejected;
    expect(adapter.requests, isEmpty);
  });
}
