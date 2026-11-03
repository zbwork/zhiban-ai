import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_model_client.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';

class Adapter implements HttpClientAdapter {
  RequestOptions? request;
  dynamic payload;
  int status = 200;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    request = options;
    return ResponseBody.fromString(jsonEncode(payload), status, headers: {
      Headers.contentTypeHeader: ['application/json']
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  for (final protocol in [
    AiEndpointType.openaiCompatible,
    AiEndpointType.anthropicMessages,
    AiEndpointType.googleGenerativeAi
  ]) {
    test('direct $protocol request uses own authentication and extracts reply',
        () async {
      final adapter = Adapter();
      adapter.payload = switch (protocol) {
        AiEndpointType.openaiCompatible => {
            'choices': [
              {
                'message': {'content': '回答'}
              }
            ]
          },
        AiEndpointType.anthropicMessages => {
            'content': [
              {'type': 'text', 'text': '回答'}
            ]
          },
        _ => {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': '回答'}
                  ]
                }
              }
            ]
          },
      };
      final client = LocalModelClient(dio: Dio()..httpClientAdapter = adapter);
      final result = await client.complete(
        provider: const AiProviderConfig(
            id: 'p', name: 'test', baseUrl: 'https://example.com'),
        protocol: protocol,
        model: 'chat',
        apiKey: 'private-key',
        system: '角色+技能',
        messages: [
          {'role': 'user', 'content': '问题'}
        ],
        cancelToken: CancelToken(),
      );
      expect(result, '回答');
      if (protocol == AiEndpointType.openaiCompatible) {
        expect(adapter.request!.uri.path, '/v1/chat/completions');
      }
      expect(adapter.request!.followRedirects, isFalse);
      expect(adapter.request!.queryParameters.values,
          isNot(contains('private-key')));
      expect(adapter.request!.data.toString(), contains('角色+技能'));
    });
  }
  test('HTTP errors do not expose response or credentials', () async {
    final adapter = Adapter()
      ..status = 401
      ..payload = {'error': 'private-key'};
    final client = LocalModelClient(dio: Dio()..httpClientAdapter = adapter);
    await expectLater(
        client.complete(
          provider: const AiProviderConfig(
              id: 'p', name: 'test', baseUrl: 'https://example.com'),
          protocol: AiEndpointType.openaiCompatible,
          model: 'chat',
          apiKey: 'private-key',
          system: '',
          messages: [],
          cancelToken: CancelToken(),
        ),
        throwsA(isA<LocalModelException>().having(
            (e) => e.message,
            'safe error',
            allOf(contains('401'), isNot(contains('private-key'))))));
  });
}
