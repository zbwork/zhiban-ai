import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';

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
          version: 9,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onUpgrade: (db, oldVersion, newVersion) async {
            if (oldVersion < 8) await _createCreatorRoundtableTables(db);
            if (oldVersion < 9) await _createCreatorWorkLinks(db);
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
            await _createCreatorRoundtableTables(db);
            await _createCreatorWorkLinks(db);
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
      await txn.update(
          'creator_jobs',
          {
            'status': 'interrupted',
            'error': '客户端退出，任务未发布。',
          },
          where: 'status = ?',
          whereArgs: ['running']);
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

  static Future<void> _createCreatorRoundtableTables(Database db) async {
    await db.execute('''CREATE TABLE creator_profiles (
      id TEXT PRIMARY KEY,
      channel TEXT NOT NULL,
      source_account_id TEXT NOT NULL,
      name TEXT NOT NULL,
      bio TEXT NOT NULL DEFAULT '',
      avatar_url TEXT NOT NULL DEFAULT '',
      followers INTEGER NOT NULL DEFAULT 0,
      work_count INTEGER NOT NULL DEFAULT 0,
      last_synced INTEGER NOT NULL,
      metadata TEXT NOT NULL DEFAULT '{}',
      UNIQUE(channel, source_account_id)
    )''');
    await db.execute('''CREATE TABLE creator_works (
      id TEXT PRIMARY KEY,
      creator_id TEXT NOT NULL REFERENCES creator_profiles(id) ON DELETE CASCADE,
      channel TEXT NOT NULL,
      source_work_id TEXT NOT NULL,
      title TEXT NOT NULL DEFAULT '',
      cover_url TEXT NOT NULL DEFAULT '',
      source_url TEXT NOT NULL,
      published_at INTEGER NOT NULL DEFAULT 0,
      likes INTEGER NOT NULL DEFAULT 0,
      comments INTEGER NOT NULL DEFAULT 0,
      collects INTEGER NOT NULL DEFAULT 0,
      shares INTEGER NOT NULL DEFAULT 0,
      source_version INTEGER NOT NULL DEFAULT 1,
      transcript TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'archived',
      created INTEGER NOT NULL,
      updated INTEGER NOT NULL,
      metadata TEXT NOT NULL DEFAULT '{}',
      UNIQUE(channel, source_work_id)
    )''');
    await db.execute(
        'CREATE INDEX creator_works_creator ON creator_works(creator_id, published_at DESC)');
    await db.execute('''CREATE TABLE creator_jobs (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      status TEXT NOT NULL,
      stage TEXT NOT NULL,
      model_snapshot TEXT NOT NULL DEFAULT '{}',
      source_snapshot TEXT NOT NULL DEFAULT '[]',
      request_payload TEXT NOT NULL DEFAULT '{}',
      result_payload TEXT NOT NULL DEFAULT '{}',
      error TEXT,
      created INTEGER NOT NULL,
      updated INTEGER NOT NULL
    )''');
    await db.execute('''CREATE TABLE creator_experts (
      id TEXT NOT NULL,
      creator_id TEXT NOT NULL REFERENCES creator_profiles(id) ON DELETE CASCADE,
      version INTEGER NOT NULL,
      status TEXT NOT NULL,
      content TEXT NOT NULL,
      evidence TEXT NOT NULL DEFAULT '[]',
      created INTEGER NOT NULL,
      PRIMARY KEY(id, version)
    )''');
    await db.execute('''CREATE TABLE roundtable_conversations (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      model_snapshot TEXT NOT NULL DEFAULT '{}',
      created INTEGER NOT NULL,
      updated INTEGER NOT NULL
    )''');
    await db.execute('''CREATE TABLE roundtable_turns (
      id TEXT PRIMARY KEY,
      conversation_id TEXT NOT NULL REFERENCES roundtable_conversations(id) ON DELETE CASCADE,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      expert_snapshot TEXT NOT NULL DEFAULT '[]',
      evidence TEXT NOT NULL DEFAULT '[]',
      created INTEGER NOT NULL
    )''');
    await db.execute('''CREATE TABLE creator_assets (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      title TEXT NOT NULL,
      file_path TEXT NOT NULL,
      model_snapshot TEXT NOT NULL DEFAULT '{}',
      source_snapshot TEXT NOT NULL DEFAULT '[]',
      created INTEGER NOT NULL
    )''');
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

  Future<List<LocalRow>> creatorProfiles() =>
      db.query('creator_profiles', orderBy: 'last_synced DESC, name');

  static Future<void> _createCreatorWorkLinks(Database db) async {
    await db.execute('''CREATE TABLE creator_work_links (
      creator_id TEXT NOT NULL REFERENCES creator_profiles(id) ON DELETE CASCADE,
      work_id TEXT NOT NULL REFERENCES creator_works(id) ON DELETE CASCADE,
      PRIMARY KEY(creator_id, work_id)
    )''');
    await db.execute(
        'CREATE INDEX creator_work_links_work ON creator_work_links(work_id)');
    await db.execute('''INSERT INTO creator_work_links(creator_id, work_id)
      SELECT creator_id, id FROM creator_works''');
  }

  Future<List<LocalRow>> creatorWorks(String creatorId) async {
    final rows = await db.rawQuery('''
      SELECT work.* FROM creator_work_links AS link
      JOIN creator_works AS work ON work.id = link.work_id
      WHERE link.creator_id = ?
      ORDER BY work.published_at DESC, work.updated DESC
    ''', [creatorId]);
    return [for (final row in rows) {...row, 'creator_id': creatorId}];
  }

  static String _stableCreatorId(String channel, String sourceId) =>
      '$channel:${sha256.convert(utf8.encode('$channel:$sourceId'))}';

  static String _stableWorkId(String channel, String sourceId) =>
      '$channel:${sha256.convert(utf8.encode('$channel:$sourceId'))}';

  Future<String> importCreatorWork(Map<String, dynamic> result,
      {String channel = 'douyin'}) async {
    final author = Map<String, dynamic>.from(result['author'] as Map);
    final work = Map<String, dynamic>.from(result['work'] as Map);
    return (await importCreatorWorks(author, [work], channel: channel))
        .creatorId;
  }

  Future<({String creatorId, int added})> importCreatorWorks(
      Map<String, dynamic> author, List<Map<String, dynamic>> works,
      {String channel = 'douyin', String? syncJobId}) async {
    final sourceAccountId = '${author['id'] ?? ''}'.trim();
    if (sourceAccountId.isEmpty ||
        works.any((work) =>
            !RegExp(r'^\d{10,24}$').hasMatch('${work['id'] ?? ''}'))) {
      throw StateError('渠道未返回稳定的博主或作品标识');
    }
    final creatorId = _stableCreatorId(channel, sourceAccountId);
    final now = DateTime.now().millisecondsSinceEpoch;
    var added = 0;
    await db.transaction((txn) async {
      if (syncJobId != null) {
        final changed = await txn.update(
          'creator_jobs',
          {
            'status': 'complete',
            'stage': 'stored',
            'result_payload': '{}',
            'updated': now,
          },
          where: "id = ? AND kind = 'creator-sync' AND status = 'running' "
              "AND json_extract(request_payload, '\$.creator_id') = ?",
          whereArgs: [syncJobId, creatorId],
        );
        if (changed != 1) throw StateError('同步任务已经结束，请重新打开同步。');
      }
      final avatar = '${author['avatar'] ?? ''}'.trim();
      final profile = <String, Object?>{
        'id': creatorId,
        'channel': channel,
        'source_account_id': sourceAccountId,
        'name': '${author['name'] ?? ''}',
        'bio': '${author['bio'] ?? ''}',
        if (avatar.isNotEmpty) 'avatar_url': avatar,
        'followers': (author['followers'] as num?)?.toInt() ?? 0,
        'work_count': (author['works'] as num?)?.toInt() ?? 0,
        'last_synced': now,
      };
      // REPLACE deletes the old parent row and cascades to its works.
      final updated = await txn.update('creator_profiles', profile,
          where: 'id = ?', whereArgs: [creatorId]);
      if (updated == 0) await txn.insert('creator_profiles', profile);
      for (final work in works) {
        final sourceWorkId = '${work['id']}';
        final images = (work['images'] as List? ?? const [])
            .whereType<String>()
            .where((value) {
              final url = Uri.tryParse(value);
              return url?.scheme == 'https' && url?.userInfo.isEmpty == true;
            })
            .take(30)
            .toList();
        final workId = _stableWorkId(channel, sourceWorkId);
        final old = await txn.query('creator_works',
            columns: [
              'creator_id',
              'source_version',
              'created',
              'transcript',
              'status',
              'title',
              'metadata'
            ],
            where: 'id = ?',
            whereArgs: [workId],
            limit: 1);
        final title = '${work['title'] ?? ''}';
        final oldMetadata = old.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(old.single['metadata'] as String)
                as Map<String, dynamic>;
        final publisherId = work['publisher_account_id'] as String?;
        final knownPublisherId = oldMetadata['publisher_account_id'] as String?;
        final owner = old.firstOrNull?['creator_id'] as String? ?? creatorId;
        final verifiedContributor = work['coauthored'] == true ||
            publisherId == sourceAccountId ||
            knownPublisherId == sourceAccountId;
        final publisherChanged = knownPublisherId != null &&
            publisherId != null &&
            publisherId.isNotEmpty &&
            knownPublisherId != publisherId;
        if (owner != creatorId && (!verifiedContributor || publisherChanged)) {
          throw StateError('该作品已归档到另一位博主');
        }
        final body = (work['article_body'] as String?)?.trim() ??
            oldMetadata['article_body'] as String? ??
            '';
        final sourceVersion = old.isEmpty
            ? 1
            : (old.single['source_version'] as int) +
                (old.single['title'] == title &&
                        (oldMetadata['article_body'] ?? '') == body &&
                        jsonEncode(oldMetadata['images'] ?? []) ==
                            jsonEncode(images)
                    ? 0
                    : 1);
        final row = <String, Object?>{
          'id': workId,
          'creator_id': owner,
          'channel': channel,
          'source_work_id': sourceWorkId,
          'title': title,
          'cover_url': '${work['cover'] ?? ''}',
          'source_url':
              'https://www.douyin.com/${images.isEmpty && body.isEmpty ? 'video' : 'note'}/$sourceWorkId',
          'published_at':
              ((work['published_at'] as num?)?.toInt() ?? 0) * 1000,
          'likes': (work['likes'] as num?)?.toInt() ?? 0,
          'comments': (work['comments'] as num?)?.toInt() ?? 0,
          'collects': (work['collects'] as num?)?.toInt() ?? 0,
          'shares': (work['shares'] as num?)?.toInt() ?? 0,
          'source_version': sourceVersion,
          'transcript': old.firstOrNull?['transcript'] ?? '',
          'status': old.firstOrNull?['status'] ?? 'archived',
          'created': old.isEmpty ? now : old.single['created'],
          'updated': now,
          'metadata': jsonEncode({
            ...oldMetadata,
            'publisher': work['publisher'] ?? oldMetadata['publisher'] ?? '',
            if (publisherId != null && publisherId.isNotEmpty)
              'publisher_account_id': publisherId,
            'images': images,
            if (work['duration_ms'] case final int duration
                when duration > 0)
              'duration_ms': duration,
            if (body.isNotEmpty || oldMetadata.containsKey('article_body'))
              'article_body': body,
          }),
        };
        if (old.isEmpty) {
          await txn.insert('creator_works', row);
        } else {
          await txn.update('creator_works', row,
              where: 'id = ?', whereArgs: [workId]);
        }
        final links = await txn.query('creator_work_links',
            columns: ['work_id'],
            where: 'creator_id = ? AND work_id = ?',
            whereArgs: [creatorId, workId]);
        if (links.isEmpty) {
          await txn.insert('creator_work_links', {
            'creator_id': creatorId,
            'work_id': workId,
          });
          added++;
        }
      }
    });
    return (creatorId: creatorId, added: added);
  }

  Future<void> saveCreatorImageText({
    required String workId,
    required int sourceVersion,
    required int index,
    required String image,
    required String text,
  }) async {
    await db.transaction((txn) async {
      final rows = await txn.query('creator_works',
          columns: ['metadata'],
          where: 'id = ? AND source_version = ?',
          whereArgs: [workId, sourceVersion]);
      if (rows.isEmpty) throw StateError('作品已经更新，请重新打开后再识别。');
      final metadata =
          jsonDecode(rows.single['metadata'] as String) as Map<String, dynamic>;
      final images = metadata['images'] as List? ?? const [];
      if (index < 0 || index >= images.length || images[index] != image) {
        throw StateError('图片已经变化，请重新打开后再识别。');
      }
      final recognized =
          Map<String, dynamic>.from(metadata['image_ocr'] as Map? ?? {});
      final existing = recognized['$index'];
      if (existing is Map &&
          existing['image'] == image &&
          existing['text'] == text) {
        return;
      }
      recognized['$index'] = {'image': image, 'text': text};
      await txn.update(
          'creator_works',
          {
            'source_version': sourceVersion + 1,
            'updated': DateTime.now().millisecondsSinceEpoch,
            'metadata': jsonEncode({...metadata, 'image_ocr': recognized}),
          },
          where: 'id = ?',
          whereArgs: [workId]);
    });
  }

  Future<void> saveCreatorImageFile({
    required String workId,
    required int index,
    required String source,
    required String fileName,
    required String digest,
  }) async {
    await db.transaction((txn) async {
      final rows = await txn.query('creator_works',
          columns: ['metadata'], where: 'id = ?', whereArgs: [workId]);
      if (rows.isEmpty) throw StateError('作品已被移除。');
      final metadata = jsonDecode(rows.single['metadata'] as String) as Map;
      final images = metadata['images'] as List? ?? const [];
      if (index < 0 || index >= images.length || images[index] != source) {
        throw StateError('图片已经变化，请重新同步。');
      }
      final files =
          Map<String, dynamic>.from(metadata['local_images'] as Map? ?? {});
      files['$index'] = {'source': source, 'file': fileName, 'sha256': digest};
      await txn.update(
          'creator_works',
          {
            'metadata': jsonEncode({...metadata, 'local_images': files})
          },
          where: 'id = ?',
          whereArgs: [workId]);
    });
  }

  Future<bool> saveCreatorMedia({
    required String workId,
    required int sourceVersion,
    required String fileName,
    required String digest,
    String? replaceMissingFile,
  }) async {
    return db.transaction((txn) async {
      final rows = await txn.query('creator_works',
          columns: ['metadata'],
          where: 'id = ? AND source_version = ?',
          whereArgs: [workId, sourceVersion]);
      if (rows.isEmpty) throw StateError('作品已经更新，请重新打开后再归档媒体。');
      final metadata =
          jsonDecode(rows.single['metadata'] as String) as Map<String, dynamic>;
      final previousMedia = metadata['local_media_file'];
      if (metadata['local_media_digest'] == digest) {
        if (replaceMissingFile == null || previousMedia != replaceMissingFile) {
          return false;
        }
        metadata['local_media_file'] = fileName;
        if (metadata['transcript_media_file'] == previousMedia) {
          metadata['transcript_media_file'] = fileName;
        }
        await txn.update('creator_works', {'metadata': jsonEncode(metadata)},
            where: 'id = ?', whereArgs: [workId]);
        return true;
      }
      final replaceTranscript = previousMedia != null &&
          metadata['transcript_media_file'] == previousMedia;
      if (replaceTranscript) {
        metadata.remove('transcript_media_file');
        metadata.remove('transcript_source');
        metadata.remove('transcript_cues');
      }
      await txn.update(
        'creator_works',
        {
          'source_version': sourceVersion + 1,
          if (replaceTranscript) 'transcript': '',
          if (replaceTranscript) 'status': 'archived',
          'updated': DateTime.now().millisecondsSinceEpoch,
          'metadata': jsonEncode({
            ...metadata,
            'local_media_file': fileName,
            'local_media_digest': digest,
          }),
        },
        where: 'id = ?',
        whereArgs: [workId],
      );
      return true;
    });
  }

  Future<void> saveCreatorTranscript({
    required String workId,
    required int sourceVersion,
    required String transcript,
    required List<Map<String, Object>> cues,
    String source = 'local_subtitle',
    String? archivedMedia,
  }) async {
    await db.transaction((txn) async {
      final rows = await txn.query('creator_works',
          columns: ['metadata', 'transcript'],
          where: 'id = ? AND source_version = ?',
          whereArgs: [workId, sourceVersion]);
      if (rows.isEmpty) throw StateError('作品已经更新，请重新打开后再导入字幕。');
      final metadata =
          jsonDecode(rows.single['metadata'] as String) as Map<String, dynamic>;
      if (archivedMedia != null &&
          metadata['local_media_file'] != archivedMedia) {
        throw StateError('归档媒体已经变化，请重新打开后再转写。');
      }
      final changed =
          jsonEncode(metadata['transcript_cues']) != jsonEncode(cues) ||
              rows.single['transcript'] != transcript ||
              metadata['transcript_source'] != source ||
              metadata['transcript_media_file'] != archivedMedia;
      if (!changed) return;
      await txn.update(
          'creator_works',
          {
            'source_version': sourceVersion + 1,
            'transcript': transcript,
            'status': 'transcribed',
            'updated': DateTime.now().millisecondsSinceEpoch,
            'metadata': jsonEncode({
              ...metadata,
              'transcript_source': source,
              'transcript_media_file': archivedMedia,
              'transcript_cues': cues
            }),
          },
          where: 'id = ?',
          whereArgs: [workId]);
    });
  }

  Future<LocalRow?> latestCreatorExpert(String creatorId) async =>
      (await db.query('creator_experts',
              where: 'creator_id = ? AND status = ?',
              whereArgs: [creatorId, 'published'],
              orderBy: 'version DESC',
              limit: 1))
          .firstOrNull;

  Future<LocalRow?> publishedCreatorExpertVersion(
          String creatorId, int version) async =>
      (await db.rawQuery('''
        SELECT expert.*, creator.name
        FROM creator_experts AS expert
        JOIN creator_profiles AS creator ON creator.id = expert.creator_id
        WHERE expert.creator_id = ? AND expert.version = ?
          AND expert.status = 'published'
      ''', [creatorId, version])).firstOrNull;

  Future<List<LocalRow>> publishedCreatorExperts() => db.rawQuery('''
    SELECT expert.* FROM creator_experts AS expert
    WHERE expert.status = 'published' AND expert.version = (
      SELECT MAX(prior.version) FROM creator_experts AS prior
      WHERE prior.creator_id = expert.creator_id AND prior.status = 'published'
    )
    ORDER BY expert.creator_id
  ''');

  Future<List<LocalRow>> roundtableChats() =>
      db.query('roundtable_conversations', orderBy: 'updated DESC, rowid DESC');

  Future<List<LocalRow>> searchRoundtableChats(String query) {
    final term = query.trim();
    if (term.isEmpty) return roundtableChats();
    return db.rawQuery('''
      SELECT conversation.* FROM roundtable_conversations AS conversation
      WHERE instr(lower(conversation.title), lower(?)) > 0
        OR EXISTS (
          SELECT 1 FROM roundtable_turns AS turn
          WHERE turn.conversation_id = conversation.id
            AND instr(lower(turn.content), lower(?)) > 0
        )
      ORDER BY conversation.updated DESC, conversation.rowid DESC
    ''', [term, term]);
  }

  Future<LocalRow?> creatorWork(String workId) async =>
      (await db.query('creator_works',
              where: 'id = ?', whereArgs: [workId], limit: 1))
          .firstOrNull;

  Future<List<LocalRow>> creatorAssets() =>
      db.query('creator_assets', orderBy: 'created DESC, rowid DESC');

  Future<void> saveCreatorAsset({
    required String id,
    required String kind,
    required String title,
    required String fileName,
    required Map<String, Object> model,
    required List<Map<String, Object?>> sources,
    String? jobId,
  }) async {
    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (jobId != null) {
        final updated = await txn.update(
            'creator_jobs',
            {
              'status': 'complete',
              'stage': 'published',
              'result_payload': jsonEncode({'asset_id': id}),
              'updated': now,
            },
            where: 'id = ? AND status = ?',
            whereArgs: [jobId, 'running']);
        if (updated != 1) throw StateError('生成任务已经结束。');
      }
      await txn.insert('creator_assets', {
        'id': id,
        'kind': kind,
        'title': title,
        'file_path': fileName,
        'model_snapshot': jsonEncode(model),
        'source_snapshot': jsonEncode(sources),
        'created': now,
      });
    });
  }

  Future<String> beginCreatorAssetJob(String kind, String title,
      Map<String, Object> model, List<Map<String, Object?>> versions) async {
    final id = uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('creator_jobs', {
      'id': id,
      'kind': 'asset-$kind',
      'status': 'running',
      'stage': 'generate_review',
      'model_snapshot': jsonEncode(model),
      'source_snapshot': jsonEncode(versions),
      'request_payload': jsonEncode({'title': title, 'workflow_version': 1}),
      'created': now,
      'updated': now,
    });
    return id;
  }

  Future<List<LocalRow>> roundtableTurns(String chatId) =>
      db.query('roundtable_turns',
          where: 'conversation_id = ?', whereArgs: [chatId], orderBy: 'rowid');

  Future<void> deleteRoundtableChat(String chatId) async {
    await db.delete('roundtable_conversations',
        where: 'id = ?', whereArgs: [chatId]);
  }

  Future<String> saveRoundtableExchange({
    String? chatId,
    required String question,
    required Map<String, Object> model,
    required List<Map<String, Object>> replies,
  }) async {
    final id = chatId ?? uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      if (chatId == null) {
        await txn.insert('roundtable_conversations', {
          'id': id,
          'title': String.fromCharCodes(question.runes.take(45)),
          'model_snapshot': jsonEncode(model),
          'created': now,
          'updated': now,
        });
      } else {
        await txn.update('roundtable_conversations', {'updated': now},
            where: 'id = ?', whereArgs: [id]);
      }
      await txn.insert('roundtable_turns', {
        'id': uuid.v4(),
        'conversation_id': id,
        'role': 'user',
        'content': question,
        'expert_snapshot': jsonEncode(model),
        'created': now,
      });
      for (final reply in replies) {
        await txn.insert('roundtable_turns', {
          'id': uuid.v4(),
          'conversation_id': id,
          'role': 'assistant',
          'content': reply['text'],
          'expert_snapshot': jsonEncode({...model, 'expert': reply['expert']}),
          'evidence': jsonEncode(reply['evidence']),
          'created': now,
        });
      }
    });
    return id;
  }

  Future<String> beginCreatorExpertJob(String creatorId,
      Map<String, Object> model, List<Map<String, Object>> evidence,
      {bool fromSync = false,
      LocalRow? creatorIdentity,
      bool queued = false}) async {
    final id = uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('creator_jobs', {
      'id': id,
      'kind': 'creator-expert',
      'status': queued ? 'queued' : 'running',
      'stage': queued ? 'queued' : 'extract_review',
      'model_snapshot': jsonEncode(model),
      'source_snapshot': jsonEncode(evidence),
      'request_payload': jsonEncode({
        'actor_id': 'community-local',
        'workflow_version': 1,
        'creator_ids': [creatorId],
        if (creatorIdentity != null) 'creator_identity': creatorIdentity,
        if (fromSync) 'trigger': 'work-sync',
      }),
      'created': now,
      'updated': now,
    });
    return id;
  }

  static const _syncCreatorScope =
      "kind = 'creator-sync' AND json_extract(request_payload, '\$.creator_id') = ?";

  Future<LocalRow?> lastResumableCreatorSyncJob(String creatorId) async {
    final rows = await db.query('creator_jobs',
        where: _syncCreatorScope,
        whereArgs: [creatorId],
        orderBy: 'created DESC, rowid DESC',
        limit: 1);
    final job = rows.firstOrNull;
    return const {'failed', 'interrupted'}.contains(job?['status'])
        ? job
        : null;
  }

  Future<String> beginCreatorSyncJob(
    String creatorId, {
    required int? latest,
    required String? model,
    String? resumeId,
  }) =>
      db.transaction((txn) async {
        final running = await txn.query('creator_jobs',
            columns: ['id'],
            where: "$_syncCreatorScope AND status = 'running'",
            whereArgs: [creatorId],
            limit: 1);
        if (running.isNotEmpty) throw StateError('该博主正在同步，请稍后重试。');
        final now = DateTime.now().millisecondsSinceEpoch;
        if (resumeId != null) {
          final changed = await txn.update(
            'creator_jobs',
            {'status': 'running', 'error': null, 'updated': now},
            where: "$_syncCreatorScope AND id = ? "
                "AND status IN ('failed', 'interrupted')",
            whereArgs: [creatorId, resumeId],
          );
          if (changed != 1) throw StateError('同步状态已变化，请重新打开同步。');
          return resumeId;
        }
        final id = uuid.v4();
        await txn.insert('creator_jobs', {
          'id': id,
          'kind': 'creator-sync',
          'status': 'running',
          'stage': 'collect',
          'request_payload':
              jsonEncode({'creator_id': creatorId, 'latest': latest}),
          'model_snapshot': jsonEncode({'selection': model}),
          'created': now,
          'updated': now,
        });
        return id;
      });

  Future<void> checkpointCreatorSyncJob(
      String id, Map<String, Object?> checkpoint) async {
    final changed = await db.update(
      'creator_jobs',
      {
        'result_payload': jsonEncode(checkpoint),
        'updated': DateTime.now().millisecondsSinceEpoch,
      },
      where: "id = ? AND kind = 'creator-sync' AND status = 'running'",
      whereArgs: [id],
    );
    if (changed != 1) throw StateError('同步已经结束，无法保存进度。');
  }

  Future<void> failCreatorJob(String id, String message) async {
    await db.update(
        'creator_jobs',
        {
          'status': 'failed',
          'error': message,
          'updated': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ? AND status = ?',
        whereArgs: [id, 'running']);
  }

  Future<
      LocalRow?> lastCreatorExpertJob(String creatorId) async => (await db.query(
          'creator_jobs',
          where:
              "kind = ? AND json_extract(request_payload, '\$.creator_ids[0]') = ?",
          whereArgs: ['creator-expert', creatorId],
          orderBy: 'created DESC, rowid DESC',
          limit: 1))
      .firstOrNull;

  Future<LocalRow?> nextQueuedCreatorExpertJob() async =>
      (await db.query('creator_jobs',
              where: "kind = 'creator-expert' AND status = 'queued'",
              orderBy: 'created, rowid',
              limit: 1))
          .firstOrNull;

  Future<void> resumeCreatorExpertJob(String id) async {
    final changed = await db.update(
        'creator_jobs',
        {
          'status': 'running',
          'error': null,
          'updated': DateTime.now().millisecondsSinceEpoch,
        },
        where:
            "id = ? AND kind = 'creator-expert' AND status IN ('failed', 'interrupted', 'queued')",
        whereArgs: [id]);
    if (changed != 1) throw StateError('任务状态已经变化，请刷新后重试。');
  }

  Future<void> checkpointCreatorExpertJob(
    String id,
    int offset,
    int batch,
    List<Map<String, Object>> methods,
  ) async {
    final changed = await db.update(
        'creator_jobs',
        {
          'result_payload': jsonEncode({
            'evidence_offset': offset,
            'batch': batch,
            'accepted_methods': methods,
          }),
          'updated': DateTime.now().millisecondsSinceEpoch,
        },
        where: "id = ? AND kind = 'creator-expert' AND status = 'running'",
        whereArgs: [id]);
    if (changed != 1) throw StateError('任务已经结束，无法保存进度。');
  }

  Future<void> checkpointCreatorMethodReconciliation(
    String id,
    int baseVersion,
    List<Map<String, Object>> methods,
  ) async {
    final changed = await db.rawUpdate(
      r"""UPDATE creator_jobs
      SET result_payload = json_set(result_payload,
            '$.reconciled_base_version', ?, '$.reconciled_methods', json(?)),
          updated = ?
      WHERE id = ? AND kind = 'creator-expert' AND status = 'running'""",
      [
        baseVersion,
        jsonEncode(methods),
        DateTime.now().millisecondsSinceEpoch,
        id
      ],
    );
    if (changed != 1) throw StateError('任务已经结束，无法保存方法复核结果。');
  }

  Future<LocalRow?> lastResumableCreatorAssetJob(String kind) async =>
      (await db.query('creator_jobs',
              where: "kind = ? AND status IN ('failed', 'interrupted') "
                  "AND (stage = 'generate_review' OR (stage IN ('review', 'render') "
                  "AND json_type(result_payload, '\$.sections') = 'array'))",
              whereArgs: ['asset-$kind'],
              orderBy: 'updated DESC, rowid DESC',
              limit: 1))
          .firstOrNull;

  Future<void> resumeCreatorAssetJob(String id, String kind) async {
    final updated = await db.update(
        'creator_jobs',
        {
          'status': 'running',
          'error': null,
          'updated': DateTime.now().millisecondsSinceEpoch,
        },
        where: "id = ? AND kind = ? AND status IN ('failed', 'interrupted') "
            "AND (stage = 'generate_review' OR (stage IN ('review', 'render') "
            "AND json_type(result_payload, '\$.sections') = 'array'))",
        whereArgs: [id, 'asset-$kind']);
    if (updated != 1) throw StateError('任务状态已经变化，请刷新后重试。');
  }

  Future<void> checkpointCreatorAssetCandidate(
      String id, String kind, Map<String, Object> draft) async {
    final changed = await db.update(
      'creator_jobs',
      {
        'stage': 'review',
        'result_payload': jsonEncode(draft),
        'updated': DateTime.now().millisecondsSinceEpoch
      },
      where:
          "id = ? AND kind = ? AND status = 'running' AND stage = 'generate_review'",
      whereArgs: [id, 'asset-$kind'],
    );
    if (changed != 1) throw StateError('任务已经结束，无法保存待复核草稿。');
  }

  Future<void> rejectCreatorAssetCandidate(String id, String kind) async {
    final changed = await db.update(
      'creator_jobs',
      {
        'stage': 'generate_review',
        'result_payload': '{}',
        'updated': DateTime.now().millisecondsSinceEpoch
      },
      where: "id = ? AND kind = ? AND status = 'running' AND stage = 'review'",
      whereArgs: [id, 'asset-$kind'],
    );
    if (changed != 1) throw StateError('任务已经结束，无法重新生成草稿。');
  }

  Future<void> checkpointCreatorAssetJob(
      String id, String kind, Map<String, Object> draft) async {
    final updated = await db.update(
        'creator_jobs',
        {
          'stage': 'render',
          'result_payload': jsonEncode(draft),
          'updated': DateTime.now().millisecondsSinceEpoch,
        },
        where: "id = ? AND kind = ? AND status = 'running'",
        whereArgs: [id, 'asset-$kind']);
    if (updated != 1) throw StateError('任务已经结束，无法保存进度。');
  }

  Future<int> publishCreatorExpert({
    required String creatorId,
    required String jobId,
    required List<Map<String, Object>> methods,
    required List<Map<String, Object>> evidence,
    List<Map<String, Object>> graphTopics = const [],
    List<Map<String, Object>>? graphPrecedence,
    Map<String, Object?>? skillProfile,
    int? expectedBaseVersion,
  }) async {
    if (methods.isEmpty) throw StateError('至少需要一个经验证的方法。');
    return db.transaction((txn) async {
      final prior = await txn.query('creator_experts',
          columns: ['version'],
          where: 'id = ?',
          whereArgs: [creatorId],
          orderBy: 'version DESC',
          limit: 1);
      final baseVersion = prior.firstOrNull?['version'] as int? ?? 0;
      if (expectedBaseVersion != null && expectedBaseVersion != baseVersion) {
        throw StateError('专家已有更新版本，请重新提交后发布。');
      }
      final version = baseVersion + 1;
      final now = DateTime.now().millisecondsSinceEpoch;
      final saved = await txn.update(
          'creator_jobs',
          {
            'status': 'complete',
            'stage': 'published',
            'result_payload':
                jsonEncode({'expert_id': creatorId, 'expert_version': version}),
            'updated': now,
          },
          where: 'id = ? AND status = ?',
          whereArgs: [jobId, 'running']);
      if (saved != 1) throw StateError('专家任务已结束，请重新提交。');
      await txn.insert('creator_experts', {
        'id': creatorId,
        'creator_id': creatorId,
        'version': version,
        'status': 'published',
        'content': jsonEncode({
          'methods': methods,
          if (skillProfile != null) 'skill_profile': skillProfile,
          'graph_topics': graphTopics,
          if (graphPrecedence != null) 'graph_precedence': graphPrecedence,
        }),
        'evidence': jsonEncode(evidence),
        'created': now,
      });
      return version;
    });
  }

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
