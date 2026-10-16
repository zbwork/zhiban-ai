import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_ui/widgets/ui_dropdown_menu.dart';
import 'package:zhiban_ui/widgets/ui_field_style.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';

import 'model_service_constants.dart';
import 'models/ai_provider_config.dart';
import 'providers/model_service_providers.dart';
import 'services/model_catalog_loader.dart';
import 'services/provider_row_order.dart';
import 'widgets/add_provider_dialog.dart';
import 'widgets/provider_detail_panel.dart';
import 'widgets/provider_list_tile.dart';

/// 「模型服务」是独立页面，和「设置」一样通过路由跳转打开，不用 Dialog 承载。
///
/// 桌面端在同一个页面内左右分栏（服务商列表 / 详情）。
class ModelServicePage extends ConsumerWidget {
  const ModelServicePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncProviders = ref.watch(modelProvidersProvider);
    final asyncCatalog = ref.watch(modelCatalogProvider);
    final persistedOrder =
        ref.watch(providerOrderProvider).value ?? const <String>[];
    final catalog = asyncCatalog.value;
    final rows = catalog == null
        ? const <ProviderRow>[]
        : sortProviderRows(
            localProviders: asyncProviders.value ?? const <AiProviderConfig>[],
            catalogProviders: catalog.providers,
            persistedOrder: persistedOrder,
          );

    final selection = ref.watch(selectedModelServiceSelectionProvider);
    final activeIndex = _activeProviderIndex(rows, selection);
    final activeSelection =
        activeIndex < 0 ? null : _selectionForProviderRow(rows[activeIndex]);
    final page = Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: const UiPageBar(title: '模型服务'),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 280,
              child: ModelServiceProviderListPane(
                rows: rows,
                catalog: asyncCatalog,
                activeIndex: activeIndex,
                onSelect: (next) => ref
                    .read(selectedModelServiceSelectionProvider.notifier)
                    .state = next,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: activeSelection == null
                  ? const _EmptyDetailPlaceholder()
                  : buildModelServiceDetailPanel(
                      activeSelection,
                      onMaterialized: (id) => ref
                          .read(selectedModelServiceSelectionProvider.notifier)
                          .state = ModelServiceSelection.local(id),
                    ),
            ),
          ],
        ),
      ),
    );
    return ModelServicePageTheme(child: page);
  }
}

int _activeProviderIndex(
  List<ProviderRow> rows,
  ModelServiceSelection? selection,
) {
  if (rows.isEmpty) return -1;
  if (selection == null) return 0;

  final index = rows.indexWhere((row) {
    if (row.provider != null) return row.provider!.id == selection.localId;
    return selection.localId == null &&
        row.catalogEntry!.id == selection.catalogEntry?.id;
  });
  return index < 0 ? 0 : index;
}

ModelServiceSelection _selectionForProviderRow(ProviderRow row) {
  if (row.provider != null) {
    return ModelServiceSelection.local(row.provider!.id);
  }
  return ModelServiceSelection.draft(row.catalogEntry!);
}

Widget buildModelServiceDetailPanel(
  ModelServiceSelection selection, {
  required ValueChanged<String> onMaterialized,
}) {
  return selection.localId != null
      ? ProviderDetailPanel.existing(
          providerId: selection.localId!,
          onMaterialized: onMaterialized,
        )
      : ProviderDetailPanel.draft(
          catalogEntry: selection.catalogEntry!,
          onMaterialized: onMaterialized,
        );
}

/// 模型服务页使用中性灰界面主色，避免与各服务商自身的品牌色竞争。
/// 描边直接复用搜索框的默认边框 token，保持亮色/暗色主题安全。
class ModelServicePageTheme extends StatelessWidget {
  const ModelServicePageTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accentColor = scheme.onSurfaceVariant;
    final lineColor = UiFieldStyle.enabledBorderColor(scheme);
    final disabledColor = scheme.onSurface.withValues(alpha: 0.38);
    final disabledLineColor = UiFieldStyle.disabledBorderColor(scheme);

    WidgetStateProperty<Color?> foregroundColor() =>
        WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.disabled)
              ? disabledColor
              : accentColor;
        });

    final outlinedStyle =
        (theme.outlinedButtonTheme.style ?? const ButtonStyle()).copyWith(
      foregroundColor: foregroundColor(),
      side: WidgetStateProperty.resolveWith((states) {
        return BorderSide(
          color: states.contains(WidgetState.disabled)
              ? disabledLineColor
              : lineColor,
        );
      }),
    );
    final textStyle =
        (theme.textButtonTheme.style ?? const ButtonStyle()).copyWith(
      foregroundColor: foregroundColor()
    );

    return Theme(
      data: theme.copyWith(
        colorScheme: scheme.copyWith(
          primary: accentColor,
          onPrimary: scheme.surface,
          primaryContainer: scheme.surfaceContainerHighest,
          onPrimaryContainer: scheme.onSurface,
          outline: lineColor,
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(style: outlinedStyle),
        textButtonTheme: TextButtonThemeData(style: textStyle),
      ),
      child: child,
    );
  }
}

class ModelServiceProviderListPane extends ConsumerStatefulWidget {
  const ModelServiceProviderListPane({
    super.key,
    required this.rows,
    required this.catalog,
    required this.activeIndex,
    required this.onSelect,
    this.allowReorder = true,
  });

  final List<ProviderRow> rows;
  final AsyncValue<ModelCatalog> catalog;
  final int activeIndex;
  final ValueChanged<ModelServiceSelection> onSelect;
  final bool allowReorder;

  @override
  ConsumerState<ModelServiceProviderListPane> createState() =>
      _ModelServiceProviderListPaneState();
}

enum _ProviderFilter {
  all('全部服务商'),
  enabledOnly('仅已启用'),
  disabledOnly('仅已禁用');

  const _ProviderFilter(this.label);
  final String label;
}

class _ModelServiceProviderListPaneState
    extends ConsumerState<ModelServiceProviderListPane> {
  String _query = '';
  _ProviderFilter _filter = _ProviderFilter.all;

  Widget _buildDragProxy(
    Widget child,
    int index,
    Animation<double> animation
  ) {
    assert(index >= 0);
    assert(animation.value >= 0 && animation.value <= 1);
    return Material(
      type: MaterialType.transparency,
      child: child
    );
  }

  bool _matchesFilter(bool enabled) {
    switch (_filter) {
      case _ProviderFilter.all:
        return true;
      case _ProviderFilter.enabledOnly:
        return enabled;
      case _ProviderFilter.disabledOnly:
        return !enabled;
    }
  }

  /// 「添加服务商」只用于目录之外的自定义地址——目录里的厂商本来就常驻列表。
  Future<void> _addCustomProvider() async {
    final input = await showAddProviderDialog(context);
    if (input == null) return;
    final created = await ref.read(modelProvidersProvider.notifier).addProvider(
          name: input.name,
          baseUrl: input.baseUrl
        );
    widget.onSelect(ModelServiceSelection.local(created.id));
  }

  @override
  Widget build(BuildContext context) {
    bool rowEnabled(ProviderRow row) => row.enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: UiSearchField(
            height: kModelServiceFieldHeight,
            hintText: '搜索模型平台...',
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
            trailing: UiDropdownMenu<_ProviderFilter>(
              items: [
                for (final filter in _ProviderFilter.values)
                  UiDropdownMenuItem(value: filter, label: filter.label),
              ],
              activeValue: _filter,
              onSelected: (value) => setState(() => _filter = value),
              hoverRadius: 6,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  CupertinoIcons.line_horizontal_3_decrease_circle,
                  size: 18,
                  color: _filter == _ProviderFilter.all
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: widget.catalog.when(
            loading: () => const Center(child: CupertinoActivityIndicator()),
            error: (error, _) => Center(child: Text('目录加载失败：$error')),
            data: (_) {
              final allRows = widget.rows;
              final query = _query;
              final visibleRows = allRows.indexed
                  .where((item) =>
                      (query.isEmpty ||
                          item.$2.name.toLowerCase().contains(query)) &&
                      _matchesFilter(rowEnabled(item.$2)))
                  .toList();

              if (visibleRows.isEmpty) {
                return Center(
                  child: Text(
                    _filter == _ProviderFilter.all
                        ? '没有匹配的服务商'
                        : '没有符合筛选条件的服务商',
                    style:
                        const TextStyle(fontSize: 12, color: Color(0xFF98A2B3)),
                  ),
                );
              }

              // 搜索/筛选生效时列表只是全量的一个子集，这时候拖动没法直接
              // 对应到完整顺序里的位置，索性禁用拖动，只在"全部服务商"且
              // 没搜索时才允许拖（2026-08-27 反馈：默认已启用放前面，用户
              // 可拖动改）。
              final reorderable = widget.allowReorder &&
                  query.isEmpty &&
                  _filter == _ProviderFilter.all;

              Widget tile(
                int index,
                ProviderRow row, {
                Widget? dragHandle
              }) =>
                  ProviderListTile(
                    key: ValueKey(row.key),
                    name: row.name,
                    iconAssetPath: row.iconAssetPath,
                    enabled: rowEnabled(row),
                    selected: index == widget.activeIndex,
                    pressedFeedback: !widget.allowReorder,
                    dragHandle: dragHandle,
                    onTap: () => widget.onSelect(_selectionForProviderRow(row)),
                  );

              if (!reorderable) {
                return ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final item in visibleRows) tile(item.$1, item.$2),
                  ],
                );
              }

              return ReorderableListView.builder(
                padding: const EdgeInsets.only(bottom: 8),
                buildDefaultDragHandles: false,
                proxyDecorator: _buildDragProxy,
                itemCount: visibleRows.length,
                itemBuilder: (context, index) => tile(
                  visibleRows[index].$1,
                  visibleRows[index].$2,
                  dragHandle: Listener(
                    key: ValueKey('provider-reorder-handle-$index'),
                    onPointerDown: (_) => ref
                        .read(modelServiceReorderGestureProvider.notifier)
                        .state = true,
                    onPointerUp: (_) => ref
                        .read(modelServiceReorderGestureProvider.notifier)
                        .state = false,
                    onPointerCancel: (_) => ref
                        .read(modelServiceReorderGestureProvider.notifier)
                        .state = false,
                    child: ReorderableDragStartListener(
                      index: index,
                      child: const Icon(Icons.drag_indicator,
                          size: 16, color: Color(0xFF98A2B3)),
                    ),
                  ),
                ),
                onReorder: (oldIndex, newIndex) {
                  // 顺序完全自由（照抄 Cherry Studio：启用状态跟排序无关），
                  // 拖到哪就是哪，不再需要按启用分区夹落点。
                  var target = newIndex;
                  if (target > oldIndex) target -= 1;
                  final rows = [for (final item in visibleRows) item.$2];
                  final moved = rows.removeAt(oldIndex);
                  rows.insert(target, moved);
                  final selection =
                      ref.read(selectedModelServiceSelectionProvider);
                  if (selection == null &&
                      widget.activeIndex >= 0 &&
                      widget.activeIndex < widget.rows.length) {
                    ref
                        .read(selectedModelServiceSelectionProvider.notifier)
                        .state = _selectionForProviderRow(
                      widget.rows[widget.activeIndex],
                    );
                  }
                  ref
                      .read(providerOrderProvider.notifier)
                      .setOrder([for (final row in rows) row.key]);
                },
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: OutlinedButton.icon(
            onPressed: _addCustomProvider,
            icon: const Icon(CupertinoIcons.add, size: 16),
            label: const Text('添加服务商'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(40),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyDetailPlaceholder extends StatelessWidget {
  const _EmptyDetailPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        '从左侧选择一个服务商查看详情',
        style: TextStyle(fontSize: 13, color: Color(0xFF98A2B3)),
      ),
    );
  }
}
