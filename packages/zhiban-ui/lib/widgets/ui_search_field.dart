import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'ui_input.dart';

class UiSearchField extends StatefulWidget {
  const UiSearchField({
    super.key,
    required this.hintText,
    required this.onChanged,
    this.controller,
    this.focusNode,
    this.height,
    this.borderRadius,
    this.contentPadding,
    this.fillColor,
    this.showBorder = true,
    this.enabled = true,
    this.showClearButton = true,
    this.onClear,
    this.trailing,
  });

  final String hintText;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final double? height;
  final double? borderRadius;
  final EdgeInsetsGeometry? contentPadding;
  final Color? fillColor;
  final bool showBorder;
  final bool enabled;
  final bool showClearButton;
  final VoidCallback? onClear;

  /// 框内尾部的额外 action（比如筛选按钮），跟在清空按钮右边一起放进
  /// `suffixIcon`——不是另起一个框外按钮，保持"搜索框自带 actions"的形态。
  final Widget? trailing;

  @override
  State<UiSearchField> createState() => _UiSearchFieldState();
}

class _UiSearchFieldState extends State<UiSearchField> {
  FocusNode? _ownedFocus;
  TextEditingController? _ownedController;
  bool _hasText = false;

  FocusNode get _focus => widget.focusNode ?? _ownedFocus!;
  TextEditingController get _controller =>
      widget.controller ?? _ownedController!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) _ownedFocus = FocusNode();
    if (widget.controller == null) _ownedController = TextEditingController();
    _controller.addListener(_onTextChange);
    _hasText = _controller.text.isNotEmpty;
  }

  @override
  void didUpdateWidget(UiSearchField old) {
    super.didUpdateWidget(old);

    // controller 变更：移除旧监听，挂到新 controller 上
    final oldController = old.controller ?? _ownedController;
    final newController = widget.controller ?? _ownedController;
    if (oldController != newController) {
      oldController?.removeListener(_onTextChange);
      if (widget.controller == null && old.controller != null) {
        // 从外部切换到内部自管：创建 owned controller
        _ownedController = TextEditingController();
      } else if (widget.controller != null && old.controller == null) {
        // 从内部切换到外部：销毁 owned controller
        _ownedController?.dispose();
        _ownedController = null;
      }
      _controller.addListener(_onTextChange);
      _hasText = _controller.text.isNotEmpty;
    }

    // focusNode 变更：销毁/创建 owned focus
    if (old.focusNode != widget.focusNode) {
      if (widget.focusNode == null && old.focusNode != null) {
        _ownedFocus = FocusNode();
      } else if (widget.focusNode != null && old.focusNode == null) {
        _ownedFocus?.dispose();
        _ownedFocus = null;
      }
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChange);
    _ownedFocus?.dispose();
    _ownedController?.dispose();
    super.dispose();
  }

  void _onTextChange() {
    final has = _controller.text.isNotEmpty;
    if (has != _hasText && mounted) setState(() => _hasText = has);
  }

  void _handleClear() {
    _controller.clear();
    widget.onChanged('');
    widget.onClear?.call();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return UiInputField(
      controller: _controller,
      focusNode: _focus,
      hintText: widget.hintText,
      onChanged: widget.onChanged,
      enabled: widget.enabled,
      borderRadius: widget.borderRadius,
      showBorder: widget.showBorder,
      filled: true,
      fillColor: widget.fillColor ?? (widget.enabled ? scheme.surface : null),
      contentPadding: widget.contentPadding,
      height: widget.height,
      prefixIcon: Icon(
        CupertinoIcons.search,
        size: 18,
        color: scheme.onSurfaceVariant,
      ),
      prefixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 0),
      suffixIcon: _buildSuffix(),
    );
  }

  Widget? _buildSuffix() {
    final showClear = widget.showClearButton && _hasText && widget.enabled;
    if (!showClear && widget.trailing == null) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showClear)
          GestureDetector(
            onTap: _handleClear,
            child: const Icon(
              CupertinoIcons.clear_thick_circled,
              size: 16,
            ),
          ),
        if (showClear && widget.trailing != null) const SizedBox(width: 4),
        if (widget.trailing != null) widget.trailing!,
      ],
    );
  }
}
