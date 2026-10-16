import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/im/wukong/wukong_cache_cleanup.dart';
import 'package:zhiban_client/im/wukong/wukong_local_schema.dart';
import 'package:zhiban_client/pages/chat/services/chat_local_store.dart';
import 'package:zhiban_client/services/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late ChatLocalStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppConfig.applyEnvOverride(null);
    ChatCacheScope.resetSession();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 1, onCreate: ChatLocalStore.createSchema));
    store = ChatLocalStore(database: Future.value(db));
    ChatLocalStore.setSharedForTesting(store);
  });
  tearDown(() async {
    debugClearImCacheOverride = null;
    ChatLocalStore.setSharedForTesting(null);
    AppConfig.applyEnvOverride(null);
    await db.close();
  });

  test(
      'clears list/history/receipts only for target scope and fences old writes',
      () async {
    for (final scope in ['a', 'b']) {
      for (final kind in ['list', 'history', 'receipts']) {
        await store.write(
            scope,
            kind,
            kind,
            {
              'items': [1]
            },
            expectedRevision: 0);
      }
    }
    final pendingRevision = store.revision('a', 'never-written');
    await store.clearScope('a');
    expect(await db.query('chat_cache', where: 'scope = ?', whereArgs: ['a']),
        isEmpty);
    expect(await db.query('chat_cache', where: 'scope = ?', whereArgs: ['b']),
        hasLength(3));
    await store.write(
        'a',
        'never-written',
        'history',
        {
          'items': [1]
        },
        expectedRevision: pendingRevision);
    expect(await store.read('a', 'never-written', 'history'), isNull);
    await store.write(
        'a',
        'new',
        'history',
        {
          'items': [2]
        },
        expectedRevision: store.revision('a', 'new'));
    expect(await store.read('a', 'new', 'history'), isNotNull);
    await store.remove('a', 'new');
    final old = store.revision('a', 'new');
    await store.clearScope('a');
    expect(store.revision('a', 'new'), greaterThan(old));
  });

  test('SDK eviction uses real schema and preserves unsent messages and drafts',
      () async {
    await replayWukongSchema(db);
    for (final id in ['sent', 'pending', 'failed']) {
      await db.insert('message', {
        'client_msg_no': id,
        'message_id': id,
        'channel_id': id,
        'channel_type': 2,
        'message_seq': id == 'sent' ? 10 : 0,
        'status': id == 'sent'
            ? 1
            : id == 'failed'
                ? 2
                : 0,
      });
      await db.insert('conversation', {'channel_id': id, 'channel_type': 2});
      await db
          .insert('conversation_extra', {'channel_id': id, 'channel_type': 2});
      await db.insert('message_extra', {'message_id': id});
      await db.insert('message_reaction', {'message_id': id, 'uid': id});
    }
    await db.insert('conversation', {'channel_id': 'draft', 'channel_type': 2});
    await db.insert('conversation_extra',
        {'channel_id': 'draft', 'channel_type': 2, 'draft': 'keep me'});
    await clearWukongCachedRows(db);
    expect((await db.query('message')).map((e) => e['message_id']),
        unorderedEquals(['pending', 'failed']));
    expect((await db.query('conversation')).map((e) => e['channel_id']),
        unorderedEquals(['pending', 'failed', 'draft']));
    expect(await db.query('message_extra'), hasLength(2));
    expect(await db.query('message_reaction'), hasLength(2));
    expect(
        (await db.query('conversation_extra',
                where: 'channel_id = ?', whereArgs: ['draft']))
            .single['draft'],
        'keep me');
    expect(await wukongHasCriticalTables(db), isTrue);
    await clearWukongCachedRows(db);
    expect(await db.query('message'), hasLength(2));
  });

  test(
      'settings cleanup preserves credentials, clears scoped cache and resets session',
      () async {
    final token = 'e30.${base64Url.encode(utf8.encode(jsonEncode({
          'aid': 1,
          'act_tid': 2
        })))}.sig';
    SharedPreferences.setMockInitialValues({
      AppConfig.storageTokenKey: token,
      AppConfig.storageRefreshTokenKey: 'refresh',
      AppConfig.storageWorkbenchAppsKey: 'cached',
      AppConfig.storageEnvOverrideKey: 'dev'
    });
    AppConfig.applyEnvOverride(AppEnv.dev);
    final scope = await ChatCacheScope.current();
    expect(scope, isNotNull);
    await store.write(
        scope!.key,
        'history',
        'history',
        {
          'items': [1]
        },
        expectedRevision: 0);
    var imCalls = 0;
    debugClearImCacheOverride = () async {
      imCalls++;
    };
    final epoch = sessionScopeKey.value;
    await const SessionService().clearCacheStorage();
    final prefs = await SharedPreferences.getInstance();
    expect(imCalls, 1);
    expect(prefs.getString(AppConfig.storageTokenKey), token);
    expect(prefs.getString(AppConfig.storageRefreshTokenKey), 'refresh');
    expect(prefs.containsKey(AppConfig.storageWorkbenchAppsKey), isFalse);
    expect(prefs.getString(AppConfig.storageEnvOverrideKey), 'dev');
    expect(AppConfig.env, AppEnv.dev);
    expect(await store.read(scope.key, 'history', 'history'), isNull);
    expect(sessionScopeKey.value, epoch + 1);
  });

  test('partial failure propagates without deleting credentials', () async {
    SharedPreferences.setMockInitialValues({AppConfig.storageTokenKey: 'keep'});
    debugClearImCacheOverride =
        () async => throw StateError('disk unavailable');
    await expectLater(
        const SessionService().clearCacheStorage(), throwsStateError);
    expect(
        (await SharedPreferences.getInstance())
            .getString(AppConfig.storageTokenKey),
        'keep');
  });
}
