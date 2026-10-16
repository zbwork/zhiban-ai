import 'package:flutter/material.dart';

class UiTag extends StatelessWidget {
  const UiTag({
    required this.label,
    required this.backgroundColor,
    required this.textColor,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.borderRadius = const BorderRadius.all(Radius.circular(999)),
    this.textStyle,
    super.key,
  });

  final String label;
  final Color backgroundColor;
  final Color textColor;
  final EdgeInsets padding;
  final BorderRadius borderRadius;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: borderRadius,
      ),
      child: Text(
        label,
        style: (textStyle ??
                const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ))
            .copyWith(color: textColor),
      ),
    );
  }
}
