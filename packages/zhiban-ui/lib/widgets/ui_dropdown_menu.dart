import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class UiDropdownMenuItem<T> {
  const UiDropdownMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.danger = false,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool danger;
}

const double _menuPadding = 4;
const double _menuItemHeight = 40;
const double _menuItemGap = 4;
const double _menuScreenMargin = 8;

/// 菜单的实际高度（上下内边距 + 各项 + 项间距，封顶 [maxHeight]），弹出前用来判断
/// 下方放不放得下。
double _menuHeight(int itemCount, double maxHeight) {
  final content = _menuPadding * 2 +
      itemCount * _menuItemHeight +
      (itemCount > 1 ? (itemCount - 1) * _menuItemGap : 0);
  return content > maxHeight ? maxHeight : content;
}

/// 在 [anchorKey] 标记的组件正下方弹出一份与 [UiDropdownMenu] 同风格的菜单
/// （图标按钮触发的下拉菜单场景；避免菜单盖住触发按钮本身）。下方放不下时翻到
/// 组件正上方（2026-09-20：本地开发工具页最后一张卡片的「打开」贴着窗口底部，
/// 「打开桌面端」被裁掉一半）。
Future<T?> showUiDropdownMenuBelow<T>({
  required BuildContext context,
  required GlobalKey anchorKey,
  required List<UiDropdownMenuItem<T>> items,
  T? activeValue,
  double menuWidth = 160,
  double menuMaxHeight = 240,
  double menuBorderRadius = 10,
  double gap = 6,
}) {
  final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (box == null) return Future.value(null);
  final anchor = box.localToGlobal(Offset(0, box.size.height + gap));
  return showUiDropdownContextMenu<T>(
    context: context,
    globalPosition: anchor,
    flipAboveY: box.localToGlobal(Offset.zero).dy - gap,
    items: items,
    activeValue: activeValue,
    menuWidth: menuWidth,
    menuMaxHeight: menuMaxHeight,
    menuBorderRadius: menuBorderRadius,
  );
}

/// 在任意光标位置弹出一份与 [UiDropdownMenu] 同风格的上下文菜单。
///
/// 下方放不下整份菜单时：给了 [flipAboveY]（触发组件上沿）且上方放得下，菜单底边
/// 贴着它向上展开；否则整体上移到刚好不出窗口。
Future<T?> showUiDropdownContextMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<UiDropdownMenuItem<T>> items,
  double? flipAboveY,
  T? activeValue,
  double menuWidth = 160,
  double menuMaxHeight = 240,
  double menuBorderRadius = 10,
}) {
  final overlayBox = Overlay.of(context, rootOverlay: true)
      .context
      .findRenderObject() as RenderBox?;
  final overlaySize = overlayBox?.size ?? MediaQuery.of(context).size;
  final safeRight = overlaySize.width - menuWidth - 8;
  final left =
      globalPosition.dx.clamp(8.0, safeRight < 8 ? 8.0 : safeRight).toDouble();
  final menuHeight = _menuHeight(items.length, menuMaxHeight);
  final bottomLimit = overlaySize.height - _menuScreenMargin;
  var top = globalPosition.dy;
  if (top + menuHeight > bottomLimit) {
    final above = flipAboveY == null ? null : flipAboveY - menuHeight;
    top = above != null && above >= _menuScreenMargin
        ? above
        : bottomLimit - menuHeight;
  }
  if (top < _menuScreenMargin) top = _menuScreenMargin;

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    barrierColor: Colors.transparent,
    pageBuilder: (ctx, _, __) {
      return Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => Navigator.of(ctx).pop(),
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: Container(
                width: menuWidth < 120 ? 120 : menuWidth,
                constraints: BoxConstraints(maxHeight: menuMaxHeight),
                padding: const EdgeInsets.all(_menuPadding),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(menuBorderRadius),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1A101828),
                      blurRadius: 20,
                      spreadRadius: 1,
                    ),
                    BoxShadow(
                      color: Color(0x24101828),
                      blurRadius: 28,
                      spreadRadius: 2,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(menuBorderRadius),
                  child: ListView.separated(
                    padding: EdgeInsets.zero,
                    primary: false,
                    shrinkWrap: true,
                    itemCount: items.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: _menuItemGap),
                    itemBuilder: (_, index) {
                      final item = items[index];
                      return _UiDropdownMenuItem<T>(
                        item: item,
                        selected:
                            activeValue != null && item.value == activeValue,
                        borderRadius: menuBorderRadius,
                        onTap: () => Navigator.of(ctx).pop(item.value),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class UiDropdownMenu<T> extends StatefulWidget {
  const UiDropdownMenu({
    super.key,
    required this.child,
    required this.items,
    required this.onSelected,
    this.onExpandedChanged,
    this.activeValue,
    this.enabled = true,
    this.menuWidth = 160,
    this.menuMaxHeight = 240,
    this.menuBorderRadius = 10,
    this.offset = const Offset(0, 6),
    this.hoverRadius,
  });

  final Widget child;
  final List<UiDropdownMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final ValueChanged<bool>? onExpandedChanged;

  /// 当前选中值，匹配的菜单项会显示勾选标记。
  final T? activeValue;
  final bool enabled;
  final double menuWidth;
  final double menuMaxHeight;
  final double menuBorderRadius;
  final Offset offset;

  /// 非 null 时在触发器上启用 hover 背景，值为圆角半径。
  /// 适合图标类触发器（SizedBox+Icon），有自身 hover 样式的按钮无需设置。
  final double? hoverRadius;

  @override
  State<UiDropdownMenu<T>> createState() => _UiDropdownMenuState<T>();
}

class _UiDropdownMenuState<T> extends State<UiDropdownMenu<T>>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  final FocusNode _focusNode = FocusNode();
  OverlayEntry? _overlayEntry;
  // 淡出动画期间持有的 entry 引用。_removeOverlay 把 _overlayEntry 置 null 后
  // 将 entry 保存在这里，dispose 时直接 remove，避免 TickerFuture 取消导致
  // whenComplete 不触发、entry 残留在 Overlay 里挡住所有点击事件。
  OverlayEntry? _fadingEntry;
  bool _expanded = false;
  bool _hovered = false;
  bool _disposing = false;
  late final AnimationController _animationController;
  late final Animation<double> _expandAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 160),
      vsync: this,
    );
    _expandAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _disposing = true;
    _overlayEntry?.remove();
    _overlayEntry = null;
    _fadingEntry?.remove(); // 动画期间 widget 被 dispose 时保证 entry 被移除
    _fadingEntry = null;
    _expanded = false;
    _focusNode.dispose();
    _animationController.dispose();
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
    if (!mounted) return;
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    // 检测触发器位置，决定菜单向左还是向右展开，避免靠近屏幕边缘时溢出。
    final triggerGlobal = renderBox.localToGlobal(Offset.zero);
    final triggerSize = renderBox.size;
    final menuWidth = widget.menuWidth < 120 ? 120.0 : widget.menuWidth;
    final rightEdge = triggerGlobal.dx + triggerSize.width;
    final alignLeft = rightEdge < menuWidth;

    _overlayEntry = OverlayEntry(
      builder: (_) => Material(
        type: MaterialType.transparency,
        child: Stack(
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
              targetAnchor:
                  alignLeft ? Alignment.bottomLeft : Alignment.bottomRight,
              followerAnchor:
                  alignLeft ? Alignment.topLeft : Alignment.topRight,
              offset: widget.offset,
              showWhenUnlinked: false,
              child: FadeTransition(
                opacity: _expandAnimation,
                child: Container(
                  width: menuWidth,
                  constraints: BoxConstraints(maxHeight: widget.menuMaxHeight),
                  padding: const EdgeInsets.all(_menuPadding),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius:
                        BorderRadius.circular(widget.menuBorderRadius),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x1A101828),
                        blurRadius: 20,
                        spreadRadius: 1,
                      ),
                      BoxShadow(
                        color: Color(0x24101828),
                        blurRadius: 28,
                        spreadRadius: 2,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius:
                        BorderRadius.circular(widget.menuBorderRadius),
                    child: ListView.separated(
                      padding: EdgeInsets.zero,
                      primary: false,
                      shrinkWrap: true,
                      itemCount: widget.items.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: _menuItemGap),
                      itemBuilder: (context, index) {
                        final item = widget.items[index];
                        return _UiDropdownMenuItem(
                          item: item,
                          selected: widget.activeValue != null &&
                              item.value == widget.activeValue,
                          onTap: () {
                            widget.onSelected(item.value);
                            _removeOverlay();
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
    if (mounted && !_disposing) {
      setState(() => _expanded = true);
    }
    if (!_disposing) {
      widget.onExpandedChanged?.call(true);
    }
    _animationController.forward();
  }

  void _removeOverlay({bool force = false}) {
    if (_overlayEntry == null) return;
    final entry = _overlayEntry!;
    _overlayEntry = null;
    if (force) {
      _fadingEntry = null;
      entry.remove();
      _animationController.value = 0;
    } else {
      _fadingEntry = entry;
      _animationController.reverse().whenComplete(() {
        // 正常动画结束后移除；若 widget 已被 dispose，_fadingEntry 在 dispose()
        // 里已被清空，这里是 no-op，避免重复 remove。
        if (_fadingEntry == entry) {
          _fadingEntry?.remove();
          _fadingEntry = null;
        }
      });
    }
    if (mounted && !_disposing) {
      setState(() => _expanded = false);
    }
    if (!_disposing) {
      widget.onExpandedChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.hoverRadius;
    Widget trigger = widget.child;

    if (radius != null && widget.enabled) {
      trigger = Container(
        decoration: BoxDecoration(
          color: (_hovered || _expanded)
              ? const Color(0xFFE8ECF2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: trigger,
      );
    }

    return Focus(
      focusNode: _focusNode,
      onFocusChange: (focused) {
        if (!focused) _removeOverlay();
      },
      child: CompositedTransformTarget(
        link: _layerLink,
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) {
            if (radius != null && mounted) setState(() => _hovered = true);
          },
          onExit: (_) {
            if (radius != null && mounted) setState(() => _hovered = false);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled ? _toggleOverlay : null,
            child: trigger,
          ),
        ),
      ),
    );
  }
}

class _UiDropdownMenuItem<T> extends StatefulWidget {
  const _UiDropdownMenuItem({
    required this.item,
    required this.onTap,
    this.selected = false,
    this.borderRadius = 10,
  });

  final UiDropdownMenuItem<T> item;
  final VoidCallback onTap;
  final bool selected;
  final double borderRadius;

  @override
  State<_UiDropdownMenuItem<T>> createState() => _UiDropdownMenuItemState<T>();
}

class _UiDropdownMenuItemState<T> extends State<_UiDropdownMenuItem<T>> {
  bool _hovered = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final scheme = Theme.of(context).colorScheme;
    final Color textColor = item.danger
        ? const Color(0xFFD92D20)
        : widget.selected
            ? scheme.primary
            : Colors.black87;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTap: () {
          _setPressed(false);
          widget.onTap();
        },
        child: Container(
          height: _menuItemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: widget.selected
                ? scheme.primary.withValues(alpha: 0.08)
                : _pressed
                    ? const Color(0xFFEBF2FF)
                    : _hovered
                        ? const Color(0xFFE8ECF2)
                        : Colors.white,
          ),
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(
                  item.icon,
                  size: 16,
                  color: item.danger
                      ? const Color(0xFFD92D20)
                      : widget.selected
                          ? scheme.primary
                          : const Color(0xFF667085),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: textColor,
                    fontWeight: widget.selected || item.danger
                        ? FontWeight.w500
                        : FontWeight.w400,
                  ),
                ),
              ),
              if (widget.selected) ...[
                const SizedBox(width: 8),
                Icon(
                  CupertinoIcons.check_mark,
                  size: 13,
                  color: scheme.primary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
