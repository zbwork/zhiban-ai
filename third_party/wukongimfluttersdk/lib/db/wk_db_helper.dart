import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../wkim.dart';

class WKDBHelper {
  WKDBHelper._privateConstructor();
  static final WKDBHelper _instance = WKDBHelper._privateConstructor();
  static WKDBHelper get shared => _instance;
  static const List<String> criticalTables = <String>[
    'channel',
    'conversation',
    'message',
  ];

  final dbVersion = 1;
  Database? _database;

  Future<bool> init() async {
    var databasesPath = await getDatabasesPath();
    final suffix = WKIM.shared.options.dbSuffix ?? '';
    String path =
        p.join(databasesPath, 'wk_${WKIM.shared.options.uid}$suffix.db');
    _database = await openDatabase(
      path,
      version: dbVersion,
      onCreate: (Database db, int version) async {
        // onUpgrade(db);
      },
      // onUpgrade: (db, oldVersion, newVersion) => {
      //   onUpgrade(db)},
    );
    await ensureCriticalTables(database: _database!);
    bool result = await onUpgrade(_database!);
    return _database != null && result;
  }

  Future<bool> onUpgrade(Database db) async {
    String path = await rootBundle
        .loadString('packages/wukongimfluttersdk/assets/sql.txt');
    List<String> names = path.split(';');
    SharedPreferences preferences = await SharedPreferences.getInstance();
    String wkUid = WKIM.shared.options.uid!;
    int maxVersion = preferences.getInt('wk_max_sql_version_$wkUid') ?? 0;
    int saveVersion = 0;
    for (int i = 0; i < names.length; i++) {
      if (names[i] == '') {
        continue;
      }
      int version = int.parse(names[i]);
      if (version > maxVersion) {
        String sqlStr = await rootBundle
            .loadString('packages/wukongimfluttersdk/assets/$version.sql');
        var sqlList = sqlStr.split(';');
        for (String sql in sqlList) {
          await _executeMigrationStatement(db, sql);
        }
        if (version > saveVersion) {
          saveVersion = version;
        }
      }
    }
    if (saveVersion > 0) {
      await preferences.setInt('wk_max_sql_version_$wkUid', saveVersion);
    }
    return true;
  }

  Future<void> ensureCriticalTables({
    DatabaseExecutor? database,
    AssetBundle? bundle,
  }) async {
    final db = database ?? _database;
    if (db == null) {
      throw StateError('WuKong local database is not initialized');
    }
    if (await hasCriticalTables(db)) return;

    await replaySchema(db, bundle: bundle);
    if (!await hasCriticalTables(db)) {
      throw StateError(
        'WuKong local database schema repair did not create '
        '${criticalTables.join(", ")}',
      );
    }
  }

  Future<bool> hasCriticalTables(DatabaseExecutor db) async {
    final placeholders =
        List<String>.filled(criticalTables.length, '?').join(',');
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
      '($placeholders)',
      criticalTables,
    );
    return rows.length == criticalTables.length;
  }

  Future<void> replaySchema(
    DatabaseExecutor db, {
    AssetBundle? bundle,
  }) async {
    final assetBundle = bundle ?? rootBundle;
    final existingTables = await _tableNames(db);
    final allowReactionIndexReset =
        !existingTables.contains('message_reaction');
    final migrationList = await assetBundle.loadString(
      'packages/wukongimfluttersdk/assets/sql.txt',
    );
    final versions = migrationList
        .split(';')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .map(int.parse)
        .toList()
      ..sort();

    Future<void> repair(DatabaseExecutor executor) async {
      for (final version in versions) {
        final sql = await assetBundle.loadString(
          'packages/wukongimfluttersdk/assets/$version.sql',
        );
        for (final statement in sql.split(';')) {
          await _executeRepairStatement(
            executor,
            statement,
            allowReactionIndexReset: allowReactionIndexReset,
          );
        }
      }
    }

    if (db is Database) {
      await db.transaction(repair);
    } else {
      await repair(db);
    }
  }

  Future<Set<String>> _tableNames(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    return rows
        .map((row) => row['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .toSet();
  }

  Future<void> _executeRepairStatement(
    DatabaseExecutor db,
    String statement, {
    required bool allowReactionIndexReset,
  }) async {
    final sql = statement.trim();
    if (sql.isEmpty) return;

    // Runtime repair can start from an unknown partial database. Replaying
    // migration DML against tables that already existed may destroy user data.
    final normalized = sql.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final isSafeDdl = normalized.startsWith('create table ') ||
        normalized.startsWith('create index ') ||
        normalized.startsWith('create unique index ') ||
        normalized.startsWith('alter table ');
    final isNewReactionTableReset = allowReactionIndexReset &&
        (normalized == 'delete from message_reaction' ||
            normalized == 'drop index if exists chat_msg_reaction_index');
    if (!isSafeDdl && !isNewReactionTableReset) return;

    await _executeMigrationStatement(db, sql);
  }

  Future<void> _executeMigrationStatement(
    DatabaseExecutor db,
    String statement,
  ) async {
    final sql = statement.trim();
    if (sql.isEmpty) return;
    try {
      await db.execute(sql);
    } on DatabaseException catch (error) {
      if (!_isBenignReplayError(error)) rethrow;
    }
  }

  bool _isBenignReplayError(DatabaseException error) {
    final message = error.toString().toLowerCase();
    return message.contains('already exists') ||
        message.contains('duplicate column name') ||
        message.contains('no such index');
  }

  Database? getDB() {
    return _database;
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    if (database != null) {
      await database.close();
    }
  }
}
