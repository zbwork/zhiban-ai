import 'package:flutter/material.dart';

/// 通用图标按钮：固定尺寸、hover 背景、可选 tooltip。
///
/// 用于面板关闭、返回等操作按钮，统一交互视觉。
class UiIconButton extends StatefulWidget {
  const UiIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.size = 32,
    this.iconSize = 16,
    this.enabled = true,
    this.color,
    this.hoverColor,
  }) : iconWidget = null;

  /// SVG 等自定义图标沿用同一套尺寸、hover 和点击行为。
  const UiIconButton.custom({
    super.key,
    required Widget icon,
    this.onTap,
    this.tooltip,
    this.size = 32,
    this.enabled = true,
    this.hoverColor,
  })  : iconWidget = icon,
        icon = null,
        iconSize = 16,
        color = null;

  final IconData? icon;
  final Widget? iconWidget;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final double iconSize;
  final bool enabled;

  /// 可按使用场景覆盖 hover 底色，默认保持原有中性灰。
  final Color? hoverColor;

  /// 图标颜色覆盖：不传则用默认 hover 态双色（未 hover 浅灰/hover 深灰）；
  /// 传了就固定用这个颜色，不随 hover 变化（disabled 态仍用禁用灰）。
  final Color? color;

  @override
  State<UiIconButton> createState() => _UiIconButtonState();
}

class _UiIconButtonState extends State<UiIconButton> {
  bool _hovered = false;

  bool get _active => widget.enabled && widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    Widget btn = MouseRegion(
      cursor: _active ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (_active) setState(() => _hovered = true);
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _active ? widget.onTap : null,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: _hovered
                ? (widget.hoverColor ?? const Color(0xFFE8ECF2))
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: widget.iconWidget ??
              Icon(
                widget.icon,
                size: widget.iconSize,
                color: _active
                    ? (widget.color ??
                        (_hovered
                            ? const Color(0xFF344054)
                            : const Color(0xFF98A2B3)))
                    : const Color(0xFFD0D5DD),
              ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      btn = Tooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}
