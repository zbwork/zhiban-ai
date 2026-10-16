import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/window/window_controller.dart';

void main() {
  group('calculateInitialWindowPosition', () {
    const visiblePosition = Offset(120, 24);
    const visibleSize = Size(1440, 900);
    const windowSize = Size(1080, 820);

    test(
        'macOS keeps horizontal center and places one third of free space above',
        () {
      final position = calculateInitialWindowPosition(
        visiblePosition: visiblePosition,
        visibleSize: visibleSize,
        windowSize: windowSize,
        biasVerticallyUp: true,
      );

      expect(position.dx, 300);
      expect(position.dy, closeTo(50.67, 0.01));
    });

    test('other desktop platforms remain geometrically centered', () {
      final position = calculateInitialWindowPosition(
        visiblePosition: visiblePosition,
        visibleSize: visibleSize,
        windowSize: windowSize,
        biasVerticallyUp: false,
      );

      expect(position, const Offset(300, 64));
    });

    test('oversized windows do not move before the visible-area origin', () {
      final position = calculateInitialWindowPosition(
        visiblePosition: visiblePosition,
        visibleSize: visibleSize,
        windowSize: const Size(1600, 1000),
        biasVerticallyUp: true,
      );

      expect(position, visiblePosition);
    });
  });
}
