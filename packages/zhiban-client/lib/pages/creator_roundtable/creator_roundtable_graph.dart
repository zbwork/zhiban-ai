import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_ui/widgets/ui_select.dart';

import '../local_workspace/services/local_workspace_store.dart';
import 'services/creator_subtitles.dart';
import 'services/creator_graph_topics.dart';
import 'services/creator_graph_precedence.dart';

enum _GraphKind { author, topic, method, condition, work }

typedef _GraphNode = ({String id, String label, _GraphKind kind, int row});
typedef _GraphEdge = ({String from, String to});
const _graphRoot = 'graph-root';
String _edgeId(_GraphEdge edge) => 'edge:${edge.from}:${edge.to}';

typedef _GraphOptions = ({
  bool scatter,
  bool collapsed,
  String topic,
  String? work
});

class CreatorRoundtableGraph extends StatefulWidget {
  const CreatorRoundtableGraph(
      {super.key, required this.experts, this.onOpenWork})
      : full = false,
        selection = null,
        transform = null,
        _viewOptions = null;

  const CreatorRoundtableGraph._fullscreen(
      {required this.experts,
      this.onOpenWork,
      this.selection,
      this.transform,
      ValueNotifier<_GraphOptions>? options})
      : full = true,
        _viewOptions = options;
  final List<LocalRow> experts;
  final void Function(String creatorId, Map<String, dynamic> evidence)?
      onOpenWork;
  final bool full;
  final ValueNotifier<({String creator, String? node})>? selection;
  final TransformationController? transform;
  final ValueNotifier<_GraphOptions>? _viewOptions;

  @override
  State<CreatorRoundtableGraph> createState() => _CreatorRoundtableGraphState();
}

class _CreatorRoundtableGraphState extends State<CreatorRoundtableGraph>
    with SingleTickerProviderStateMixin {
  late final _transform = widget.transform ?? TransformationController();
  late final _selection = widget.selection ??
      ValueNotifier<({String creator, String? node})>(
          (creator: widget.experts.first['id'] as String, node: null));
  late final _options = widget._viewOptions ??
      ValueNotifier<_GraphOptions>(
          (scatter: false, collapsed: false, topic: '', work: null));
  late final _topic = TextEditingController(text: _options.value.topic);
  late final _viewTabs = TabController(
      length: 2, initialIndex: _options.value.scatter ? 1 : 0, vsync: this);

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelectionChanged);
    _options.addListener(_onOptionsChanged);
  }

  void _onSelectionChanged() => setState(() {});

  void _onOptionsChanged() {
    if (_topic.text != _options.value.topic) _topic.text = _options.value.topic;
    final index = _options.value.scatter ? 1 : 0;
    if (_viewTabs.index != index) _viewTabs.index = index;
    setState(() {});
  }

  @override
  void dispose() {
    _selection.removeListener(_onSelectionChanged);
    _options.removeListener(_onOptionsChanged);
    _topic.dispose();
    _viewTabs.dispose();
    if (widget._viewOptions == null) _options.dispose();
    if (widget.selection == null) _selection.dispose();
    if (widget.transform == null) _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) =>
            _buildGraph(context, floatingWorks: constraints.maxWidth >= 820),
      );

  Widget _buildGraph(BuildContext context, {required bool floatingWorks}) {
    final selection = _selection.value;
    final options = _options.value;
    final expert = widget.experts
            .where((item) => item['id'] == selection.creator)
            .firstOrNull ??
        widget.experts.first;
    final canAggregate = widget.experts.length > 1 &&
        widget.experts.any((row) => creatorGraphTopics(row).isNotEmpty);
    final aggregate = canAggregate && selection.creator.isEmpty;
    final selectedCreator = aggregate ? '' : expert['id'] as String;
    final content = jsonDecode(expert['content'] as String) as Map;
    var allMethods =
        (content['methods'] as List).whereType<Map<String, dynamic>>().toList();
    final evidence = (jsonDecode(expert['evidence'] as String) as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    final byId = {for (final source in evidence) source['id']: source};
    final precedingSources = <_GraphEdge, Map<String, dynamic>>{};
    final members = <String, Map<String, Map<String, dynamic>>>{};
    var allSources = {
      for (final method in allMethods)
        method['id']: (method['steps'] as List)
            .whereType<Map>()
            .expand((step) => step['evidence_ids'] as List)
            .toSet()
            .map((id) => byId[id])
            .whereType<Map<String, dynamic>>()
            .toList(),
    };
    if (aggregate) {
      final themes = <String, Map<String, dynamic>>{};
      final sources = <Object?, List<Map<String, dynamic>>>{};
      for (final row in widget.experts) {
        final entries = (jsonDecode(row['evidence'] as String) as List)
            .whereType<Map<String, dynamic>>();
        final available = {for (final source in entries) source['id']: source};
        final rowContent = jsonDecode(row['content'] as String) as Map;
        final methods =
            (rowContent['methods'] as List).whereType<Map<String, dynamic>>();
        final byMethod = {for (final method in methods) method['id']: method};
        for (final edge in creatorGraphPrecedence(rowContent)) {
          if (available[edge.sourceId] case final source?) {
            precedingSources[(
              from: "${row['id']}:${edge.before}",
              to: "${row['id']}:${edge.after}"
            )] = {
              ...source,
              'graph_creator_id': row['id'],
              'graph_creator_name': row['name'],
              'graph_method': byMethod[edge.before]?['problem'] ?? '',
            };
          }
        }
        for (final topic in creatorGraphTopics(row)) {
          final method = byMethod[topic.methodId];
          if (method == null) continue;
          final memberId = "${row['id']}:${topic.methodId}";
          for (final id in topic.evidenceIds) {
            final source = available[id];
            if (source == null) continue;
            themes.putIfAbsent(
                topic.id,
                () => {
                      'id': topic.id,
                      'problem': topic.title,
                      'applies_when': topic.meaning,
                    });
            sources.putIfAbsent(topic.id, () => []).add({
              ...source,
              'graph_creator_id': row['id'],
              'graph_creator_name': row['name'],
              'graph_method': method['problem'],
              'graph_method_id': memberId,
            });
            members.putIfAbsent(topic.id, () => {})[memberId] = method;
          }
        }
      }
      allMethods = themes.values.toList();
      allSources = sources;
    } else {
      for (final edge in creatorGraphPrecedence(content)) {
        if (byId[edge.sourceId] case final source?) {
          precedingSources[(from: edge.before, to: edge.after)] = source;
        }
      }
    }
    final workNames = <String, String>{};
    for (final source in allSources.values.expand((items) => items)) {
      workNames.putIfAbsent(
          source['work_id'] as String, () => '作品 ${workNames.length + 1}');
    }
    final workFilter =
        workNames.containsKey(options.work) ? options.work : null;
    final topic = options.topic.trim().toLowerCase();
    bool matches(Map? method) =>
        method != null &&
        '${method['problem']} ${method['applies_when'] ?? ''} ${method['limits'] ?? ''}'
            .toLowerCase()
            .contains(topic);
    final visibleSources = {
      for (final method in allMethods)
        method['id']: allSources[method['id']]!
            .where((source) =>
                (workFilter == null || source['work_id'] == workFilter) &&
                (matches(method) ||
                    matches(members[method['id']]?[source['graph_method_id']])))
            .toList(),
    };
    final methods = allMethods
        .where((method) => visibleSources[method['id']]!.isNotEmpty)
        .toList();
    final workOrder = <String, int>{};
    final edges = <_GraphEdge>{};
    final additionalNodes = <_GraphNode>[];
    int nextMethodRow = 0;
    int nextConditionRow = 0;
    final methodRefs = <String, List<Map<String, dynamic>>>{};
    void link(String from, String to, List<Map<String, dynamic>> sources) {
      final edge = (from: from, to: to);
      if (sources.isEmpty || !edges.add(edge)) return;
      methodRefs[_edgeId(edge)] = sources;
    }

    void conditions(String parent, Map<String, dynamic> method,
        List<Map<String, dynamic>> sources) {
      for (final (key, label) in [('applies_when', '适用条件'), ('limits', '边界')]) {
        final text = method[key] as String? ?? '';
        if (text.trim().isEmpty || sources.isEmpty) continue;
        final conditionId = 'condition:$parent:$key';
        additionalNodes.add((
          id: conditionId,
          label: '$label · $text',
          kind: _GraphKind.condition,
          row: nextConditionRow++,
        ));
        methodRefs[conditionId] = sources;
        link(parent, conditionId, sources);
      }
    }

    for (final method in methods) {
      final methodId = method['id'] as String;
      final sources = visibleSources[methodId]!;
      methodRefs[methodId] = sources;
      link(_graphRoot, methodId, sources);
      if (aggregate) {
        for (final entry in members[methodId]!.entries) {
          final memberSources = sources
              .where((source) => source['graph_method_id'] == entry.key)
              .toList();
          if (memberSources.isEmpty) continue;
          additionalNodes.add((
            id: entry.key,
            label: entry.value['problem'] as String,
            kind: _GraphKind.method,
            row: nextMethodRow++,
          ));
          methodRefs[entry.key] = memberSources;
          link(methodId, entry.key, memberSources);
          conditions(entry.key, entry.value, memberSources);
        }
      } else {
        conditions(methodId, method, sources);
      }
      final evidenceLinks = <_GraphEdge, List<Map<String, dynamic>>>{};
      for (final source in sources) {
        final workId = source['work_id'] as String;
        final workNode = 'work:$workId';
        final workRefs = methodRefs.putIfAbsent(workNode, () => []);
        if (!workRefs.any((item) =>
            item['id'] == source['id'] &&
            item['graph_method'] == source['graph_method'])) {
          workRefs.add(source);
        }
        workOrder.putIfAbsent(workId, () => workOrder.length);
        final parent = source['graph_method_id'] as String? ?? methodId;
        evidenceLinks
            .putIfAbsent((from: parent, to: workNode), () => []).add(source);
      }
      for (final entry in evidenceLinks.entries) {
        link(entry.key.from, entry.key.to, entry.value);
      }
    }
    final precedingEdges = <_GraphEdge>{};
    for (final entry in precedingSources.entries) {
      final edge = entry.key;
      final source = entry.value;
      if (!methodRefs.containsKey(edge.from) ||
          !methodRefs.containsKey(edge.to) ||
          (workFilter != null && source['work_id'] != workFilter)) {
        continue;
      }
      link(edge.from, edge.to, [source]);
      precedingEdges.add(edge);
    }
    final scheme = Theme.of(context).colorScheme;
    final refs = methodRefs[selection.node] ?? const [];
    final visibleWorkCount =
        refs.map((source) => source['work_id']).toSet().length;
    final typography = Theme.of(context).textTheme;
    Widget relatedWorks(double maxBodyHeight) => Material(
          key: const ValueKey('roundtable-related-works'),
          color: scheme.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                expanded: !options.collapsed,
                child: InkWell(
                  onTap: () => _options.value = (
                    scatter: options.scatter,
                    collapsed: !options.collapsed,
                    topic: options.topic,
                    work: options.work,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('关联作品 · $visibleWorkCount',
                              style: typography.titleSmall),
                        ),
                        Icon(
                          options.collapsed
                              ? Icons.expand_more
                              : Icons.expand_less,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (!options.collapsed) ...[
                Divider(height: 1, color: scheme.outlineVariant),
                if (precedingEdges
                    .any((edge) => _edgeId(edge) == selection.node))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Text('前置关系 · 原文顺序',
                        style: typography.labelMedium
                            ?.copyWith(color: scheme.tertiary)),
                  ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxBodyHeight),
                  child: ListView.separated(
                    key: ValueKey(selection.node),
                    primary: false,
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: refs.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: scheme.outlineVariant),
                    itemBuilder: (context, index) {
                      final source = refs[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (aggregate)
                              Text(
                                "${source['graph_creator_name']} · ${source['graph_method']}",
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: typography.labelMedium,
                              ),
                            Text(
                              creatorEvidenceLocation(source),
                              style: typography.labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "${source['text']}",
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: typography.bodyMedium,
                            ),
                            const SizedBox(height: 4),
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                minimumSize: const Size(0, 32),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                              ),
                              icon: const Icon(Icons.north_east, size: 14),
                              onPressed: () {
                                if (widget.onOpenWork case final openWork?) {
                                  openWork(
                                    source['graph_creator_id'] as String? ??
                                        expert['id'] as String,
                                    source,
                                  );
                                  return;
                                }
                                final url = Uri.tryParse('${source['url']}');
                                if (url?.scheme == 'https' &&
                                    url?.host == 'www.douyin.com') {
                                  launchUrl(url!,
                                      mode: LaunchMode.externalApplication);
                                }
                              },
                              label: Text(widget.onOpenWork == null
                                  ? '打开原作品'
                                  : '查看归档作品'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        );
    final nodes = <_GraphNode>[
      (
        id: _graphRoot,
        label: aggregate ? '全部博主' : '${expert['name']}',
        kind: _GraphKind.author,
        row: 0
      ),
      for (final (index, method) in methods.indexed)
        (
          id: method['id'] as String,
          label: '${method['problem']}',
          kind: aggregate ? _GraphKind.topic : _GraphKind.method,
          row: index
        ),
      for (final entry in workOrder.entries)
        (
          id: 'work:${entry.key}',
          label: workNames[entry.key]!,
          kind: _GraphKind.work,
          row: entry.value
        ),
      ...additionalNodes,
    ];
    final workNodes = {
      for (final node in nodes)
        if (node.kind == _GraphKind.work) node.id,
    };
    final positions = options.scatter
        ? const <String, double>{}
        : _networkRows(edges, precedingEdges, workNodes);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(children: [
            Expanded(
                child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: UiSelect<String>(
                  height: 36,
                  value: selectedCreator,
                  options: [
                    if (canAggregate)
                      const UiSelectOption(value: '', label: '全部博主'),
                    for (final item in widget.experts)
                      UiSelectOption(
                        value: item['id'] as String,
                        label: '${item['name']} · v${item['version']}',
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    _options.value = (
                      scatter: options.scatter,
                      collapsed: options.collapsed,
                      topic: options.topic,
                      work: null
                    );
                    _selection.value = (creator: value, node: null);
                    _transform.value = Matrix4.identity();
                  },
                ),
              ),
            )),
            const SizedBox(width: 8),
            SizedBox(
              width: 112,
              child: TabBar(
                controller: _viewTabs,
                dividerHeight: 0,
                indicatorSize: TabBarIndicatorSize.label,
                labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                labelColor: scheme.primary,
                unselectedLabelColor: scheme.onSurfaceVariant,
                indicatorColor: scheme.primary,
                tabs: const [
                  Tab(height: 36, text: '网络'),
                  Tab(height: 36, text: '散点'),
                ],
                onTap: (index) => _options.value = (
                  scatter: index == 1,
                  collapsed: options.collapsed,
                  topic: options.topic,
                  work: options.work,
                ),
              ),
            ),
          ])),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
        child: Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 170,
              child: UiSearchField(
                controller: _topic,
                height: 36,
                hintText: '筛选主题',
                onChanged: (value) => _options.value = (
                  scatter: options.scatter,
                  collapsed: options.collapsed,
                  topic: value,
                  work: options.work,
                ),
              ),
            ),
            SizedBox(
              width: 136,
              child: Tooltip(
                message: '筛选作品',
                child: UiSelect<String>(
                  height: 36,
                  value: workFilter ?? '',
                  options: [
                    const UiSelectOption(value: '', label: '全部作品'),
                    for (final item in workNames.entries)
                      UiSelectOption(value: item.key, label: item.value),
                  ],
                  onChanged: (value) => _options.value = (
                    scatter: options.scatter,
                    collapsed: options.collapsed,
                    topic: options.topic,
                    work: value == '' ? null : value,
                  ),
                ),
              ),
            ),
            Text('${nodes.length} 个节点 · ${edges.length} 条关系',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
      Expanded(child: LayoutBuilder(builder: (context, viewport) {
        final graphWidth = (viewport.maxWidth - (floatingWorks ? 290 : 0))
            .clamp(680.0, 1100.0);
        final horizontalScale = graphWidth / 680;
        (double, double) column(_GraphKind kind) => switch (kind) {
              _GraphKind.author => (16, 98),
              _GraphKind.topic => (126, 118),
              _GraphKind.method => aggregate ? (256, 143) : (145, 181),
              _GraphKind.condition => aggregate ? (409, 142) : (343, 196),
              _GraphKind.work => (563, 105),
            };
        final boxes = <String, Rect>{
          for (final node in nodes)
            node.id: Rect.fromLTWH(
                (column(node.kind).$1 +
                        (options.scatter ? (node.row % 2) * 6 : 0)) *
                    horizontalScale,
                options.scatter
                    ? 18.0 + node.row * 70 + node.kind.index * 10
                    : positions[node.id]! - 24,
                column(node.kind).$2 * horizontalScale,
                48),
        };
        void select(String id) => _selection.value =
            (creator: selectedCreator, node: id == _graphRoot ? null : id);
        final lines = _GraphLinks(
          boxes: boxes,
          edges: edges,
          preceding: precedingEdges,
          workNodes: workNodes,
          selected: selection.node,
          color: scheme.outlineVariant,
          activeColor: scheme.primary,
          precedingColor: scheme.tertiary,
        );
        final canvas = Color.alphaBlend(
            scheme.primary.withValues(alpha: .018), scheme.surface);
        Color nodeColor(_GraphKind kind) => switch (kind) {
              _GraphKind.author => scheme.onSurfaceVariant,
              _GraphKind.topic || _GraphKind.method => scheme.primary,
              _GraphKind.condition => scheme.tertiary,
              _GraphKind.work => scheme.secondary,
            };
        return ColoredBox(
          color: canvas,
          child: Stack(children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter:
                      _GraphGrid(scheme.outlineVariant.withValues(alpha: .55)),
                ),
              ),
            ),
            Positioned.fill(
                child: InteractiveViewer(
              constrained: false,
              transformationController: _transform,
              minScale: .5,
              maxScale: 3,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              child: SizedBox(
                width: graphWidth,
                height: boxes.values.fold<double>(
                    210.0, (height, box) => math.max(height, box.bottom + 18)),
                child: Stack(children: [
                  if (!options.scatter)
                    Positioned.fill(
                        child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (event) {
                        if (lines.at(event.localPosition) case final edge?) {
                          select(_edgeId(edge));
                        }
                      },
                      child: CustomPaint(painter: lines),
                    )),
                  for (final node in nodes)
                    Positioned.fromRect(
                        rect: boxes[node.id]!,
                        child: Tooltip(
                            message: node.label,
                            child: FilterChip(
                              key: ValueKey('roundtable-graph-${node.id}'),
                              showCheckmark: false,
                              backgroundColor: scheme.surface,
                              selectedColor: scheme.primaryContainer,
                              side: BorderSide(
                                color: selection.node == node.id
                                    ? scheme.primary
                                    : scheme.outlineVariant,
                              ),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              labelPadding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6)),
                              visualDensity: VisualDensity.compact,
                              avatar: Icon(Icons.circle,
                                  size: node.kind == _GraphKind.author ? 10 : 7,
                                  color: nodeColor(node.kind)),
                              selected: selection.node == node.id,
                              labelStyle: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(height: 1.25),
                              label: Text(node.label,
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              onSelected: (_) => select(node.id),
                            ))),
                ]),
              ),
            )),
            if (methods.isEmpty)
              const Positioned(top: 88, left: 18, child: Text('没有符合筛选条件的内容')),
            if (floatingWorks && refs.isNotEmpty)
              Positioned(
                top: 10,
                right: 10,
                width: 270,
                child:
                    relatedWorks((viewport.maxHeight - 80).clamp(0.0, 220.0)),
              ),
            Positioned(
              left: 10,
              bottom: 8,
              child: Material(
                color: scheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                child: ValueListenableBuilder<Matrix4>(
                  valueListenable: _transform,
                  builder: (context, transform, _) {
                    final scale = transform.getMaxScaleOnAxis();
                    final center = viewport.biggest.center(Offset.zero);
                    return Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          tooltip: '缩小图谱',
                          icon: const Icon(Icons.remove),
                          onPressed: scale <= .5
                              ? null
                              : () => _setZoom(scale - .25, center)),
                      Text('${(scale * 100).round()}%'),
                      IconButton(
                          tooltip: '放大图谱',
                          icon: const Icon(Icons.add),
                          onPressed: scale >= 3
                              ? null
                              : () => _setZoom(scale + .25, center)),
                      IconButton(
                          tooltip: '复位图谱',
                          icon: const Icon(Icons.center_focus_strong),
                          onPressed: () =>
                              _transform.value = Matrix4.identity()),
                      if (!widget.full)
                        IconButton(
                          tooltip: '全屏知识图谱',
                          icon: const Icon(Icons.fullscreen),
                          onPressed: () => showDialog<void>(
                              context: context,
                              builder: (context) => Dialog.fullscreen(
                                      child: Scaffold(
                                    appBar: AppBar(
                                        title: const Text('知识图谱'),
                                        leading: BackButton(
                                            onPressed: () =>
                                                Navigator.pop(context))),
                                    body: CreatorRoundtableGraph._fullscreen(
                                        experts: widget.experts,
                                        onOpenWork: widget.onOpenWork,
                                        selection: _selection,
                                        transform: _transform,
                                        options: _options),
                                  ))),
                        ),
                    ]);
                  },
                ),
              ),
            ),
          ]),
        );
      })),
      if (!floatingWorks && refs.isNotEmpty)
        Padding(
          padding: const EdgeInsets.all(10),
          child: relatedWorks(152),
        ),
    ]);
  }

  void _setZoom(double value, Offset center) {
    final scale = value.clamp(.5, 3.0).toDouble();
    final anchor = _transform.toScene(center);
    _transform.value = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(2, 2, scale)
      ..setEntry(0, 3, center.dx - anchor.dx * scale)
      ..setEntry(1, 3, center.dy - anchor.dy * scale);
  }
}

Map<String, double> _networkRows(
    Set<_GraphEdge> edges, Set<_GraphEdge> preceding, Set<String> workNodes) {
  const firstCenter = 48.0;
  const rowGap = 64.0;
  final children = <String, List<String>>{};
  final workSources = <String, List<String>>{};
  for (final edge in edges) {
    if (preceding.contains(edge)) continue;
    if (workNodes.contains(edge.to)) {
      workSources.putIfAbsent(edge.to, () => []).add(edge.from);
    } else {
      children.putIfAbsent(edge.from, () => []).add(edge.to);
    }
  }

  final centers = <String, double>{};
  var nextCenter = firstCenter;
  double placeBranch(String id) {
    final branches = children[id];
    if (branches == null) {
      final center = nextCenter;
      nextCenter += rowGap;
      return centers[id] = center;
    }
    final rows = branches.map(placeBranch).toList();
    return centers[id] = (rows.first + rows.last) / 2;
  }

  placeBranch(_graphRoot);
  final workCenters = [
    for (final entry in workSources.entries)
      (
        id: entry.key,
        center: entry.value.fold(0.0, (sum, id) => sum + centers[id]!) /
            entry.value.length,
      ),
  ]..sort((a, b) {
      final byCenter = a.center.compareTo(b.center);
      return byCenter == 0 ? a.id.compareTo(b.id) : byCenter;
    });
  var nextWorkCenter = firstCenter;
  for (final work in workCenters) {
    final center = math.max(work.center, nextWorkCenter);
    centers[work.id] = center;
    nextWorkCenter = center + rowGap;
  }
  return centers;
}

class _GraphLinks extends CustomPainter {
  const _GraphLinks(
      {required this.boxes,
      required this.edges,
      required this.preceding,
      required this.workNodes,
      required this.selected,
      required this.color,
      required this.activeColor,
      required this.precedingColor});
  final Map<String, Rect> boxes;
  final Set<_GraphEdge> edges;
  final Set<_GraphEdge> preceding;
  final Set<String> workNodes;
  final String? selected;

  bool _isActive(_GraphEdge edge) =>
      selected == edge.from || selected == edge.to || selected == _edgeId(edge);

  Iterable<_GraphEdge> get _visibleEdges =>
      edges.where((edge) => !workNodes.contains(edge.to) || _isActive(edge));
  final Color color;
  final Color activeColor;
  final Color precedingColor;

  List<Offset> _segments(_GraphEdge edge) {
    final from = boxes[edge.from]!;
    final to = boxes[edge.to]!;
    if (preceding.contains(edge)) {
      final start = from.centerLeft;
      final end = to.centerLeft;
      final channel = math.min(start.dx, end.dx) - 14;
      return [start, Offset(channel, start.dy), Offset(channel, end.dy), end];
    }
    final start = from.centerRight;
    final end = to.centerLeft;
    if (workNodes.contains(edge.to)) {
      const routeY = 12.0;
      final departure = start.dx + 5;
      final arrival = end.dx - 7;
      return [
        start,
        Offset(departure, start.dy),
        Offset(departure, routeY),
        Offset(arrival, routeY),
        Offset(arrival, end.dy),
        end,
      ];
    }
    final channel = (start.dx + end.dx) / 2;
    return [start, Offset(channel, start.dy), Offset(channel, end.dy), end];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    final visible = _visibleEdges.toList();
    for (final edge in [
      ...visible.where((edge) => !_isActive(edge)),
      ...visible.where(_isActive),
    ]) {
      final active = _isActive(edge);
      paint
        ..color = active
            ? activeColor
            : preceding.contains(edge)
                ? precedingColor
                : color
        ..strokeWidth = active ? 2 : 1.5;
      final segments = _segments(edge);
      final path = Path()..addPolygon(segments, false);
      paint
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(path, paint);
      if (preceding.contains(edge)) {
        final start = segments[1];
        final vector = segments[2] - start;
        final tangent = vector / vector.distance;
        final normal = Offset(-tangent.dy, tangent.dx);
        final arrow = start + vector * .65;
        canvas.drawLine(arrow, arrow - tangent * 8 + normal * 4, paint);
        canvas.drawLine(arrow, arrow - tangent * 8 - normal * 4, paint);
      }
    }
  }

  _GraphEdge? at(Offset position) {
    var minDistance = 7.0;
    _GraphEdge? hit;
    for (final edge in _visibleEdges) {
      final segments = _segments(edge);
      for (var index = 1; index < segments.length; index++) {
        final start = segments[index - 1];
        final vector = segments[index] - start;
        final delta = position - start;
        if (vector.distanceSquared == 0) continue;
        final projection = (delta.dx * vector.dx + delta.dy * vector.dy) /
            vector.distanceSquared;
        final distance = (delta - vector * projection.clamp(0.0, 1.0)).distance;
        if (distance < minDistance) {
          minDistance = distance;
          hit = edge;
        }
      }
    }
    return hit;
  }

  @override
  bool shouldRepaint(_GraphLinks oldDelegate) =>
      oldDelegate.boxes != boxes ||
      oldDelegate.edges != edges ||
      oldDelegate.preceding != preceding ||
      oldDelegate.workNodes != workNodes ||
      oldDelegate.selected != selected ||
      oldDelegate.color != color ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.precedingColor != precedingColor;
}

class _GraphGrid extends CustomPainter {
  const _GraphGrid(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var x = 8.0; x < size.width; x += 16) {
      for (var y = 8.0; y < size.height; y += 16) {
        canvas.drawCircle(Offset(x, y), .75, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GraphGrid oldDelegate) => oldDelegate.color != color;
}
