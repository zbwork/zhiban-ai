import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/network/interceptor/response_interceptor.dart';
import 'package:zhiban_core/network/public_auth_paths.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/services/session_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_core/network/auth_refresh_interceptor.dart';
import 'package:zhiban_core/network/request_interceptor.dart';
import 'package:zhiban_core/session/token_refresher.dart';

class _ModelFailureAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    return ResponseBody.fromString(
        '{"success":false,"code":5020,"message":"model.request_invalid: 模型请求格式错误（HTTP 400）。"}',
        502,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}

class _EnvelopeAdapter implements HttpClientAdapter {
  _EnvelopeAdapter(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
          Future<void>? cancel) async =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        },
      );

  @override
  void close({bool force = false}) {}
}

void main() {
  test('envelope rejection refreshes and replays with new authorization',
      () async {
    SharedPreferences.setMockInitialValues({AppConfig.storageTokenKey: 'old'});
    RequestInterceptor.clearTokenCache();
    addTearDown(RequestInterceptor.clearTokenCache);
    final body = <String, dynamic>{'success': false, 'code': 4010};
    final headers = <Object?>[];
    var refreshes = 0;
    final dio = Dio()
      ..httpClientAdapter = _EnvelopeAdapter(200, body)
      ..interceptors.add(createRequestInterceptor())
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        headers.add(options.headers['Authorization']);
        handler.next(options);
      }))
      ..interceptors.add(ResponseInterceptor());
    addTearDown(dio.close);
    dio.interceptors.add(AuthRefreshInterceptor(dio,
        refresh: () async {
          refreshes++;
          await tokenRefresher.persistTokens('next', 'next-refresh');
          RequestInterceptor.clearTokenCache();
          RequestInterceptor.primeToken('next');
          body
            ..clear()
            ..addAll({'success': true, 'data': 'ok'});
          return RefreshOutcome.ok;
        },
        forceLogout: () => fail('unexpected logout')));
    final response = await dio.get<dynamic>('/auth/me',
        options: Options(extra: {'silent': true}));
    expect(response.data, 'ok');
    expect(refreshes, 1);
    expect(headers, ['Bearer old', 'Bearer next']);
  });

  for (final code in ['call.room_busy', 'call.account_busy']) {
    test('409 $code remains machine readable after the real interceptor',
        () async {
      final envelope = <String, dynamic>{
        'success': false,
        'code': 4090,
        'message': code,
        'traceId': 'rtc-test-trace',
      };
      final dio = Dio(BaseOptions(validateStatus: (s) => s != null && s < 500))
        ..httpClientAdapter = _EnvelopeAdapter(409, envelope)
        ..interceptors.add(ResponseInterceptor());
      try {
        await dio.post<void>('http://localhost/calls',
            options: Options(extra: {'silent': true}));
        fail('expected conflict');
      } on DioException catch (error) {
        expect(error.response?.statusCode, 409);
        expect(error.response?.data, envelope);
        expect(error.error, '请求失败');
      } finally {
        dio.close();
      }
    });
  }

  test('successful responses still unwrap data', () async {
    final dio = Dio()
      ..httpClientAdapter = _EnvelopeAdapter(200, {
        'success': true,
        'code': 0,
        'message': 'ok',
        'data': {'call_uuid': 'call-test'},
      })
      ..interceptors.add(ResponseInterceptor());
    try {
      final response =
          await dio.post<Map<String, dynamic>>('http://localhost/calls');
      expect(response.data, {'call_uuid': 'call-test'});
    } finally {
      dio.close();
    }
  });

  test('5xx interceptor preserves a safe model reason instead of server busy',
      () async {
    final dio = Dio()..httpClientAdapter = _ModelFailureAdapter();
    dio.interceptors.add(ResponseInterceptor());
    try {
      await dio.get<void>('http://localhost/model',
          options: Options(extra: {'silent': true}));
      fail('expected model error');
    } on DioException catch (error) {
      expect(error.error, '模型请求格式错误（HTTP 400）。');
    } finally {
      dio.close();
    }
  });

  test('public auth requests do not trigger global re-login handling', () {
    expect(
      isPublicAuthRequestPath('/auth/login/sms'),
      isTrue
    );
    expect(
      isPublicAuthRequestPath(
        '/api/agent-bus/v1/auth/register/sms'
      ),
      isTrue,
    );
    expect(
      isPublicAuthRequestPath(
        'http://localhost:8080/api/agent-bus/v1/auth/sms/send',
      ),
      isTrue,
    );
  });

  test('session-bound auth requests still trigger global re-login handling',
      () {
    expect(isPublicAuthRequestPath('/auth/me'), isFalse);
    expect(
      isPublicAuthRequestPath('/auth/scope/switch'),
      isFalse
    );
    expect(
      isPublicAuthRequestPath('/chat/conversations'),
      isFalse
    );
  });

  test('204 response accepts the empty bodies Dio may expose', () {
    expect(ResponseInterceptor.isSuccessfulNoContent(204, null), isTrue);
    expect(ResponseInterceptor.isSuccessfulNoContent(204, ''), isTrue);
    expect(ResponseInterceptor.isSuccessfulNoContent(204, const {}), isFalse);
    expect(ResponseInterceptor.isSuccessfulNoContent(200, null), isFalse);
  });

  test('API diagnostics keep only safe HTTP correlation fields', () {
    final options = RequestOptions(
      path: '/runtime/ensure?token=must-not-log',
      method: 'POST',
      baseUrl: 'https://bus.example.com/api/agent-bus/v1',
      extra: const {'diagnosticOperation': 'runtime.ensure'},
    );
    final line = ResponseInterceptor.diagnosticLine(
      DioException(
        requestOptions: options,
        response: Response(
          requestOptions: options,
          statusCode: 503,
          data: {
            'message': 'runtime.warming: internal endpoint must not appear',
            'traceId': 'trace-123',
          },
        ),
        type: DioExceptionType.badResponse,
      ),
    );

    expect(line, contains('operation=runtime.ensure'));
    expect(line, contains('path=/api/agent-bus/v1/runtime/ensure'));
    expect(line, contains('status=503'));
    expect(line, contains('code=runtime.warming'));
    expect(line, contains('trace_id=trace-123'));
    expect(line, isNot(contains('must-not-log')));
    expect(line, isNot(contains('token=')));
  });
}
