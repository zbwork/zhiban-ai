import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_expert_workflow.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_graph_topics.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_subtitles.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/douyin_creator_service.dart';

void main() {
  test('知识更新只在原文或来源锚点变化时提交', () {
    final refs = <Map<String, Object>>[
      {'id': 'work-1:1:0', 'text': '原文甲'},
      {'id': 'work-2:1:0', 'text': '原文乙'},
    ];
    final published = jsonEncode(refs);
    expect(
        creatorEvidenceHasChanged(refs.reversed.toList(), published), isFalse);
    expect(creatorEvidenceHasChanged([refs.first], published), isTrue);
    expect(
        creatorEvidenceHasChanged([
          refs.first,
          {'id': 'work-2:2:0', 'text': '原文乙'},
        ], published),
        isTrue);
    expect(
        creatorEvidenceHasChanged([
          refs.first,
          {'id': 'work-2:1:0', 'text': '正文更新'},
        ], published),
        isTrue);
  });
  test('抖音分享文案支持转义分隔符并继续拒绝外部域名或多条链接', () {
    const canonical = 'https://v.douyin.com/QSOW49trZuA/';
    for (final input in [
      canonical,
      r'前缀 https\://v.douyin.com/QSOW49trZuA/。 复制打开抖音',
      r'前缀 https:\/\/v.douyin.com/QSOW49trZuA/。 复制打开抖音',
    ]) {
      expect(DouyinCreatorService.normalizeLink(input), canonical);
    }
    for (final invalid in [
      r'https\://another.example/QSOW49trZuA/',
      '$canonical $canonical',
    ]) {
      expect(() => DouyinCreatorService.normalizeLink(invalid),
          throwsA(isA<DouyinCreatorException>()));
    }
  });

  test('仅明确的抖音授权错误需要重新登录', () {
    for (final code in ['auth_required', 'auth_expired']) {
      expect(DouyinCreatorException('登录失效', code: code).requiresLogin, isTrue);
    }
    for (final code in [
      'forbidden',
      'rate_limited',
      'connection_failed',
      null
    ]) {
      expect(DouyinCreatorException('读取失败', code: code).requiresLogin, isFalse);
    }
  });
  test('新版相同方法沿用编号，合并当前证据并排除过期证据', () {
    Map<String, Object> method(String id, String limits, List<String> refs) => {
          'id': id,
          'problem': '确认试点范围',
          'applies_when': '有真实预算',
          'limits': limits,
          'steps': [
            {'action': '核对发票', 'evidence_ids': refs}
          ],
        };
    final updated = mergePublishedCreatorMethods(
      current: [
        method('new', '需预算负责人在场', ['new-source']),
        method('distinct', '可先由项目经理确认', ['new-source']),
      ],
      evidence: [
        {'id': 'new-source'},
        {'id': 'unchanged-source', 'text': '同一内容'},
        {'id': 'overwritten-source', 'text': '不同的新内容'},
      ],
      published: {
        'evidence': jsonEncode([
          {'id': 'unchanged-source', 'text': '同一内容'},
          {'id': 'overwritten-source', 'text': '较早的内容'},
        ]),
        'content': jsonEncode({
          'methods': [
            method('original', '需预算负责人在场',
                ['unchanged-source', 'overwritten-source', 'obsolete']),
          ],
        }),
      },
    );
    expect(updated.map((item) => item['id']), ['original', 'distinct']);
    expect(((updated.first['steps'] as List).single as Map)['evidence_ids'],
        ['new-source', 'unchanged-source']);
  });

  test('同义方法沿用方法和图谱主题标识，合并现行证据，条件冲突独立', () async {
    Map<String, Object> method(
            String id, String action, String limits, List<String> refs) =>
        {
          'id': id,
          'problem': '确定试点预算',
          'applies_when': '已有预计成本',
          'limits': limits,
          'steps': [
            {'action': action, 'evidence_ids': refs},
          ],
        };
    final original = method(
        'original', '核对客户已发生费用', '必须由预算负责人确认', ['verified', 'superseded']);
    final paraphrase =
        method('rewritten', '检查客户实际支出', '需要预算负责人确认', ['new-source']);
    final conflict =
        method('conflict', '不得先核对客户支出', '不要找预算负责人', ['conflict-source']);
    final evidence = <Map<String, Object>>[
      {'id': 'verified', 'text': '先核对支出'},
      {'id': 'new-source', 'text': '查验实际费用'},
      {'id': 'conflict-source', 'text': '无须查询支出，预算负责人不必参与'},
    ];
    final previous = {
      'evidence': jsonEncode([evidence.first]),
      'content': jsonEncode({
        'methods': [original],
        'graph_topics': [
          {
            'id': 'topic-budget',
            'title': '试点预算验证',
            'meaning': '核对试点预算和历史成本',
            'method_id': 'original',
            'fingerprint': 'previous',
            'evidence_ids': ['verified', 'superseded'],
          },
        ],
      }),
    };

    final result = await reconcilePublishedCreatorMethods(
      current: [paraphrase, conflict],
      evidence: evidence,
      published: previous,
      complete: (prompt, payload) async {
        expect(prompt, contains('停止边界'));
        expect((payload as Map)['method_comparisons'], hasLength(2));
        return jsonEncode({
          'equivalent_methods': [
            {'current_id': 'rewritten', 'previous_id': 'original'},
            {'current_id': 'conflict', 'previous_id': 'other-author'},
          ],
        });
      },
    );
    expect(result.map((method) => method['id']), ['original', 'conflict']);
    expect(((result.first['steps'] as List).single as Map)['evidence_ids'],
        ['new-source', 'verified']);
    expect(jsonDecode(previous['content']!)['methods'].single, original);
    final topics = await buildCreatorGraphTopics(
      methods: result,
      evidence: evidence,
      published: [previous],
      previous: previous,
      preserveReconciledTopics: true,
      complete: (_, payload) async {
        final pending = ((payload as Map)['methods'] as List).single as Map;
        expect(pending['method']['id'], 'conflict');
        return jsonEncode({
          'memberships': [
            {
              'method_id': 'conflict',
              'title': '免查询预算的情形',
              'meaning': '该做法不要求核对历史支出',
              'evidence_ids': ['conflict-source'],
            },
          ],
        });
      },
    );
    expect(topics.first['id'], 'topic-budget');
    expect(topics.first['evidence_ids'], ['new-source', 'verified']);
    expect(topics.last['id'], isNot('topic-budget'));

    final ambiguous = await reconcilePublishedCreatorMethods(
      current: [paraphrase, conflict],
      evidence: evidence,
      published: previous,
      complete: (_, __) async => jsonEncode({
        'equivalent_methods': [
          {'current_id': 'rewritten', 'previous_id': 'original'},
          {'current_id': 'conflict', 'previous_id': 'original'},
        ],
      }),
    );
    expect(ambiguous.map((method) => method['id']), ['rewritten', 'conflict']);
  });

  test('中断后从原证据检查点继续，已复核的批次不会再调用模型', () async {
    final evidence = List.generate(
        2,
        (i) => <String, Object>{
              'id': 'e$i',
              'text': List.filled(13000, '文').join(),
            });
    final original = <String, Object>{
      'id': 'method-old',
      'problem': '已复核的方法',
    };
    final seen = <int>[];
    final result = await buildCreatorMethods(
      evidence,
      (_, batch) async {
        expect((batch as List).single['id'], 'e1');
        return '{"methods":[]}';
      },
      resumeOffset: 1,
      resumeBatch: 1,
      acceptedMethods: [original],
      onCheckpoint: (offset, batch, methods) async {
        expect(batch, 2);
        expect(methods, [original]);
        seen.add(offset);
      },
    );
    expect(seen, [2]);
    expect(result, [original]);
  });
  test('问候和身份介绍按所选专家回复，实质问题仍查证据', () {
    final experts = [
      {'id': 'a', 'name': '卡车生活', 'version': 2},
      {'id': 'b', 'name': '运输研究', 'version': 1},
    ];
    for (final message in [
      '你好！',
      '大家好！',
      '我想认识你们',
      '可以先了解一下各位吗？',
      '你是谁？',
      'HELLO',
      '介绍一下自己。',
      '你们介绍下自己吧',
      '请各位分别自我介绍一下。',
      '你介绍下你自己？'
    ]) {
      final replies = roundtableIntroduction(message, experts)!;
      expect(replies, hasLength(2));
      expect(replies.first['expert'], experts.first);
      expect(replies.first['text'], contains('「卡车生活」的 AI 圆桌专家'));
      expect(replies.last['text'], contains('「运输研究」'));
      expect(replies.every((reply) => (reply['evidence'] as List).isEmpty),
          isTrue);
    }
    expect(roundtableIntroduction('你好，请分析运价。', experts), isNull);
    expect(roundtableIntroduction('大家好，请分析运价。', experts), isNull);
    expect(roundtableIntroduction('我想认识你们，请分析运价。', experts), isNull);
    expect(roundtableIntroduction('我想了解你们对运价的看法。', experts), isNull);
    expect(roundtableIntroduction('你们介绍下自己吧，再分析运价。', experts), isNull);
    expect(roundtableIntroduction('介绍一下你们对运价的看法。', experts), isNull);
    expect(roundtableIntroduction('你是谁推荐的？', experts), isNull);
  });

  test('roundtable rejects invented citations and keeps independent replies',
      () async {
    final cue = {'id': 'work:2:0', 'text': '预算需要核对'};
    final expert = {
      'id': 'expert',
      'name': '预算专家',
      'version': 2,
      'content': '{"methods":[]}',
      'evidence': jsonEncode([cue]),
    };
    final first = await answerCreatorRoundtable(
        question: '预算',
        experts: [expert],
        complete: (_, __) async => jsonEncode({
              'points': [
                {
                  'text': '核对预算',
                  'evidence_ids': ['work:2:0']
                },
                {
                  'text': '编造的内容',
                  'evidence_ids': ['unseen']
                },
              ]
            }));
    expect(first.single['text'], '核对预算 [1]');
    expect(first.single['evidence'], [cue]);
    final fallback = await answerCreatorRoundtable(
        question: '预算',
        experts: [expert],
        complete: (_, __) async =>
            '{"points":[{"text":"未知","evidence_ids":["missing"]}]}');
    expect(fallback.single['evidence'], isEmpty);
    expect(fallback.single['text'], contains('没有足够依据'));
  });
  test('expert methods must cite known evidence and pass independent review',
      () async {
    final evidence = <Map<String, Object>>[
      {'id': 'source:1:0', 'text': '先核对已有支出，再找预算负责人。'},
    ];
    final method = {
      'problem': '核对预算',
      'applies_when': '已有支出',
      'limits': '仅核对已发生支出',
      'steps': [
        {
          'action': '核对已有支出',
          'evidence_ids': ['source:1:0']
        },
      ],
    };
    var calls = 0;
    final result = await buildCreatorMethods(evidence, (_, input) async {
      calls++;
      if (calls == 1) {
        return jsonEncode({
          'methods': [method]
        });
      }
      expect((input as Map)['evidence'], evidence);
      return '{"supported":[0]}';
    });
    expect(calls, 2);
    expect(result.single['problem'], '核对预算');
    expect(result.single['id'], isNotEmpty);
    await expectLater(
        buildCreatorMethods(
            evidence,
            (_, input) async => input is List
                ? jsonEncode({
                    'methods': [method]
                  })
                : '{"supported":[]}'),
        throwsA(isA<CreatorWorkflowException>()));
    await expectLater(
        buildCreatorMethods(evidence, (_, input) async {
          expect(input, isA<List>());
          return jsonEncode({
            'methods': [
              {
                ...method,
                'steps': [
                  {
                    'action': '无依据动作',
                    'evidence_ids': ['unknown']
                  }
                ]
              },
            ]
          });
        }),
        throwsA(isA<CreatorWorkflowException>()));
  });
  test('SRT and WebVTT preserve time ranges and cue text', () {
    final srt = parseCreatorSubtitles(
        '\uFEFF1\r\n00:00:01,020 --> 00:00:04,100\r\n第一行\r\n第二行\r\n');
    expect(srt.single, (startMs: 1020, endMs: 4100, text: '第一行\n第二行'));
    final vtt = parseCreatorSubtitles(
        'WEBVTT\n\nNOTE comment\n\ncue\n00:00.400 --> 00:01.500 align:start\n你好');
    expect(vtt.single, (startMs: 400, endMs: 1500, text: '你好'));
    expect(creatorTimecode(3601020), '01:00:01.020');
  });

  test('invalid, empty or reversed cues are rejected', () {
    for (final source in ['', 'WEBVTT', '00:02.000 --> 00:01.000\n无效']) {
      expect(() => parseCreatorSubtitles(source), throwsFormatException);
    }
  });

  Map<String, dynamic> page(
          String authorId, List<Map<String, dynamic>> works, int? next) =>
      {
        'author': <String, dynamic>{'id': authorId},
        'posts': works,
        'next_cursor': next,
      };

  test('older pinned posts do not count towards the requested latest works',
      () async {
    final result = await collectDouyinWorks(
      authorId: 'author',
      latest: 2,
      fetch: (cursor, count) async => cursor == 0
          ? page(
              'author',
              [
                {'id': 'pinned', 'published_at': 1, 'pinned': true},
                {'id': 'a', 'published_at': 4}
              ],
              3)
          : page(
              'author',
              [
                {'id': 'a', 'published_at': 4},
                {'id': 'b', 'published_at': 5}
              ],
              null),
    );
    expect(result.works.map((work) => work['id']), ['b', 'a']);
  });

  test('latest four requests four and stops when the response has four',
      () async {
    final visited = <(int, int)>[];
    Map<String, Object?>? saved;
    final result = await collectDouyinWorks(
      authorId: 'author',
      latest: 4,
      fetch: (cursor, count) async {
        visited.add((cursor, count));
        return page(
            'author',
            [
              for (var index = 0; index < count; index++)
                {'id': 'work-$index', 'published_at': 10 - index},
            ],
            123);
      },
      onPage: (progress) async => saved = progress,
    );
    expect(visited, [(0, 4)]);
    expect(result.works.map((work) => work['id']),
        ['work-0', 'work-1', 'work-2', 'work-3']);
    expect(saved!['next_cursor'], isNull);
  });

  test('latest requests only the remainder after an old pinned result',
      () async {
    final visited = <(int, int)>[];
    final result = await collectDouyinWorks(
      authorId: 'author',
      latest: 2,
      fetch: (cursor, count) async {
        visited.add((cursor, count));
        return cursor == 0
            ? page(
                'author',
                [
                  {'id': 'old', 'published_at': 1, 'pinned': true},
                  {'id': 'a', 'published_at': 10},
                ],
                8)
            : page(
                'author',
                [
                  {'id': 'b', 'published_at': 9}
                ],
                7);
      },
    );
    expect(visited, [(0, 2), (8, 1)]);
    expect(result.works.map((work) => work['id']), ['a', 'b']);
  });

  test('latest resumes from collected work without scanning another page',
      () async {
    final work = {'id': 'a', 'published_at': 10};
    final restored = await collectDouyinWorks(
      authorId: 'author',
      latest: 1,
      checkpoint: {
        'author_id': 'author',
        'next_cursor': 8,
        'cursors': [0],
        'works': {'a': 10},
      },
      archivedAuthor: {'id': 'author'},
      fetch: (_, __) async => throw StateError('the range is already complete'),
      restoreWork: (_) async => work,
    );
    expect(restored.works, [work]);
  });

  test('pagination resumes only unread pages and reloads selected details',
      () async {
    Map<String, Object?>? saved;
    final original = {'id': 'first', 'published_at': 4, 'media_url': 'signed'};
    await expectLater(
      collectDouyinWorks(
        authorId: 'author',
        latest: 2,
        fetch: (cursor, count) async {
          if (cursor == 0) {
            return page(
                'author',
                [
                  original,
                  {'id': 'skipped', 'published_at': 1, 'pinned': true},
                ],
                3);
          }
          throw const DouyinCreatorException('连接中断');
        },
        onPage: (progress) async => saved = progress,
      ),
      throwsA(isA<DouyinCreatorException>()),
    );
    expect(saved, {
      'author_id': 'author',
      'next_cursor': 3,
      'cursors': [0],
      'pinned_ids': ['skipped'],
      'works': {'first': 4, 'skipped': 1},
    });
    final visited = <int>[];
    final reloaded = <String>[];
    final result = await collectDouyinWorks(
      authorId: 'author',
      latest: 2,
      checkpoint: saved,
      archivedAuthor: {'id': 'author'},
      fetch: (cursor, count) async {
        visited.add(cursor);
        expect(count, 1);
        return page(
            'author',
            [
              original,
              {'id': 'second', 'published_at': 5},
            ],
            null);
      },
      restoreWork: (id) async {
        reloaded.add(id);
        return {...original, 'media_url': 'renewed'};
      },
    );
    expect(visited, [3]);
    expect(reloaded, ['first']);
    expect(result.works.map((work) => work['id']), ['second', 'first']);
    expect(result.works.last['media_url'], 'renewed');
  });

  test('resumed pages can reuse the archived author profile', () async {
    final archived = {'id': 'author', 'name': '现有博主', 'avatar': 'example'};
    final result = await collectDouyinWorks(
      authorId: 'author',
      checkpoint: {
        'author_id': 'author',
        'next_cursor': 3,
        'cursors': [0],
        'works': <String, int>{},
      },
      archivedAuthor: archived,
      restoreWork: (_) async => throw StateError('no earlier posts'),
      fetch: (cursor, count) async {
        expect(cursor, 3);
        return {
          ...page(
              'author',
              [
                {'id': 'b', 'published_at': 2}
              ],
              null),
          'author': {'id': 'author', 'profile_complete': false},
        };
      },
    );
    expect(result.author, archived);
    expect(result.works.single['id'], 'b');
  });

  test('a new sync requires an authoritative author profile on page one',
      () async {
    await expectLater(
      collectDouyinWorks(
        authorId: 'author',
        archivedAuthor: {'id': 'author', 'name': '现有博主'},
        fetch: (_, __) async => {
          ...page(
              'author',
              [
                {'id': 'a', 'published_at': 1}
              ],
              null),
          'author': {'id': 'author', 'profile_complete': false},
        },
      ),
      throwsA(isA<DouyinCreatorException>()),
    );
  });

  test('finished page checkpoint only reloads details and checks identity',
      () async {
    final checkpoint = {
      'author_id': 'author',
      'next_cursor': null,
      'cursors': [0],
      'works': {'first': 4},
    };
    await expectLater(
      collectDouyinWorks(
        authorId: 'author',
        checkpoint: checkpoint,
        archivedAuthor: {'id': 'author'},
        fetch: (_, __) async => throw StateError('no pages should be fetched'),
        restoreWork: (_) async => {'id': 'other'},
      ),
      throwsA(isA<DouyinCreatorException>()),
    );
  });

  test('pagination rejects duplicate cursor and wrong author', () async {
    for (final fetch in [
      (int cursor, int count) async => page('author', [], cursor),
      (int cursor, int count) async => page('someone-else', [], null),
    ]) {
      await expectLater(collectDouyinWorks(authorId: 'author', fetch: fetch),
          throwsA(isA<DouyinCreatorException>()));
    }
  });
}
