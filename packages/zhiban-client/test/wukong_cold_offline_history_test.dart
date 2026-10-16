import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart' hide Options;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wukongimfluttersdk/common/options.dart';
import 'package:wukongimfluttersdk/db/message.dart';
import 'package:wukongimfluttersdk/db/wk_db_helper.dart';
import 'package:wukongimfluttersdk/entity/msg.dart';
import 'package:wukongimfluttersdk/wkim.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/im_credentials_client.dart';
import 'package:zhiban_client/im/human_direct_im_controller.dart';
import 'package:zhiban_client/im/wukong/wukong_im_client.dart';
import 'package:zhiban_client/pages/chat/services/chat_local_store.dart';

String _token(String account, int tenant) {
  final claims = base64Url.encode(utf8.encode(jsonEncode({
    'aid': account,
    'sub': account,
    'act_tid': tenant,
  })));
  return 'x.$claims.x';
}

class _OfflineCredentials extends IMCredentialsClient {
  _OfflineCredentials({this.failure});
  final Object? failure;
  int calls = 0;
  @override
  Future<ImConnInfo> fetchWukongConnInfo() async {
    calls++;
    if (failure != null) throw failure!;
    throw DioException(
        requestOptions: RequestOptions(path: '/im/credentials'),
        type: DioExceptionType.connectionError);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'new IM client reads existing disk before offline credentials without login',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('wk-cold-offline-');
    await databaseFactory.setDatabasesPath(dir.path);
    AppConfig.applyEnvOverride(AppEnv.dev);
    SharedPreferences.setMockInitialValues({'token': _token('account-a', 1)});
    ChatCacheScope.resetSession();
    final writer = WukongImClient();
    await writer.login(const ImConnInfo(
        substrate: 'wukong',
        uid: 't_1_u_account-a',
        token: 'test-token',
        tcpAddr: '',
        wsAddr: 'ws://localhost'));
    for (final seq in [1, 2, 3, 4]) {
      await MessageDB.shared.insert(WKMsg()
        ..messageID = '$seq'
        ..messageSeq = seq
        ..orderSeq = seq * 1000
        ..channelID = 'saved-channel'
        ..channelType = 2
        ..fromUID = 't_1_u_account-a'
        ..timestamp = seq
        ..status = seq == 4 ? 2 : 1
        ..contentType = 1
        ..content = jsonEncode({'type': 1, 'content': 'saved $seq'}));
    }
    await MessageDB.shared.insertMsgExtras([
      WKMsgExtra()
        ..messageID = '2'
        ..revoke = 1,
      WKMsgExtra()
        ..messageID = '3'
        ..isMutualDeleted = 1,
    ]);
    await writer.dispose();
    await WKDBHelper.shared.close();
    WKIM.shared.options = Options(); // No SDK login survives process restart.
    ChatCacheScope.resetSession();
    final client = WukongImClient();
    addTearDown(() async {
      await client.dispose();
      await WKDBHelper.shared.close();
      await dir.delete(recursive: true);
      AppConfig.applyEnvOverride(null);
      ChatCacheScope.resetSession();
    });
    final credentials = _OfflineCredentials();
    final controller = HumanDirectImController(
        client: client,
        credentials: credentials,
        presetChannelId: 'saved-channel',
        presetChannelType: 2,
        presetConversationUuid: 'conversation');
    await controller.open();
    expect(credentials.calls, 1);
    expect(client.connectedUid, isNull);
    expect(WKIM.shared.options.uid, isNull);
    expect(WKDBHelper.shared.getDB(), isNull);
    expect(controller.loading, isFalse);
    expect(controller.error, isNull);
    expect(controller.messages.map((m) => m.messageId), ['1', '2', '4']);
    expect(controller.messages[0].text, 'saved 1');
    expect(controller.messages[1].isRevoked, isTrue);
    expect(controller.messages[1].text, isEmpty);
    expect(controller.messages[2].isFailed, isTrue);
    controller.dispose();

    final cleared = HumanDirectImController(
        client: client,
        credentials: credentials,
        presetChannelId: 'saved-channel',
        presetChannelType: 2,
        presetConversationUuid: 'conversation',
        presetClearedAt: '1970-01-01T00:00:02Z');
    await cleared.open();
    expect(cleared.messages.map((m) => m.messageId), ['4']);
    cleared.dispose();

    final denied = HumanDirectImController(
      client: client,
      credentials: _OfflineCredentials(failure: IMCredentialsException('imcred.cross_tenant')),
      presetChannelId: 'saved-channel', presetChannelType: 2,
      presetConversationUuid: 'conversation');
    await denied.open();
    expect(denied.historyAccessDenied, isTrue);
    expect(denied.messages, isEmpty);
    denied.dispose();

    final prefs = await SharedPreferences.getInstance();
    for (final token in [_token('account-b', 1), _token('account-a', 2)]) {
      await prefs.setString('token', token);
      ChatCacheScope.resetSession();
      expect(await client.readLocalHistory('saved-channel', 2), isNull);
    }
    await prefs.setString('token', _token('account-a', 1));
    AppConfig.applyEnvOverride(AppEnv.test);
    expect(await client.readLocalHistory('saved-channel', 2), isNull);
    AppConfig.applyEnvOverride(AppEnv.dev);
    await prefs.remove('token');
    ChatCacheScope.resetSession();
    expect(await client.readLocalHistory('saved-channel', 2), isNull);
  });
}
