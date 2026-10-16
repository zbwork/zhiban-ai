import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:zhiban_core/network/auth_refresh_interceptor.dart';
import 'package:zhiban_core/network/request_interceptor.dart';
import 'package:zhiban_core/session/token_refresher.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async => respond(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);
Dio _client(
  FutureOr<ResponseBody> Function(RequestOptions) respond, [
  BaseOptions? options,
]) {
  final dio = Dio(options)..httpClientAdapter = _Adapter(respond);
  addTearDown(dio.close);
  return dio;
}

void main() {
  setUp(RequestInterceptor.clearTokenCache);
  tearDown(RequestInterceptor.clearTokenCache);

  test('concurrent refresh waits for one request and persistence', () async {
    final saving = Completer<void>(), saved = Completer<void>();
    var calls = 0;
    final refresher = TokenRefresher(
      apiUrl: () => 'https://bus.example',
      readRefreshToken: () async => 'refresh',
      createDio: (options) => _client((_) {
        calls++;
        return _json(200, {
          'success': true,
          'data': {'accessToken': 'next'},
        });
      }, options),
      persistTokens: (access, _) async {
        expect(access, 'next');
        saving.complete();
        await saved.future;
      },
    );
    final flights = List.generate(12, (_) => refresher.refresh());
    await saving.future;
    expect(RequestInterceptor.cachedToken, isNull);
    saved.complete();
    expect(await Future.wait(flights), everyElement(RefreshOutcome.ok));
    expect(calls, 1);
    expect(RequestInterceptor.cachedToken, 'next');
  });

  test('401 retries once but never replays uploads or streams', () async {
    for (final (data, type, expectedRequests) in [
      (null, ResponseType.json, 2),
      (FormData.fromMap({'file': 'value'}), ResponseType.json, 1),
      (null, ResponseType.stream, 1),
    ]) {
      var requests = 0, refreshes = 0;
      final dio = _client((_) {
        requests++;
        return _json(401, {});
      });
      dio.interceptors.add(
        AuthRefreshInterceptor(
          dio,
          refresh: () async {
            refreshes++;
            return RefreshOutcome.ok;
          },
          forceLogout: () => fail('unexpected logout'),
        ),
      );
      await expectLater(
        dio.post<void>(
          'https://bus.example/private',
          data: data,
          options: Options(responseType: type),
        ),
        throwsA(isA<DioException>()),
      );
      expect([requests, refreshes], [expectedRequests, 1]);
    }
  });
}
