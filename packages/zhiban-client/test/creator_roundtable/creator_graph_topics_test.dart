import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_expert_workflow.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_graph_topics.dart';

void main() {
  test('复用跨作者主题，拒绝他人引用，保留未变更方法且刷新变化证据', () async {
    Future<List<Map<String, Object>>> build(
      String method,
      String source,
      String text, {
      List<Map<String, Object?>> published = const [],
      Map<String, Object?>? previous,
      required CreatorCompletion complete,
    }) =>
        buildCreatorGraphTopics(
          methods: [
            {
              'id': method,
              'problem': '付费试点',
              'steps': [
                {
                  'action': '核对',
                  'evidence_ids': [source]
                }
              ],
            },
          ],
          evidence: [
            {'id': source, 'text': text, 'work_id': 'work-$source'},
          ],
          published: published,
          previous: previous,
          complete: complete,
        );
    String output(String method, String source,
            {Object? topic, String meaning = '核对预算负责人是否承诺试点支出'}) =>
        jsonEncode({
          'memberships': [
            {
              'method_id': method,
              'topic_id': topic,
              'title': '试点前验证付费意愿',
              'meaning': meaning,
              'evidence_ids': [source],
            }
          ]
        });
    final first = await build('a', 'a1', '先核对预算',
        complete: (_, data) async => output('a', 'a1'));
    final row = {
      'content': jsonEncode({
        'graph_topics': first,
        'methods': [
          {
            'id': 'a',
            'applies_when': '付费验证开始前',
            'limits': '取得书面付款承诺后才能开始',
            'steps': [
              {
                'action': '要求试点前付款承诺',
                'evidence_ids': ['a1']
              },
            ],
          },
        ],
      })
    };
    final sharedId = first.single['id'];
    final second = await build('b', 'b1', '先确认预算人', published: [row],
        complete: (_, data) async {
      expect((data as Map)['existing_topics'].single['id'], sharedId);
      return output('b', 'b1', topic: sharedId);
    });
    expect(second.single['id'], sharedId);
    expect(second.single['evidence_ids'], ['b1']);
    final conflict = await build('c', 'c1', '试点严禁提前承诺或付款', published: [row],
        complete: (instruction, data) async {
      final topic = (data as Map)['existing_topics'].single as Map;
      expect(topic['verified_rules'], [
        {
          'applies_when': '付费验证开始前',
          'limits': '取得书面付款承诺后才能开始',
          'actions': ['要求试点前付款承诺'],
        },
      ]);
      expect(instruction, contains('明确要求和明确禁止同一核心动作'));
      expect(jsonEncode(topic['verified_rules']), isNot(contains('a1')));
      return output('c', 'c1', meaning: '仅核对匿名意向，试点前禁止预算承诺或付款');
    });
    expect(conflict.single['id'], isNot(sharedId));
    await expectLater(
      build('c', 'c1', '试点严禁提前承诺或付款',
          published: [row], complete: (_, __) async => output('c', 'c1')),
      throwsA(isA<CreatorWorkflowException>()),
    );
    final unchanged = await build('a', 'a1', '先核对预算',
        previous: row,
        complete: (_, __) async => throw StateError('未改变的方法无需调用模型'));
    expect(unchanged, first);
    await expectLater(
      build('a', 'a2', '新的原文',
          previous: row,
          published: [row],
          complete: (_, __) async => output('a', 'b1', topic: sharedId)),
      throwsA(isA<CreatorWorkflowException>()),
    );
  });
  test('一个方法缺少主题时拒绝整批发布', () async {
    await expectLater(
      buildCreatorGraphTopics(
        methods: [
          for (final id in ['a', 'b'])
            {
              'id': id,
              'steps': [
                {
                  'action': '核对',
                  'evidence_ids': [id]
                },
              ],
            },
        ],
        evidence: [
          for (final id in ['a', 'b']) {'id': id, 'text': '核对预算'},
        ],
        published: [],
        previous: null,
        complete: (_, __) async => jsonEncode({
          'memberships': [
            {
              'method_id': 'a',
              'topic_id': '',
              'title': '核对预算',
              'meaning': '核对预算后开始试点',
              'evidence_ids': ['a'],
            },
          ],
        }),
      ),
      throwsA(isA<CreatorWorkflowException>()),
    );
  });
}
