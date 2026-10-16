import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui_field_style.dart';
import 'ui_search_field.dart';
import 'ui_segmented_tabs.dart';

class UiSelectOption<T> {
  const UiSelectOption(
      {required this.value,
      required this.label,
      this.icon,
      this.group,
      this.description = ''});

  final T value;
  final String label;
  final IconData? icon;
  final String? group;
  final String description;
}

/// 选择控件：与输入框（UiInput/UiSearchField）共用同一套视觉语言。
///
/// 边框/填充/文字色全部取自 [ColorScheme]（暗黑模式安全），由「下拉是否展开」
/// (_expanded) 驱动：
///   - 展开：primary 边框
///   - hover：primary 浅边框 + hover 填充
///   - 收起：outlineVariant 边框
///
/// 注意：选中项通过 `T ==` 判断。若 [T] 是自定义类，需重写 `==` 和 `hashCode`，
/// 否则选中高亮将静默失效。
class UiSelect<T> extends StatefulWidget {
  const UiSelect({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.placeholder = '请选择',
    this.enabled = true,
    this.borderRadius,
    this.menuMaxHeight = 260,
    this.height,
    this.groupTabs = const [],
    this.searchPlaceholder = '搜索选项...',
  });

  final List<UiSelectOption<T>> options;
  final T? value;
  final ValueChanged<T?> onChanged;
  final String placeholder;
  final bool enabled;
  final double? borderRadius;
  final double menuMaxHeight;
  final double? height;
  final List<String> groupTabs;
  final String searchPlaceholder;

  @override
  State<UiSelect<T>> createState() => _UiSelectState<T>();
}

class _UiSelectState<T> extends State<UiSelect<T>> {
  final LayerLink _layerLink = LayerLink();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _listScrollController = ScrollController();
  OverlayEntry? _overlayEntry;
  bool _expanded = false;
  bool _hovered = false;
  double _targetWidth = 0;
  final TextEditingController _searchController = TextEditingController();
  String? _activeGroup;
  bool get _tabbed => widget.groupTabs.isNotEmpty;
  List<int> get _visibleIndices {
    final query = _searchController.text.trim().toLowerCase();
    return [
      for (var i = 0; i < widget.options.length; i++)
        if (widget.options[i].group == _activeGroup &&
            ('${widget.options[i].label} ${widget.options[i].description}')
                .toLowerCase()
                .contains(query))
          i
    ];
  }

  void _refreshPanel() {
    _overlayEntry?.markNeedsBuild();
    if (_listScrollController.hasClients) _listScrollController.jumpTo(0);
  }

  double get _borderRadius =>
      widget.borderRadius ?? UiFieldStyle.defaultBorderRadius;
  double get _height => widget.height ?? UiFieldStyle.defaultHeight;

  bool get _grouped => widget.options.any((option) => option.group != null);

  bool _startsGroup(int index) =>
      widget.options[index].group != null &&
      (index == 0 ||
          widget.options[index - 1].group != widget.options[index].group);

  double _headerHeight(int index) =>
      _startsGroup(index) ? (index == 0 ? 32 : 44) : 0;
  double _rowHeight(int index) => !_grouped
      ? _height
      : (widget.options[index].description.isEmpty ? 48 : 62);
  double _offsetFor(int index) {
    var offset = 0.0;
    for (var i = 0; i < index; i++) {
      offset += _headerHeight(i) + _rowHeight(i);
    }
    return offset;
  }

  UiSelectOption<T>? get _selectedOption {
    for (final option in widget.options) {
      if (option.value == widget.value) return option;
    }
    return null;
  }

  @override
  void dispose() {
    _removeOverlay(force: true);
    _searchController.dispose();
    _focusNode.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  void _toggleOverlay() {
    if (!widget.enabled) return;
    if (_expanded) {
      _removeOverlay();
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    if (_tabbed) {
      _activeGroup = widget.groupTabs.contains(_selectedOption?.group)
          ? _selectedOption!.group
          : widget.groupTabs.first;
      _searchController.clear();
    }
    final scheme = Theme.of(context).colorScheme;
    _targetWidth = renderBox.size.width;
    const gap = 6.0;
    const viewportMargin = 12.0;
    const menuPadding = 12.0;
    final origin = renderBox.localToGlobal(Offset.zero);
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final naturalHeight = math.min(
        widget.menuMaxHeight,
        (_tabbed
                ? 100 +
                    _visibleIndices.fold<double>(0, (h, i) => h + _rowHeight(i))
                : _offsetFor(widget.options.length)) +
            menuPadding);
    final availableBelow =
        viewportHeight - origin.dy - renderBox.size.height - viewportMargin;
    final availableAbove = origin.dy - viewportMargin;
    final openAbove =
        availableBelow < naturalHeight && availableAbove > availableBelow;
    final availableHeight = math.max(
      96.0,
      (openAbove ? availableAbove : availableBelow) - gap,
    );
    final menuMaxHeight = math.min(widget.menuMaxHeight, availableHeight);

    _overlayEntry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _removeOverlay,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: _layerLink,
            targetAnchor: openAbove ? Alignment.topLeft : Alignment.bottomLeft,
            followerAnchor:
                openAbove ? Alignment.bottomLeft : Alignment.topLeft,
            offset: Offset(0, openAbove ? -gap : gap),
            showWhenUnlinked: false,
            child: Container(
              width: _targetWidth,
              constraints: BoxConstraints(maxHeight: menuMaxHeight),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(_borderRadius),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.shadow.withValues(alpha: 0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: _tabbed
                  ? Material(
                      type: MaterialType.transparency,
                      child: _buildTabbedPanel(scheme))
                  : ListView.builder(
                      controller: _listScrollController,
                      padding: EdgeInsets.zero,
                      primary: false,
                      shrinkWrap: true,
                      itemCount: widget.options.length,
                      itemBuilder: (context, index) {
                        final option = widget.options[index];
                        final selected = option.value == widget.value;
                        return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_startsGroup(index))
                                SizedBox(
                                    height: _headerHeight(index),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        if (index > 0)
                                          Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 10),
                                              child: Divider(
                                                  height: 12,
                                                  thickness: .5,
                                                  color:
                                                      scheme.outlineVariant)),
                                        Expanded(
                                            child: Align(
                                                alignment: Alignment.centerLeft,
                                                child: Padding(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 10),
                                                    child: Semantics(
                                                        header: true,
                                                        child: Text(
                                                            option.group!,
                                                            style: TextStyle(
                                                                fontSize: 12,
                                                                decoration:
                                                                    TextDecoration
                                                                        .none,
                                                                height: 1.3,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w500,
                                                                color: scheme
                                                                    .onSurfaceVariant)))))),
                                      ],
                                    )),
                              _UiSelectMenuItem(
                                option: option,
                                selected: selected,
                                grouped: _grouped,
                                itemBorderRadius: _borderRadius.clamp(0, 12),
                                itemHeight: _rowHeight(index),
                                onTap: () {
                                  widget.onChanged(option.value);
                                  _removeOverlay();
                                },
                              ),
                            ]);
                      },
                    ),
            ),
          ),
        ],
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
    setState(() => _expanded = true);

    // 打开后将当前选中项滚入可视区域。
    final selectedIndex =
        widget.options.indexWhere((o) => o.value == widget.value);
    if (selectedIndex > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_listScrollController.hasClients) return;
        final visible = _tabbed ? _visibleIndices : <int>[];
        final selectedEnd = _tabbed
            ? visible
                    .takeWhile((i) => i != selectedIndex)
                    .fold<double>(0, (h, i) => h + _rowHeight(i)) +
                _rowHeight(selectedIndex)
            : 0.0;
        final desired = _tabbed
            ? math.max(0.0, selectedEnd - menuMaxHeight + menuPadding + 100)
            : _grouped
                ? math.max(0.0,
                    _offsetFor(selectedIndex + 1) - menuMaxHeight + menuPadding)
                : _offsetFor(selectedIndex);
        final target =
            desired.clamp(0.0, _listScrollController.position.maxScrollExtent);
        _listScrollController.jumpTo(target);
      });
    }
  }

  Widget _buildTabbedPanel(ColorScheme scheme) {
    final indices = _visibleIndices;
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _removeOverlay();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: DefaultTextStyle(
        style: TextStyle(
            color: scheme.onSurface,
            fontSize: 14,
            fontWeight: FontWeight.w400,
            decoration: TextDecoration.none),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 10),
              child: UiSegmentedTabs<String>(
                groupId: this,
                expand: true,
                tabs: [
                  for (final group in widget.groupTabs)
                    UiSegmentedTab(value: group, label: group)
                ],
                current: _activeGroup!,
                trackColor: scheme.surfaceContainerLow,
                pillColor: scheme.primary.withValues(alpha: .09),
                activeColor: scheme.primary,
                inactiveColor: scheme.onSurfaceVariant,
                onChanged: (group) {
                  _activeGroup = group;
                  _searchController.clear();
                  _refreshPanel();
                },
              )),
          Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
              child: UiSearchField(
                  hintText: widget.searchPlaceholder,
                  controller: _searchController,
                  height: 40,
                  showBorder: false,
                  fillColor: scheme.surfaceContainerLow,
                  onChanged: (_) => _refreshPanel())),
          Flexible(
              child: indices.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 22),
                      child: Text('没有匹配的 Agent 类型',
                          style: TextStyle(color: scheme.onSurfaceVariant)))
                  : Scrollbar(
                      controller: _listScrollController,
                      child: ListView.builder(
                          controller: _listScrollController,
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          primary: false,
                          itemCount: indices.length,
                          itemBuilder: (_, index) {
                            final i = indices[index];
                            final option = widget.options[i];
                            return _UiSelectMenuItem(
                                option: option,
                                selected: option.value == widget.value,
                                grouped: true,
                                itemBorderRadius: _borderRadius.clamp(0, 12),
                                itemHeight: _rowHeight(i),
                                onTap: () {
                                  widget.onChanged(option.value);
                                  _removeOverlay();
                                });
                          }))),
        ]),
      ),
    );
  }

  void _removeOverlay({bool force = false}) {
    if (_overlayEntry == null) return;
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) {
      setState(() => _expanded = false);
    }
  }

  String _selectedLabel() {
    if (widget.value == null) return widget.placeholder;
    for (final option in widget.options) {
      if (option.value == widget.value) return option.label;
    }
    return widget.placeholder;
  }

  @override
  Widget build(BuildContext context) {
    final selectedOption = _selectedOption;
    final hasValue = selectedOption != null;
    final scheme = Theme.of(context).colorScheme;
    final height = widget.height ?? UiFieldStyle.defaultHeight;
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (focused) {
        if (!focused && !_tabbed) _removeOverlay();
      },
      child: CompositedTransformTarget(
        link: _layerLink,
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) {
            if (widget.enabled) setState(() => _hovered = true);
          },
          onExit: (_) {
            if (widget.enabled) setState(() => _hovered = false);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? _toggleOverlay : null,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 14,
                vertical: UiFieldStyle.verticalPaddingForHeight(
                  height,
                  contentHeight: 24,
                ),
              ),
              decoration: BoxDecoration(
                color: !widget.enabled
                    ? UiFieldStyle.disabledFillColor(scheme)
                    : (_hovered && !_expanded
                        ? UiFieldStyle.hoverFillColor(scheme)
                        : scheme.surface),
                borderRadius: BorderRadius.circular(_borderRadius),
              ),
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_borderRadius),
                border: Border.all(
                  color: _expanded
                      ? UiFieldStyle.focusBorderColor(scheme)
                      : _hovered
                          ? UiFieldStyle.hoverBorderColor(scheme)
                          : UiFieldStyle.enabledBorderColor(scheme),
                ),
              ),
              child: Row(
                children: [
                  if (_grouped && selectedOption?.icon != null) ...[
                    _SelectGroupIcon(icon: selectedOption!.icon!, size: 24),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      _selectedLabel(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: hasValue
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant
                                    .withValues(alpha: 0.45),
                            fontSize: 15,
                            height: 1.6,
                            decoration: TextDecoration.none,
                            decorationColor: Colors.transparent,
                          ),
                    ),
                  ),
                  if (_grouped && selectedOption?.group != null)
                    ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8, right: 10),
                          child: Text(selectedOption!.group!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                  height: 1.3,
                                  fontWeight: FontWeight.w400,
                                  decoration: TextDecoration.none)),
                        )),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 22,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UiSelectMenuItem<T> extends StatefulWidget {
  const _UiSelectMenuItem({
    required this.option,
    required this.selected,
    required this.grouped,
    required this.itemBorderRadius,
    required this.itemHeight,
    required this.onTap,
  });

  final UiSelectOption<T> option;
  final bool selected;
  final bool grouped;
  final double itemBorderRadius;
  final double itemHeight;
  final VoidCallback onTap;

  @override
  State<_UiSelectMenuItem<T>> createState() => _UiSelectMenuItemState<T>();
}

class _UiSelectMenuItemState<T> extends State<_UiSelectMenuItem<T>> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: widget.itemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.itemBorderRadius),
            color: widget.selected
                ? scheme.primary.withValues(alpha: 0.1)
                : _hovered
                    ? scheme.onSurface.withValues(alpha: 0.05)
                    : Colors.transparent,
          ),
          child: Row(
            children: [
              if (widget.option.icon != null) ...[
                if (widget.grouped)
                  _SelectGroupIcon(icon: widget.option.icon!, size: 32)
                else
                  Icon(widget.option.icon,
                      size: 16, color: scheme.onSurfaceVariant),
                SizedBox(width: widget.grouped ? 10 : 8),
              ],
              Expanded(
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.option.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(
                                  color: widget.grouped && widget.selected
                                      ? scheme.primary
                                      : (widget.selected ||
                                              _hovered ||
                                              widget.grouped
                                          ? scheme.onSurface
                                          : scheme.onSurfaceVariant),
                                  fontWeight: widget.selected || widget.grouped
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  decoration: TextDecoration.none,
                                  decorationColor: Colors.transparent)),
                      if (widget.grouped &&
                          widget.option.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(widget.option.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                                height: 1.3,
                                fontWeight: FontWeight.w400,
                                decoration: TextDecoration.none)),
                      ],
                    ]),
              ),
              if (widget.selected)
                Icon(
                  CupertinoIcons.check_mark,
                  size: 16,
                  color: scheme.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectGroupIcon extends StatelessWidget {
  const _SelectGroupIcon({required this.icon, required this.size});
  final IconData icon;
  final double size;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(8)),
        alignment: Alignment.center,
        child: Icon(icon, size: size == 24 ? 19 : 22, color: scheme.primary));
  }
}
