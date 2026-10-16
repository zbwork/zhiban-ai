import 'package:zhiban_client/services/conversation_model_sources.dart';
import 'package:zhiban_client/services/conversation_models.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_ui/widgets/ui_segmented_tabs.dart';
import 'package:uuid/uuid.dart';

import 'package:zhiban_ui/widgets/ui_content_dialog.dart';
import 'package:zhiban_ui/widgets/ui_dialog_shell.dart';
import 'package:zhiban_ui/widgets/ui_icon_button.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';

import '../model_service_constants.dart';
import '../models/ai_endpoint_type.dart';
import '../models/ai_model_capability.dart';
import '../models/ai_model_config.dart';
import '../models/ai_provider_config.dart';
import '../models/catalog_entry.dart';
import '../providers/model_service_providers.dart';
import '../services/model_modality_classifier.dart';
import '../services/provider_model_fetcher.dart';
import '../services/vendor_group_display.dart';
import 'add_provider_dialog.dart' show ProviderIcon;
import 'group_header.dart';

const _uuid = Uuid();

/// 「添加模型」列表里展示用的统一条目——把内置目录条目（[CatalogModelEntry]）
/// 和拉取结果（[FetchedModel]）拍平成同一个形状，分组/筛选/图标/添加渲染
/// 只需要写一套，不用给两个数据源各写一遍几乎一样的逻辑。
class _BrowsableItem {
  const _BrowsableItem({
    required this.modelId,
    required this.displayName,
    required this.group,
    required this.capabilities,
  });

  final String modelId;
  final String displayName;

  /// 分组名：目录数据优先用真实 groupName；拉取结果优先用 modelId 里
  /// "vendor/model" 的真实前缀；两者都没有时兜底用关键词猜（可能是空）。
  final String group;
  final Set<AiModelCapability> capabilities;
}

/// 编辑一个已存在的模型条目。pop 返回更新后的配置，落盘由调用方负责
/// （跟「添加」不同——编辑天然是单条记录，维持原来的 pop-返回契约）。
Future<AiModelConfig?> showEditModelDialog(
  BuildContext context,
  AiModelConfig model,
) {
  return showDialog<AiModelConfig>(
    context: context,
    // `showDialog` 默认 `useRootNavigator: true`，弹框其实是压在根 Navigator
    // 上的；这个 shell 页面本身又套了一层 go_router 的嵌套 Navigator（见
    // app_router.dart 的 ShellRoute），如果用外层 context 调
    // `Navigator.of(context).pop()`，拿到的是嵌套 Navigator 而不是弹框真正
    // 所在的根 Navigator，点关闭/保存都会 pop 错栈，弹框关不掉——必须用
    // builder 自己的 dialogContext(2026-08-27 反馈：编辑模型的弹框还不能
    // 关闭)。
    builder: (dialogContext) => UiContentDialog(
      size: UiDialogSize.standard,
      maxHeight: 640,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: _ManualModelForm(
          initial: model,
          onClose: () => Navigator.of(dialogContext).pop(),
          onSubmit: (updated) => Navigator.of(dialogContext).pop(updated),
        ),
      ),
    ),
  );
}

/// 「添加模型」入口。“获取模型列表”和手动新增共用同一个抽屉壳，就地添加：
/// 点一次加一个，弹框不关，可以连续加多个。成功拉取后以完整实时列表为准，
/// 清理已配置的失效条目；失败或不支持拉取时才用目录/本地配置兜底。
///
/// 外部有两个独立入口按钮（照抄 Cherry Studio 服务商详情页的
/// “拉取”+“+”布局，2026-09-03 反馈）：“获取模型列表”使用 [AddModelDialogMode.browse]，
/// 打开即拉取服务商列表；
/// “+”使用 [AddModelDialogMode.manual]，直接落到手动填表单。抽屉不暴露数据
/// 来源切换，跟 Cherry Studio 的统一模型管理列表保持一致。
///
/// 整体用右侧抽屉展示（参考 Cherry Studio 的模型列表面板），不是居中弹框
/// ——列表本身需要滚动浏览很多条，抽屉比居中弹框更适合这种"边看边操作"
/// 的场景(2026-08-27 反馈)。
Future<void> showAddModelDialog(
  BuildContext context, {
  required AiProviderConfig provider,
  required AiEndpointType endpointType,
  required List<CatalogModelEntry> catalogModels,
  required String apiKey,
  required String baseUrl,
  required Future<String> Function() ensureLocalId,
  AddModelDialogMode mode = AddModelDialogMode.browse,
  ProviderModelFetcher modelFetcher = const ProviderModelFetcher(),
}) {
  return showGeneralDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: '关闭添加模型',
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (dialogContext, _, __) {
      final screenWidth = MediaQuery.sizeOf(dialogContext).width;
      final drawerWidth = screenWidth < 640
          ? (screenWidth * 0.94).clamp(320.0, 480.0).toDouble()
          : 560.0;
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: drawerWidth,
          height: double.infinity,
          child: Material(
            color: Theme.of(dialogContext).colorScheme.surface,
            child: SafeArea(
              child: _AddModelDialog(
                provider: provider,
                endpointType: endpointType,
                catalogModels: catalogModels,
                apiKey: apiKey,
                baseUrl: baseUrl,
                ensureLocalId: ensureLocalId,
                mode: mode,
                modelFetcher: modelFetcher,
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (_, animation, __, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

enum AddModelDialogMode { browse, manual }

class _AddModelDialog extends ConsumerStatefulWidget {
  const _AddModelDialog({
    required this.provider,
    required this.endpointType,
    required this.catalogModels,
    required this.apiKey,
    required this.baseUrl,
    required this.ensureLocalId,
    required this.mode,
    required this.modelFetcher,
  });

  final AiProviderConfig provider;
  final AiEndpointType endpointType;
  final List<CatalogModelEntry> catalogModels;
  final String apiKey;
  final String baseUrl;
  final Future<String> Function() ensureLocalId;
  final AddModelDialogMode mode;
  final ProviderModelFetcher modelFetcher;

  @override
  ConsumerState<_AddModelDialog> createState() => _AddModelDialogState();
}

class _AddModelDialogState extends ConsumerState<_AddModelDialog> {
  late final bool _canFetch;
  String _query = '';
  ModelModality? _modalityFilter;

  bool _liveLoading = false;
  bool _liveLoaded = false;
  String? _liveError;
  List<FetchedModel> _liveModels = const <FetchedModel>[];
  bool _addingAll = false;

  late final Set<String> _addedModelIds;
  final Set<String> _pendingIds = <String>{};
  final Set<String> _collapsedGroups = <String>{};
  final Set<String> _addingGroups = <String>{};

  @override
  void initState() {
    super.initState();
    _canFetch = const ProviderModelFetcher().supports(
      widget.endpointType,
      catalogId: widget.provider.catalogId,
    );
    _addedModelIds = widget.provider.models.map((m) => m.modelId).toSet();
    if (widget.mode == AddModelDialogMode.browse && _canFetch) {
      // 抽屉还没完成首帧不能同步 setState，把打开后的拉取挪到首帧之后触发。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadLive();
      });
    }
  }

  Future<void> _loadLive() async {
    setState(() {
      _liveLoading = true;
      _liveError = null;
    });
    try {
      if (widget.provider.catalogId == 'beebridge') {
        final refreshed = await ConversationModelSources().refreshManaged();
        ConversationModels.instance.applyCatalog(refreshed.items);
        if (!mounted) return;
        setState(() {
          _liveLoading = false;
          _liveLoaded = true;
          _liveModels = [
            for (final m in refreshed.models)
              FetchedModel(modelId: m.modelId, displayName: m.displayName)
          ];
          _addedModelIds
            ..clear()
            ..addAll(refreshed.models.map((m) => m.modelId));
        });
        return;
      }
      final notifier = ref.read(modelProvidersProvider.notifier);
      final scope = await ref.read(modelServiceStoreProvider).managedScope();
      if (!mounted) return;
      await ref.read(modelProvidersProvider.future);
      if (!mounted) return;
      final result = await widget.modelFetcher.fetch(
        endpointType: widget.endpointType,
        baseUrl: widget.baseUrl,
        apiKey: widget.apiKey,
        customHeaders: widget.provider.customHeaders,
        catalogId: widget.provider.catalogId,
      );
      if (!mounted) return;
      if (result.ok && scope != null) {
        try {
          await notifier.retainAvailableModels(widget.provider,
              result.models.map((m) => m.modelId).toSet(), scope);
        } catch (_) {
          if (!mounted) return;
          setState(() {
            _liveLoading = false;
            _liveError = '模型配置保存失败，请重试';
          });
          return;
        }
        if (!mounted) return;
      }
      setState(() {
        _liveLoading = false;
        if (result.ok) {
          _liveLoaded = true;
          _liveModels = result.models;
          _addedModelIds.retainAll(result.models.map((m) => m.modelId));
        } else {
          _liveError = result.message ?? '拉取失败';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _liveLoading = false;
        _liveError = '获取模型列表失败，请重试';
      });
    }
  }

  List<_BrowsableItem> get _catalogItems => [
        for (final e in widget.catalogModels)
          _BrowsableItem(
            modelId: e.modelId,
            displayName: e.displayName,
            group: e.groupName.isNotEmpty
                ? e.groupName
                : (guessVendorGroup(e.modelId) ?? ''),
            // 目录里的能力标签是真实数据（哪怕经常是空数组），优先用；只有
            // 目录本身没标注时才退回关键词猜测。
            capabilities: e.capabilities.isNotEmpty
                ? e.capabilities
                : guessModelCapabilities(e.modelId),
          ),
      ];

  List<_BrowsableItem> get _localItems => [
        for (final model in widget.provider.models)
          _BrowsableItem(
            modelId: model.modelId,
            displayName: model.displayName,
            group: model.groupName.isNotEmpty
                ? model.groupName
                : (guessVendorGroup(model.modelId) ?? ''),
            capabilities: model.capabilities.isNotEmpty
                ? model.capabilities
                : guessModelCapabilities(model.modelId),
          ),
      ];

  List<_BrowsableItem> get _liveItems => [
        for (final m in _liveModels)
          _BrowsableItem(
            modelId: m.modelId,
            displayName: m.displayName,
            group: m.group.isNotEmpty
                ? m.group
                : (guessVendorGroup(m.modelId) ?? ''),
            capabilities: guessModelCapabilities(m.modelId),
          ),
      ];

  List<_BrowsableItem> get _currentItems {
    if (widget.mode == AddModelDialogMode.manual) {
      return const <_BrowsableItem>[];
    }
    final seen = <String>{};
    return [
      for (final item
          in _liveLoaded ? _liveItems : [..._catalogItems, ..._localItems])
        if (seen.add(item.modelId)) item,
    ];
  }

  List<_BrowsableItem> get _filteredItems {
    var list = _currentItems;
    if (_modalityFilter != null) {
      list = list
          .where((it) => classifyModelId(it.modelId) == _modalityFilter)
          .toList();
    }
    if (_query.isNotEmpty) {
      list = list
          .where((it) =>
              it.displayName.toLowerCase().contains(_query) ||
              it.modelId.toLowerCase().contains(_query))
          .toList();
    }
    return list;
  }

  Future<void> _addItem(_BrowsableItem item) async {
    if (_addedModelIds.contains(item.modelId) ||
        _pendingIds.contains(item.modelId)) {
      return;
    }
    setState(() => _pendingIds.add(item.modelId));
    await _persistItems([item]);
    if (!mounted) return;
    setState(() => _pendingIds.remove(item.modelId));
  }

  Future<void> _addAllVisible() async {
    setState(() => _addingAll = true);
    await _persistItems(
      _filteredItems
          .where((it) => !_addedModelIds.contains(it.modelId))
          .toList(),
    );
    if (!mounted) return;
    setState(() => _addingAll = false);
  }

  Future<void> _addGroup(String group, List<_BrowsableItem> items) async {
    setState(() => _addingGroups.add(group));
    await _persistItems(
      items.where((it) => !_addedModelIds.contains(it.modelId)).toList(),
    );
    if (!mounted) return;
    setState(() => _addingGroups.remove(group));
  }

  Future<void> _persistItems(List<_BrowsableItem> toAdd) async {
    if (toAdd.isEmpty) return;
    try {
      final id = await widget.ensureLocalId();
      await ref.read(modelProvidersProvider.notifier).addModels(id, [
        for (final it in toAdd)
          AiModelConfig(
            id: _uuid.v4(),
            modelId: it.modelId,
            displayName: it.displayName,
            groupName: it.group,
            capabilities: it.capabilities,
          ),
      ]);
      if (!mounted) return;
      setState(() => _addedModelIds.addAll(toAdd.map((it) => it.modelId)));
      if (toAdd.length > 1) {
        BotToast.showText(text: '已添加 ${toAdd.length} 个模型');
      }
    } catch (error) {
      if (!mounted) return;
      BotToast.showText(text: '添加失败：$error');
    }
  }

  Future<void> _submitManual(AiModelConfig model) async {
    final id = await widget.ensureLocalId();
    await ref.read(modelProvidersProvider.notifier).addModel(id, model);
    if (!mounted) return;
    setState(() => _addedModelIds.add(model.modelId));
    BotToast.showText(text: '已添加');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isManual = widget.mode == AddModelDialogMode.manual;
    final showFilters = !isManual && !_liveLoading && _currentItems.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UiSheetHeader(
            title: '添加模型',
            subtitle: widget.provider.name,
            trailing: _buildHeaderActions(),
            onClose: () => Navigator.of(context).pop(),
          ),
          const SizedBox(height: 12),
          if (!isManual) ...[
            UiSearchField(
              height: kModelServiceFieldHeight,
              hintText: '搜索模型...',
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
          ],
          if (showFilters) ...[
            const SizedBox(height: 10),
            _buildModalityChips(),
          ],
          const SizedBox(height: 10),
          Expanded(child: _buildBody(scheme)),
          if (showFilters) ...[
            const SizedBox(height: 14),
            _buildAddAllButton(),
          ],
        ],
      ),
    );
  }

  /// 浏览模式打开后自动拉取；这里只保留重试/刷新，不暴露数据来源切换。
  Widget _buildHeaderActions() {
    if (widget.mode == AddModelDialogMode.manual || !_canFetch) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_liveLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: CupertinoActivityIndicator(radius: 8),
          )
        else
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: UiIconButton(
              icon: CupertinoIcons.refresh,
              tooltip: _liveError == null ? '重新拉取' : '拉取失败：$_liveError，点击重试',
              onTap: _loadLive,
            ),
          ),
      ],
    );
  }

  /// 复用共享的 [UiSegmentedTabs]（跟移动端消息中心「消息/未读」同一个组件），
  /// 不再自己另起一套 chip 实现(2026-08-27 反馈：tab 要用 UiSegmentedTab
  /// 这个组件)。
  Widget _buildModalityChips() {
    final scheme = Theme.of(context).colorScheme;
    final source = _currentItems;
    final counts = <ModelModality, int>{};
    for (final it in source) {
      final modality = classifyModelId(it.modelId);
      counts[modality] = (counts[modality] ?? 0) + 1;
    }
    return UiSegmentedTabs<ModelModality?>(
      groupId:
          'add-model-modality-${widget.provider.id}-${widget.provider.name}',
      current: _modalityFilter,
      onChanged: (value) => setState(() => _modalityFilter = value),
      height: 32,
      fontSize: 12,
      segmentPadding: const EdgeInsets.symmetric(horizontal: 10),
      trackColor: scheme.surfaceContainerHighest.withValues(alpha: 0.56),
      activeColor: scheme.primary,
      inactiveColor: scheme.onSurfaceVariant.withValues(alpha: 0.9),
      tabs: [
        UiSegmentedTab(value: null, label: '全部 ${source.length}'),
        for (final modality in ModelModality.values)
          UiSegmentedTab(
            value: modality,
            label: '${modality.label} ${counts[modality] ?? 0}',
            icon: modality.icon,
          ),
      ],
    );
  }

  Widget _buildAddAllButton() {
    final pendingCount = _filteredItems
        .where((it) => !_addedModelIds.contains(it.modelId))
        .length;
    return FilledButton(
      onPressed: pendingCount == 0 || _addingAll ? null : _addAllVisible,
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(vertical: 13),
      ),
      child: _addingAll
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : Text(pendingCount == 0 ? '已全部添加' : '添加全部模型（$pendingCount）'),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (widget.mode == AddModelDialogMode.manual) {
      return SingleChildScrollView(
        child: _ManualModelForm(onSubmit: _submitManual),
      );
    }
    if (_liveLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    if (_liveError != null && _currentItems.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _liveError!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _loadLive, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final filtered = _filteredItems;
    if (filtered.isEmpty) {
      final empty = _currentItems.isEmpty;
      final message = !empty ? '没有匹配的模型' : '没有可用模型';
      return _emptyHint(scheme, message);
    }
    return _buildGroupedList(filtered);
  }

  Widget _emptyHint(ColorScheme scheme, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      );

  /// 按分组名折叠展示（可展开/收起 + 组内批量添加），没有分组的条目直接
  /// 平铺在最前面——实时结果、目录和本地模型都走这一套。
  Widget _buildGroupedList(List<_BrowsableItem> filtered) {
    final ungrouped = <_BrowsableItem>[];
    final grouped = <String, List<_BrowsableItem>>{};
    for (final it in filtered) {
      if (it.group.isEmpty) {
        ungrouped.add(it);
      } else {
        grouped.putIfAbsent(it.group, () => <_BrowsableItem>[]).add(it);
      }
    }

    // 显式给每行一个跟 modelId 绑定的 key——不然 ListView 在不带 key 的情况下
    // 按位置复用 Element，列表因为搜索/筛选/添加而重建时，鼠标正悬停的那一
    // 行可能被换了个完全不同的模型，Tooltip 状态跟着挂到错的行上，显示成
    // 别的模型的 modelId(2026-08-27 反馈：hover 显示不对)。
    Widget row(_BrowsableItem item) => _ModelRow(
          key: ValueKey(item.modelId),
          title: item.displayName,
          modelId: item.modelId,
          capabilities: item.capabilities,
          leading: ProviderIcon(
            iconAssetPath: _iconForItem(item),
            name: item.group.isNotEmpty
                ? _groupDisplayLabel(item.group)
                : item.displayName,
            size: 18,
          ),
          added: _addedModelIds.contains(item.modelId),
          pending: _pendingIds.contains(item.modelId),
          onAdd: () => _addItem(item),
        );

    final items = <Widget>[
      for (final it in ungrouped) row(it),
      for (final entry in grouped.entries) ...[
        GroupHeader(
          label: _groupDisplayLabel(entry.key),
          count: entry.value.length,
          collapsed: _collapsedGroups.contains(entry.key),
          onToggle: () => setState(() {
            if (!_collapsedGroups.add(entry.key)) {
              _collapsedGroups.remove(entry.key);
            }
          }),
          trailing: _addingGroups.contains(entry.key)
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : UiIconButton(
                  icon: CupertinoIcons.add,
                  tooltip: '添加本组全部',
                  onTap: () => _addGroup(entry.key, entry.value),
                  size: 26,
                  iconSize: 14,
                ),
        ),
        if (!_collapsedGroups.contains(entry.key))
          for (final it in entry.value)
            Padding(padding: const EdgeInsets.only(left: 18), child: row(it)),
      ],
    ];
    return ListView(shrinkWrap: true, children: items);
  }

  String _groupDisplayLabel(String group) => vendorGroupDisplayLabel(group);

  String? _iconForItem(_BrowsableItem item) {
    final catalog = ref.read(modelCatalogProvider).value;
    if (catalog == null) return null;
    return modelVendorIconAssetPath(
      modelId: item.modelId,
      group: item.group,
      providerCatalogId: widget.provider.catalogId,
      providers: catalog.providers,
    );
  }
}

class _ModelRow extends StatefulWidget {
  const _ModelRow({
    super.key,
    required this.title,
    this.modelId,
    this.capabilities = const <AiModelCapability>{},
    this.leading,
    required this.added,
    required this.pending,
    required this.onAdd,
  });

  final String title;

  /// 只用于 hover tooltip，不再常驻渲染成第二行——列表只显示模型名称，
  /// 完整 modelId 需要的时候鼠标悬停看(2026-08-27 反馈)。
  final String? modelId;
  final Set<AiModelCapability> capabilities;

  /// 行首图标，通常是按分组厂商解出来的 [ProviderIcon]；不传就不占位置。
  final Widget? leading;
  final bool added;
  final bool pending;
  final VoidCallback onAdd;

  @override
  State<_ModelRow> createState() => _ModelRowState();
}

class _ModelRowState extends State<_ModelRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final inheritedTooltipTextStyle = TooltipTheme.of(context).textStyle;
    final modelIdTooltipTextStyle =
        (inheritedTooltipTextStyle ?? theme.textTheme.bodySmall!).copyWith(
      color: inheritedTooltipTextStyle?.color ?? scheme.onInverseSurface,
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final tooltipMessage =
        (widget.modelId != null && widget.modelId != widget.title)
            ? widget.modelId!
            : widget.title;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        decoration: BoxDecoration(
          color: _hovered
              ? scheme.surfaceContainerHighest.withValues(alpha: 0.4)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: Row(
          children: [
            if (widget.leading != null) ...[
              widget.leading!,
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Tooltip(
                  message: tooltipMessage,
                  waitDuration: const Duration(milliseconds: 400),
                  textAlign: TextAlign.left,
                  textStyle: modelIdTooltipTextStyle,
                  // Tooltip 默认取 child 整个 RenderBox 的中心作为锚点；必须让
                  // child 只包住左侧模型名称，不能把 Expanded 的剩余宽度也算
                  // 进去，否则气泡会漂到列表中部。
                  // 列表底部几行下方紧贴着悬浮的"添加全部模型"按钮，默认
                  // preferBelow 只看屏幕边界、不知道按钮的存在，会把气泡盖在
                  // 按钮上；固定显示在上方就不会再撞到它。
                  preferBelow: false,
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
            for (final capability in widget.capabilities)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Tooltip(
                  message: capability.label,
                  preferBelow: false,
                  child: Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: capability.badgeColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      capability.icon,
                      size: 11,
                      color: capability.badgeColor,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 6),
            if (widget.pending)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (widget.added)
              SizedBox(
                height: 24,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.checkmark_alt,
                        size: 15, color: scheme.primary),
                    const SizedBox(width: 4),
                    Text('已添加',
                        style: TextStyle(fontSize: 12, color: scheme.primary)),
                  ],
                ),
              )
            else
              UiIconButton(
                icon: CupertinoIcons.add,
                tooltip: '添加',
                onTap: widget.onAdd,
                size: 24,
                iconSize: 14,
              ),
          ],
        ),
      ),
    );
  }
}

/// 手动填写模型表单，「添加」和「编辑」共用。[onClose] 非空时渲染自带的
/// `UiSheetHeader`（独立弹框场景）；嵌入到 [_AddModelDialog] 里时外层已经
/// 有自己的 header，传 null 跳过。
class _ManualModelForm extends StatefulWidget {
  const _ManualModelForm({this.initial, this.onClose, required this.onSubmit});

  final AiModelConfig? initial;
  final VoidCallback? onClose;
  final ValueChanged<AiModelConfig> onSubmit;

  @override
  State<_ManualModelForm> createState() => _ManualModelFormState();
}

class _ManualModelFormState extends State<_ManualModelForm> {
  late final TextEditingController _modelIdController;
  late final TextEditingController _displayNameController;
  late final TextEditingController _groupController;
  late Set<AiModelCapability> _capabilities;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _modelIdController = TextEditingController(text: initial?.modelId ?? '');
    _displayNameController =
        TextEditingController(text: initial?.displayName ?? '');
    _groupController = TextEditingController(text: initial?.groupName ?? '');
    _capabilities = {...?initial?.capabilities};
  }

  @override
  void dispose() {
    _modelIdController.dispose();
    _displayNameController.dispose();
    _groupController.dispose();
    super.dispose();
  }

  void _submit() {
    final modelId = _modelIdController.text.trim();
    if (modelId.isEmpty) return;
    final displayName = _displayNameController.text.trim();
    final config = AiModelConfig(
      id: widget.initial?.id ?? _uuid.v4(),
      modelId: modelId,
      displayName: displayName.isEmpty ? modelId : displayName,
      groupName: _groupController.text.trim(),
      capabilities: _capabilities,
      enabled: widget.initial?.enabled ?? true,
    );
    widget.onSubmit(config);
    if (widget.initial == null) {
      // 就地新增用完清空，方便连续手动加下一个；编辑态提交后弹框就关了，
      // 不需要清空。
      _modelIdController.clear();
      _displayNameController.clear();
      _groupController.clear();
      setState(() => _capabilities = <AiModelCapability>{});
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editing = widget.initial != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.onClose != null) ...[
          UiSheetHeader(
            title: editing ? '编辑模型' : '手动添加模型',
            onClose: widget.onClose,
          ),
          const SizedBox(height: 14),
        ],
        UiInputField(
          label: '模型标识',
          controller: _modelIdController,
          hintText: '例如 deepseek-chat',
        ),
        const SizedBox(height: 14),
        UiInputField(
          label: '展示名称',
          controller: _displayNameController,
          hintText: '不填则使用模型标识',
        ),
        const SizedBox(height: 14),
        UiInputField(
          label: '分组（可选）',
          controller: _groupController,
          hintText: '例如 deepseek',
        ),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: Text('能力标签',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final capability in AiModelCapability.values)
              _CapabilityChip(
                capability: capability,
                selected: _capabilities.contains(capability),
                onTap: () => setState(() {
                  if (!_capabilities.remove(capability)) {
                    _capabilities.add(capability);
                  }
                }),
              ),
          ],
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(vertical: 13),
          ),
          child: Text(editing ? '保存' : '添加'),
        ),
      ],
    );
  }
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({
    required this.capability,
    required this.selected,
    required this.onTap,
  });

  final AiModelCapability capability;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.10)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.4)
                : scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              capability.icon,
              size: 13,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              capability.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
