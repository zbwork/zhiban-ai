import 'dart:io';

import 'package:flutter/material.dart';

const creatorRoundtableSceneSize = Size(1586, 992);

// Coordinates measured on the 800×500 review of the v20 scene. The portrait
// frame controls perspective; foreground outlines restore pixels from the
// empty scene wherever a chair should block the portrait.
const _portraitFrames = [
  Rect.fromLTRB(94, 211, 263, 444),
  Rect.fromLTRB(161, 53, 265, 161),
  Rect.fromLTRB(508, 49, 630, 164),
  Rect.fromLTRB(517, 211, 677, 446),
  Rect.fromLTRB(340, 27, 447, 124),
  Rect.fromLTRB(53, 113, 163, 251),
  Rect.fromLTRB(617, 115, 738, 259),
  Rect.fromLTRB(308, 260, 470, 438),
];

const _foreground = <int, List<Offset>>{
  0: [
    Offset(58, 313),
    Offset(65, 312),
    Offset(79, 324),
    Offset(93, 344),
    Offset(111, 377),
    Offset(118, 389),
    Offset(187, 372),
    Offset(197, 370),
    Offset(204, 377),
    Offset(208, 411),
    Offset(200, 424),
    Offset(121, 437),
    Offset(95, 431),
    Offset(80, 415),
    Offset(68, 376),
  ],
  3: [
    Offset(728, 314),
    Offset(720, 311),
    Offset(709, 317),
    Offset(692, 337),
    Offset(675, 364),
    Offset(661, 388),
    Offset(650, 395),
    Offset(597, 372),
    Offset(590, 372),
    Offset(585, 382),
    Offset(578, 406),
    Offset(584, 418),
    Offset(646, 436),
    Offset(670, 434),
    Offset(696, 418),
    Offset(715, 374),
  ],
  5: [
    Offset(51, 196),
    Offset(61, 210),
    Offset(68, 219),
    Offset(82, 224),
    Offset(102, 226),
    Offset(109, 224),
    Offset(113, 239),
    Offset(120, 254),
    Offset(108, 263),
    Offset(87, 264),
    Offset(69, 254),
    Offset(59, 234),
  ],
  6: [
    Offset(737, 193),
    Offset(732, 207),
    Offset(725, 221),
    Offset(714, 229),
    Offset(687, 234),
    Offset(672, 230),
    Offset(668, 247),
    Offset(659, 261),
    Offset(674, 268),
    Offset(699, 263),
    Offset(716, 251),
    Offset(726, 225),
  ],
  7: [
    Offset(331, 388),
    Offset(343, 395),
    Offset(349, 376),
    Offset(357, 369),
    Offset(384, 366),
    Offset(427, 367),
    Offset(442, 371),
    Offset(449, 391),
    Offset(459, 385),
    Offset(464, 399),
    Offset(452, 450),
    Offset(439, 455),
    Offset(352, 450),
    Offset(337, 444),
  ],
};

const _reviewSize = Size(800, 500);

class CreatorRoundtableSeatLayer extends StatelessWidget {
  const CreatorRoundtableSeatLayer({
    super.key,
    required this.slot,
    this.portrait,
  });

  final int slot;
  final Future<File?>? portrait;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      key: ObjectKey(portrait),
      future: portrait,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) return const SizedBox.expand();
        return LayoutBuilder(
          builder: (context, constraints) {
            final bounds = _seatRect(
              constraints.biggest,
              _portraitFrames[slot],
            );
            return ClipPath(
              clipper: _SeatForegroundClip(slot),
              child: Stack(
                children: [
                  Positioned.fromRect(
                    rect: bounds,
                    child: Image.file(
                      file,
                      key: ValueKey('generated-seat-$slot'),
                      alignment: Alignment.bottomCenter,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      excludeFromSemantics: true,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

Offset _scenePoint(Size size, Offset point) => Offset(
  point.dx * size.width / _reviewSize.width,
  point.dy * size.height / _reviewSize.height,
);

Rect _seatRect(Size size, Rect rect) => Rect.fromPoints(
  _scenePoint(size, rect.topLeft),
  _scenePoint(size, rect.bottomRight),
);

class _SeatForegroundClip extends CustomClipper<Path> {
  const _SeatForegroundClip(this.slot);

  final int slot;

  @override
  Path getClip(Size size) {
    if (size.isEmpty) return Path();
    final bounds = Path()..addRect(_seatRect(size, _portraitFrames[slot]));
    final foreground = _foreground[slot];
    if (foreground == null) return bounds;
    final chair = Path()
      ..addPolygon(
        foreground.map((point) => _scenePoint(size, point)).toList(),
        true,
      );
    return Path.combine(PathOperation.difference, bounds, chair);
  }

  @override
  bool shouldReclip(_SeatForegroundClip oldClipper) => oldClipper.slot != slot;
}
