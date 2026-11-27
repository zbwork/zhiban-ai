import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_expert_workflow.dart';
import 'package:zhiban_client/pages/local_workspace/services/local_workspace_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('重开数据库后续传同步，作品和任务状态同时提交', () async {
    final dir = await Directory.systemTemp.createTemp('creator-sync-');
    addTearDown(() => dir.delete(recursive: true));
    Future<LocalWorkspaceStore> open() => LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: '${dir.path}/workspace.db');
    var store = await open();
    addTearDown(() => store.db.close());
    const author = {'id': 'author', 'name': '测试博主'};
    const first = {'id': '1234567890123456789', 'title': '原有作品'};
    const second = {'id': '1234567890123456790', 'title': '新作品'};
    final original = await store.importCreatorWorks(author, [first]);
    final creator = original.creatorId;
    await store.importCreatorWorks({'id': 'another-author'}, [second]);
    final job = await store.beginCreatorSyncJob(creator, latest: 3, model: 'm');
    final progress = {
      'author_id': 'author',
      'next_cursor': 7,
      'cursors': [0],
      'works': {first['id']!: 1},
    };
    await store.checkpointCreatorSyncJob(job, progress);
    await expectLater(
        store.beginCreatorSyncJob(creator, latest: null, model: null),
        throwsStateError);
    await store.db.close();
    store = await open();

    final pending = (await store.lastResumableCreatorSyncJob(creator))!;
    expect(pending['id'], job);
    expect(pending['status'], 'interrupted');
    expect(jsonDecode(pending['result_payload'] as String), progress);
    expect(jsonDecode(pending['request_payload'] as String)['latest'], 3);
    expect(jsonDecode(pending['model_snapshot'] as String)['selection'], 'm');
    expect(
        await store.beginCreatorSyncJob(creator,
            latest: 3, model: 'm', resumeId: job),
        job);
    final profileBefore = (await store.creatorProfiles())
        .singleWhere((row) => row['id'] == creator);
    await expectLater(
        store.importCreatorWorks(author, [first, second], syncJobId: job),
        throwsStateError);
    expect(
        (await store.creatorProfiles())
            .singleWhere((row) => row['id'] == creator),
        profileBefore);
    expect((await store.creatorWorks(creator)).single['title'], '原有作品');
    expect(
        (await store.db
                .query('creator_jobs', where: 'id = ?', whereArgs: [job]))
            .single['status'],
        'running');

    final saved = await store.importCreatorWorks(
        author,
        [
          first,
          {'id': '1234567890123456791', 'title': '可入库的新作品'},
        ],
        syncJobId: job);
    expect(saved.added, 1);
    expect(await store.creatorWorks(creator), hasLength(2));
    expect(await store.lastResumableCreatorSyncJob(creator), isNull);
    final complete = (await store.db
            .query('creator_jobs', where: 'id = ?', whereArgs: [job]))
        .single;
    expect(complete['status'], 'complete');
    expect(complete['result_payload'], '{}');
  });

  test('升级旧库后联合作品共享归档并且不阻塞整批同步', () async {
    final dir = await Directory.systemTemp.createTemp('creator-links-');
    addTearDown(() => dir.delete(recursive: true));
    Future<LocalWorkspaceStore> open() => LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: '${dir.path}/workspace.db');
    var store = await open();
    addTearDown(() => store.db.close());
    const publisher = {'id': 'publisher', 'name': '原作者'};
    const collaborator = {'id': 'collaborator', 'name': '联合作品作者'};
    const joint = {'id': '1234567890123456789', 'title': '联合作品'};
    final original = await store.importCreatorWorks(publisher, [joint]);
    final originalWork = (await store.creatorWorks(original.creatorId)).single;
    final workId = originalWork['id'] as String;
    await store.saveCreatorTranscript(
        workId: workId,
        sourceVersion: 1,
        transcript: '两位博主共享的原文',
        cues: [
          {'start_ms': 0, 'end_ms': 1000, 'text': '两位博主共享的原文'}
        ]);
    await store.db.execute('DROP TABLE creator_work_links');
    await store.db.setVersion(8);
    await store.db.close();
    store = await open();

    final first = (await store.creatorWorks(original.creatorId)).single;
    expect(first['id'], workId);
    expect(first['source_version'], 2);
    final other = await store.importCreatorWorks(collaborator, []);
    final job = await store.beginCreatorSyncJob(other.creatorId,
        latest: 4, model: null);
    const batch = [
      {'id': '1234567890123456790', 'title': '其他新作品'},
      {...joint, 'coauthored': true, 'publisher_account_id': 'publisher'},
    ];
    expect((await store.importCreatorWorks(collaborator, batch, syncJobId: job))
        .added, 2);
    final otherWorks = await store.creatorWorks(other.creatorId);
    expect(otherWorks, hasLength(2));
    final linked = otherWorks.singleWhere((row) => row['id'] == workId);
    expect(linked['creator_id'], other.creatorId);
    expect(linked['transcript'], first['transcript']);
    expect(creatorEvidence([linked]), creatorEvidence([first]));
    expect((await store.importCreatorWorks(collaborator, batch)).added, 0);
    expect(await store.db.query('creator_works'), hasLength(2));
    expect(await store.lastResumableCreatorSyncJob(other.creatorId), isNull);

    const otherJoint = {'id': '1234567890123456791', 'title': '先从合作者导入'};
    await store.importCreatorWorks(collaborator, [
      {...otherJoint, 'coauthored': true, 'publisher_account_id': 'publisher'}
    ]);
    expect((await store.importCreatorWorks(publisher, [otherJoint])).added, 1);
    expect(await store.db.query('creator_works'), hasLength(3));
    const legacyJoint = {'id': '1234567890123456792', 'title': '旧版归档的联合作品'};
    await store.importCreatorWorks(collaborator, [
      {...legacyJoint, 'coauthored': true}
    ]);
    expect(
        (await store.importCreatorWorks(publisher, [
          {...legacyJoint, 'publisher_account_id': 'publisher'}
        ])).added,
        1);
    expect(await store.db.query('creator_works'), hasLength(4));
  });

  test('重开后按顺序取出待蒸馏任务并保留模型和证据', () async {
    final dir = await Directory.systemTemp.createTemp('creator-expert-queue-');
    addTearDown(() => dir.delete(recursive: true));
    Future<LocalWorkspaceStore> open() => LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: '${dir.path}/workspace.db');
    var store = await open();
    addTearDown(() => store.db.close());
    const model = {'provider_id': 'fixture', 'model_id': 'original'};
    const evidence = [{'id': 'evidence-v1', 'text': '原始作品证据'}];
    final active = await store.beginCreatorExpertJob('a', model, evidence);
    final first = await store.beginCreatorExpertJob('b', model, evidence,
        queued: true, fromSync: true);
    final second = await store.beginCreatorExpertJob('c', model, evidence,
        queued: true, fromSync: true);
    await store.db.close();
    store = await open();

    expect((await store.lastCreatorExpertJob('a'))!['id'], active);
    expect((await store.lastCreatorExpertJob('a'))!['status'], 'interrupted');
    final queued = (await store.nextQueuedCreatorExpertJob())!;
    expect(queued['id'], first);
    expect(queued['status'], 'queued');
    expect(jsonDecode(queued['model_snapshot'] as String), model);
    expect(jsonDecode(queued['source_snapshot'] as String), evidence);
    await store.resumeCreatorExpertJob(first);
    expect((await store.lastCreatorExpertJob('b'))!['status'], 'running');
    expect((await store.nextQueuedCreatorExpertJob())!['id'], second);
    await store.failCreatorJob(first, '所选模型已停用');
    expect((await store.lastCreatorExpertJob('b'))!['status'], 'failed');
    expect((await store.nextQueuedCreatorExpertJob())!['id'], second);
  });

  test('对话历史按标题或正文搜索并将通配符视为普通文本', () async {
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.db.close);
    final pilot = await store.saveRoundtableExchange(
      question: '付费试点',
      model: {},
      replies: [
        {
          'text': '绿色发票 100%',
          'expert': {'name': '专家'},
          'evidence': []
        },
        {
          'text': '绿色发票',
          'expert': {'name': '复核人'},
          'evidence': []
        },
      ],
    );
    final other = await store
        .saveRoundtableExchange(question: '交付方案', model: {}, replies: []);
    Future<List<Object?>> ids(String term) async =>
        (await store.searchRoundtableChats(term))
            .map((row) => row['id'])
            .toList();
    expect(await ids('  发票 '), [pilot]);
    expect(await ids('付费'), [pilot]);
    expect(await ids('%'), [pilot]);
    expect(await ids('_'), isEmpty);
    expect(await ids(''), [other, pilot]);
  });

  test('图文正文按顺序引用，重导不改变版本，正文变化生成新证据', () async {
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.db.close);
    Future<String> save(String body) async => (await store.importCreatorWorks({
          'id': 'paragraph-test'
        }, [
          {
            'id': '1234567890123456789',
            'title': '图文',
            'images': ['https://p3.douyinpic.com/first.jpg'],
            'article_body': body,
          }
        ]))
            .creatorId;
    final creator = await save('核对付款记录\n\n确认预算负责人');
    final first = creatorEvidence(await store.creatorWorks(creator));
    expect(first.map((item) => item['paragraph_number']), [1, 2]);
    expect(first.last['text'], '确认预算负责人');
    await save('核对付款记录\n\n确认预算负责人');
    expect(creatorEvidence(await store.creatorWorks(creator)), first);
    await save('核对付款记录\n复核发票');
    final updated = creatorEvidence(await store.creatorWorks(creator));
    expect(updated.last['source_version'], 2);
    expect(updated.last['text'], '复核发票');
    expect(updated.last['id'], isNot(first.last['id']));
  });

  test('更换媒体时清除绑定旧文件的逐字稿，并拒绝过期写入', () async {
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.db.close);
    final creator = await store.importCreatorWorks(
      {'id': 'media-test', 'name': '媒体作者'},
      [
        {'id': '1234567890123456789', 'title': '媒体作品'}
      ],
    );
    final id =
        (await store.creatorWorks(creator.creatorId)).single['id'] as String;
    expect(
        await store.saveCreatorMedia(
            workId: id, sourceVersion: 1, fileName: 'first.mp4', digest: 'one'),
        isTrue);
    await store.saveCreatorTranscript(
      workId: id,
      sourceVersion: 2,
      archivedMedia: 'first.mp4',
      transcript: '旧视频的文字',
      cues: [
        {'start_ms': 0, 'end_ms': 1000, 'text': '旧视频的文字'}
      ],
    );
    expect(
        await store.saveCreatorMedia(
            workId: id,
            sourceVersion: 3,
            fileName: 'second.mp4',
            digest: 'one'),
        isFalse);
    expect(
        await store.saveCreatorMedia(
            workId: id,
            sourceVersion: 3,
            fileName: 'second.mp4',
            digest: 'two'),
        isTrue);
    final current = (await store.creatorWorks(creator.creatorId)).single;
    expect(current['source_version'], 4);
    expect(current['transcript'], '');
    expect(current['status'], 'archived');
    await expectLater(
        store.saveCreatorTranscript(
            workId: id,
            sourceVersion: 4,
            archivedMedia: 'first.mp4',
            transcript: '过期结果',
            cues: []),
        throwsStateError);
  });

  test('图片证据按归档顺序定位，换图后旧记录不再参与蒸馏', () async {
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.db.close);
    const author = {'id': 'ocr-test', 'name': '测试博主'};
    const first = 'https://p3.douyinpic.com/first.jpg';
    const second = 'https://p3.douyinpic.com/second.jpg';
    Future<String> importImages(List<String> images) async =>
        (await store.importCreatorWorks(author, [
          {'id': '1234567890123456789', 'title': '图文', 'images': images},
        ]))
            .creatorId;
    final creator = await importImages([first, second]);
    final work = (await store.creatorWorks(creator)).single;
    final id = work['id'] as String;
    await store.saveCreatorImageText(
        workId: id, sourceVersion: 1, index: 1, image: second, text: '第二张原文');
    final evidence = creatorEvidence(await store.creatorWorks(creator)).single;
    expect(evidence['image_number'], 2);
    expect(evidence['source_version'], 2);
    expect(evidence['text'], '第二张原文');
    await importImages([second, first]);
    expect(creatorEvidence(await store.creatorWorks(creator)), isEmpty);
    await expectLater(
        store.saveCreatorImageText(
            workId: id, sourceVersion: 2, index: 1, image: second, text: '旧结果'),
        throwsStateError);
  });

  test('资产复核前中断后恢复原专家版本和任务编号', () async {
    final directory =
        await Directory.systemTemp.createTemp('creator-asset-job-');
    final path = '${directory.path}/roundtable.db';
    var store =
        await LocalWorkspaceStore.open(factory: databaseFactoryFfi, path: path);
    addTearDown(() async {
      if (store.db.isOpen) await store.db.close();
      await directory.delete(recursive: true);
    });
    final creator = (await store.importCreatorWorks(
      {'id': 'asset-source-author', 'name': '来源博主'},
      [
        {'id': '1234567890123456789', 'title': '作品'}
      ],
    ))
        .creatorId;
    const model = {'provider_id': 'p1', 'model_id': 'model-a'};
    Future<int> publish(String evidenceId) async {
      final evidence = <Map<String, Object>>[
        {'id': evidenceId, 'text': '原文 $evidenceId'}
      ];
      const identity = {'name': '来源博主'};
      final job = await store.beginCreatorExpertJob(creator, model, evidence,
          creatorIdentity: identity);
      expect(
        jsonDecode(
            (await store.lastCreatorExpertJob(creator))!['request_payload']
                as String)['creator_identity'],
        identity,
      );
      return store.publishCreatorExpert(
        creatorId: creator,
        jobId: job,
        methods: [
          {'id': evidenceId}
        ],
        evidence: evidence,
        skillProfile: {
          'creator': identity,
          'source_refs': [evidenceId]
        },
      );
    }

    expect(await publish('first'), 1);
    final job = await store.beginCreatorAssetJob(
      'web',
      '冻结资产名称',
      model,
      [
        {'expert_id': creator, 'version': 1}
      ],
    );
    await store.db.close();
    store =
        await LocalWorkspaceStore.open(factory: databaseFactoryFfi, path: path);
    expect(await publish('second'), 2);
    final pending = (await store.lastResumableCreatorAssetJob('web'))!;
    expect(pending['id'], job);
    expect(pending['stage'], 'generate_review');
    expect(pending['status'], 'interrupted');
    expect(pending['model_snapshot'], contains('model-a'));
    expect(pending['request_payload'], contains('冻结资产名称'));
    expect((await store.latestCreatorExpert(creator))?['evidence'],
        contains('second'));
    final frozen = await store.publishedCreatorExpertVersion(creator, 1);
    expect(frozen?['name'], '来源博主');
    expect(frozen?['evidence'], contains('first'));
    expect(frozen?['evidence'], isNot(contains('second')));
    expect(
      jsonDecode(frozen!['content'] as String)['skill_profile']['source_refs'],
      ['first'],
    );
    expect(await store.publishedCreatorExpertVersion(creator, 3), isNull);

    await store.resumeCreatorAssetJob(job, 'web');
    await expectLater(
        store.resumeCreatorAssetJob(job, 'web'), throwsStateError);
    await store
        .checkpointCreatorAssetCandidate(job, 'web', {'sections': <Object>[]});
    await store.failCreatorJob(job, '复核服务中断');
    expect(
        (await store.lastResumableCreatorAssetJob('web'))?['stage'], 'review');
    await store.resumeCreatorAssetJob(job, 'web');
    await store.rejectCreatorAssetCandidate(job, 'web');
    await store.failCreatorJob(job, '复核拒绝');
    expect((await store.lastResumableCreatorAssetJob('web'))?['stage'],
        'generate_review');
    await store.resumeCreatorAssetJob(job, 'web');
    await store.checkpointCreatorAssetJob(job, 'web', {'sections': <Object>[]});
    await store.failCreatorJob(job, '磁盘失败');
    final saved = await store.lastResumableCreatorAssetJob('web');
    expect(saved?['id'], job);
    expect(saved?['stage'], 'render');
    expect(saved?['source_snapshot'], pending['source_snapshot']);
  });

  test('资产复核完成后可重试渲染并且只发布一次', () async {
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.db.close);
    const model = {'model_id': 'model-a'};
    const versions = [
      {'expert_id': 'creator-a', 'version': 2}
    ];
    final ready =
        await store.beginCreatorAssetJob('web', '测试', model, versions);
    await store
        .checkpointCreatorAssetJob(ready, 'web', {'sections': <Object>[]});
    await store.failCreatorJob(ready, '磁盘写入失败');
    expect((await store.lastResumableCreatorAssetJob('web'))?['id'], ready);
    expect(await store.lastResumableCreatorAssetJob('ebook'), isNull);
    await store.resumeCreatorAssetJob(ready, 'web');
    await expectLater(
        store.resumeCreatorAssetJob(ready, 'web'), throwsStateError);
    await store.saveCreatorAsset(
      id: ready,
      kind: 'web',
      title: '测试',
      fileName: '$ready.html',
      model: model,
      sources: versions,
      jobId: ready,
    );
    expect((await store.creatorAssets()).single['id'], ready);
    expect(await store.lastResumableCreatorAssetJob('web'), isNull);
  });

  test(
      'publishing experts is versioned and conversations retain their frozen citations',
      () async {
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.db.close);
    final inserted = await store.importCreatorWorks(
      {'id': 'author-roundtable', 'name': '测试专家'},
      [
        {'id': '1234567890123456789', 'title': '测试来源'}
      ],
    );
    final work = (await store.creatorWorks(inserted.creatorId)).single;
    final workId = work['id'] as String;
    await store.saveCreatorTranscript(
        workId: workId,
        sourceVersion: 1,
        transcript: '00:00 原文',
        cues: [
          {'start_ms': 0, 'end_ms': 1000, 'text': '原文'}
        ]);
    await expectLater(
        store.saveCreatorTranscript(
            workId: workId, sourceVersion: 1, transcript: '过期', cues: []),
        throwsStateError);
    final evidence = <Map<String, Object>>[
      {
        'id': '$workId:2:0',
        'work_id': workId,
        'source_version': 2,
        'text': '原文'
      },
    ];
    final model = <String, Object>{'model_id': 'model-a'};
    final first =
        await store.beginCreatorExpertJob(inserted.creatorId, model, evidence);
    final methods = <Map<String, Object>>[
      {'id': 'method-a'}
    ];
    expect(
        await store.publishCreatorExpert(
            creatorId: inserted.creatorId,
            jobId: first,
            methods: methods,
            evidence: evidence),
        1);
    final second =
        await store.beginCreatorExpertJob(inserted.creatorId, model, evidence);
    await store.failCreatorJob(second, '测试失败');
    expect(
        (await store.lastCreatorExpertJob(inserted.creatorId))?['id'], second);
    await store.resumeCreatorExpertJob(second);
    await store.checkpointCreatorExpertJob(second, 1, 1, methods);
    await store.checkpointCreatorMethodReconciliation(second, 1, methods);
    await store.failCreatorJob(second, '中途失败');
    await store.resumeCreatorExpertJob(second);
    final resumed = (await store.lastCreatorExpertJob(inserted.creatorId))!;
    expect(resumed['status'], 'running');
    final checkpoint = jsonDecode(resumed['result_payload'] as String) as Map;
    expect(checkpoint['evidence_offset'], 1);
    expect(checkpoint['accepted_methods'], methods);
    expect(checkpoint['reconciled_base_version'], 1);
    expect(checkpoint['reconciled_methods'], methods);
    expect(resumed['model_snapshot'], contains('model-a'));
    expect(
        (await store.latestCreatorExpert(inserted.creatorId))!['version'], 1);
    final chat = await store
        .saveRoundtableExchange(question: '请给出依据', model: model, replies: [
      {
        'text': '这是原文 [1]',
        'evidence': evidence,
        'expert': {'version': 1}
      },
    ]);
    expect(
        (await store.roundtableTurns(chat)).last['evidence'], contains('原文'));
    await store.deleteRoundtableChat(chat);
    expect(await store.roundtableTurns(chat), isEmpty);
  });

  test('同一抖音作品重复导入只保留一个博主和一个作品', () async {
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.db.close);
    final result = <String, dynamic>{
      'author': {
        'id': 'MS4wLjABAAAA-stable-author',
        'name': '真实博主',
        'bio': '介绍',
        'avatar': 'https://example.com/avatar.png',
        'followers': 12,
        'works': 3,
      },
      'work': {
        'id': '1234567890123456789',
        'title': '第一条真实作品',
        'cover': 'https://example.com/cover.png',
        'published_at': 1700000000,
        'likes': 10,
        'comments': 2,
        'collects': 1,
        'shares': 0,
        'publisher': '真实博主',
      },
    };

    final first = await store.importCreatorWork(result);
    final second = await store.importCreatorWork({
      ...result,
      'work': {...result['work'] as Map, 'likes': 11},
    });

    expect(second, first);
    final creators = await store.creatorProfiles();
    final works = await store.creatorWorks(first);
    expect(creators, hasLength(1));
    expect(works, hasLength(1));
    expect(works.single['likes'], 11);
    expect(works.single['source_version'], 1);
    await store.db.update(
        'creator_works',
        {
          'transcript': '00:00 之前生成的逐字稿',
        },
        where: 'id = ?',
        whereArgs: [works.single['id']]);
    await store.importCreatorWork({
      ...result,
      'work': {...result['work'] as Map, 'id': '1234567890123456790'},
    });
    await store.importCreatorWork(result);
    final allWorks = await store.creatorWorks(first);
    expect(allWorks, hasLength(2));
    expect(
        allWorks.singleWhere(
            (row) => row['id'] == works.single['id'])['transcript'],
        '00:00 之前生成的逐字稿');
  });

  test('稳定标识不依赖博主昵称', () async {
    final store = await LocalWorkspaceStore.open(
        factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.db.close);
    final base = <String, dynamic>{
      'author': {
        'id': 'MS4wLjABAAAA-same-author',
        'name': '旧昵称',
        'avatar': 'https://p3.douyinpic.com/test.png',
        'followers': 0,
        'works': 1,
      },
      'work': {
        'id': '9876543210123456789',
        'title': '作品',
        'published_at': 1700000000,
      },
    };
    final id = await store.importCreatorWork(base);
    final renamed = await store.importCreatorWork({
      ...base,
      'author': {...base['author'] as Map, 'name': '新昵称', 'avatar': ''},
    });

    expect(renamed, id);
    final updated = (await store.creatorProfiles()).single;
    expect(updated['name'], '新昵称');
    expect(updated['avatar_url'], 'https://p3.douyinpic.com/test.png');
  });
}
