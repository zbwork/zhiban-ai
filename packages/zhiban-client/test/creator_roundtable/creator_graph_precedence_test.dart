import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/creator_roundtable/services/creator_graph_precedence.dart';

void main() {
  test('前置关系必须有两个方法共同引用的明确顺序原文', () async {
    Map<String, Object> method(
            String id, String action, List<String> sources) =>
        {
          'id': id,
          'problem': action,
          'steps': [
            {'action': action, 'evidence_ids': sources}
          ],
        };
    Map<String, Object> link(
            String before, String after, String id, String head, String tail) =>
        {
          'before': before,
          'after': after,
          'source_id': id,
          'before_quote': head,
          'after_quote': tail,
        };
    const a = '核对实际发票';
    const b = '确认审批人';
    const c = '提交正式订单';
    final methods = [
      method('a', a,
          ['ordered', 'reverse', 'cooccur', 'private', 'negative', 'cycle']),
      method('b', b, ['ordered', 'reverse', 'cooccur', 'negative', 'second']),
      method('c', c, ['second', 'cycle']),
    ];
    final evidence = <Map<String, Object>>[
      {'id': 'ordered', 'text': '先$a，再$b。'},
      {'id': 'reverse', 'text': '先$a，再$b。'},
      {'id': 'second', 'text': '先$b，再$c。'},
      {'id': 'cycle', 'text': '先$c，再$a。'},
      {'id': 'cooccur', 'text': '安排$a和$b。'},
      {'id': 'private', 'text': '先$a，再$b。'},
      {'id': 'negative', 'text': '不要先$a，再$b。'},
    ];
    final expected = [
      link('a', 'b', 'ordered', a, b),
      link('b', 'c', 'second', b, c)
    ];
    final all = [
      link('b', 'a', 'reverse', b, a),
      link('a', 'b', 'cooccur', a, b),
      link('a', 'b', 'private', a, b),
      link('a', 'b', 'negative', a, b),
      ...expected,
      link('c', 'a', 'cycle', c, a),
    ];
    final result = await buildCreatorGraphPrecedence(
      methods: methods,
      evidence: evidence,
      previous: null,
      complete: (_, data) async {
        final sources = ((data as Map)['sources'] as List)
            .map((source) => source['id'])
            .toSet();
        return jsonEncode({
          'precedence':
              all.where((edge) => sources.contains(edge['source_id'])).toList()
        });
      },
    );
    expect(result, expected);
    final reused = await buildCreatorGraphPrecedence(
      methods: methods,
      evidence: evidence,
      previous: {
        'content': jsonEncode({'methods': methods, 'graph_precedence': result}),
        'evidence': jsonEncode(evidence)
      },
      complete: (_, __) async => throw StateError('未变版本无需再次推理'),
    );
    expect(reused, expected);
  });
}
