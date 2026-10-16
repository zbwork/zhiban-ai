import 'package:flutter/material.dart';

bool _isPhone(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.iOS ||
    Theme.of(context).platform == TargetPlatform.android;

/// Each mounted thumbnail owns its tag; identical URLs may appear many times.
class UiImageHero extends StatefulWidget {
  const UiImageHero({super.key, required this.builder});

  final Widget Function(BuildContext context, Object tag) builder;

  @override
  State<UiImageHero> createState() => _UiImageHeroState();
}

class _UiImageHeroState extends State<UiImageHero> {
  final Object _tag = Object();

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(context, _tag);
    return _isPhone(context) ? Hero(tag: _tag, child: child) : child;
  }
}

Widget imagePreviewHero({required Object? tag, required Widget child}) {
  if (tag == null) return child;
  return Hero(
    tag: tag,
    // Keep the already visible thumbnail while the full image resolves. The
    // destination may still be loading on the first frame of a push.
    flightShuttleBuilder: (_, animation, direction, from, to) {
      final source = direction == HeroFlightDirection.push ? from : to;
      final hero = source.widget as Hero;
      final size = (source.findRenderObject()! as RenderBox).size;
      return Material(
        type: MaterialType.transparency,
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
              width: size.width, height: size.height, child: hero.child),
        ),
      );
    },
    child: child,
  );
}

/// HeroController animates between PageRoutes, not dialog PopupRoutes.
Future<T?> showImagePreviewRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useSafeArea = true,
  Color? barrierColor,
}) {
  if (!_isPhone(context)) {
    return showDialog<T>(
        context: context,
        builder: builder,
        useSafeArea: useSafeArea,
        barrierColor: barrierColor);
  }
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return Navigator.of(context, rootNavigator: true).push<T>(PageRouteBuilder<T>(
    opaque: false,
    transitionDuration:
        reduceMotion ? Duration.zero : const Duration(milliseconds: 280),
    reverseTransitionDuration:
        reduceMotion ? Duration.zero : const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) =>
        FadeTransition(opacity: animation, child: builder(context)),
  ));
}
