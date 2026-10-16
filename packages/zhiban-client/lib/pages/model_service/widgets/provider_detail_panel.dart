import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_ui/widgets/ui_field_style.dart';
import 'package:zhiban_ui/widgets/ui_icon_button.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_ui/widgets/ui_segmented_tabs.dart';
import 'package:zhiban_ui/widgets/ui_switch.dart';

import '../model_service_constants.dart';
import '../models/ai_endpoint_type.dart';
import '../models/ai_model_config.dart';
import '../models/ai_provider_config.dart';
import '../models/catalog_entry.dart';
import '../providers/model_service_providers.dart';
import '../services/model_modality_classifier.dart';
import '../services/provider_key_tester.dart';
import '../services/provider_model_fetcher.dart';
import '../services/vendor_group_display.dart';
import 'add_model_dialog.dart';
import 'add_provider_dialog.dart' show ProviderIcon;
import 'group_header.dart';
import 'model_list_item.dart';
import '../providers/managed_model_service_provider.dart';
import 'request_config_dialog.dart';

/// Provider 详情面板：改名/开关/API Key/API 地址/模型列表增删。
///
/// 两种入口：
/// - [ProviderDetailPanel.existing]：本地已经落地过配置，直接编辑。
/// - [ProviderDetailPanel.draft]：用户刚点开目录里的厂商，还没做任何配置
///   动作，本地压根没有这条记录——只是拿目录数据渲染表单。只有用户真的执行
///   一次保存/启用/添加模型，才会调用 [ModelProvidersNotifier.materializeFromCatalog]
///   把草稿落成本地记录；纯浏览不会写入任何存储。
///
/// 模型列表与密钥探测按内置目录的只读协议元数据执行；自定义服务商统一按
/// OpenAI-compatible 处理，不提供用户可编辑的协议类型。
class ProviderDetailPanel extends ConsumerStatefulWidget {
  const ProviderDetailPanel.existing({
    super.key,
    required String this.providerId,
    required this.onMaterialized,
  }) : catalogEntry = null;

  const ProviderDetailPanel.draft({
    super.key,
    required CatalogProviderEntry this.catalogEntry,
    required this.onMaterialized,
  }) : providerId = null;

  final String? providerId;
  final CatalogProviderEntry? catalogEntry;

  /// 草稿第一次真正落地成本地记录时回调新 id，供上层（桌面分栏）把选中态从
  /// "草稿" 切到 "本地记录"，下次再点同一个厂商就直接复用而不是再问一次。
  final ValueChanged<String> onMaterialized;

  @override
  ConsumerState<ProviderDetailPanel> createState() =>
      _ProviderDetailPanelState();
}

class _ProviderDetailPanelState extends ConsumerState<ProviderDetailPanel> {
  final _apiKeyController = TextEditingController();
  late final TextEditingController _baseUrlController;
  final _modelSearchController = TextEditingController();
  final _apiKeyFocusNode = FocusNode();
  final _baseUrlFocusNode = FocusNode();
  final _modelSearchFocusNode = FocusNode();
  bool _obscureApiKey = true;
  bool _loadingKey = true;
  bool _testingKey = false;
  bool _modelSearchOpen = false;
  bool _modelFilterOpen = false;
  String _modelQuery = '';
  ModelModality? _modelModalityFilter;
  String? _localId;
  String _lastSavedApiKey = '';
  int _keyLoadRevision = 0;
  final Set<String> _collapsedModelGroups = <String>{};

  String get _selectionIdentity =>
      widget.providerId ?? 'catalog:${widget.catalogEntry!.id}';

  @override
  void initState() {
    super.initState();
    _baseUrlController = TextEditingController();
    _localId = widget.providerId;
    _loadKey();
    // 失焦即保存：用户填完字段点到别处，就当作一次确认提交，不需要额外的
    // "保存" 按钮。
    _apiKeyFocusNode.addListener(() {
      if (!_apiKeyFocusNode.hasFocus) {
        _saveApiKey(
          showConfirmation: !ref.read(modelServiceReorderGestureProvider),
        );
      }
    });
    _baseUrlFocusNode.addListener(() {
      if (!_baseUrlFocusNode.hasFocus) _saveBaseUrl();
    });
    _modelSearchFocusNode.addListener(_handleModelSearchFocusChange);
  }

  @override
  void didUpdateWidget(covariant ProviderDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIdentity =
        oldWidget.providerId ?? 'catalog:${oldWidget.catalogEntry!.id}';
    if (oldIdentity != _selectionIdentity) {
      _localId = widget.providerId;
      _obscureApiKey = true;
      _baseUrlController.text = '';
      _modelSearchController.clear();
      _modelSearchOpen = false;
      _modelFilterOpen = false;
      _modelQuery = '';
      _modelModalityFilter = null;
      _loadKey();
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelSearchController.dispose();
    _apiKeyFocusNode.dispose();
    _baseUrlFocusNode.dispose();
    _modelSearchFocusNode
      ..removeListener(_handleModelSearchFocusChange)
      ..dispose();
    super.dispose();
  }

  void _handleModelSearchFocusChange() {
    if (_modelSearchFocusNode.hasFocus || !_modelSearchOpen || !mounted) return;
    _modelSearchController.clear();
    setState(() {
      _modelQuery = '';
      _modelSearchOpen = false;
    });
  }

  void _openModelSearch() {
    setState(() => _modelSearchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _modelSearchFocusNode.requestFocus();
    });
  }

  List<AiModelConfig> _visibleModels(List<AiModelConfig> models) {
    return [
      for (final model in models)
        if ((_modelQuery.isEmpty ||
                model.displayName.toLowerCase().contains(_modelQuery) ||
                model.modelId.toLowerCase().contains(_modelQuery)) &&
            (_modelModalityFilter == null ||
                classifyModelId(model.modelId) == _modelModalityFilter))
          model,
    ];
  }

  bool get _isManaged =>
      widget.catalogEntry?.id == 'beebridge' ||
      (_localId != null &&
          _findLocalProvider(_localId!)?.catalogId == 'beebridge');

  Future<void> _refreshManaged() async {
    final selection = _selectionIdentity;
    setState(() => _testingKey = true);
    try {
      final status = await ref.refresh(managedModelServiceProvider.future);
      if (!mounted || selection != _selectionIdentity) return;
      if (!status.keyReady || status.status != 'ready') {
        BotToast.showText(text: '检测失败：${status.message}');
        return;
      }
      final key = await ref.read(managedModelKeyProvider.future);
      if (!mounted || selection != _selectionIdentity) return;
      BotToast.showText(
        text: key.trim().isEmpty ? '检测失败：未读取到 API 密钥' : '检测成功，密钥可用',
      );
    } catch (_) {
      if (mounted && selection == _selectionIdentity) {
        BotToast.showText(text: '检测失败，请检查连接后重试');
      }
    } finally {
      if (mounted) setState(() => _testingKey = false);
    }
  }

  Future<void> _loadKey() async {
    final revision = ++_keyLoadRevision;
    // A reused panel must never save the previous provider's text on blur.
    _apiKeyController.clear();
    _lastSavedApiKey = '';
    if (_isManaged) {
      _apiKeyController.clear();
      _lastSavedApiKey = '';
      _loadingKey = false;
      return;
    }
    final id = _localId;
    if (id == null) {
      setState(() {
        _apiKeyController.text = '';
        _lastSavedApiKey = '';
        _loadingKey = false;
      });
      return;
    }
    setState(() => _loadingKey = true);
    final key = await ref.read(modelProvidersProvider.notifier).readApiKey(id);
    if (!mounted ||
        revision != _keyLoadRevision ||
        _localId != id ||
        _isManaged) {
      return;
    }
    setState(() {
      _apiKeyController.text = key ?? '';
      _lastSavedApiKey = (key ?? '').trim();
      _loadingKey = false;
    });
  }

  AiProviderConfig? _findLocalProvider(String id) {
    final providers = ref.read(modelProvidersProvider).value ?? const [];
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 本地已有这条记录就直接用；第一次真正需要落地时才创建。
  Future<String> _ensureLocalId() async {
    final existing = _localId;
    if (existing != null) return existing;
    final createdId = await ref
        .read(modelProvidersProvider.notifier)
        .materializeFromCatalog(widget.catalogEntry!);
    if (!mounted) return createdId;
    setState(() => _localId = createdId);
    widget.onMaterialized(createdId);
    return createdId;
  }

  /// 只在值真的变了才落地——避免"只是点进字段又点出去，什么都没改"也触发
  /// 草稿落地或产生一次没有意义的保存提示。
  Future<void> _saveApiKey({bool showConfirmation = true}) async {
    if (_isManaged || _loadingKey) return;
    final revision = _keyLoadRevision;
    final next = _apiKeyController.text.trim();
    if (next == _lastSavedApiKey) return;
    final id = await _ensureLocalId();
    if (!mounted || revision != _keyLoadRevision) return;
    await ref.read(modelProvidersProvider.notifier).setApiKey(id, next);
    if (!mounted || revision != _keyLoadRevision) return;
    _lastSavedApiKey = next;
    if (showConfirmation) BotToast.showText(text: 'API 密钥已保存');
  }

  Future<void> _saveBaseUrl() async {
    if (_isManaged) return;
    final next = _baseUrlController.text.trim();
    if (next == _displayProvider.baseUrl) return;
    final id = await _ensureLocalId();
    final current = _findLocalProvider(id);
    if (current == null) return;
    await ref
        .read(modelProvidersProvider.notifier)
        .updateProvider(current.copyWith(baseUrl: next));
  }

  Future<void> _testApiKey() async {
    if (_isManaged) return _refreshManaged();
    final provider = _displayProvider;
    final apiKey = _apiKeyController.text.trim();
    setState(() => _testingKey = true);
    final result = await const ProviderKeyTester().test(
      endpointType: _endpointTypeFor(provider),
      baseUrl: _baseUrlController.text.trim(),
      apiKey: apiKey,
    );
    if (!mounted) return;
    setState(() => _testingKey = false);
    BotToast.showText(text: result.message);
  }

  Future<void> _onEnabledChanged(bool value) async {
    final id = await _ensureLocalId();
    await ref
        .read(modelProvidersProvider.notifier)
        .setProviderEnabled(id, value);
  }

  /// 「添加模型」抽屉的两个独立触发入口（照抄 Cherry Studio 服务商详情页
  /// 的“拉取”+“+”按钮布局，2026-09-03 反馈）：默认打开统一模型列表并自动
  /// 获取实时结果并剔除失效配置；`manual` 直接落到手动填表单。
  Future<void> _addModel({
    AddModelDialogMode mode = AddModelDialogMode.browse,
  }) async {
    final selection = _selectionIdentity;
    if (_isManaged && mode == AddModelDialogMode.manual) {
      try {
        final key = await ref.read(managedModelKeyProvider.future);
        if (!mounted || selection != _selectionIdentity) return;
        if (key.trim().isEmpty) {
          BotToast.showText(text: '请先检测 API 密钥');
          return;
        }
        _apiKeyController.text = key;
      } catch (_) {
        if (mounted && selection == _selectionIdentity) {
          BotToast.showText(text: '密钥读取失败，请先检测');
        }
        return;
      }
    }
    final provider = _displayProvider;
    final catalogId = _localId != null
        ? _findLocalProvider(_localId!)?.catalogId
        : widget.catalogEntry?.id;
    final catalog = ref.read(modelCatalogProvider).value;
    final catalogModels = catalogId == null || catalog == null
        ? const <CatalogModelEntry>[]
        : catalog.modelsFor(catalogId);
    await showAddModelDialog(
      context,
      provider: provider,
      endpointType: _endpointTypeFor(provider),
      catalogModels: catalogModels,
      apiKey: _apiKeyController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
      ensureLocalId: _ensureLocalId,
      mode: mode,
    );
  }

  Future<void> _editModel(AiModelConfig model) async {
    final id = _localId;
    if (id == null) return;
    final updated = await showEditModelDialog(context, model);
    if (updated == null) return;
    await ref.read(modelProvidersProvider.notifier).updateModel(id, updated);
  }

  AiProviderConfig get _displayProvider {
    final id = _localId;
    if (id != null) {
      final live = ref.watch(modelProvidersProvider).value;
      if (live != null) {
        for (final p in live) {
          if (p.id == id) return p;
        }
      }
    }
    final entry = widget.catalogEntry!;
    return AiProviderConfig(
      id: '',
      name: entry.name,
      baseUrl: entry.baseUrl,
      catalogId: entry.id,
    );
  }

  AiEndpointType _endpointTypeFor(AiProviderConfig provider) {
    final selectedCatalogEntry = widget.catalogEntry;
    if (selectedCatalogEntry != null &&
        selectedCatalogEntry.id == provider.catalogId) {
      return selectedCatalogEntry.endpointType;
    }
    final catalog = ref.read(modelCatalogProvider).value;
    return catalog?.endpointTypeFor(provider) ??
        AiEndpointType.openaiCompatible;
  }

  String? _catalogIconFor(AiProviderConfig provider) {
    final catalogId = provider.catalogId ?? widget.catalogEntry?.id;
    if (catalogId == null) return null;
    if (widget.catalogEntry?.id == catalogId) {
      return widget.catalogEntry!.iconAssetPath;
    }
    final catalog = ref.watch(modelCatalogProvider).value;
    if (catalog == null) return null;
    for (final entry in catalog.providers) {
      if (entry.id == catalogId) return entry.iconAssetPath;
    }
    return null;
  }

  /// 已添加模型列表与添加抽屉共用 modelId 家族、分组、当前 Provider 三层
  /// 图标回退，避免服务端分组名与图标 key 不一致时退回首字母
  /// (2026-08-27 反馈：已添加的模型也要有图标)。
  String? _modelIconFor(AiModelConfig model, AiProviderConfig provider) {
    final catalog = ref.watch(modelCatalogProvider).value;
    if (catalog != null) {
      final icon = modelVendorIconAssetPath(
        modelId: model.modelId,
        group: model.groupName,
        providerCatalogId: provider.catalogId ?? widget.catalogEntry?.id,
        providers: catalog.providers,
      );
      if (icon != null) return icon;
    }
    return _catalogIconFor(provider);
  }

  /// 已添加模型按分组折叠展示，跟"添加模型"抽屉同一套视觉（[GroupHeader] +
  /// 缩进），没有分组的条目直接平铺在最前面
  /// (2026-08-27 反馈：已添加列表也要跟添加模型抽屉一样按分组展示)。
  Widget _buildModelList(
    AiProviderConfig provider,
    List<AiModelConfig> visibleModels,
  ) {
    final ungrouped = <AiModelConfig>[];
    final grouped = <String, List<AiModelConfig>>{};
    for (final model in visibleModels) {
      if (model.groupName.isEmpty) {
        ungrouped.add(model);
      } else {
        grouped
            .putIfAbsent(model.groupName, () => <AiModelConfig>[])
            .add(model);
      }
    }
    // 已启用的模型排在同一分组内的前面 (2026-08-31 反馈：启用状态必须体现在
    // 排序上，不是纯展示态)。手写稳定分区而不用 List.sort——Dart 的
    // List.sort 不保证稳定，用它会让同一 enabled 状态内的相对顺序随机跳动。
    List<AiModelConfig> byEnabledFirst(List<AiModelConfig> models) => [
          for (final m in models)
            if (m.enabled) m,
          for (final m in models)
            if (!m.enabled) m,
        ];
    final sortedUngrouped = byEnabledFirst(ungrouped);
    final sortedGrouped = {
      for (final entry in grouped.entries)
        entry.key: byEnabledFirst(entry.value),
    };

    // 只有最后一个实际显示的模型行会紧贴外层容器底边；该行不再额外画内部
    // 分隔线，避免与容器底边叠加成截图中的深色粗线。若末组已折叠，底部是
    // GroupHeader，不需要改前面模型行的分隔线。
    AiModelConfig? trailingModel;
    if (sortedGrouped.isEmpty) {
      trailingModel = sortedUngrouped.isEmpty ? null : sortedUngrouped.last;
    } else {
      final lastGroup = sortedGrouped.entries.last;
      if (_modelQuery.isNotEmpty ||
          !_collapsedModelGroups.contains(lastGroup.key)) {
        trailingModel = lastGroup.value.last;
      }
    }

    Widget row(AiModelConfig model) => ModelListItem(
          key: ValueKey(model.id),
          model: model,
          showBottomDivider: model.id != trailingModel?.id,
          leading: _ModelAvatar(
            iconAssetPath: _modelIconFor(model, provider),
            name: model.groupName.isNotEmpty
                ? model.groupName
                : model.displayName,
          ),
          onEdit: () => _editModel(model),
          onRemove: () {
            final id = _localId;
            if (id == null) return;
            ref.read(modelProvidersProvider.notifier).removeModel(id, model.id);
          },
        );

    return Column(
      children: [
        for (final model in sortedUngrouped) row(model),
        for (final entry in sortedGrouped.entries) ...[
          GroupHeader(
            label: vendorGroupDisplayLabel(entry.key),
            filled: true,
            collapsed: _modelQuery.isEmpty &&
                _collapsedModelGroups.contains(entry.key),
            onToggle: () => setState(() {
              if (!_collapsedModelGroups.add(entry.key)) {
                _collapsedModelGroups.remove(entry.key);
              }
            }),
          ),
          if (_modelQuery.isNotEmpty ||
              !_collapsedModelGroups.contains(entry.key))
            for (final model in entry.value) row(model),
        ],
      ],
    );
  }

  String? _catalogDocsUrlFor(AiProviderConfig provider) =>
      _resolveCatalogEntry(provider)?.docsUrl;

  CatalogProviderEntry? _resolveCatalogEntry(AiProviderConfig provider) {
    final catalogId = provider.catalogId ?? widget.catalogEntry?.id;
    if (catalogId == null) return null;
    if (widget.catalogEntry?.id == catalogId) return widget.catalogEntry;
    final catalog = ref.watch(modelCatalogProvider).value;
    if (catalog == null) return null;
    for (final entry in catalog.providers) {
      if (entry.id == catalogId) return entry;
    }
    return null;
  }

  Widget _buildModelSearch(bool hasModels) {
    if (_modelSearchOpen || _modelQuery.isNotEmpty) {
      return SizedBox(
        width: 144,
        child: UiSearchField(
          key: const ValueKey('provider-model-search'),
          controller: _modelSearchController,
          focusNode: _modelSearchFocusNode,
          height: 28,
          borderRadius: 8,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          hintText: '搜索模型...',
          enabled: hasModels,
          onChanged: (value) => setState(
            () => _modelQuery = value.trim().toLowerCase()
          ),
          onClear: () => setState(() => _modelSearchOpen = false),
        ),
      );
    }
    return UiIconButton(
      icon: CupertinoIcons.search,
      tooltip: '搜索模型',
      enabled: hasModels,
      onTap: _openModelSearch,
      size: 22,
      iconSize: 13,
    );
  }

  Widget _buildModelFilterButton(ColorScheme scheme, bool hasModels) {
    final active = _modelFilterOpen || _modelModalityFilter != null;
    return Container(
      decoration: BoxDecoration(
        color: active ? scheme.primary.withValues(alpha: 0.10) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: UiIconButton(
        icon: CupertinoIcons.line_horizontal_3_decrease,
        tooltip: '筛选模型',
        enabled: hasModels,
        onTap: () => setState(() => _modelFilterOpen = !_modelFilterOpen),
        size: 22,
        iconSize: 13,
        color: active ? scheme.primary : null,
      ),
    );
  }

  Widget _buildModelFilterTabs(
    ColorScheme scheme,
    List<AiModelConfig> models
  ) {
    final counts = <ModelModality, int>{};
    for (final model in models) {
      final modality = classifyModelId(model.modelId);
      counts[modality] = (counts[modality] ?? 0) + 1;
    }
    return UiSegmentedTabs<ModelModality?>(
      groupId: 'provider-model-filter-$_selectionIdentity',
      current: _modelModalityFilter,
      onChanged: (value) => setState(() => _modelModalityFilter = value),
      height: 32,
      fontSize: 12,
      segmentPadding: const EdgeInsets.symmetric(horizontal: 10),
      trackColor: scheme.surfaceContainerHighest.withValues(alpha: 0.56),
      activeColor: scheme.primary,
      inactiveColor: scheme.onSurfaceVariant.withValues(alpha: 0.9),
      tabs: [
        UiSegmentedTab(value: null, label: '全部 ${models.length}'),
        for (final modality in ModelModality.values)
          UiSegmentedTab(
            value: modality,
            label: '${modality.label} ${counts[modality] ?? 0}',
            icon: modality.icon,
          ),
      ],
    );
  }

  Future<void> _openExternalUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      BotToast.showText(text: '无法打开链接');
    }
  }

  @override
  Widget build(BuildContext context) {
    var provider = _displayProvider;
    final managed = provider.catalogId == 'beebridge' ||
        widget.catalogEntry?.id == 'beebridge';
    final managedState =
        managed ? ref.watch(managedModelServiceProvider) : null;
    final managedKey = managed ? ref.watch(managedModelKeyProvider) : null;
    if (managed) {
      provider = provider.copyWith(
        baseUrl: _resolveCatalogEntry(provider)?.baseUrl ?? provider.baseUrl,
      );
      final key = managedKey?.isLoading == false && !managedKey!.hasError
          ? managedKey.value ?? ''
          : '';
      if (_apiKeyController.text != key) {
        _apiKeyController.text = key;
        _obscureApiKey = true;
      }
    }
    final visibleModels = _visibleModels(provider.models);
    if (_baseUrlController.text != provider.baseUrl &&
        !_baseUrlController.value.selection.isValid) {
      _baseUrlController.text = provider.baseUrl;
    }
    final docsUrl = _catalogDocsUrlFor(provider);
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProviderIcon(
                iconAssetPath: _catalogIconFor(provider),
                name: provider.name,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  provider.name,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              UiSwitch(
                value: provider.enabled,
                onChanged: _onEnabledChanged,
                width: 44,
                height: 26,
                toggleSize: 20,
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'API 密钥',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _ApiKeyField(
                  controller: _apiKeyController,
                  focusNode: _apiKeyFocusNode,
                  enabled: managed || !_loadingKey,
                  readOnly: managed,
                  hintText: managed
                      ? (managedState?.isLoading == true ||
                              managedKey?.isLoading == true
                          ? '读取中…'
                          : managedKey?.hasError == true
                              ? '密钥读取失败，请点击检测'
                              : '未初始化，请点击检测')
                      : (_loadingKey ? '读取中…' : '输入 API 密钥'),
                  obscure: _obscureApiKey,
                  onToggleObscure: () =>
                      setState(() => _obscureApiKey = !_obscureApiKey),
                  onSubmitted: (_) => _saveApiKey(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: kModelServiceFieldHeight,
                child: OutlinedButton(
                  onPressed: _testingKey || managedState?.isLoading == true
                      ? null
                      : _testApiKey,
                  style: OutlinedButton.styleFrom(
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        UiFieldStyle.defaultBorderRadius,
                      ),
                    ),
                  ),
                  child: _testingKey
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('检测'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text(
                'API 地址',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(CupertinoIcons.gear_alt, size: 15),
                tooltip: '请求配置',
                onPressed: () => showRequestConfigDialog(
                  context,
                  provider: provider,
                  ensureLocalId: _ensureLocalId,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          UiInputField(
            height: kModelServiceFieldHeight,
            controller: _baseUrlController,
            focusNode: _baseUrlFocusNode,
            readOnly: managed,
            hintText: 'https://api.example.com',
            onSubmitted: (_) => _saveBaseUrl(),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        '已配置模型（${provider.models.length}）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    if (docsUrl != null)
                      UiIconButton(
                        icon: CupertinoIcons.doc_text,
                        tooltip: '查看官方文档',
                        onTap: () => _openExternalUrl(docsUrl),
                        size: 22,
                        iconSize: 13,
                      ),
                    if (PlatformUtils.isDesktop) ...[
                      Flexible(
                        child: _buildModelSearch(provider.models.isNotEmpty),
                      ),
                      _buildModelFilterButton(
                        scheme,
                        provider.models.isNotEmpty,
                      ),
                    ],
                  ],
                ),
              ),
              if (const ProviderModelFetcher().supports(
                _endpointTypeFor(_displayProvider),
                catalogId: _displayProvider.catalogId,
              ))
                TextButton.icon(
                  onPressed: _addModel,
                  icon: const Icon(CupertinoIcons.refresh, size: 14),
                  label: const Text('获取模型列表'),
                ),
              UiIconButton(
                icon: CupertinoIcons.add,
                tooltip: '添加模型',
                onTap: () => _addModel(mode: AddModelDialogMode.manual),
                size: 28,
                iconSize: 15,
              ),
            ],
          ),
          if (PlatformUtils.isDesktop &&
              _modelFilterOpen &&
              provider.models.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildModelFilterTabs(scheme, provider.models),
          ],
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: provider.models.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Center(
                      child: Text(
                        '还没有配置模型，点右上角「添加模型」新增',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : visibleModels.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: Center(
                          child: Text(
                            '没有匹配的模型',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : _buildModelList(provider, visibleModels),
          ),
        ],
      ),
    );
  }
}

/// API 密钥输入框：`UiInputField` 目前不支持 `obscureText`，这里单独用一个
/// `TextField` 实现真正的遮蔽显示，视觉上尽量对齐 `UiInputField` 的边框/圆角规范。
class _ApiKeyField extends StatelessWidget {
  const _ApiKeyField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.hintText,
    required this.obscure,
    required this.onToggleObscure,
    required this.onSubmitted,
    this.readOnly = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final String hintText;
  final bool obscure;
  final VoidCallback? onToggleObscure;
  final bool readOnly;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: kModelServiceFieldHeight,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        readOnly: readOnly,
        obscureText: obscure,
        onSubmitted: onSubmitted,
        style: TextStyle(fontSize: 14, color: scheme.onSurface),
        decoration: InputDecoration(
          isDense: true,
          hintText: hintText,
          hintStyle: TextStyle(
            fontSize: 14,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                BorderSide(color: scheme.primary.withValues(alpha: 0.45)),
          ),
          suffixIcon: IconButton(
            tooltip: obscure ? '显示密钥' : '隐藏密钥',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              obscure ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
              size: 16,
            ),
            onPressed: onToggleObscure,
          ),
        ),
      ),
    );
  }
}

/// 已添加模型行首的圆形 Logo 底——参考截图里 MiniMax/Claude 那种"白底圆圈裹
/// 品牌图标"的样式，跟 [ProviderIcon] 在别处（侧栏、添加模型抽屉）用的圆角
/// 方形裁切不一样，只在这个列表单独套一层圆形容器，不改 [ProviderIcon] 本身
/// 影响别处(2026-08-27 反馈：参考截图样式)。
class _ModelAvatar extends StatelessWidget {
  const _ModelAvatar({required this.iconAssetPath, required this.name});

  final String? iconAssetPath;
  final String name;

  static const double _size = 30;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: _size,
      height: _size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: ClipOval(
        child: ProviderIcon(iconAssetPath: iconAssetPath, name: name, size: 22),
      ),
    );
  }
}
