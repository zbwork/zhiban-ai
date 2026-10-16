import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/im/wukong/wukong_local_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wukongimfluttersdk/db/wk_db_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
  });

  group('WuKong local schema repair', () {
    test('empty sqlite file is missing critical tables', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);

      expect(await wukongHasCriticalTables(db), isFalse);
    });

    test('replays bundled WuKong schema into an empty sqlite file', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);

      await replayWukongSchema(db);

      expect(await wukongHasCriticalTables(db), isTrue);
      for (final table in kWukongCriticalTables) {
        final rows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          <Object?>[table],
        );
        expect(rows, hasLength(1), reason: '$table should exist');
      }
      final reactionIndexColumns = await db.rawQuery(
        "PRAGMA index_info('chat_msg_reaction_index')",
      );
      expect(
        reactionIndexColumns.map((row) => row['name']),
        <Object?>['message_id', 'uid', 'channel_id', 'channel_type']
      );
    });

    test('ensureWukongLocalSchema repairs a provided empty database', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);

      await ensureWukongLocalSchema(database: db);

      expect(await wukongHasCriticalTables(db), isTrue);
    });

    test('repairs a missing critical table without deleting reactions',
        () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);

      await replayWukongSchema(db);
      await db.insert('message_reaction', <String, Object?>{
        'channel_id': 'channel-1',
        'channel_type': 1,
        'uid': 'user-1',
        'name': 'Alice',
        'emoji': '👍',
        'message_id': 'message-1',
        'seq': 1,
        'is_deleted': 0,
      });
      await db.execute('DROP TABLE message');

      await ensureWukongLocalSchema(database: db);

      expect(await wukongHasCriticalTables(db), isTrue);
      final reactions = await db.query('message_reaction');
      expect(reactions, hasLength(1));
      expect(reactions.single['message_id'], 'message-1');
      expect(reactions.single['emoji'], '👍');
    });

    test('SDK repairs schema before startup message status cleanup', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);

      await WKDBHelper.shared.ensureCriticalTables(database: db);
      final updatedRows = await db.update(
        'message',
        <String, Object?>{'status': 2},
        where: 'status=0'
      );

      expect(await WKDBHelper.shared.hasCriticalTables(db), isTrue);
      expect(updatedRows, 0);
    });
  });
}
