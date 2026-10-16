import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/wukong/wukong_im_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wukongimfluttersdk/db/wk_db_helper.dart';
import 'package:wukongimfluttersdk/type/const.dart';
import 'package:wukongimfluttersdk/wkim.dart';

class _GatedInitClient extends WukongImClient {
  final gate = Completer<void>();

  @override
  Future<void> init() => gate.future;
}

const _info = ImConnInfo(
  substrate: 'wukong',
  uid: 'logout-test-user',
  token: 'test-token',
  tcpAddr: '',
  wsAddr: 'ws://localhost',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
      'logout is idle before disconnect and ignores late SDK events; relogin works',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('wk-logout-');
    await databaseFactory.setDatabasesPath(dir.path);
    final client = WukongImClient();
    addTearDown(() async {
      await client.logout();
      await client.dispose();
      await WKDBHelper.shared.close();
      await dir.delete(recursive: true);
    });
    await client.login(_info);
    WKIM.shared.connectionManager.setConnectionStatus(WKConnectStatus.success);
    expect(client.isRealtimeConnected, isTrue);
    final logout = client.logout();
    expect(client.connectionStatus, ImConnectionStatus.idle);
    expect(client.connectedUid, isNull);
    await logout;
    for (final status in [
      WKConnectStatus.fail,
      WKConnectStatus.noNetwork,
      WKConnectStatus.connecting,
      WKConnectStatus.success,
      WKConnectStatus.kicked
    ]) {
      WKIM.shared.connectionManager.setConnectionStatus(status);
      expect(client.connectionStatus, ImConnectionStatus.idle);
    }
    await client.connect();
    expect(client.connectionStatus, ImConnectionStatus.idle);
    await client.login(_info);
    WKIM.shared.connectionManager.setConnectionStatus(WKConnectStatus.success);
    expect(client.connectedUid, _info.uid);
    expect(client.isRealtimeConnected, isTrue);
  });

  test('logout while login init pending cannot resurrect identity', () async {
    final client = _GatedInitClient();
    addTearDown(client.dispose);
    final login = client.login(_info);
    await client.logout();
    client.gate.complete();
    await login;
    expect(client.connectedUid, isNull);
    expect(client.connectionStatus, ImConnectionStatus.idle);
  });
}
