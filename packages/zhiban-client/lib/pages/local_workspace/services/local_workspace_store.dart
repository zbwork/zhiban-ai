import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:uuid/uuid.dart';

typedef LocalRow = Map<String, Object?>;

/// Authoritative local data. This is intentionally separate from the expiring
/// server chat cache and never stores credentials.
class LocalWorkspaceStore {
  LocalWorkspaceStore(this.db);
  final Database db;
  static const uuid = Uuid();

  static Future<LocalWorkspaceStore> open({
    DatabaseFactory? factory,
    String? path,
    List<dynamic>? skills,
  }) async {
    if (factory == null && (Platform.isWindows || Platform.isLinux)) {
      ffi.sqfliteFfiInit();
      factory = ffi.databaseFactoryFfi;
    }
    final location = path ??
        '${(await getApplicationSupportDirectory()).path}/community_workspace_v1.db';
    final database = await (factory ?? databaseFactory).openDatabase(location,
        options: OpenDatabaseOptions(
          version: 7,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 7) await _createTaskTables(db);
            if (oldVersion < 6) {
              await db.execute(
                  "ALTER TABLE messages ADD COLUMN timeline TEXT NOT NULL DEFAULT '[]'");
            }
            if (oldVersion < 5) {
              await _addSkillPresentationColumns(db);
            }
            if (oldVersion < 4) {
              await db.execute(
                  "ALTER TABLE messages ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]'");
            }
            if (oldVersion < 3) {
              await db.execute(
                  "ALTER TABLE employees ADD COLUMN metadata TEXT NOT NULL DEFAULT '{}'");
            }
            if (oldVersion < 2) {
              for (final column in [
                'category_id INTEGER NOT NULL DEFAULT 1',
                "version TEXT NOT NULL DEFAULT ''",
                "usage_example TEXT NOT NULL DEFAULT ''",
                'executable INTEGER NOT NULL DEFAULT 1',
                'sort_order INTEGER NOT NULL DEFAULT 1000',
              ]) {
                await db.execute('ALTER TABLE skills ADD COLUMN $column');
              }
            }
          },
          onCreate: (db, version) async {
            await _createTaskTables(db);
            await db.execute(
                'CREATE TABLE employees (id TEXT PRIMARY KEY, name TEXT NOT NULL, prompt TEXT NOT NULL, provider_id TEXT NOT NULL, model_id TEXT NOT NULL, skills TEXT NOT NULL, created INTEGER NOT NULL)');
            await db.execute(
                'CREATE TABLE messages (id TEXT PRIMARY KEY, employee_id TEXT NOT NULL REFERENCES employees(id) ON DELETE CASCADE, role TEXT NOT NULL, content TEXT NOT NULL, status TEXT NOT NULL, created INTEGER NOT NULL)');
            await db.execute(
                "ALTER TABLE messages ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]'");
            await db.execute(
                "ALTER TABLE messages ADD COLUMN timeline TEXT NOT NULL DEFAULT '[]'");
            await db.execute(
                'CREATE INDEX messages_employee ON messages(employee_id, created)');
            await db.execute(
                "ALTER TABLE employees ADD COLUMN metadata TEXT NOT NULL DEFAULT '{}'");
            await db.execute(
                "CREATE TABLE skills (id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL, prompt TEXT NOT NULL, category_id INTEGER NOT NULL DEFAULT 1, version TEXT NOT NULL DEFAULT '', usage_example TEXT NOT NULL DEFAULT '', executable INTEGER NOT NULL DEFAULT 1, sort_order INTEGER NOT NULL DEFAULT 1000)");
            await _addSkillPresentationColumns(db);
          },
        ));
    final store = LocalWorkspaceStore(database);
    await database.transaction((txn) async {
      await txn.execute(
          'CREATE TABLE IF NOT EXISTS community_catalog (id INTEGER PRIMARY KEY, body TEXT NOT NULL)');
      await txn.execute(
          'CREATE TABLE IF NOT EXISTS community_skill_packages (id TEXT PRIMARY KEY, body TEXT NOT NULL)');
      // Old catalog rows remain available to employee bindings, never the market.
      await txn.update('skills', {'listed': 0});
      await txn.update('skills', {'icon_url': ''},
          where: 'icon_url LIKE ?', whereArgs: ['asset:assets/local_skills/%']);
      for (final skill in skills ?? const []) {
        await txn.insert('skills', Map<String, Object?>.from(skill as Map),
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      final interrupted = await txn.query('local_task_runs',
          where: 'status = ?', whereArgs: ['running']);
      for (final run in interrupted) {
        final jobs = await txn
            .query('local_tasks', where: 'id = ?', whereArgs: [run['job_id']]);
        if (jobs.isNotEmpty) {
          final body = Map<String, dynamic>.from(
              jsonDecode(jobs.single['body'] as String) as Map);
          await txn.update(
              'local_tasks',
              {
                'body': jsonEncode({
                  ...body,
                  'last_run_status': 'cancelled',
                  'last_run_summary': '客户端退出，本次执行已中断'
                })
              },
              where: 'id = ?',
              whereArgs: [run['job_id']]);
        }
      }
      await txn.update('local_task_runs',
          {'status': 'interrupted', 'error': '客户端退出，本次执行已中断'},
          where: 'status = ?', whereArgs: ['running']);
      await txn.update('messages', {'status': 'interrupted'},
          where: 'status = ?', whereArgs: ['pending']);
    });
    return store;
  }

  static Future<void> _createTaskTables(Database db) async {
    await db.execute(
        'CREATE TABLE local_tasks (id TEXT PRIMARY KEY, employee_id TEXT NOT NULL, body TEXT NOT NULL, next_run INTEGER, enabled INTEGER NOT NULL, updated INTEGER NOT NULL)');
    await db.execute(
        'CREATE INDEX local_tasks_due ON local_tasks(enabled, next_run)');
    // Snapshots intentionally survive deleting a task or employee.
    await db.execute(
        "CREATE TABLE local_task_runs (id TEXT PRIMARY KEY, job_id TEXT NOT NULL, employee_id TEXT NOT NULL, job_name TEXT NOT NULL, started INTEGER NOT NULL, status TEXT NOT NULL, body TEXT NOT NULL, summary TEXT NOT NULL DEFAULT '', error TEXT, message_id TEXT, duration INTEGER NOT NULL DEFAULT 0)");
    await db.execute(
        'CREATE INDEX local_task_runs_job ON local_task_runs(job_id, started)');
  }

  static Future<void> _addSkillPresentationColumns(Database db) async {
    for (final column in [
      "icon_url TEXT NOT NULL DEFAULT ''",
      "source TEXT NOT NULL DEFAULT 'builtin'",
      'download_count INTEGER NOT NULL DEFAULT 0',
      'listed INTEGER NOT NULL DEFAULT 1',
    ]) {
      await db.execute('ALTER TABLE skills ADD COLUMN $column');
    }
  }

  Future<List<LocalRow>> employees() => db.rawQuery('''
    SELECT e.*, (SELECT content FROM messages WHERE employee_id=e.id ORDER BY created DESC, rowid DESC LIMIT 1) AS last_content, (SELECT MAX(created) FROM messages WHERE employee_id=e.id) AS last_message
    FROM employees e ORDER BY COALESCE(last_message,e.created) DESC
  ''');
  Future<List<LocalRow>> skills() =>
      db.query('skills', orderBy: 'sort_order, id');

  Future<Map<String, dynamic>?> cachedSkillCatalog() async {
    final rows = await db.query('community_catalog', limit: 1);
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['body'] as String) as Map<String, dynamic>;
  }

  Future<void> cacheSkillCatalog(
      Map<String, dynamic> catalog, List<LocalRow> rows) async {
    await db.transaction((txn) async {
      // Preserve executable skills and existing employee bindings. Removed
      // catalog entries stay available to old bindings but leave the market.
      await txn.update('skills', {'listed': 0});
      for (final row in rows) {
        final existing = await txn.query('skills',
            where: 'id = ?', whereArgs: [row['id']], limit: 1);
        final value = {...row};
        if (existing.isNotEmpty && existing.first['executable'] != 0) {
          value['prompt'] = existing.first['prompt'];
          value['executable'] = existing.first['executable'];
          value['version'] = existing.first['version'];
        }
        await txn.insert('skills', value,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.insert(
          'community_catalog', {'id': 1, 'body': jsonEncode(catalog)},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<Map<String, dynamic>?> installedSkill(String id) async {
    final rows = await db.query('community_skill_packages',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single['body'] as String) as Map<String, dynamic>;
  }

  Future<void> recordInstalledSkill(
      String id, Map<String, dynamic> metadata, String prompt) async {
    await db.transaction((txn) async {
      await txn.insert(
          'community_skill_packages', {'id': id, 'body': jsonEncode(metadata)},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update('skills',
          {'prompt': prompt, 'executable': 1, 'version': metadata['version']},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<LocalRow>> messages(String employee) => db.query('messages',
      where: 'employee_id = ?',
      whereArgs: [employee],
      orderBy: 'created, rowid');

  Future<void> saveEmployee(LocalRow row) async {
    final value = Map<String, Object?>.from(row)
      ..remove('last_message')
      ..remove('last_content');
    await db.transaction((txn) async {
      final count = await txn.update('employees', value,
          where: 'id = ?', whereArgs: [value['id']]);
      if (count == 0) await txn.insert('employees', value);
    });
  }

  Future<void> deleteEmployee(String id) async {
    await db.transaction((txn) async {
      await txn
          .delete('local_tasks', where: 'employee_id = ?', whereArgs: [id]);
      await txn.delete('employees', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<String> addMessage(String employee, String role, String content,
      {String status = 'complete', String attachments = '[]'}) async {
    final id = uuid.v4();
    await db.insert('messages', {
      'id': id,
      'employee_id': employee,
      'role': role,
      'content': content,
      'attachments': attachments,
      'status': status,
      'created': DateTime.now().millisecondsSinceEpoch,
    });
    return id;
  }

  Future<void> finishMessage(String id, String content, String status,
      {String? attachments, String? timeline}) async {
    await db.update(
        'messages',
        {
          'content': content,
          'status': status,
          if (attachments != null) 'attachments': attachments,
          if (timeline != null) 'timeline': timeline
        },
        where: 'id = ?',
        whereArgs: [id]);
  }
}
