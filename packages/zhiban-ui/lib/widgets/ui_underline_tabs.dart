import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:flutter/material.dart';

class UiUnderlineTab<T> {
  const UiUnderlineTab({required this.value, required this.label});

  final T value;
  final String label;
}

class UiUnderlineTabs<T> extends StatelessWidget {
  const UiUnderlineTabs({
    super.key,
    required this.tabs,
    required this.current,
    required this.onChanged,
    this.spacing = 28,
    this.horizontalPadding = 16,
    this.topPadding = 4,
    this.showBottomBorder,
    this.activeColor = const Color(0xFF1E66F5),
    this.inactiveColor = const Color(0xFF4E5969),
    this.fontSize = 16,
    this.indicatorWidth = 28,
  });

  final List<UiUnderlineTab<T>> tabs;
  final T current;
  final ValueChanged<T> onChanged;
  final double spacing;
  final double horizontalPadding;
  final double topPadding;
  final bool? showBottomBorder;
  final Color activeColor;
  final Color inactiveColor;
  final double fontSize;
  final double indicatorWidth;

  @override
  Widget build(BuildContext context) {
    final shouldShowBorder = showBottomBorder ?? !PlatformUtils.isMobile;
    return Container(
      padding: EdgeInsets.fromLTRB(
          horizontalPadding, topPadding, horizontalPadding, 0),
      decoration: BoxDecoration(
        border: shouldShowBorder
            ? const Border(bottom: BorderSide(color: Color(0xFFEFF1F5)))
            : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          for (var i = 0; i < tabs.length; i++) ...[
            _UiUnderlineTabItem(
              label: tabs[i].label,
              active: tabs[i].value == current,
              activeColor: activeColor,
              inactiveColor: inactiveColor,
              fontSize: fontSize,
              indicatorWidth: indicatorWidth,
              onTap: () => onChanged(tabs[i].value),
            ),
            if (i != tabs.length - 1) SizedBox(width: spacing),
          ],
        ],
      ),
    );
  }
}

class _UiUnderlineTabItem extends StatelessWidget {
  const _UiUnderlineTabItem({
    required this.label,
    required this.active,
    required this.activeColor,
    required this.inactiveColor,
    required this.fontSize,
    required this.indicatorWidth,
    required this.onTap,
  });

  final String label;
  final bool active;
  final Color activeColor;
  final Color inactiveColor;
  final double fontSize;
  final double indicatorWidth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? activeColor : inactiveColor,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 3,
                width: active ? indicatorWidth : 0,
                decoration: BoxDecoration(
                  color: active ? activeColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
