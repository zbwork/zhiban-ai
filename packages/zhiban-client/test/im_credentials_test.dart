import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/im/im_credentials_client.dart';
import 'package:zhiban_client/im/im_credentials_storage.dart';
import 'package:zhiban_client/services/device_info_service.dart';

/// F09 IM credentials 单测（非 SDK 集成）。
///
/// 真正端到端 WuKong smoke 需要：
/// 1. 跑起来的 WuKongIM 集群
/// 2. 两个测试账号 (A / B) + 互为联系人
/// 3. agent-bus 已 issue 凭证
/// 这类需要 live env 的场景留给 docs/runbook 手工 smoke 步骤；
/// 单测覆盖范围限制在客户端纯逻辑：fromJson / isRefreshFresh / error code mapping /
/// refresh→issue 回退。
void main() {
  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.cancel,
    DioExceptionType.badCertificate,
    DioExceptionType.unknown
  ]) {
    test('credentials preserves transport failure $type for classification',
        () async {
      final client = IMCredentialsClient(
        storage: _InMemoryStorage(),
        deviceInfoCollector: _testDeviceInfo,
        dio: _StubDio(
            (opts, _) => throw DioException(requestOptions: opts, type: type)),
      );
      await expectLater(client.issue(),
          throwsA(isA<DioException>().having((e) => e.type, 'type', type)));
    });
  }

  for (final status in [500, 502, 503, 504]) {
    test('credentials preserves HTTP $status for classification', () async {
      final error = DioException(
        requestOptions: RequestOptions(path: '/im/credentials'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/im/credentials'),
          statusCode: status,
        ),
      );
      final client = IMCredentialsClient(
        storage: _InMemoryStorage(),
        deviceInfoCollector: _testDeviceInfo,
        dio: _StubDio((opts, _) => throw error),
      );
      await expectLater(client.issue(), throwsA(same(error)));
    });
  }

  group('IMCredentials.fromJson', () {
    test('解析全字段', () {
      final cred = IMCredentials.fromJson({
        'im_refresh_token': 'refresh_yy',
        'im_refresh_expires_at': '2099-12-31T00:00:00Z',
        'wukong': {
          'substrate': 'wukong',
          'uid': 'wk_001',
          'token': 'token_xx',
          'tcp_addr': '127.0.0.1:5100',
          'ws_addr': 'ws://127.0.0.1:5200',
          'device_id': 'device-test-0001',
          'device_flag': 2,
        },
      });

      expect(cred.imRefreshToken, 'refresh_yy');
      expect(cred.wukong?.uid, 'wk_001');
      expect(cred.wukong?.tcpAddr, '127.0.0.1:5100');
      expect(cred.wukong?.deviceFlag, 2);
      expect(cred.wukong?.deviceID, 'device-test-0001');
      expect(cred.isRefreshFresh, isTrue);
    });

    test('老后端未下发或下发非法 device_flag 时兼容回退 App', () {
      final missing = IMCredentials.fromJson({
        'im_refresh_token': 'r',
        'im_refresh_expires_at': '2099-12-31T00:00:00Z',
        'wukong': {'uid': 'wk', 'token': 't'},
      });
      final invalid = IMCredentials.fromJson({
        'im_refresh_token': 'r',
        'im_refresh_expires_at': '2099-12-31T00:00:00Z',
        'wukong': {'uid': 'wk', 'token': 't', 'device_flag': 99},
      });
      expect(missing.wukong?.deviceFlag, 0);
      expect(invalid.wukong?.deviceFlag, 0);
    });

    test('refresh 已过期 → isRefreshFresh = false', () {
      final cred = IMCredentials.fromJson({
        'im_refresh_token': 'r',
        'im_refresh_expires_at': '2020-01-01T00:00:00Z',
        'wukong': {
          'uid': 'wk',
          'token': 't'
        },
      });
      expect(cred.isRefreshFresh, isFalse);
    });
  });

  group('IMCredentialsException 分类', () {
    test('needsReLogin 覆盖 401 类业务码', () {
      expect(IMCredentialsException('imcred.refresh_expired').needsReLogin,
          isTrue);
      expect(IMCredentialsException('imcred.device_mismatch').needsReLogin,
          isTrue);
      expect(IMCredentialsException('imcred.refresh_invalid').needsReLogin,
          isTrue);
      expect(
          IMCredentialsException('imcred.cross_tenant').needsReLogin, isTrue);
    });

    test('isRetryable 只对 upstream 故障 true', () {
      expect(
          IMCredentialsException('imcred.wukong_upstream').isRetryable, isTrue);
      expect(
          IMCredentialsException('imcred.rate_limited').isRetryable, isFalse);
      expect(IMCredentialsException('wukong_disabled').isRetryable, isFalse);
    });
  });

  group('IMCredentialsClient.refresh fallback', () {
    test('无本地 refresh_token → 直接走 issue 分支', () async {
      final storage = _InMemoryStorage();
      final dio = _StubDio((opts, _) {
        // 调到接口；返回一份合法 cred。
        expect(opts.path, '/im/credentials');
        expect(opts.extra['silent'], isTrue);
        return Response<dynamic>(
          requestOptions: opts,
          statusCode: 200,
          data: _validCredJson(),
        );
      });
      final client = IMCredentialsClient(
        storage: storage,
        dio: dio,
        deviceInfoCollector: _testDeviceInfo,
      );
      final cred = await client.refresh();
      expect(cred.wukong?.uid, 'wk_001');
      expect(await storage.readRefreshToken(), 'refresh_yy');
    });

    test('refresh 报 401 device_mismatch → 自动清 token 并重新 issue', () async {
      final storage = _InMemoryStorage();
      await storage.writeRefreshToken(
        refreshToken: 'stale',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
      );

      var calls = 0;
      final dio = _StubDio((opts, _) {
        calls++;
        if (calls == 1) {
          // 第一次：refresh 调用，返 401 device_mismatch
          return Response<dynamic>(
            requestOptions: opts,
            statusCode: 401,
            data: null,
            statusMessage: 'imcred.device_mismatch',
          );
        }
        // 第二次：fallback issue，成功
        return Response<dynamic>(
          requestOptions: opts,
          statusCode: 200,
          data: _validCredJson(),
        );
      }, throwOnStatus: (resp) {
        if (resp.statusCode == 401) {
          throw DioException(
            requestOptions: resp.requestOptions,
            response: resp,
            error: 'imcred.device_mismatch',
            type: DioExceptionType.badResponse,
          );
        }
      });
      final client = IMCredentialsClient(
        storage: storage,
        dio: dio,
        deviceInfoCollector: _testDeviceInfo,
      );
      final cred = await client.refresh();
      expect(cred.wukong?.uid, 'wk_001');
      expect(calls, 2);
    });

    test('fetchWukongConnInfo 返回 wukong 连接信息', () async {
      final storage = _InMemoryStorage();
      final dio = _StubDio((opts, _) {
        expect(opts.path, '/im/credentials');
        return Response<dynamic>(
          requestOptions: opts,
          statusCode: 200,
          data: _validCredJson(),
        );
      });
      final client = IMCredentialsClient(
        storage: storage,
        dio: dio,
        deviceInfoCollector: _testDeviceInfo,
      );
      final info = await client.fetchWukongConnInfo();
      expect(info.substrate, 'wukong');
      expect(info.uid, 'wk_001');
      expect(info.tcpAddr, '127.0.0.1:5100');
    });
  });

  test('issue 上报客户端版本并使用 Bus 回显的同一 DeviceID', () async {
    final storage = _InMemoryStorage();
    final dio = _StubDio((opts, _) {
      final body = (opts.data as Map).cast<String, dynamic>();
      expect(body['device_id'], 'device-test-0001');
      expect(body['client_version'], '1.6.2+1087');
      expect(body['os_version'], '15.6');
      expect(body['platform'], isNotEmpty);
      return Response<dynamic>(
        requestOptions: opts,
        statusCode: 200,
        data: _validCredJson(),
      );
    });
    final client = IMCredentialsClient(
      storage: storage,
      dio: dio,
      deviceInfoCollector: _testDeviceInfo,
    );

    final cred = await client.issue();
    expect(cred.wukong?.deviceID, 'device-test-0001');
  });
}

Future<LoginDeviceInfo> _testDeviceInfo() async => const LoginDeviceInfo(
      type: 'macOS',
      systemVersion: '15.6',
      appVersion: '1.6.2+1087',
    );

Map<String, dynamic> _validCredJson() => {
      'im_refresh_token': 'refresh_yy',
      'im_refresh_expires_at': '2099-12-31T00:00:00Z',
      'wukong': {
        'substrate': 'wukong',
        'uid': 'wk_001',
        'token': 'token_xx',
        'tcp_addr': '127.0.0.1:5100',
        'ws_addr': 'ws://127.0.0.1:5200',
        'device_id': 'device-test-0001',
        'device_flag': 2,
      },
    };

class _InMemoryStorage implements IMCredentialsStorage {
  final Map<String, String> _kv = {};
  String? _deviceId;

  @override
  Future<String> getOrCreateDeviceId() async {
    _deviceId ??= 'device-test-0001';
    return _deviceId!;
  }

  @override
  Future<String?> readRefreshToken() async => _kv['refresh'];

  @override
  Future<DateTime?> readRefreshExpiresAt() async {
    final raw = _kv['refresh_expires'];
    return raw == null ? null : DateTime.tryParse(raw);
  }

  @override
  Future<void> writeRefreshToken({
    required String refreshToken,
    required DateTime expiresAt,
  }) async {
    _kv['refresh'] = refreshToken;
    _kv['refresh_expires'] = expiresAt.toUtc().toIso8601String();
  }

  @override
  Future<void> clearTokens() async {
    _kv.remove('refresh');
    _kv.remove('refresh_expires');
  }

  @override
  Future<void> clearAll() async {
    _kv.clear();
    _deviceId = null;
  }

  // Storage 的非接口字段（构造器内部成员）不需要重写。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 极简 Dio stub：直接复用真实 Dio 实例，重写 fetch 走单测路径。
class _StubDio implements Dio {
  _StubDio(this._handler, {this.throwOnStatus});

  final Response<dynamic> Function(
    RequestOptions options,
    bool throwIfNeeded
  ) _handler;
  final void Function(Response<dynamic> resp)? throwOnStatus;

  @override
  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    final opts = RequestOptions(path: path, data: data, extra: options?.extra);
    final resp = _handler(opts, true);
    final shouldThrow = throwOnStatus;
    if (shouldThrow != null) shouldThrow(resp);
    return Response<T>(
      requestOptions: opts,
      data: resp.data as T?,
      statusCode: resp.statusCode,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('stub: ${invocation.memberName}');
}
