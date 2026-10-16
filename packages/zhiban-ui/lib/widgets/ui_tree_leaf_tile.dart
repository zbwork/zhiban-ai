import 'package:flutter/material.dart';

import 'ui_tree_folder_tile.dart';

class UiTreeLeafTile extends StatelessWidget {
  const UiTreeLeafTile({
    super.key,
    required this.leading,
    required this.title,
    required this.selected,
    required this.onTap,
    required this.margin,
    required this.padding,
    required this.borderRadius,
    this.selectedColor = const Color(0xFF3762E0),
    this.unselectedColor = const Color(0xFF1A1D29),
    this.selectedBgColor = const Color(0xFFEEF2FF),
    this.fontSize = 14.0,
    this.showExpandSlot = true,
    this.leadingGap = 8,
  });

  final Widget leading;
  final String title;
  final bool selected;
  final VoidCallback onTap;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color selectedColor;
  final Color unselectedColor;
  final Color selectedBgColor;
  final double fontSize;
  final bool showExpandSlot;
  final double leadingGap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(borderRadius),
      onTap: onTap,
      child: Container(
        margin: margin,
        padding: padding,
        decoration: BoxDecoration(
          color: selected ? selectedBgColor : Colors.transparent,
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: Row(
          children: [
            SizedBox(
              width: showExpandSlot ? UiTreeFolderTile.expandIconSlot : 0,
            ),
            leading,
            SizedBox(width: leadingGap),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? selectedColor : unselectedColor,
                  fontSize: fontSize,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
