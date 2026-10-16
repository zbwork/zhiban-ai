import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/services/conversation_model_sources.dart';

class RemoteCatalogAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(
        jsonEncode({
          'data': {
            'items': [
              {
                'id': 'desktop-model-ref',
                'label': 'Desktop model',
                'model_id': 'test-model',
                'provider_id': 'beebridge',
                'provider_name': 'BeeBridge'
              }
            ]
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'remote dispatch reads server catalog without publishing local provider snapshot',
      () async {
    final claims = base64Url.encode(utf8.encode(jsonEncode({
      'aid': 1039,
      'sub': 'account',
      'sid': 'session',
      'act_scope': 'tenant',
      'act_tid': 1
    })));
    const local =
        '[{"id":"phone-only","catalogId":"beebridge","name":"BeeBridge","models":[]}]';
    SharedPreferences.setMockInitialValues({
      AppConfig.storageTokenKey: 'header.$claims.signature',
      'model_service.providers.v1.1039': local,
      'model_service.api_key.1039.phone-only': 'fixture-local-secret',
    });
    final adapter = RemoteCatalogAdapter();
    final old = sensitiveRequest.httpClientAdapter;
    sensitiveRequest.httpClientAdapter = adapter;
    addTearDown(() => sensitiveRequest.httpClientAdapter = old);
    final models = await ConversationModelSources().sync();
    expect(models.single.id, 'desktop-model-ref');
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.method, 'GET');
    expect(adapter.requests.single.path, '/conversation-models');
    expect(adapter.requests.single.data, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('model_service.providers.v1.1039'), local);
    await ConversationModelSources().sync(
        publishLocalConfiguration: true,
        changes: [
          AiProviderConfig(
              id: 'edited-platform', name: 'Edited', enabled: false)
        ],
        expectedToken: 'header.$claims.signature');
    final body = adapter.requests.last.data as Map;
    expect(adapter.requests.last.method, 'POST');
    expect(body['partial'], isTrue);
    expect((body['providers'] as List).single['id'], 'edited-platform');
    final count = adapter.requests.length;
    await expectLater(
        ConversationModelSources().sync(
            publishLocalConfiguration: true,
            changes: [],
            expectedToken: 'another-login'),
        throwsStateError);
    expect(adapter.requests, hasLength(count));
  });
}
