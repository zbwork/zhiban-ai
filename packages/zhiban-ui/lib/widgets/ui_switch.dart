import 'package:flutter/material.dart';
import 'package:flutter_switch/flutter_switch.dart';

class UiSwitch extends StatelessWidget {
  const UiSwitch({
    required this.value,
    super.key,
    this.onChanged,
    this.width = 34,
    this.height = 20,
    this.toggleSize = 16,
    this.borderRadius = 999,
    this.padding = 2,
    this.disabled = false,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final double width;
  final double height;
  final double toggleSize;
  final double borderRadius;
  final double padding;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      ignoring: disabled || onChanged == null,
      child: FlutterSwitch(
        width: width,
        height: height,
        toggleSize: toggleSize,
        value: value,
        borderRadius: borderRadius,
        padding: padding,
        activeColor: theme.primaryColor,
        inactiveColor: const Color(0xFFE4E7EC),
        activeToggleColor: Colors.white,
        inactiveToggleColor: Colors.white,
        onToggle: onChanged ?? (_) {},
      ),
    );
  }
}
