import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/services/provider_model_fetcher.dart';

void main() {
  test(
    'OpenAI-compatible discovery requests /models with a Bearer key',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      late String requestPath;
      late String? authorization;
      final requestHandled = server.first.then((request) async {
        requestPath = request.uri.path;
        authorization = request.headers.value(HttpHeaders.authorizationHeader);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"data":[{"id":"openai/gpt-5"},{"id":"anthropic/claude-sonnet"}]}',
        );
        await request.response.close();
      });

      final resultFuture = const ProviderModelFetcher().fetch(
        endpointType: AiEndpointType.openaiCompatible,
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'test-key',
      );
      await requestHandled;
      final result = await resultFuture;

      expect(requestPath, '/v1/models');
      expect(authorization, 'Bearer test-key');
      expect(result.ok, isTrue);
      expect(result.models.map((model) => model.modelId), [
        'openai/gpt-5',
        'anthropic/claude-sonnet',
      ]);
    },
  );
  Future<ProviderModelFetchResult> fetchResponses(
      AiEndpointType type, List<Map<String, Object?>> pages,
      {void Function(Uri)? observe}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var page = 0;
    server.listen((request) async {
      observe?.call(request.uri);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
          jsonEncode(pages[page < pages.length ? page++ : pages.length - 1]));
      await request.response.close();
    });
    return const ProviderModelFetcher().fetch(
        endpointType: type,
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'fixture');
  }

  test('valid empty list is authoritative, malformed list is a failure',
      () async {
    for (final body in <Map<String, Object?>>[
      {},
      {'data': 'bad'},
      {
        'data': [
          {'name': 'missing-id'}
        ]
      },
      {
        'data': [
          {'id': 'valid'},
          {'id': ''}
        ]
      },
    ]) {
      expect((await fetchResponses(AiEndpointType.openaiCompatible, [body])).ok,
          isFalse);
    }
    final empty = await fetchResponses(AiEndpointType.openaiCompatible, [
      {'data': []}
    ]);
    expect(empty.ok, isTrue);
    expect(empty.models, isEmpty);
  });
  test('Anthropic follows all pages before returning available IDs', () async {
    final queries = <Uri>[];
    final result = await fetchResponses(
        AiEndpointType.anthropicMessages,
        [
          {
            'data': [
              {'id': 'first'}
            ],
            'has_more': true,
            'last_id': 'first'
          },
          {
            'data': [
              {'id': 'second'}
            ],
            'has_more': false
          },
        ],
        observe: queries.add);
    expect(result.ok, isTrue);
    expect(result.models.map((m) => m.modelId), ['first', 'second']);
    expect(queries.last.queryParameters['after_id'], 'first');
  });
  test('Google follows nextPageToken and strips resource prefixes', () async {
    final queries = <Uri>[];
    final result = await fetchResponses(
        AiEndpointType.googleGenerativeAi,
        [
          {
            'models': [
              {'name': 'models/first'}
            ],
            'nextPageToken': 'next'
          },
          {
            'models': [
              {'name': 'models/second'}
            ]
          },
        ],
        observe: queries.add);
    expect(result.models.map((m) => m.modelId), ['first', 'second']);
    expect(queries.last.queryParameters['pageToken'], 'next');
    expect(queries.last.queryParameters['key'], 'fixture');
  });
  test(
      'malformed later page and looping cursor cannot return a partial success',
      () async {
    for (final last in <Map<String, Object?>>[
      {'error': 'bad page'},
      {
        'data': [
          {'id': 'second'}
        ],
        'has_more': true,
        'last_id': 'first'
      },
    ]) {
      final result = await fetchResponses(AiEndpointType.anthropicMessages, [
        {
          'data': [
            {'id': 'first'}
          ],
          'has_more': true,
          'last_id': 'first'
        },
        last,
      ]);
      expect(result.ok, isFalse);
      expect(result.models, isEmpty);
    }
  });
}
