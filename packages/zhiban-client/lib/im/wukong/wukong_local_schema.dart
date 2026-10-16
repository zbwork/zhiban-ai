import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wukongimfluttersdk/db/wk_db_helper.dart';

const List<String> kWukongCriticalTables = WKDBHelper.criticalTables;

/// WuKong SDK stores migration progress in SharedPreferences, separate from
/// the actual sqlite file. During local dev the preference can survive while
/// the sqlite file is recreated empty, so SDK setup reports success but sends
/// fail with "no such table: channel".
Future<void> ensureWukongLocalSchema({
  AssetBundle? bundle,
  DatabaseExecutor? database,
}) async {
  final assetBundle = bundle ?? rootBundle;
  final db = database ?? WKDBHelper.shared.getDB();
  if (db == null) {
    throw StateError('WuKong local database is not initialized');
  }
  await WKDBHelper.shared.ensureCriticalTables(
    database: db,
    bundle: assetBundle,
  );
}

Future<bool> wukongHasCriticalTables(DatabaseExecutor db) async {
  return WKDBHelper.shared.hasCriticalTables(db);
}

Future<void> replayWukongSchema(
  DatabaseExecutor db, {
  AssetBundle? bundle,
}) async {
  await WKDBHelper.shared.replaySchema(db, bundle: bundle ?? rootBundle);
}
