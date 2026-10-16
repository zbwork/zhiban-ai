import 'package:zhiban_client/network/user_refresh.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/model_service/widgets/add_provider_dialog.dart'
    show ProviderIcon;
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/services/conversation_model_order.dart';
import 'package:zhiban_client/services/conversation_models.dart';

/// Keeps the existing popup shell while giving its list an independent scroll.
class ModelPickerEntry extends PopupMenuEntry<String> {
  const ModelPickerEntry({
    super.key,
    required this.height,
    required this.models,
    required this.selected,
    required this.error,
    required this.modelIcon,
    required this.platform,
    required this.onRefresh,
  });

  @override
  final double height;
  final List<LlmModelOption> models;
  final String selected, error;
  final Widget Function(String) modelIcon;
  final Widget? Function(LlmModelOption) platform;
  final Future<ConversationModelState> Function() onRefresh;

  @override
  bool represents(String? value) => false;

  @override
  State<ModelPickerEntry> createState() => _ModelPickerEntryState();
}

class _ModelPickerEntryState extends State<ModelPickerEntry> {
  String _query = '';
  String? _provider;
  final _scroll = ScrollController();
  ConversationModelState? _refreshed;
  bool _refreshing = false;
  String _refreshError = '';

  List<LlmModelOption> get _models => _refreshed?.models ?? widget.models;
  String get _selected => _refreshed?.selected ?? widget.selected;
  String get _error => _refreshError.isNotEmpty
      ? _refreshError
      : _refreshed?.error ?? widget.error;

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _refreshError = '';
    });
    try {
      final next = await widget.onRefresh();
      if (!mounted) return;
      setState(() {
        _refreshed = next;
        if (_provider != null &&
            !next.models.any((model) => _platformKey(model) == _provider)) {
          _provider = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _refreshError = '模型列表刷新失败，请重试');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _platformKey(LlmModelOption model) =>
      model.providerId.isEmpty ? model.providerName : model.providerId;

  void _filter(VoidCallback update) {
    setState(update);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _choose(String value) => Navigator.of(context).pop(value);

  String _displayTitle(LlmModelOption model) {
    // Only prettify raw Qwen IDs; preserve member-defined display names.
    if (model.label == model.modelId &&
        model.modelId.toLowerCase().startsWith('qwen/')) {
      return model.modelId.split('/').last.replaceAll('-', ' ');
    }
    return model.label;
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
        child: Text(title,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  Widget _row(LlmModelOption model) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selected == model.id;
    final platform = widget.platform(model);
    final title = _displayTitle(model);
    final subtitle = model.modelId.isNotEmpty && model.modelId != title;
    return Padding(
      padding: EdgeInsets.zero,
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: .08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: ValueKey('model-option-${model.id}'),
          borderRadius: BorderRadius.circular(8),
          onTap: _refreshing || _refreshError.isNotEmpty
              ? null
              : () => _choose(model.id),
          child: Semantics(
            selected: selected,
            button: true,
            child: Container(
              height: subtitle ? 48 : 42,
              padding: const EdgeInsets.fromLTRB(0, 4, 6, 4),
              child: Row(children: [
                widget.modelIcon(
                    model.modelId.isEmpty ? model.id : model.modelId),
                const SizedBox(width: 8),
                Expanded(
                  child: Tooltip(
                    message:
                        subtitle ? '$title\n${model.modelId}' : model.label,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: selected
                                    ? scheme.primary
                                    : scheme.onSurface)),
                        if (subtitle) ...[
                          const SizedBox(height: 3),
                          Text(model.modelId,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant
                                      .withValues(alpha: .7))),
                        ],
                      ],
                    ),
                  ),
                ),
                if (platform != null) ...[const SizedBox(width: 10), platform],
                if (selected) ...[
                  const SizedBox(width: 6),
                  Icon(CupertinoIcons.check_mark,
                      size: 16, color: scheme.primary),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final orderedModels = orderConversationModels(_models);
    final providers = <String, LlmModelOption>{};
    for (final model in orderedModels) {
      if (model.providerName.isNotEmpty) {
        providers.putIfAbsent(_platformKey(model), () => model);
      }
    }
    final filtered = orderedModels
        .where((model) =>
            (_provider == null || _platformKey(model) == _provider) &&
            '${model.label}\n${_displayTitle(model)}\n${model.modelId}\n${model.providerName}'
                .toLowerCase()
                .contains(_query))
        .toList();
    final current =
        filtered.where((model) => model.id == _selected).firstOrNull;
    final others = filtered.where((model) => model.id != _selected).toList();
    return SizedBox(
      height: widget.height,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
          child: UiSheetHeader(
              title: '选择模型',
              trailing: Text('${_models.length} 个模型',
                  style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant.withValues(alpha: .7)))),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: UiSearchField(
              hintText: '搜索模型或平台…',
              height: 36,
              showBorder: false,
              fillColor: scheme.onSurface.withValues(alpha: .035),
              borderRadius: 8,
              onChanged: (value) =>
                  _filter(() => _query = value.trim().toLowerCase())),
        ),
        if (providers.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
            child: Row(children: [
              _chip('全部平台', null),
              for (final entry in providers.entries)
                _chip(entry.value.providerName, entry.key, model: entry.value),
            ]),
          )
        else
          const SizedBox(height: 8),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                          _models.isEmpty
                              ? '暂无可选模型，请刷新或管理模型服务'
                              : '未找到匹配的模型\n试试其他名称或平台',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.7,
                              color: scheme.onSurfaceVariant))))
              : Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  thickness: 4,
                  radius: const Radius.circular(4),
                  child: ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      children: [
                        if (current != null) ...[
                          _section('当前模型'),
                          _row(current),
                          if (others.isNotEmpty)
                            Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: Divider(
                                    height: 1,
                                    color: UiFieldStyle.enabledBorderColor(
                                        scheme))),
                        ],
                        if (others.isNotEmpty) ...[
                          _section(_query.isEmpty && _provider == null
                              ? '全部模型'
                              : '匹配模型'),
                          ...others.map(_row),
                        ],
                      ])),
        ),
        if (_error.isNotEmpty)
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(_error,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: scheme.error))),
        Divider(height: 1, color: UiFieldStyle.enabledBorderColor(scheme)),
        Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
            child: Text('切换后从下一条消息生效',
                style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant.withValues(alpha: .65)))),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(children: [
              TextButton.icon(
                  style: TextButton.styleFrom(
                      foregroundColor: scheme.onSurfaceVariant),
                  onPressed: _refreshing ? null : () => UserRefresh.run(_refresh),
                  icon: _refreshing
                      ? const CupertinoActivityIndicator(radius: 7)
                      : const Icon(CupertinoIcons.arrow_clockwise, size: 16),
                  label: Text(_refreshing ? '刷新中…' : '刷新列表',
                      style: const TextStyle(fontSize: 12))),
              const Spacer(),
              _action('管理模型服务', CupertinoIcons.gear_alt, '@settings'),
            ])),
      ]),
    );
  }

  Widget _chip(String label, String? value, {LlmModelOption? model}) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _provider == value;
    return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          key: ValueKey('model-platform-${value ?? 'all'}'),
          label: Text(label),
          avatar: model == null
              ? null
              : ProviderIcon(
                  iconAssetPath: model.providerIconAssetPath,
                  name: label,
                  size: 18),
          selected: selected,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          labelStyle: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: selected ? scheme.primary : scheme.onSurface),
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          selectedColor: scheme.primary.withValues(alpha: .08),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          side: BorderSide(
              color: selected
                  ? Colors.transparent
                  : UiFieldStyle.enabledBorderColor(scheme)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          onSelected: (_) => _filter(() => _provider = value),
        ));
  }

  Widget _action(String label, IconData icon, String value) => TextButton.icon(
      style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
          textStyle: const TextStyle(fontWeight: FontWeight.w400)),
      onPressed: () => _choose(value),
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)));
}
