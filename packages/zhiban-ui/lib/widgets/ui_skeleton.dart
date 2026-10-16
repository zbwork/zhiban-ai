import 'package:flutter/material.dart';
import 'package:zhiban_ui/config/skeleton_config.dart';

class UiSkeletonBlock extends StatelessWidget {
  const UiSkeletonBlock({
    super.key,
    required this.width,
    required this.height,
    this.radius = 8,
    this.color = SkeletonConfig.block,
  });

  final double width;
  final double height;
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width.isFinite ? width : double.infinity,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
