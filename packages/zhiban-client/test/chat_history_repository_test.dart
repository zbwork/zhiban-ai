import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/pages/chat/services/chat_history_repository.dart';
import 'package:zhiban_client/pages/chat/services/chat_local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> message(int id, {String status = 'final'}) => {
      'uuid': '$id',
      'role': 'assistant',
      'status': status,
      'created_at': '2026-10-08T00:00:00Z',
      'blocks': [
        {'type': 'text', 'text': 'message $id'}
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late ChatLocalStore store;
  late Dio dio;
  late ChatCacheScope? identity;
  late ChatHistoryRepository repo;
  late List<RequestOptions> requests;
  late Future<List<Map<String, dynamic>>> Function(RequestOptions) respond;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 1, onCreate: ChatLocalStore.createSchema));
    store = ChatLocalStore(database: Future.value(db));
    dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'));
    identity = const ChatCacheScope('account-a/tenant-a/env-a', 1);
    requests = [];
    respond = (_) async => [message(1), message(2)];
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      requests.add(options);
      try {
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'items': await respond(options)}));
      } catch (e) {
        handler.reject(e is DioException
            ? e
            : DioException(requestOptions: options, error: e));
      }
    }));
    repo = ChatHistoryRepository(
        dio: dio, store: store, scopeResolver: () async => identity);
  });
  tearDown(() async {
    dio.close();
    await db.close();
  });

  test('delete updates disk snapshot and fences an older list response',
      () async {
    final original = await repo.conversationList({}, cacheDefaultPage: true);
    final pending = Completer<List<Map<String, dynamic>>>();
    final started = Completer<void>();
    respond = (options) async {
      if (options.method == 'DELETE') return [];
      started.complete();
      return pending.future;
    };
    final fetch = repo.conversationList({}, cacheDefaultPage: true);
    await started.future;
    await repo.deleteConversation('1');
    pending.complete(original);
    await fetch;
    final restarted = ChatHistoryRepository(
        dio: dio, store: store, scopeResolver: () async => identity);
    expect((await restarted.cachedConversationList())!.map((e) => e['uuid']),
        ['2']);
    respond = (options) async => throw DioException(requestOptions: options);
    await expectLater(
        repo.deleteConversation('2'), throwsA(isA<DioException>()));
    expect((await restarted.cachedConversationList())!.map((e) => e['uuid']),
        ['2']);
  });

  test(
      'conversation snapshot survives repository recreation; scope isolation and permission revocation',
      () async {
    final original = await repo
        .conversationList({'limit': 40, 'offset': 0}, cacheDefaultPage: true);
    final restarted = ChatHistoryRepository(
        dio: dio, store: store, scopeResolver: () async => identity);
    expect(await restarted.cachedConversationList(), original);
    final count = requests.length;
    expect(await restarted.cachedConversationList(), isNotEmpty);
    expect(requests.length, count);
    identity = const ChatCacheScope('another-account-tenant-env', 2);
    expect(await restarted.cachedConversationList(), isNull);
    identity = const ChatCacheScope('account-a/tenant-a/env-a', 1);
    respond = (options) async => throw DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 403));
    await expectLater(
        restarted.conversationList({'limit': 40, 'offset': 0},
            cacheDefaultPage: true),
        throwsA(isA<DioException>()));
    expect(await restarted.cachedConversationList(), isNull);
  });

  test(
      'known empty conversation snapshot differs from cache miss; filtered page does not overwrite it',
      () async {
    expect(await repo.cachedConversationList(), isNull);
    respond = (_) async => [];
    await repo
        .conversationList({'limit': 40, 'offset': 0}, cacheDefaultPage: true);
    expect(await repo.cachedConversationList(), isEmpty);
    respond = (_) async => [message(9)];
    await repo.conversationList({'include_hidden': 1}, cacheDefaultPage: false);
    expect(await repo.cachedConversationList(), isEmpty);
  });

  test(
      'late conversation response after identity switch cannot populate the new cache',
      () async {
    final pending = Completer<List<Map<String, dynamic>>>();
    respond = (_) => pending.future;
    final request =
        repo.conversationList({'limit': 40}, cacheDefaultPage: true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    identity = const ChatCacheScope('another-account', 2);
    final assertion = expectLater(request, throwsStateError);
    pending.complete([message(1)]);
    await assertion;
    expect(await repo.cachedConversationList(), isNull);
    identity = const ChatCacheScope('account-a/tenant-a/env-a', 1);
    expect(await repo.cachedConversationList(), isNull);
  });

  test(
      'restart reads durable history without network; identities never share it',
      () async {
    await repo.latest('conv');
    final restarted = ChatHistoryRepository(
        dio: dio, store: store, scopeResolver: () async => identity);
    expect((await restarted.cached('conv')).length, 2);
    expect(requests.length, 1);
    for (final key in [
      'account-b/tenant-a/env-a',
      'account-a/tenant-b/env-a',
      'account-a/tenant-a/env-b'
    ]) {
      identity = ChatCacheScope(key, 1);
      expect(await restarted.cached('conv'), isEmpty);
    }
    identity = null;
    expect(await restarted.cached('conv'), isEmpty);
  });

  test('re-entry queries tail + all incremental pages, not latest history',
      () async {
    await repo.latest('conv');
    requests.clear();
    respond = (r) async {
      if (r.path.endsWith('/around')) return [message(2)];
      expect(r.path.endsWith('/newer'), isTrue);
      final cursor = r.queryParameters['since_message_uuid'];
      if (cursor == '2') return List.generate(100, (i) => message(i + 3));
      expect(cursor, '102');
      return [message(103)];
    };
    final result = await repo.latest('conv', incremental: true);
    expect(result.map((e) => e['uuid']), List.generate(103, (i) => '${i + 1}'));
    expect(requests.length, 3);
    expect((await repo.cached('conv')).length, 103);
  });

  test('in-flight response after switch cannot write either user partition',
      () async {
    final held = Completer<List<Map<String, dynamic>>>();
    respond = (_) => held.future;
    final fetch = repo.latest('conv');
    await Future<void>.delayed(Duration.zero);
    identity = const ChatCacheScope('account-b', 2);
    final assertion = expectLater(fetch, throwsStateError);
    held.complete([message(1)]);
    await assertion;
    expect(await repo.cached('conv'), isEmpty);
    identity = const ChatCacheScope('account-a/tenant-a/env-a', 1);
    expect(await repo.cached('conv'), isEmpty);
  });

  test('clear during request fences response; no resurrected history',
      () async {
    final held = Completer<List<Map<String, dynamic>>>();
    respond = (_) => held.future;
    final fetch = repo.latest('conv');
    while (requests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await repo.remove('conv');
    final assertion = expectLater(fetch, throwsStateError);
    held.complete([message(1)]);
    await assertion;
    expect(await repo.cached('conv'), isEmpty);
  });

  test('older pagination uses actual around cursor and then local cached pages',
      () async {
    respond = (_) async => [message(4), message(5)];
    await repo.latest('conv', limit: 2);
    respond = (r) async {
      expect(r.path.endsWith('/around'), true);
      expect(r.queryParameters,
          {'anchor_message_uuid': '4', 'before': 3, 'after': 1});
      return [message(2), message(3), message(4), message(5)];
    };
    expect(
        (await repo.latest('conv', before: '4', limit: 2))
            .map((e) => e['uuid']),
        ['2', '3']);
    final count = requests.length;
    expect(
        (await repo.latest('conv', before: '4', limit: 2))
            .map((e) => e['uuid']),
        ['2', '3']);
    expect(requests.length, count);
  });

  test('access rejection clears cached content instead of serving it forever',
      () async {
    await repo.latest('conv');
    respond = (r) async => throw DioException(
        requestOptions: r,
        response: Response(requestOptions: r, statusCode: 403));
    await expectLater(
        repo.latest('conv', incremental: true), throwsA(isA<DioException>()));
    expect(await repo.cached('conv'), isEmpty);
  });

  test('offline failure keeps existing cache; a stuck delta cursor is an error',
      () async {
    await repo.latest('conv');
    respond = (r) async => throw StateError('offline');
    await expectLater(
        repo.latest('conv', incremental: true), throwsA(isA<DioException>()));
    expect((await repo.cached('conv')).length, 2);
    respond =
        (r) async => r.path.endsWith('/around') ? [message(2)] : [message(2)];
    await expectLater(repo.latest('conv', incremental: true), throwsStateError);
    expect((await repo.cached('conv')).length, 2);
  });

  test('incomplete cached tail is refreshed before newly appended messages',
      () async {
    respond = (_) async => [message(1, status: 'streaming')];
    await repo.latest('conv');
    respond = (r) async => r.path.endsWith('/around') ? [message(1)] : [];
    final result = await repo.latest('conv', incremental: true);
    expect(result.single['status'], 'final');
  });

  test('remote clear boundary invalidates disk history before rendering',
      () async {
    await repo.latest('conv');
    expect(
        await repo.cached('conv', clearedAt: '2026-10-08T00:00:01Z'), isEmpty);
    expect(await repo.cached('conv'), isEmpty);
  });

  test(
      'failed second delta page does not commit a cursor across missing messages',
      () async {
    await repo.latest('conv');
    respond = (r) async {
      if (r.path.endsWith('/around')) return [message(2)];
      if (r.queryParameters['since_message_uuid'] == '2') {
        return List.generate(100, (i) => message(i + 3));
      }
      throw StateError('offline second page');
    };
    await expectLater(
        repo.latest('conv', incremental: true), throwsA(isA<DioException>()));
    expect((await repo.cached('conv')).map((e) => e['uuid']), ['1', '2']);
  });

  test('expired cache cannot be read', () async {
    await repo.latest('conv');
    await db.update('chat_cache', {'updated_at': 0});
    expect(await repo.cached('conv'), isEmpty);
  });

  test('scope uses environment/account/tenant and fences logout generation',
      () async {
    String token(int account, int tenant) =>
        'x.${base64Url.encode(utf8.encode(jsonEncode({
              'aid': account,
              'act_tid': tenant
            })))}.x';
    SharedPreferences.setMockInitialValues({'token': token(1, 2)});
    final a = await ChatCacheScope.current();
    expect(a, isNotNull);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token(2, 2));
    expect((await ChatCacheScope.current())!.key, isNot(a!.key));
    await prefs.setString('token', token(1, 3));
    expect((await ChatCacheScope.current())!.key, isNot(a.key));
    await prefs.setString('token', token(1, 2));
    ChatCacheScope.resetSession();
    expect(await a.isCurrent(), false);
    await prefs.remove(AppConfig.storageTokenKey);
    expect(await ChatCacheScope.current(), isNull);
  });
}
