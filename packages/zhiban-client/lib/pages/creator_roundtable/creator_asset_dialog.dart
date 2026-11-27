import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

import '../local_workspace/services/local_workspace_store.dart';
import 'creator_roundtable_chat.dart';
import 'services/creator_asset_workflow.dart';
import 'services/creator_expert_workflow.dart';
import 'creator_roundtable_controls.dart';

Future<Directory> creatorAssetDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/creator-assets');
final creatorAssetDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => creatorAssetDirectory,
);

class CreatorAssetDialog extends ConsumerStatefulWidget {
  const CreatorAssetDialog(
      {super.key,
      required this.kind,
      required this.experts,
      required this.store,
      required this.canGenerate,
      required this.resolveModel,
      this.resolveOriginalModel});

  final CreatorAssetKind kind;
  final List<LocalRow> experts;
  final LocalWorkspaceStore store;
  final bool canGenerate;
  final Future<RoundtableModel> Function(CancelToken) resolveModel;
  final Future<RoundtableModel> Function(Map<String, Object>, CancelToken)?
      resolveOriginalModel;

  @override
  ConsumerState<CreatorAssetDialog> createState() => _CreatorAssetDialogState();
}

class _CreatorAssetDialogState extends ConsumerState<CreatorAssetDialog> {
  final _title = TextEditingController();
  final _search = TextEditingController();
  bool _failed = false;
  String? _failedJobId;
  late final _selected =
      widget.experts.map((expert) => expert['id'] as String).toSet();
  CancelToken? _busy;
  String? _error, _status;
  late Future<LocalRow?> _resumable;

  @override
  void initState() {
    super.initState();
    _resumable = widget.store.lastResumableCreatorAssetJob(widget.kind.name);
  }

  @override
  void dispose() {
    _busy?.cancel();
    _title.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _generate({LocalRow? retry}) async {
    if (_busy != null) return;
    final assetDirectory = ref.read(creatorAssetDirectoryProvider);
    final inputTitle = _title.text.trim();
    if (retry == null && (inputTitle.isEmpty || _selected.isEmpty)) {
      setState(() => _error = '请填写资产名称并选择至少一位博主。');
      return;
    }
    final token = CancelToken();
    final experts = widget.experts
        .where((expert) => _selected.contains(expert['id']))
        .toList();
    setState(() {
      _busy = token;
      _status = retry?['stage'] == 'render' ? '正在恢复已复核内容…' : '正在生成并复核内容…';
      _error = null;
      _failed = false;
    });
    File? pending;
    File? output;
    String? jobId;
    try {
      final String title;
      final CreatorAssetDraft draft;
      final List<Map<String, Object?>> versions;
      final Map<String, Object> modelSnapshot;
      if (retry != null) {
        final original = jsonDecode(retry['request_payload'] as String) as Map;
        title = original['title'] as String;
        versions = (jsonDecode(retry['source_snapshot'] as String) as List)
            .cast<Map<String, Object?>>();
        modelSnapshot = Map<String, Object>.from(
            jsonDecode(retry['model_snapshot'] as String) as Map);
        final id = retry['id'] as String;
        await widget.store.resumeCreatorAssetJob(id, widget.kind.name);
        jobId = id;
        if (retry['stage'] == 'render') {
          draft = restoreCreatorAssetDraft(
              widget.kind, retry['result_payload'] as String);
        } else {
          final resolver = widget.resolveOriginalModel;
          if (resolver == null) {
            throw const CreatorWorkflowException('无法读取原任务模型配置。');
          }
          final candidate = retry['stage'] == 'review'
              ? restoreCreatorAssetDraft(
                  widget.kind, retry['result_payload'] as String)
              : null;
          final frozen = candidate == null
              ? await _loadFrozenExperts(versions)
              : <LocalRow>[];
          final model = await resolver(modelSnapshot, token);
          if (model.snapshot['provider_id'] != modelSnapshot['provider_id'] ||
              model.snapshot['model_id'] != modelSnapshot['model_id']) {
            throw const CreatorWorkflowException('原任务的模型配置已变化。');
          }
          draft = await _produceDraft(id, title, frozen, model,
              candidate: candidate);
        }
      } else {
        title = inputTitle;
        final model = await widget.resolveModel(token);
        modelSnapshot = model.snapshot;
        versions = [
          for (final expert in experts)
            {
              'expert_id': expert['id'],
              'version': expert['version'],
              'name': expert['name']
            },
        ];
        jobId = await widget.store.beginCreatorAssetJob(
            widget.kind.name, title, modelSnapshot, versions);
        draft = await _produceDraft(jobId, title, experts, model);
      }
      if (!mounted || token.isCancelled) {
        throw const CreatorWorkflowException('已取消生成。');
      }
      setState(() => _status = '正在生成文件…');
      final bytes = await renderCreatorAsset(widget.kind, title, draft);
      if (!mounted || token.isCancelled) {
        throw const CreatorWorkflowException('已取消生成。');
      }
      verifyRenderedCreatorAsset(widget.kind, bytes);
      final id = jobId;
      final name = '$id.${widget.kind.extension}';
      final directory = await assetDirectory();
      await directory.create(recursive: true);
      pending = File('${directory.path}/$name.part');
      await pending.writeAsBytes(bytes, flush: true);
      if (token.isCancelled) {
        throw const CreatorWorkflowException('已取消生成。');
      }
      output = await pending.rename('${directory.path}/$name');
      if (token.isCancelled) {
        throw const CreatorWorkflowException('已取消生成。');
      }
      await widget.store.saveCreatorAsset(
          id: id,
          kind: widget.kind.name,
          title: title,
          fileName: name,
          model: modelSnapshot,
          sources: [...versions, ...draft.sources.values],
          jobId: jobId);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      for (final file in [pending, output]) {
        try {
          if (file != null && await file.exists()) await file.delete();
        } on FileSystemException {
          // Unpublished files have no record or download entry.
        }
      }
      final message = switch (error) {
        CreatorWorkflowException(:final message) => message,
        StateError(:final message) => message.toString(),
        _ => '文件生成失败，请检查模型和本机存储。',
      };
      if (jobId != null) await widget.store.failCreatorJob(jobId, message);
      if (mounted) {
        setState(() {
          _error = message;
          _failed = true;
          _failedJobId = jobId ?? retry?['id'] as String?;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _status = null;
          _resumable =
              widget.store.lastResumableCreatorAssetJob(widget.kind.name);
        });
      }
    }
  }

  Future<List<LocalRow>> _loadFrozenExperts(List<LocalRow> versions) async {
    if (versions.isEmpty) throw const CreatorWorkflowException('原任务没有可用的来源版本。');
    final frozen = <LocalRow>[];
    for (final version in versions) {
      final expert = await widget.store.publishedCreatorExpertVersion(
          version['expert_id'] as String, version['version'] as int);
      if (expert == null) throw const CreatorWorkflowException('无法读取原任务的专家版本。');
      frozen.add({
        ...expert,
        if (version['name'] case final String name) 'name': name
      });
    }
    return frozen;
  }

  Future<CreatorAssetDraft> _produceDraft(
      String jobId, String title, List<LocalRow> experts, RoundtableModel model,
      {CreatorAssetDraft? candidate}) async {
    if (candidate != null && mounted) setState(() => _status = '正在复核已保存的候选稿…');
    final CreatorAssetDraft draft;
    try {
      draft = await generateCreatorAssetDraft(
        kind: widget.kind,
        title: title,
        experts: experts,
        complete: model.complete,
        candidate: candidate,
        onCandidate: (value) async {
          await widget.store.checkpointCreatorAssetCandidate(
              jobId, widget.kind.name, creatorAssetCheckpoint(value));
          if (mounted) setState(() => _status = '正在复核候选稿…');
        },
      );
    } on CreatorAssetReviewRejected {
      await widget.store.rejectCreatorAssetCandidate(jobId, widget.kind.name);
      rethrow;
    }
    await widget.store.checkpointCreatorAssetJob(
        jobId, widget.kind.name, creatorAssetCheckpoint(draft));
    return draft;
  }

  @override
  Widget build(BuildContext context) {
    final running = _busy != null;
    final title = running
        ? '正在生成${widget.kind.label}'
        : _failed
            ? '生成失败'
            : '生成${widget.kind.label}';
    final theme = Theme.of(context);
    void close() => Navigator.pop(context);
    return PopScope(
      canPop: !running,
      child: UiContentDialog(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              UiSheetHeader(
                showCloseTooltip: false,
                title: title, onClose: running ? null : close),
              const Divider(height: 20),
              if (running) ...[
                Text(_status ?? '正在整理所选博主的作品…'),
                const SizedBox(height: 10),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(width: 180, child: LinearProgressIndicator()),
                ),
              ] else if (!_failed) ...[
                _sources(theme),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('roundtable-asset-title'),
                  controller: _title,
                  maxLength: 80,
                  decoration: const InputDecoration(
                    labelText: '资产名称 *',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Text('成品格式  ${widget.kind.extension.toUpperCase()}',
                    style: theme.textTheme.labelMedium),
              ],
              if (_error case final message?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(message,
                      style: TextStyle(color: theme.colorScheme.error)),
                ),
              const Divider(height: 20),
              FutureBuilder<LocalRow?>(
                future: _resumable,
                builder: (context, snapshot) {
                  final checkpoint = snapshot.data;
                  final failedCheckpoint =
                      checkpoint?['id'] == _failedJobId ? checkpoint : null;
                  return Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (!running && _failed)
                        OutlinedButton(
                          style: roundtableTextControlStyle,
                          onPressed: () => setState(() {
                            _failed = false;
                            _error = null;
                          }),
                          child: const Text('修改参数'),
                        ),
                      if (!running && !_failed && checkpoint != null)
                        TextButton(
                          style: roundtableTextControlStyle,
                          onPressed: () => _generate(retry: checkpoint),
                          child: const Text('继续上次生成'),
                        ),
                      if (_failed)
                        FilledButton(
                          style: roundtableTextControlStyle,
                          onPressed:
                              failedCheckpoint != null || widget.canGenerate
                                  ? () => _generate(retry: failedCheckpoint)
                                  : null,
                          child: const Text('重试'),
                        ),
                      if (!running && !_failed)
                        FilledButton(
                          style: roundtableTextControlStyle,
                          onPressed:
                              widget.canGenerate ? () => _generate() : null,
                          child: const Text('生成'),
                        ),
                      OutlinedButton(
                        style: roundtableTextControlStyle,
                        onPressed: running ? null : close,
                        child: Text(running || _failed ? '完成' : '取消'),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sources(ThemeData theme) {
    final search = _search.text.trim().toLowerCase();
    final matches = widget.experts
        .where((expert) => '${expert['name']}'.toLowerCase().contains(search))
        .toList();
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('来源博主 *', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: '搜索博主',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                style: roundtableTextControlStyle,
                onPressed: matches.isEmpty
                    ? null
                    : () => setState(() {
                          _selected.addAll(
                              matches.map((expert) => expert['id'] as String));
                        }),
                child: const Text('全选'),
              ),
            ]),
            const SizedBox(height: 6),
            SizedBox(
              height: 180,
              child: matches.isEmpty
                  ? const Center(child: Text('没有符合条件的博主'))
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, index) {
                        final expert = matches[index];
                        final id = expert['id'] as String;
                        final name = '${expert['name']}';
                        final checked = _selected.contains(id);
                        return CheckboxListTile(
                          value: checked,
                          tileColor: checked
                              ? scheme.primary.withValues(alpha: .07)
                              : null,
                          dense: true,
                          controlAffinity: ListTileControlAffinity.trailing,
                          title: Text(name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('专家 v${expert['version']}'),
                          onChanged: (value) => setState(() {
                            if (value == true) {
                              _selected.add(id);
                            } else {
                              _selected.remove(id);
                            }
                          }),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Text('已选 ${_selected.length} / ${widget.experts.length} 位',
                style: theme.textTheme.labelMedium),
            if (_selected.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final expert in widget.experts)
                    if (_selected.contains(expert['id']))
                      InputChip(
                        label: Text('${expert['name']}',
                            overflow: TextOverflow.ellipsis),
                        onDeleted: () =>
                            setState(() => _selected.remove(expert['id'])),
                        visualDensity: VisualDensity.compact,
                      ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
