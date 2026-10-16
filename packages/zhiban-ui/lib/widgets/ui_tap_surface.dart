import 'package:flutter/material.dart';

/// 为可点击内容提供独立绘制层，避免按压底色被外层背景遮住。
///
/// 继承主题的静态按压、hover、focus 和 NoSplash；child 不应铺整面背景。
class UiTapSurface extends StatelessWidget {
  const UiTapSurface({
    super.key,
    required this.child,
    this.onTap,
    this.onHover,
    this.color,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.borderSide = BorderSide.none,
  });

  final Widget child;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onHover;
  final Color? color;
  final BorderRadius borderRadius;
  final BorderSide borderSide;

  @override
  Widget build(BuildContext context) => Material(
        color: color ?? Colors.transparent,
        shape: RoundedRectangleBorder(
            borderRadius: borderRadius, side: borderSide),
        clipBehavior: Clip.antiAlias,
        animationDuration: Duration.zero,
        child: InkWell(
          onTap: onTap,
          onHover: onHover,
          borderRadius: borderRadius,
          child: child,
        ),
      );
}
