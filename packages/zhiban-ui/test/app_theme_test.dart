import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_ui/themes/app_theme.dart';

void main() {
  group('AppTheme ink feedback', () {
    for (final entry in <String, ThemeData>{
      'light': AppTheme.light(),
      'dark': AppTheme.dark(),
    }.entries) {
      test('${entry.key} theme disables ripple but keeps state feedback', () {
        final theme = entry.value;

        expect(theme.splashFactory, same(NoSplash.splashFactory));
        expect(theme.splashColor, Colors.transparent);
        expect(theme.highlightColor, isNot(Colors.transparent));
        expect(theme.focusColor, isNot(Colors.transparent));
      });

      for (final useDialogStyle in [false, true]) {
        testWidgets(
            '${entry.key} text button feedback dialogStyle=$useDialogStyle',
            (tester) async {
          final theme = entry.value;
          final boundaryKey = GlobalKey();
          final focusNode = FocusNode();
          addTearDown(focusNode.dispose);
          var enabled = true;
          var taps = 0;
          late StateSetter rebuild;
          await tester.pumpWidget(MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Center(
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: Material(
                    color: theme.colorScheme.surface,
                    child: SizedBox(
                      width: 160,
                      height: 60,
                      child: StatefulBuilder(builder: (context, setState) {
                        rebuild = setState;
                        return TextButton(
                          focusNode: focusNode,
                          style: useDialogStyle
                              ? AppTheme.dialogActionStyle(context,
                                  primary: false)
                              : null,
                          onPressed: enabled ? () => taps++ : null,
                          child: const Text('Action'),
                        );
                      }),
                    ),
                  ),
                ),
              ),
            ),
          ));
          await tester.pumpAndSettle();

          Future<Color> backgroundPixel() async {
            return (await tester.runAsync(() async {
              final image = await (boundaryKey.currentContext!
                      .findRenderObject() as RenderRepaintBoundary)
                  .toImage();
              final bytes =
                  (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
              final offset = (30 * image.width + 20) * 4;
              final color = Color.fromARGB(
                bytes.getUint8(offset + 3),
                bytes.getUint8(offset),
                bytes.getUint8(offset + 1),
                bytes.getUint8(offset + 2),
              );
              image.dispose();
              return color;
            }))!;
          }

          final normal = await backgroundPixel();
          final gesture = await tester
              .startGesture(tester.getCenter(find.byType(TextButton)));
          await tester.pump(const Duration(milliseconds: 150));
          await tester.pump(const Duration(milliseconds: 250));
          final pressed = await backgroundPixel();
          final expected = Color.alphaBlend(
              useDialogStyle
                  ? theme.colorScheme.onSurface.withValues(alpha: 0.05)
                  : theme.colorScheme.primary.withValues(alpha: 0.10),
              normal);
          // The raster output quantizes floating-point theme colors to 8 bits.
          expect(pressed.r, closeTo(expected.r, 1 / 255));
          expect(pressed.g, closeTo(expected.g, 1 / 255));
          expect(pressed.b, closeTo(expected.b, 1 / 255));
          expect(taps, 0);
          await gesture.cancel();
          await tester.pumpAndSettle();
          expect(await backgroundPixel(), normal);
          expect(taps, 0);

          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          focusNode.requestFocus();
          await tester.pumpAndSettle();
          expect(await backgroundPixel(), isNot(normal));
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(taps, 1);

          rebuild(() => enabled = false);
          await tester.pumpAndSettle();
          await tester.tap(find.byType(TextButton));
          await tester.pumpAndSettle();
          expect(taps, 1);
          expect(await backgroundPixel(), normal);
        });
      }
    }
  });

  testWidgets('incoming page IME layout stays live during Android pop',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
    for (final brightness in Brightness.values) {
      final navigatorKey = GlobalKey<NavigatorState>();
      final boundaryKey = GlobalKey();
      var searching = false;
      late StateSetter rebuild;
      await tester.pumpWidget(MaterialApp(
        theme: (brightness == Brightness.light
                ? AppTheme.light()
                : AppTheme.dark())
            .copyWith(platform: TargetPlatform.android),
        home: RepaintBoundary(
            key: boundaryKey,
            child: StatefulBuilder(builder: (context, setState) {
              rebuild = setState;
              return Navigator(
                  key: navigatorKey,
                  pages: [
                    const NoTransitionPage(
                        child: Scaffold(
                      body: ClipRect(
                          child: Scaffold(
                              body: ColoredBox(
                                  color: Colors.blue,
                                  child: SizedBox.expand()))),
                      bottomNavigationBar: SizedBox(
                          height: 68, child: ColoredBox(color: Colors.grey)),
                    )),
                    if (searching)
                      const MaterialPage(
                          child: Scaffold(
                              body: ColoredBox(
                                  color: Colors.amber,
                                  child: SizedBox.expand()))),
                  ],
                  onDidRemovePage: (_) {});
            })),
      ));
      await tester.pumpAndSettle();
      rebuild(() => searching = true);
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      // Rasterize the incoming page while the keyboard is still closing.
      await tester.runAsync(() async {
        final img = await (boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
        img.dispose();
      });
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() async {
        final img = await (boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
        final bytes =
            (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final pos = (650 * img.width + 200) * 4;
        final rgba = [for (var i = 0; i < 4; i++) bytes.getUint8(pos + i)];
        expect(rgba, [33, 150, 243, 255],
            reason:
                '$brightness: returning content must repaint before the transition ends');
        img.dispose();
      });
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
