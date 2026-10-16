import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';
import 'package:zhiban_client/pages/model_service/widgets/add_model_dialog.dart';
import 'package:zhiban_client/services/conversation_model_sources.dart';
import 'package:zhiban_client/services/conversation_models.dart';

class CatalogAdapter implements HttpClientAdapter {
  int refreshes = 0;
  bool fail = false;
  bool empty = false;
  Future<void> Function()? beforeReturn;
  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<Uint8List>? stream, Future<void>? cancel) async {
    final refresh = o.path == '/model-service/beebridge/refresh';
    if (refresh) {
      refreshes++;
      expect(o.method, 'POST');
      expect(o.data, isNull);
    } else {
      expect(o.path, '/conversation-models');
      expect(o.method, 'GET');
    }
    await beforeReturn?.call();
    return ResponseBody.fromString(
        jsonEncode({
          'success': !fail,
          'data': {
            'enabled': true,
            'models': empty
                ? []
                : [
                    {
                      'id': 'keep',
                      'label': '自定义名称',
                      'enabled': false,
                      'tool_use': true
                    },
                    {
                      'id': 'new',
                      'label': '新模型',
                      'enabled': true,
                      'tool_use': true
                    }
                  ],
            'items': empty
                ? []
                : refresh
                    ? [
                        {
                          'id': 'new-ref',
                          'label': '新模型',
                          'model_id': 'new',
                          'provider_id': 'beebridge',
                          'provider_name': 'BeeBridge'
                        }
                      ]
                    : [
                        {
                          'id': 'old-ref',
                          'label': '旧模型',
                          'model_id': 'old',
                          'provider_id': 'beebridge',
                          'provider_name': 'BeeBridge'
                        }
                      ],
          }
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}

String token(int tenant) => 'header.${base64Url.encode(utf8.encode(jsonEncode({
          'aid': 1039,
          'sub': 'account',
          'sid': 'session',
          'act_scope': 'tenant',
          'act_tid': tenant
        })))}.signature';
const local =
    '[{"id":"bee","name":"BeeBridge","catalogId":"beebridge","enabled":true,"baseUrl":"https://fixture.example/v1","models":[{"id":"keep-local","modelId":"keep","displayName":"自定义名称","enabled":false},{"id":"old-local","modelId":"old","displayName":"旧模型"}]},{"id":"other","name":"Other","models":[{"id":"other-local","modelId":"old","displayName":"其他平台"}]}]';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CatalogAdapter adapter;
  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppConfig.storageTokenKey: token(1),
      'model_service.providers.v1.1039': local
    });
    adapter = CatalogAdapter();
    final old = sensitiveRequest.httpClientAdapter;
    sensitiveRequest.httpClientAdapter = adapter;
    addTearDown(() => sensitiveRequest.httpClientAdapter = old);
  });
  test(
      'manual chat refresh updates server catalog and local mirror; removed choice requires reselect',
      () async {
    final model = ConversationModels();
    addTearDown(model.dispose);
    final agent =
        AgentItem.fromJson({'uuid': 'agent', 'supports_model_selection': true});
    await model.load(agent, 'conversation');
    await model.select(agent.agentId, 'conversation', 'old-ref');
    await model.load(agent, 'conversation', refresh: true);
    expect(adapter.refreshes, 1);
    final state = model.state(agent.agentId, 'conversation');
    expect(state.selected, 'old-ref');
    expect(state.ready, isFalse);
    expect(state.error, contains('请切换模型'));
    expect(state.models.single.id, 'new-ref');
    final prefs = await SharedPreferences.getInstance();
    final providers =
        jsonDecode(prefs.getString('model_service.providers.v1.1039')!) as List;
    expect(
        providers.last,
        AiProviderConfig.fromJson(
                Map<String, dynamic>.from(jsonDecode(local)[1]))
            .toJson());
    expect((providers.first['models'] as List).map((m) => m['modelId']),
        ['keep', 'new']);
    expect(providers.first['models'][0]['id'], 'keep-local');
    expect(providers.first['models'][0]['enabled'], false);
    await model.select(agent.agentId, 'conversation', 'new-ref');
    expect(model.state(agent.agentId, 'conversation').ready, isTrue);
  });
  test(
      'failed refresh preserves catalog and reports error instead of old success',
      () async {
    final model = ConversationModels();
    addTearDown(model.dispose);
    final agent = AgentItem.fromJson({'uuid': 'agent'});
    await model.load(agent, 'c');
    adapter.fail = true;
    await model.load(agent, 'c', refresh: true);
    expect(model.state(agent.agentId, 'c').models.single.id, 'old-ref');
    expect(model.state(agent.agentId, 'c').error, contains('加载失败'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('model_service.providers.v1.1039'), local);
  });
  test('valid choices survive refresh and other loaded conversations update',
      () async {
    final models = ConversationModels();
    addTearDown(models.dispose);
    final agent = AgentItem.fromJson({'uuid': 'agent'});
    await models.load(agent, 'valid');
    await models.load(agent, 'removed');
    models.applyCatalog([
      LlmModelOption.fromJson({'id': 'old-ref', 'label': '旧模型'}),
      LlmModelOption.fromJson({'id': 'new-ref', 'label': '新模型'}),
    ]);
    await models.select(agent.agentId, 'valid', 'new-ref');
    await models.select(agent.agentId, 'removed', 'old-ref');
    await models.load(agent, 'valid', refresh: true);
    expect(models.state(agent.agentId, 'valid').selected, 'new-ref');
    expect(models.state(agent.agentId, 'valid').ready, isTrue);
    expect(models.state(agent.agentId, 'valid').manuallySelected, isTrue);
    expect(models.state(agent.agentId, 'removed').selected, 'old-ref');
    expect(models.state(agent.agentId, 'removed').ready, isFalse);
    expect(models.state(agent.agentId, 'removed').models.single.id, 'new-ref');
  });
  test(
      'complete empty catalog removes all managed rows; identity switch cannot apply late response',
      () async {
    adapter.empty = true;
    final result = await ConversationModelSources().refreshManaged();
    expect(result.models, isEmpty);
    expect(result.items, isEmpty);
    SharedPreferences.setMockInitialValues({
      AppConfig.storageTokenKey: token(1),
      'model_service.providers.v1.1039': local
    });
    adapter.beforeReturn = () async {
      final p = await SharedPreferences.getInstance();
      await p.setString(AppConfig.storageTokenKey, token(2));
    };
    await expectLater(
        ConversationModelSources().refreshManaged(), throwsStateError);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('model_service.providers.v1.1039'), local);
  });
  testWidgets(
      'model service refresh uses the same managed endpoint without requesting a model Key',
      (tester) async {
    // Asset decoding uses compute for large bundled catalogs; finish the real
    // isolate work before driving widget frames under the fake test clock.
    await tester.runAsync(() => const ModelCatalogLoader().load());
    final provider = AiProviderConfig.fromJson(
        Map<String, dynamic>.from(jsonDecode(local)[0]));
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            home: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showAddModelDialog(context,
                        provider: provider,
                        endpointType: AiEndpointType.openaiCompatible,
                        catalogModels: const [],
                        apiKey: '',
                        baseUrl: 'https://fixture.example/v1',
                        ensureLocalId: () async => 'bee'),
                    child: const Text('打开'))))));
    final refreshed = Completer<void>();
    void onRefresh() {
      if (!refreshed.isCompleted) refreshed.complete();
    }

    ConversationModelSources.managedRevision.addListener(onRefresh);
    addTearDown(() =>
        ConversationModelSources.managedRevision.removeListener(onRefresh));
    await tester.tap(find.text('打开'));
    for (var i = 0; i < 100 && !refreshed.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    expect(refreshed.isCompleted, isTrue);
    await tester.pumpAndSettle();
    expect(adapter.refreshes, 1);
    expect(find.text('旧模型'), findsNothing);
    expect(find.text('新模型'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
