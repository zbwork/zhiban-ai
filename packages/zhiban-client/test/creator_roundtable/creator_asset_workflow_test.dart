import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_asset_workflow.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_expert_workflow.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const source = {
    'id': 'e1',
    'work_id': 'archived-work',
    'source_version': 1,
    'start_ms': 1200,
    'end_ms': 4300,
    'url': 'https://www.douyin.com/video/1234567890123456789',
    'text': '先核对已有支出',
  };
  final expert = {
    'id': 'author',
    'version': 1,
    'evidence': jsonEncode([source]),
    'content': jsonEncode({
      'methods': [
        {
          'id': 'budget-review',
          'problem': '核对预算',
          'steps': [
            {
              'action': '核对已有支出',
              'evidence_ids': ['e1']
            },
          ]
        },
      ]
    }),
  };

  test('专家清单只暴露已复核的能力并保持发布时的身份', () {
    const author = {
      'name': '原始作者',
      'has_avatar': true,
      'source_account_id': 'source-author',
    };
    const method = {
      'id': 'budget-review',
      'problem': '核对预算',
      'applies_when': '提交采购前',
      'limits': '缺发票暂停',
      'steps': [
        {
          'action': '核对已有支出',
          'evidence_ids': ['e1']
        },
      ],
    };
    final manifest = creatorExpertProfile(
      author: author,
      methods: [method],
      evidence: [source],
      previousVersion: 1,
      previousMethods: [
        {...method, 'limits': '旧边界'},
        {'id': 'prior-method'},
      ],
    );
    expect((manifest['capabilities'] as List).single,
        containsPair('evidence_ids', ['e1']));
    expect(manifest['soul'], [
      containsPair('decision_order', ['核对已有支出'])
    ]);
    expect(manifest['appearance'], containsPair('kind', 'creator_avatar'));
    expect(manifest['source_work_count'], 1);

    final payload = bundlePublishedCreatorExpert({
      ...expert,
      'status': 'published',
      'version': 2,
      'created': 123,
      'content': jsonEncode({
        'methods': [method],
        'skill_profile': manifest,
      }),
    }, '后来改名');
    final files = {
      for (final file in ZipDecoder().decodeBytes(payload).files)
        file.name: utf8.decode(file.content)
    };
    final frozen = jsonDecode(files['manifest.json']!) as Map;
    expect(frozen['creator'], author);
    expect(frozen['previous_version'], 1);
    expect(frozen['method_changes'], {
      'updated': ['budget-review'],
      'added': [],
      'removed': ['prior-method'],
    });
    expect(frozen['verified_method_count'], 1);
    expect(files['SKILL.md'], contains('原始作者 · v2'));
    expect(files['SKILL.md'], contains('停止边界'));
    expect(
      () => creatorExpertProfile(
        author: author,
        methods: [method],
        evidence: [],
        previousVersion: 0,
      ),
      throwsA(isA<CreatorWorkflowException>()),
    );
  });

  test('已发布专家技能包固定包含调用说明、方法、冻结证据及版本图谱', () {
    final payload = bundlePublishedCreatorExpert(
        {...expert, 'status': 'published'}, '验收博主');
    final archive = ZipDecoder().decodeBytes(payload, verify: true);
    final files = {
      for (final file in archive.files) file.name: utf8.decode(file.content)
    };
    expect(
        files.keys,
        unorderedEquals(
            ['SKILL.md', 'methods.json', 'evidence.json', 'graph.json']));
    expect(files['SKILL.md'], contains('验收博主 · v1'));
    expect((jsonDecode(files['methods.json']!) as Map)['version'], 1);
    expect(jsonDecode(files['evidence.json']!), [source]);
    final graph = jsonDecode(files['graph.json']!) as Map;
    expect(graph['version'], 1);
    expect(graph['source_refs'], [source]);
    final nodes = (graph['nodes'] as List).cast<Map>();
    final edges = (graph['edges'] as List).cast<Map>();
    final ids = nodes.map((node) => node['id']).toSet();
    expect(nodes.map((node) => node['type']),
        containsAll(['author', 'method', 'work', 'evidence']));
    expect(graph['counts'],
        {'nodes': nodes.length, 'edges': edges.length, 'sources': 1});
    expect(edges.any((edge) => edge['type'] == 'supports'), isTrue);
    for (final edge in edges) {
      expect(ids, containsAll([edge['from_id'], edge['to_id']]));
      expect(edge['evidence_ids'], ['e1']);
    }
  });

  for (final kind in CreatorAssetKind.values) {
    test('生成并读取真实 ${kind.extension} 字节', () async {
      final draft = await generateCreatorAssetDraft(
        kind: kind,
        title: '预算验证手册',
        experts: [expert],
        complete: (_, input) async {
          return (input as Map).containsKey('required')
              ? jsonEncode({
                  'sections': [
                    for (final heading in kind.sections)
                      {
                        'heading': heading,
                        'text': heading == '检查清单'
                            ? '- 核对已有支出 <script>\n2. 让预算负责人确认'
                            : '先核对已有支出 <script>',
                        'evidence_ids': ['e1']
                      },
                  ]
                })
              : '{"approved":true}';
        },
      );
      final checkpoint = creatorAssetCheckpoint(draft);
      final restored = restoreCreatorAssetDraft(kind, jsonEncode(checkpoint));
      expect(creatorAssetCheckpoint(restored), checkpoint);
      final bytes = await renderCreatorAsset(kind, '预算验证手册', restored);
      verifyRenderedCreatorAsset(kind, bytes);
      if (kind == CreatorAssetKind.ebook) {
        expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
      } else if (kind == CreatorAssetKind.web) {
        final html = utf8.decode(bytes);
        expect(html, contains('href="#e0"'));
        expect(html, contains('&lt;script&gt;'));
        expect(RegExp('<script>').allMatches(html), hasLength(1));
        expect(RegExp('<input type="checkbox"').allMatches(html), hasLength(2));
        expect(html, contains('让预算负责人确认'));
        expect(html, isNot(contains('2. 让预算负责人确认')));
        expect(html, contains('creator-roundtable-checklist:'));
      } else {
        final expanded = ZipDecoder().decodeBytes(bytes, verify: true);
        expect(expanded.files.single.name, 'SKILL.md');
        expect(utf8.decode(expanded.files.single.content), contains('## 停止条件'));
      }
      final path = Platform.environment['ROUNDTABLE_TEST_ARTIFACTS'];
      if (path != null) {
        await File('$path/roundtable.${kind.extension}').writeAsBytes(bytes);
      }
    });
  }

  test('同一组双博主证据可复核并生成三类文件，两条出处保持可区分', () async {
    final second = {
      ...source,
      'id': 'second-evidence',
      'work_id': 'second-archived-work',
      'source_version': 3,
      'start_ms': 6000,
      'end_ms': 9500,
      'url': 'https://www.douyin.com/video/1234567890123456790',
      'text': '让预算负责人书面确认',
    };
    final secondExpert = {
      'id': 'second-author',
      'version': 3,
      'evidence': jsonEncode([second]),
      'content': jsonEncode({
        'methods': [
          {
            'id': 'budget-approval',
            'problem': '确认预算',
            'steps': [
              {
                'action': '让预算负责人书面确认',
                'evidence_ids': ['second-evidence'],
              },
            ],
          },
        ],
      }),
    };
    for (final kind in CreatorAssetKind.values) {
      final draft = await generateCreatorAssetDraft(
        kind: kind,
        title: '两位博主的预算验证',
        experts: [expert, secondExpert],
        complete: (_, payload) async {
          final input = payload as Map;
          expect((input['evidence'] as Map).values,
              unorderedEquals([source, second]));
          if (!input.containsKey('required')) return '{"approved":true}';
          return jsonEncode({
            'sections': [
              for (final heading in kind.sections)
                {
                  'heading': heading,
                  'text': '1. 核对支出\n2. 让预算负责人确认',
                  'evidence_ids': ['e1', 'second-evidence'],
                },
            ],
          });
        },
      );
      final bytes = await renderCreatorAsset(kind, '预算验证', draft);
      verifyRenderedCreatorAsset(kind, bytes);
      final String output = switch (kind) {
        CreatorAssetKind.ebook => latin1.decode(bytes),
        CreatorAssetKind.web => utf8.decode(bytes),
        CreatorAssetKind.skill => utf8.decode(
            ZipDecoder().decodeBytes(bytes, verify: true).files.single.content),
      };
      if (kind == CreatorAssetKind.ebook) {
        expect(output, contains('/S/GoTo/D(sources)'));
        for (final anchor in ['source-0', 'source-1']) {
          expect(output, contains('/S/GoTo/D($anchor)'));
          expect(output, contains('($anchor)<</D['));
        }
      }
      for (final evidence in [source, second]) {
        final url = evidence['url'] as String;
        final link = kind == CreatorAssetKind.web
            ? const HtmlEscape().convert(url)
            : url;
        expect(output, contains(link));
      }
      final malformed = bytes.sublist(0, 16);
      expect(() => verifyRenderedCreatorAsset(kind, malformed),
          throwsA(isA<CreatorWorkflowException>()));
    }
  });

  test('按中文资产名称召回后面的相关专家，优先占用上下文额度', () async {
    final irrelevant = {
      ...expert,
      'evidence': jsonEncode([
        for (var n = 0; n < 10; n++)
          {...source, 'id': 'irrelevant-$n', 'text': '记录每周交接清单。' * 400},
      ]),
      'content': jsonEncode({
        'methods': [
          for (var n = 0; n < 10; n++)
            {
              'id': 'irrelevant-$n',
              'problem': '人员交接记录',
              'steps': [
                {
                  'action': '核对交接清单',
                  'evidence_ids': ['irrelevant-$n']
                },
              ],
            },
        ],
      }),
    };
    final draft = await generateCreatorAssetDraft(
      kind: CreatorAssetKind.web,
      title: '为项目核对预算的实操手册',
      experts: [irrelevant, expert],
      complete: (_, input) async {
        final data = input as Map;
        if (!data.containsKey('required')) {
          expect((data['evidence'] as Map).keys, ['e1']);
          return '{"approved":true}';
        }
        expect((data['methods'] as List).first['id'], 'budget-review');
        expect((data['evidence'] as Map).keys.first, 'e1');
        return jsonEncode({
          'sections': [
            for (final heading in CreatorAssetKind.web.sections)
              {
                'heading': heading,
                'text': '先核对已有支出',
                'evidence_ids': ['e1']
              },
          ],
        });
      },
    );
    expect(draft.sources.keys, ['e1']);
    expect(CreatorEvidenceQuery('如何核对 GPU 预算').score('核对 gpu 内存预算'), 3);
  });

  test('证据不足时保留填写内容，跳过候选保存和复核', () async {
    var modelRequests = 0;
    var candidateSaved = false;
    await expectLater(
      generateCreatorAssetDraft(
        kind: CreatorAssetKind.ebook,
        title: '资料中没有的主题',
        experts: [expert],
        onCandidate: (_) async => candidateSaved = true,
        complete: (instruction, input) async {
          modelRequests++;
          expect((input as Map)['title'], '资料中没有的主题');
          return '{"status":"insufficient_evidence"}';
        },
      ),
      throwsA(isA<CreatorWorkflowException>().having(
        (error) => error.message,
        'message',
        contains('补充来源或调整资产名称'),
      )),
    );
    expect(modelRequests, 1);
    expect(candidateSaved, isFalse);
  });

  test('拒绝引用不存在的资料', () async {
    await expectLater(
        generateCreatorAssetDraft(
            kind: CreatorAssetKind.web,
            title: '测试',
            experts: [expert],
            complete: (_, __) async => jsonEncode({
                  'sections': [
                    for (final heading in CreatorAssetKind.web.sections)
                      {
                        'heading': heading,
                        'text': '错误',
                        'evidence_ids': ['missing']
                      }
                  ],
                })),
        throwsA(isA<CreatorWorkflowException>()));
  });
}
