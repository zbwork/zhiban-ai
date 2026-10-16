import 'package:flutter/material.dart';

enum UiDialogSize {
  compact(440),
  standard(640),
  wide(960);

  const UiDialogSize(this.maxWidth);

  final double maxWidth;
}

/// 通用弹框外壳，只负责 surface、圆角、裁剪和视口约束。
class UiDialogShell extends StatelessWidget {
  const UiDialogShell({
    super.key,
    required this.child,
    this.size = UiDialogSize.standard,
    this.maxHeight,
    this.minWidth = 320,
    this.insetPadding = const EdgeInsets.all(16),
  });

  final Widget child;
  final UiDialogSize size;
  final double? maxHeight;
  final double minWidth;
  final EdgeInsets insetPadding;

  @override
  Widget build(BuildContext context) {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final availableHeight =
        (viewportHeight - insetPadding.vertical).clamp(0.0, double.infinity);
    final resolvedMaxHeight = maxHeight == null
        ? availableHeight
        : maxHeight!.clamp(0.0, availableHeight);

    return Dialog(
      insetPadding: insetPadding,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: Theme.of(context).colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      constraints: BoxConstraints(
        minWidth: minWidth,
        maxWidth: size.maxWidth,
        maxHeight: resolvedMaxHeight,
      ),
      child: child,
    );
  }
}
