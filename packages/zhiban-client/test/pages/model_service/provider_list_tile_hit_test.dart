import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/widgets/provider_list_tile.dart';

void main() {
  for (final withHandle in [false, true]) {
    testWidgets('whole background is clickable; handle=$withHandle',
        (tester) async {
      var taps = 0;
      var handleTaps = 0;
      var drags = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Center(
        child: SizedBox(
            width: 260,
            child: ProviderListTile(
              name: 'Alpha',
              iconAssetPath: null,
              enabled: true,
              selected: true,
              onTap: () => taps++,
              dragHandle: withHandle
                  ? GestureDetector(
                      key: const ValueKey('handle'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => handleTaps++,
                      onPanStart: (_) => drags++,
                      child: const Icon(Icons.drag_indicator, size: 12),
                    )
                  : null,
            )),
      ))));
      final rect = tester.getRect(
          find.byKey(const ValueKey('provider-list-tile-surface-Alpha')));
      for (final point in [
        rect.topLeft + const Offset(1, 1),
        rect.topRight + const Offset(-1, 1),
        rect.bottomLeft + const Offset(1, -1),
        rect.bottomRight + const Offset(-1, -1),
        rect.center,
      ]) {
        await tester.tapAt(point);
        await tester.pump();
      }
      expect(taps, 5);
      await tester.tapAt(rect.topLeft - const Offset(1, 1));
      await tester.pump();
      expect(taps, 5);
      if (withHandle) {
        await tester.tap(find.byKey(const ValueKey('handle')));
        await tester.drag(
            find.byKey(const ValueKey('handle')), const Offset(0, 40));
        await tester.pump();
        expect(handleTaps, 1);
        expect(drags, 1);
        expect(taps, 5);
      }
    });
  }
}
