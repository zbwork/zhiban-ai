import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wukongimfluttersdk/common/crypto_utils.dart';
import 'package:wukongimfluttersdk/common/options.dart';
import 'package:wukongimfluttersdk/proto/proto.dart';
import 'package:wukongimfluttersdk/proto/write_read.dart';
import 'package:wukongimfluttersdk/type/const.dart';
import 'package:wukongimfluttersdk/wkim.dart';

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _WebSocketFixture {
  _WebSocketFixture(this.server, this.sockets);

  final HttpServer server;
  final List<WebSocket> sockets;
}

class _RecordingWebSocket implements WebSocket {
  int closeCalls = 0;
  int _readyState = WebSocket.open;

  @override
  int get readyState => _readyState;

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCalls++;
    _readyState = WebSocket.closed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<_WebSocketFixture> _startWebSocketServer(void Function()? onConnected,
    {void Function(dynamic data)? onData}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final sockets = <WebSocket>[];
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    if (onData != null) {
      socket.listen(onData);
    }
    onConnected?.call();
  });
  return _WebSocketFixture(server, sockets);
}

Uint8List _connackSuccessBytes() {
  final publicKey = CryptoUtils.dhPublicKey;
  if (publicKey == null) throw StateError('CONNECT packet was not sent');
  final body = WriteData()
    ..writeUint64(BigInt.zero)
    ..writeUint8(1)
    ..writeString(base64Encode(publicKey))
    ..writeString('1234567890123456')
    ..writeUint64(BigInt.one);
  return Uint8List.fromList(<int>[
    PacketType.connack.index << 4,
    ...encodeVariableLength(body.data.length),
    ...body.data,
  ]);
}

Uint8List _disconnectBytes({int reasonCode = 1, String reason = 'kicked'}) {
  final body = WriteData()
    ..writeUint8(reasonCode)
    ..writeString(reason);
  return Uint8List.fromList(<int>[
    PacketType.disconnect.index << 4,
    ...encodeVariableLength(body.data.length),
    ...body.data,
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final manager = WKIM.shared.connectionManager;
    manager.isNetworkUnavailable = false;
    manager.webSocketConnectTimeout = const Duration(seconds: 5);
    manager.webSocketConnector = WebSocket.connect;
    await manager.disconnect(false);
  });

  test('explicit recovery connect must not wait for stale offline flag', () async {
    var connections = 0;
    final fixture = await _startWebSocketServer(() => connections++);
    addTearDown(() async {
      await WKIM.shared.connectionManager.disconnect(false);
      for (final socket in fixture.sockets) {
        await socket.close();
      }
      await fixture.server.close(force: true);
    });

    WKIM.shared.options = Options.newDefault(
      'uid-single-flight',
      'token',
      addr: 'ws://${fixture.server.address.address}:${fixture.server.port}',
    );

    WKIM.shared.connectionManager.isNetworkUnavailable = true;
    WKIM.shared.connectionManager.connect();
    WKIM.shared.connectionManager.connect();
    WKIM.shared.connectionManager.connect();

    await _waitUntil(() => connections == 1);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(connections, 1);
  });

  test('repeated connect while connecting is single-flight', () async {
    var connections = 0;
    final fixture = await _startWebSocketServer(() => connections++);
    addTearDown(() async {
      await WKIM.shared.connectionManager.disconnect(false);
      for (final socket in fixture.sockets) {
        await socket.close();
      }
      await fixture.server.close(force: true);
    });

    WKIM.shared.options = Options.newDefault(
      'uid-single-flight',
      'token',
      addr: 'ws://${fixture.server.address.address}:${fixture.server.port}',
    );

    WKIM.shared.connectionManager.connect();
    WKIM.shared.connectionManager.connect();
    WKIM.shared.connectionManager.connect();

    await _waitUntil(() => connections == 1);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(connections, 1);
  });

  test('repeated connect after connack success remains idempotent', () async {
    const channel = MethodChannel('dev.fluttercommunity.plus/connectivity');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => ['wifi']);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    WKIM.shared.connectionManager.lastConnectivityResult = ConnectivityResult.none;
    var connections = 0;
    dynamic firstFrame;
    final fixture = await _startWebSocketServer(
      () => connections++,
      onData: (dynamic data) => firstFrame ??= data,
    );
    final statuses = <int>[];
    const listenerKey = 'connected-idempotent-test';
    WKIM.shared.connectionManager.addOnConnectionStatus(
      listenerKey,
      (int status, int? reasonCode, dynamic info) => statuses.add(status),
    );
    addTearDown(() async {
      WKIM.shared.connectionManager.removeOnConnectionStatus(listenerKey);
      await WKIM.shared.connectionManager.disconnect(false);
      for (final socket in fixture.sockets) {
        await socket.close();
      }
      await fixture.server.close(force: true);
    });

    WKIM.shared.options = Options.newDefault(
      'uid-connected-idempotent',
      'token',
      addr: 'ws://${fixture.server.address.address}:${fixture.server.port}',
    );
    final manager = WKIM.shared.connectionManager;
    manager.connect();
    await _waitUntil(() => firstFrame != null);
    manager.testCutData(_connackSuccessBytes());
    await _waitUntil(() => statuses.contains(WKConnectStatus.success));

    manager.connect();
    manager.connect();
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(statuses.where((s) => s == WKConnectStatus.fail), isEmpty,
        reason: '新连接不能被上一代 none 网络快照误判为网络切换而断开');
    expect(connections, 1);
  });

  test('server disconnect is terminal until login state is restored', () async {
    var connections = 0;
    dynamic firstFrame;
    final fixture = await _startWebSocketServer(
      () => connections++,
      onData: (dynamic data) => firstFrame ??= data,
    );
    final statuses = <int>[];
    const listenerKey = 'kicked-terminal-test';
    final manager = WKIM.shared.connectionManager;
    manager.addOnConnectionStatus(
      listenerKey,
      (int status, int? reasonCode, dynamic info) => statuses.add(status),
    );
    addTearDown(() async {
      manager.removeOnConnectionStatus(listenerKey);
      await manager.disconnect(false);
      for (final socket in fixture.sockets) {
        await socket.close();
      }
      await fixture.server.close(force: true);
    });

    WKIM.shared.options = Options.newDefault(
      'uid-kicked-terminal',
      'token',
      addr: 'ws://${fixture.server.address.address}:${fixture.server.port}',
    );
    manager.connect();
    await _waitUntil(() => firstFrame != null);
    manager.testCutData(_connackSuccessBytes());
    await _waitUntil(() => statuses.contains(WKConnectStatus.success));

    manager.testCutData(_disconnectBytes());
    await _waitUntil(() => statuses.contains(WKConnectStatus.kicked));
    await _waitUntil(() => WKIM.shared.options.uid?.isEmpty ?? true);

    manager.connect();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(connections, 1, reason: 'kicked state must require a fresh login');
  });

  test('configured stable device ID is sent in CONNECT packet', () async {
    dynamic firstFrame;
    final fixture = await _startWebSocketServer(
      null,
      onData: (dynamic data) => firstFrame ??= data,
    );
    addTearDown(() async {
      await WKIM.shared.connectionManager.disconnect(false);
      for (final socket in fixture.sockets) {
        await socket.close();
      }
      await fixture.server.close(force: true);
    });

    WKIM.shared.options = Options.newDefault(
      'uid-stable-device',
      'token',
      addr: 'ws://${fixture.server.address.address}:${fixture.server.port}',
      deviceID: 'business-device-001',
    );
    WKIM.shared.connectionManager.connect();
    await _waitUntil(() => firstFrame != null);

    final bytes = List<int>.from(firstFrame as List<dynamic>);
    expect(utf8.decode(bytes, allowMalformed: true),
        contains('business-device-001'));
  });

  test('unexpected socket close reports failure without SDK reconnect',
      () async {
    var connections = 0;
    final fixture = await _startWebSocketServer(() => connections++);
    final statuses = <int>[];
    const listenerKey = 'single-flight-close-test';
    WKIM.shared.connectionManager.addOnConnectionStatus(
      listenerKey,
      (int status, int? reasonCode, dynamic info) => statuses.add(status),
    );
    addTearDown(() async {
      WKIM.shared.connectionManager.removeOnConnectionStatus(listenerKey);
      await WKIM.shared.connectionManager.disconnect(false);
      for (final socket in fixture.sockets) {
        await socket.close();
      }
      await fixture.server.close(force: true);
    });

    WKIM.shared.options = Options.newDefault(
      'uid-close',
      'token',
      addr: 'ws://${fixture.server.address.address}:${fixture.server.port}',
    );
    WKIM.shared.connectionManager.connect();
    await _waitUntil(() => connections == 1);

    await fixture.sockets.single.close();
    await _waitUntil(() => statuses.contains(WKConnectStatus.fail));
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(connections, 1, reason: 'SDK must wait for the bridge to retry');
  });

  test('old onDone after disconnect cannot replace the new connection',
      () async {
    var connections = 0;
    final fixture = await _startWebSocketServer(() => connections++);
    addTearDown(() async {
      await WKIM.shared.connectionManager.disconnect(false);
      for (final socket in fixture.sockets) {
        await socket.close();
      }
      await fixture.server.close(force: true);
    });

    WKIM.shared.options = Options.newDefault(
      'uid-generation',
      'token',
      addr: 'ws://${fixture.server.address.address}:${fixture.server.port}',
    );
    final manager = WKIM.shared.connectionManager;
    manager.connect();
    await _waitUntil(() => connections == 1);

    await manager.disconnect(false);
    manager.connect();
    await _waitUntil(() => connections == 2);
    await Future<void>.delayed(const Duration(seconds: 2));

    expect(connections, 2);
  });

  test('websocket timeout reports once and closes a late handshake result',
      () async {
    final statuses = <int>[];
    const listenerKey = 'late-websocket-timeout-test';
    final manager = WKIM.shared.connectionManager;
    final lateSocket = _RecordingWebSocket();
    final connector = Completer<WebSocket>();
    manager.webSocketConnectTimeout = const Duration(milliseconds: 20);
    manager.webSocketConnector = (_) => connector.future;
    manager.addOnConnectionStatus(
      listenerKey,
      (int status, int? reasonCode, dynamic info) => statuses.add(status),
    );
    addTearDown(() async {
      manager.webSocketConnectTimeout = const Duration(seconds: 5);
      manager.webSocketConnector = WebSocket.connect;
      manager.removeOnConnectionStatus(listenerKey);
      await manager.disconnect(false);
    });

    WKIM.shared.options = Options.newDefault(
      'uid-timeout',
      'token',
      addr: 'ws://late-connect.test',
    );
    manager.connect();

    await _waitUntil(() => statuses.contains(WKConnectStatus.fail));
    connector.complete(lateSocket);
    await _waitUntil(() => lateSocket.closeCalls == 1);

    expect(statuses.where((s) => s == WKConnectStatus.connecting).length, 1);
    expect(statuses.where((s) => s == WKConnectStatus.fail).length, 1);
  });
}
