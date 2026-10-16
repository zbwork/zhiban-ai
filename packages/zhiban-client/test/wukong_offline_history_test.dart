import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wukongimfluttersdk/common/options.dart';
import 'package:wukongimfluttersdk/db/message.dart';
import 'package:wukongimfluttersdk/db/wk_db_helper.dart';
import 'package:wukongimfluttersdk/entity/msg.dart';
import 'package:wukongimfluttersdk/wkim.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('incomplete cached latest page returns without waiting for remote sync',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('wk-offline-history-');
    await databaseFactory.setDatabasesPath(dir.path);
    SharedPreferences.setMockInitialValues({});
    await WKIM.shared.setup(Options.newDefault('offline-test', 'test-token'));
    addTearDown(() async {
      WKIM.shared.messageManager.addOnSyncChannelMsgListener(null);
      await WKDBHelper.shared.close();
      await dir.delete(recursive: true);
    });
    for (final seq in [5, 7]) {
      await MessageDB.shared.insert(WKMsg()
        ..messageID = '$seq'
        ..messageSeq = seq
        ..orderSeq = seq * 1000
        ..channelID = 'cached'
        ..channelType = 2
        ..contentType = 1
        ..content = '{"type":1,"content":"cached"}');
    }
    var syncCalls = 0;
    WKIM.shared.messageManager
        .addOnSyncChannelMsgListener((a, b, c, d, e, f, back) {
      syncCalls++; // Deliberately no network callback.
    });
    final result = Completer<List<WKMsg>>();
    WKIM.shared.messageManager.getOrSyncHistoryMessages(
        'cached', 2, 0, true, 0, 40, 0, result.complete, () {});
    final rows = await result.future.timeout(const Duration(seconds: 1));
    expect(rows.map((m) => m.messageSeq), unorderedEquals([5, 7]));
    expect(syncCalls, 0);
    WKIM.shared.messageManager.addOnSyncChannelMsgListener((a, b, c, d, e, f, back) {
      syncCalls++;
      back(null);
    });
    final remote = Completer<List<WKMsg>>();
    WKIM.shared.messageManager.getOrSyncHistoryMessages(
        'cached', 2, 0, true, 0, 40, 0, remote.complete, () {}, true);
    await remote.future.timeout(const Duration(seconds: 1));
    expect(syncCalls, 1);
    final older = Completer<List<WKMsg>>();
    WKIM.shared.messageManager.getOrSyncHistoryMessages(
        'cached', 2, 8000, false, 0, 40, 0, older.complete, () {});
    await older.future.timeout(const Duration(seconds: 1));
    expect(syncCalls, 2);

  });
}
