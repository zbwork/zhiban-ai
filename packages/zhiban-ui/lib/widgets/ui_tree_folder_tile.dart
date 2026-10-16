import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class UiTreeFolderTile extends StatelessWidget {
  const UiTreeFolderTile({
    super.key,
    required this.label,
    required this.selected,
    required this.margin,
    required this.onTap,
    this.expanded,
    this.selectedColor = const Color(0xFF3762E0),
    this.unselectedColor = const Color(0xFF1A1D29),
    this.selectedBgColor = const Color(0xFFEEF2FF),
    this.fontSize = 14.5,
    this.fontWeight = FontWeight.w600,
    this.showExpandSlot = true,
  });

  final String label;
  final bool selected;
  final EdgeInsetsGeometry margin;
  final VoidCallback onTap;
  final bool? expanded;
  final Color selectedColor;
  final Color unselectedColor;
  final Color selectedBgColor;
  final double fontSize;
  final FontWeight fontWeight;
  final bool showExpandSlot;

  static const double expandIconSlot = 24;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        margin: margin,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? selectedBgColor : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            SizedBox(
              width: showExpandSlot ? expandIconSlot : 0,
              height: 24,
              child: expanded == null
                  ? null
                  : ClipRect(
                      child: Center(
                        child: Transform.translate(
                          offset: const Offset(-3, -3),
                          child: Icon(
                            expanded!
                                ? Icons.arrow_drop_down_rounded
                                : Icons.arrow_right_rounded,
                            size: 30,
                            color: selected
                                ? selectedColor
                                : const Color(0xFF9AA1AE),
                          ),
                        ),
                      ),
                    ),
            ),
            const Icon(
              CupertinoIcons.folder_fill,
              size: 20,
              color: Color(0xFF4B90E8),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? selectedColor : unselectedColor,
                  fontSize: fontSize,
                  fontWeight: fontWeight,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
