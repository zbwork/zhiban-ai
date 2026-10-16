import 'package:flutter/material.dart';

/// [UiSlantedTabs] 的一个受控选项。
class UiSlantedTab<T> {
  const UiSlantedTab({required this.value, required this.label});

  final T value;
  final String label;
}

/// 等宽斜切 Tab。
///
/// 选中项的白色斜切块只负责绘制：首项左直右斜，中间项是左右对称的等腰梯形，
/// 末项是首项的水平翻转。每个选项始终按完整等宽矩形命中，避免视觉裁剪缩小
/// 触屏点击区。组件不持有业务状态，调用方通过 [current] 和 [onChanged] 控制
/// 选中项，因此同一实现可承载两个或更多选项。
class UiSlantedTabs<T> extends StatelessWidget {
  const UiSlantedTabs({
    super.key,
    required this.tabs,
    required this.current,
    required this.onChanged,
    this.height = 70,
    this.gradientTopInset = 10,
    this.slantExtent = 40,
    this.selectionOverlap = 12,
    this.cornerRadius = 12,
    this.inactiveGradient = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFC0E2FF), Color(0xFFFFFFFF)],
    ),
    this.selectionColor,
    this.activeColor,
    this.inactiveColor,
    this.fontSize = 18,
    this.indicatorColor = const Color(0xFF4D8EFF),
    this.indicatorWidth = 22,
    this.indicatorHeight = 4,
    this.indicatorGap = 8,
    this.animationDuration = const Duration(milliseconds: 200),
  })  : assert(tabs.length >= 2, 'UiSlantedTabs requires at least two tabs.'),
        assert(gradientTopInset >= 0 && gradientTopInset < height);

  final List<UiSlantedTab<T>> tabs;
  final T current;
  final ValueChanged<T> onChanged;
  final double height;
  final double gradientTopInset;
  final double slantExtent;
  final double selectionOverlap;
  final double cornerRadius;
  final Gradient inactiveGradient;
  final Color? selectionColor;
  final Color? activeColor;
  final Color? inactiveColor;
  final double fontSize;
  final Color indicatorColor;
  final double indicatorWidth;
  final double indicatorHeight;
  final double indicatorGap;
  final Duration animationDuration;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = tabs.indexWhere((tab) => tab.value == current);
    if (selectedIndex < 0) {
      throw FlutterError(
        'UiSlantedTabs.current must match one of the supplied tab values.',
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth = constraints.maxWidth / tabs.length;
          final effectiveSlant = slantExtent.clamp(0.0, segmentWidth * 0.31);
          final effectiveOverlap =
              selectionOverlap.clamp(0.0, segmentWidth * 0.2);
          final placement = selectedIndex == 0
              ? _SlantedTabPlacement.first
              : selectedIndex == tabs.length - 1
                  ? _SlantedTabPlacement.last
                  : _SlantedTabPlacement.middle;
          final selectionLeft = placement == _SlantedTabPlacement.first
              ? 0.0
              : segmentWidth * selectedIndex - effectiveOverlap;
          final selectionWidth = segmentWidth +
              (placement == _SlantedTabPlacement.middle
                  ? effectiveOverlap * 2
                  : effectiveOverlap);
          // Align selected content to the center of the shape's top edge.
          final edgeOffset = (effectiveSlant - effectiveOverlap) / 2;
          final selectedContentOffset = switch (placement) {
            _SlantedTabPlacement.first => -edgeOffset,
            _SlantedTabPlacement.middle => 0.0,
            _SlantedTabPlacement.last => edgeOffset,
          };

          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                key: const ValueKey('ui-slanted-tabs-inactive-gradient'),
                top: gradientTopInset,
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(gradient: inactiveGradient),
                ),
              ),
              AnimatedPositioned(
                key: const ValueKey('ui-slanted-tabs-selection'),
                duration: animationDuration,
                curve: Curves.easeOutCubic,
                left: selectionLeft,
                top: 0,
                width: selectionWidth,
                height: height,
                child: IgnorePointer(
                  child: ClipPath(
                    clipper: _SlantedTabClipper(
                      slantExtent: effectiveSlant,
                      placement: placement,
                      cornerRadius: cornerRadius,
                    ),
                    child: ColoredBox(
                      color: selectionColor ?? scheme.surface,
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var index = 0; index < tabs.length; index++)
                    Expanded(
                      child: _SlantedTabItem(
                        label: tabs[index].label,
                        selected: tabs[index].value == current,
                        activeColor: activeColor ?? scheme.onSurface,
                        inactiveColor: inactiveColor ?? scheme.onSurfaceVariant,
                        fontSize: fontSize,
                        indicatorColor: indicatorColor,
                        indicatorWidth: indicatorWidth,
                        indicatorHeight: indicatorHeight,
                        indicatorGap: indicatorGap,
                        contentOffsetX: tabs[index].value == current
                            ? selectedContentOffset
                            : 0,
                        onTap: () => onChanged(tabs[index].value),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SlantedTabItem extends StatelessWidget {
  const _SlantedTabItem({
    required this.label,
    required this.selected,
    required this.activeColor,
    required this.inactiveColor,
    required this.fontSize,
    required this.indicatorColor,
    required this.indicatorWidth,
    required this.indicatorHeight,
    required this.indicatorGap,
    required this.contentOffsetX,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color activeColor;
  final Color inactiveColor;
  final double fontSize;
  final Color indicatorColor;
  final double indicatorWidth;
  final double indicatorHeight;
  final double indicatorGap;
  final double contentOffsetX;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: selected ? activeColor : inactiveColor,
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        height: 1.2,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      child: ExcludeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            // The rectangular hit target must not cover the slanted artwork.
            highlightColor: Colors.transparent,
            child: SizedBox.expand(
              child: Center(
                child: Transform.translate(
                  offset: Offset(contentOffsetX, 0),
                  child: selected
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            text,
                            SizedBox(height: indicatorGap),
                            Container(
                              key: const ValueKey(
                                'ui-slanted-tab-indicator',
                              ),
                              width: indicatorWidth,
                              height: indicatorHeight,
                              decoration: BoxDecoration(
                                color: indicatorColor,
                                borderRadius:
                                    BorderRadius.circular(indicatorHeight / 2),
                              ),
                            ),
                          ],
                        )
                      : text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _SlantedTabPlacement { first, middle, last }

class _SlantedTabClipper extends CustomClipper<Path> {
  const _SlantedTabClipper({
    required this.slantExtent,
    required this.placement,
    required this.cornerRadius,
  });

  final double slantExtent;
  final _SlantedTabPlacement placement;
  final double cornerRadius;

  @override
  Path getClip(Size size) {
    final topLeft = placement == _SlantedTabPlacement.first ? 0.0 : slantExtent;
    final topRight = placement == _SlantedTabPlacement.last
        ? size.width
        : size.width - slantExtent;
    return _roundedPolygon(
      [
        Offset(topLeft, 0),
        Offset(topRight, 0),
        Offset(size.width, size.height),
        Offset(0, size.height),
      ],
      cornerRadius,
    );
  }

  @override
  bool shouldReclip(covariant _SlantedTabClipper oldClipper) {
    return oldClipper.slantExtent != slantExtent ||
        oldClipper.placement != placement ||
        oldClipper.cornerRadius != cornerRadius;
  }
}

Path _roundedPolygon(List<Offset> vertices, double radius) {
  assert(vertices.length >= 3);
  final path = Path();

  Offset pointTowards(Offset from, Offset to) {
    final delta = to - from;
    final distance = delta.distance;
    if (distance == 0 || radius <= 0) return from;
    final step = radius.clamp(0.0, distance / 2) / distance;
    return from + delta * step;
  }

  final first = vertices.first;
  path.moveTo(
      pointTowards(first, vertices[1]).dx, pointTowards(first, vertices[1]).dy);
  for (var i = 1; i < vertices.length; i++) {
    final vertex = vertices[i];
    final previous = vertices[i - 1];
    final next = vertices[(i + 1) % vertices.length];
    final entry = pointTowards(vertex, previous);
    final exit = pointTowards(vertex, next);
    path
      ..lineTo(entry.dx, entry.dy)
      ..quadraticBezierTo(vertex.dx, vertex.dy, exit.dx, exit.dy);
  }
  final firstEntry = pointTowards(first, vertices.last);
  final firstExit = pointTowards(first, vertices[1]);
  path
    ..lineTo(firstEntry.dx, firstEntry.dy)
    ..quadraticBezierTo(first.dx, first.dy, firstExit.dx, firstExit.dy)
    ..close();
  return path;
}
