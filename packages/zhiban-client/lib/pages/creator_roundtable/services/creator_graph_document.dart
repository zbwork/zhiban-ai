import 'creator_graph_precedence.dart';
import 'creator_graph_topics.dart';

Map<String, Object> publishedCreatorGraph({
  required Map<String, Object?> expert,
  required String name,
  required Map content,
  required List evidence,
}) {
  final creatorId = expert['id'] as String;
  final author = 'author:$creatorId';
  final sources = {
    for (final entry in evidence.whereType<Map>())
      if (entry['id'] case final String id) id: entry,
  };
  final nodes = <String, Map<String, Object>>{};
  final edges = <({String from, String to, String type}), Set<String>>{};

  void addNode(String id, String type, String title) {
    nodes.putIfAbsent(id, () => {'id': id, 'type': type, 'title': title});
  }

  void link(String from, String to, String type, Iterable<Object?> references) {
    final valid = references.whereType<String>().where(sources.containsKey);
    if (valid.isNotEmpty) {
      edges.putIfAbsent(
          (from: from, to: to, type: type), () => {}).addAll(valid);
    }
  }

  addNode(author, 'author', name);
  for (final method in (content['methods'] as List).whereType<Map>()) {
    final id = method['id'] as String;
    addNode(id, 'method', method['problem'] as String);
    final references = (method['steps'] as List)
        .whereType<Map>()
        .expand((step) => step['evidence_ids'] as List)
        .whereType<String>()
        .where(sources.containsKey)
        .toSet();
    link(author, id, 'owns', references);
    for (final key in ['applies_when', 'limits']) {
      if (method[key] case final String condition
          when condition.trim().isNotEmpty) {
        final conditionId = 'condition:$id:$key';
        addNode(conditionId, 'condition', condition);
        link(id, conditionId, key, references);
      }
    }
    for (final ref in references) {
      final source = sources[ref]!;
      final workId = source['work_id'] as String;
      final work = 'work:$workId';
      addNode(work, 'work', source['work_title'] as String? ?? workId);
      addNode(ref, 'evidence', source['text'] as String? ?? ref);
      link(author, work, 'owns', [ref]);
      link(work, ref, 'contains', [ref]);
      link(ref, id, 'supports', [ref]);
    }
  }
  for (final topic in creatorGraphTopics(expert)) {
    if (!nodes.containsKey(topic.methodId)) continue;
    final references = topic.evidenceIds.where(sources.containsKey).toList();
    if (references.isEmpty) continue;
    addNode(topic.id, 'theme', topic.title);
    link(topic.methodId, topic.id, 'belongs_to', references);
  }
  for (final order in creatorGraphPrecedence(content)) {
    if (nodes.containsKey(order.before) && nodes.containsKey(order.after)) {
      link(order.before, order.after, 'precedes', [order.sourceId]);
    }
  }

  final used = edges.values.expand((references) => references).toSet();
  return {
    'version': expert['version'] as int,
    'nodes': nodes.values.toList(),
    'edges': [
      for (final edge in edges.entries)
        {
          'from_id': edge.key.from,
          'to_id': edge.key.to,
          'type': edge.key.type,
          'evidence_ids': edge.value.toList(),
        },
    ],
    'source_refs': [for (final id in used) sources[id]!],
    'counts': {
      'nodes': nodes.length,
      'edges': edges.length,
      'sources': used.length
    },
  };
}
