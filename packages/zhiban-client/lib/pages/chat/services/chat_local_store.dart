import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

/// Identity is captured before IO. Tokens are never persisted in cache keys.
class ChatCacheScope {
  const ChatCacheScope(this.key, this.generation);
  final String key;
  final int generation;

  static int _generation = 0;
  static ChatCacheScope? _resolved;
  static String? _resolvedApi;
  static String? _resolvedEnv;
  static ChatCacheScope? get resolved => _resolved?.generation == _generation &&
          _resolvedApi == AppConfig.apiUrl() &&
          _resolvedEnv == AppConfig.env.name
      ? _resolved
      : null;
  static void resetSession() {
    _generation++;
    _resolved = null;
  }

  static Future<ChatCacheScope?> current() async {
    final generation = _generation;
    final api = AppConfig.apiUrl();
    final env = AppConfig.env.name;
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(AppConfig.storageTokenKey);
    if (generation != _generation) return null;
    if (token == null || api.isEmpty) {
      _resolved = null;
      return null;
    }
    try {
      final claims = jsonDecode(utf8.decode(base64Url.decode(
        base64Url.normalize(token.split('.')[1]),
      ))) as Map;
      final account = claims['aid']?.toString();
      final tenant = claims['act_tid']?.toString();
      if (account == null ||
          tenant == null ||
          account.isEmpty ||
          tenant.isEmpty) {
        _resolved = null;
        return null;
      }
      final scope = ChatCacheScope(
        sha256
            .convert(utf8.encode(jsonEncode([api, env, account, tenant])))
            .toString(),
        generation,
      );
      _resolvedApi = api;
      _resolvedEnv = env;
      _resolved = scope;
      return scope;
    } catch (_) {
      _resolved = null;
      return null;
    }
  }

  Future<bool> isCurrent() async {
    final now = await current();
    return now?.key == key && now?.generation == generation;
  }
}

/// Bounded, disposable cache in the OS application-private directory.
/// One row is one contiguous message window or a set of receipt summaries.
/// It is not an authorization source and does not claim file-level encryption.
class ChatLocalStore {
  ChatLocalStore({required Future<Database> database}) : _database = database;
  static Future<ChatLocalStore>? _shared;
  static Future<ChatLocalStore> get shared =>
      _shared ??= _open().catchError((Object error, StackTrace stack) {
        _shared = null;
        Error.throwWithStackTrace(error, stack);
      });
  @visibleForTesting
  static void setSharedForTesting(ChatLocalStore? store) {
    _shared = store == null ? null : Future.value(store);
  }

  final Future<Database> _database;
  final Map<String, int> _revisions = {};
  final Map<String, int> _scopeRevisions = {};
  int _revisionClock = 0;
  static const retention = Duration(days: 30);

  static Future<ChatLocalStore> _open() async {
    final dir = await getApplicationSupportDirectory();
    if (Platform.isWindows || Platform.isLinux) ffi.sqfliteFfiInit();
    final factory = Platform.isWindows || Platform.isLinux
        ? ffi.databaseFactoryFfi
        : databaseFactory;
    final db = factory.openDatabase('${dir.path}/chat_cache_v1.db',
        options: OpenDatabaseOptions(version: 1, onCreate: createSchema));
    return ChatLocalStore(database: db);
  }

  static Future<void> createSchema(Database db, int version) async {
    await db.execute('CREATE TABLE chat_cache ('
        'scope TEXT NOT NULL, conversation TEXT NOT NULL, kind TEXT NOT NULL, '
        'payload TEXT NOT NULL, updated_at INTEGER NOT NULL, '
        'PRIMARY KEY(scope, conversation, kind))');
  }

  int revision(String scope, String conversation) =>
      _revisions['$scope/$conversation'] ?? _scopeRevisions[scope] ?? 0;

  /// Fence even requests for conversations that have never written a row.
  Future<void> clearScope(String scope) async {
    _scopeRevisions[scope] = ++_revisionClock;
    _revisions.removeWhere((key, _) => key.startsWith('$scope/'));
    final db = await _database;
    await db.delete('chat_cache', where: 'scope = ?', whereArgs: [scope]);
  }

  Future<Map<String, dynamic>?> read(
      String scope, String conversation, String kind) async {
    final db = await _database;
    final rows = await db.query('chat_cache',
        where: 'scope = ? AND conversation = ? AND kind = ? AND updated_at > ?',
        whereArgs: [
          scope,
          conversation,
          kind,
          DateTime.now().subtract(retention).millisecondsSinceEpoch
        ]);
    if (rows.isEmpty) return null;
    try {
      return (jsonDecode(rows.single['payload'] as String) as Map)
          .cast<String, dynamic>();
    } catch (e) {
      if (e is! FormatException && e is! TypeError) rethrow;
      await remove(scope, conversation);
      debugPrint('[chat-cache] invalid JSON removed');
      return null;
    }
  }

  Future<void> write(String scope, String conversation, String kind,
      Map<String, dynamic> payload,
      {required int expectedRevision}) async {
    final db = await _database;
    await db.transaction((tx) async {
      if (revision(scope, conversation) != expectedRevision) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      await tx.insert(
          'chat_cache',
          {
            'scope': scope,
            'conversation': conversation,
            'kind': kind,
            'payload': jsonEncode(payload),
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.delete('chat_cache',
          where: 'updated_at <= ?',
          whereArgs: [now - retention.inMilliseconds]);
      // Two kinds per conversation; bound the whole cache, including old users.
      await tx.execute(
          'DELETE FROM chat_cache WHERE conversation || char(0) || scope NOT IN '
          '(SELECT conversation || char(0) || scope FROM chat_cache '
          'GROUP BY scope, conversation ORDER BY MAX(updated_at) DESC LIMIT 200)');
    });
  }

  /// Mutate a snapshot atomically and fence list responses started before it.
  Future<void> removeListItem(
      String scope, String conversation, String kind, String itemId) async {
    final key = '$scope/$conversation';
    _revisions[key] = ++_revisionClock;
    final db = await _database;
    await db.transaction((tx) async {
      final rows = await tx.query('chat_cache',
          where: 'scope = ? AND conversation = ? AND kind = ?',
          whereArgs: [scope, conversation, kind]);
      if (rows.isEmpty) return;
      final payload = jsonDecode(rows.single['payload'] as String) as Map;
      (payload['items'] as List).removeWhere((item) => item['uuid'] == itemId);
      await tx.update('chat_cache', {'payload': jsonEncode(payload)},
          where: 'scope = ? AND conversation = ? AND kind = ?',
          whereArgs: [scope, conversation, kind]);
    });
  }

  Future<void> remove(String scope, String conversation) async {
    final key = '$scope/$conversation';
    _revisions[key] = ++_revisionClock;
    final db = await _database;
    await db.delete('chat_cache',
        where: 'scope = ? AND conversation = ?',
        whereArgs: [scope, conversation]);
  }
}
