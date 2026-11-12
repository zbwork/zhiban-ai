import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/network.dart';
import 'package:zhiban_client/services/server_connection.dart';
import 'package:zhiban_client/services/session_runtime.dart';
import 'package:zhiban_core/network/request_interceptor.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
          Future<void>? cancel) =>
      respond(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppConfig.serverApiUrl = null;
    AppConfig.connectionChanging = false;
    AppConfig.connectionEpoch++;
    Request.resetForConnection();
    RequestInterceptor.clearTokenCache();
  });
  tearDown(() async {
    await drainConnectionCredentials();
    AppConfig.serverApiUrl = null;
    AppConfig.connectionChanging = false;
    Request.resetForConnection();
    RequestInterceptor.clearTokenCache();
  });

  test('normalizes root/API addresses and allows only explicit private HTTP',
      () {
    for (final input in [
      ' https://EXAMPLE.com/ ',
      'https://example.com/api/agent-bus/v1/'
    ]) {
      expect(ServerConnection.normalize(input),
          'https://example.com/api/agent-bus/v1');
    }
    for (final host in [
      'localhost',
      '127.0.0.1',
      '[::1]',
      '10.1.2.3',
      '172.16.0.1',
      '192.168.1.2'
    ]) {
      expect(ServerConnection.normalize('http://$host:18080'),
          contains(':18080/api/agent-bus/v1'));
    }
    for (final input in [
      '',
      'example.com',
      'ftp://example.com',
      'https://user:pass@example.com',
      'https://example.com?token=a',
      'https://example.com#x',
      'https://example.com/admin',
      'https://example.com:99999',
      'https://example.com:0',
      'http://example.com',
      'http://172.32.0.1',
      'http://192.169.1.1',
      'http://127.0.0.1.example.com',
    ]) {
      expect(() => ServerConnection.normalize(input), throwsFormatException,
          reason: input);
    }
  });

  test('anonymous probe validates Bus envelope and never sends cached token',
      () async {
    RequestInterceptor.primeToken('private-token');
    final dio = Dio()
      ..httpClientAdapter = _Adapter((options) async {
        expect(options.uri.toString(),
            'https://example.com/api/agent-bus/v1/auth/captcha');
        expect(options.headers.keys.map((s) => s.toLowerCase()),
            isNot(contains('authorization')));
        expect(options.followRedirects, isFalse);
        return _json({
          'success': true,
          'data': {'captchaId': 'id', 'captchaImage': 'data:image/png;base64,a'}
        });
      });
    expect(await ServerConnection.probe('https://example.com', client: dio),
        'https://example.com/api/agent-bus/v1');
  });

  test('probe rejects redirects, HTML, incomplete or failing envelopes',
      () async {
    for (final response in [
      _json({'success': true}, 302),
      ResponseBody.fromString('<html>login</html>', 200),
      _json({'success': true, 'data': {}}),
      _json({
        'success': false,
        'data': {'captchaId': 'id', 'captchaImage': 'image'}
      }),
    ]) {
      final dio = Dio()..httpClientAdapter = _Adapter((_) async => response);
      await expectLater(
          ServerConnection.probe('https://example.com', client: dio),
          throwsFormatException);
    }
  });

  test('saved profile does not activate server or change local preferences',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('local-sentinel', 'retained');
    await ServerConnection.save('https://example.com');
    expect(await ServerConnection.savedAddress(),
        'https://example.com/api/agent-bus/v1');
    expect(AppConfig.serverWorkspace, isFalse);
    expect(prefs.getString('local-sentinel'), 'retained');
  });

  test('old response and old client cannot cross a connection boundary',
      () async {
    AppConfig.serverApiUrl = 'https://a.example/api/agent-bus/v1';
    final response = Completer<ResponseBody>();
    final started = Completer<void>();
    final oldClient = Dio()..interceptors.add(createRequestInterceptor());
    oldClient.httpClientAdapter = _Adapter((options) {
      expect(options.uri.host, 'a.example');
      started.complete();
      return response.future;
    });
    final pending = oldClient.get('/auth/me');
    final rejected = expectLater(
        pending,
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)));
    await started.future;
    AppConfig.connectionEpoch++;
    AppConfig.serverApiUrl = 'https://b.example/api/agent-bus/v1';
    response.complete(_json({'success': true, 'data': {}}));
    await rejected;
    await expectLater(oldClient.get('/auth/me'), throwsA(isA<DioException>()));
    oldClient.close();
  });

  test('switch drains active credential writes and rejects late writes/refresh',
      () async {
    final epoch = AppConfig.connectionEpoch;
    final release = Completer<void>();
    final started = Completer<void>();
    final active = withConnectionCredentials(epoch, () async {
      started.complete();
      await release.future;
      await (await SharedPreferences.getInstance()).setString('token', 'old');
    });
    await started.future;
    final refresher = tokenRefresher;
    AppConfig.connectionChanging = true;
    AppConfig.connectionEpoch++;
    var drained = false;
    final drain = drainConnectionCredentials().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    release.complete();
    await active;
    await drain;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    AppConfig.connectionChanging = false;
    await expectLater(
        withConnectionCredentials(
            epoch, () async => prefs.setString('token', 'late')),
        throwsStateError);
    await expectLater(
        refresher.persistTokens('late', 'late-refresh'), throwsStateError);
    expect(prefs.getString('token'), isNull);
  });
}
