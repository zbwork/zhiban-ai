import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/pages/server_connection/server_connection_dialog.dart';
import 'package:zhiban_ui/themes/app_theme.dart';

void main() {
  testWidgets('connection form fits desktop and uses existing controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 620));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final preview = Platform.environment['ZHIBAN_PREVIEW_DIR'];
    if (preview != null) {
      final font = FontLoader('packages/zhiban_ui/HarmonyOS Sans SC')
        ..addFont(rootBundle.load(
            'packages/zhiban_ui/assets/fonts/harmonyos-sans/HarmonyOS_Sans_SC.ttf'));
      await tester.runAsync(font.load);
      final icons = FontLoader('packages/cupertino_icons/CupertinoIcons')
        ..addFont(rootBundle
            .load('packages/cupertino_icons/assets/CupertinoIcons.ttf'));
      await tester.runAsync(icons.load);
    }
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light().copyWith(
              textTheme: AppTheme.light()
                  .textTheme
                  .apply(fontFamily: 'packages/zhiban_ui/HarmonyOS Sans SC')),
          home: const Scaffold(
              body: ServerConnectionDialog(
                  initialAddress: 'https://ai.example.com')),
        )));
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.text('连接服务器'), findsOneWidget);
    expect(find.text('检测并连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (preview != null) {
      final boundary = boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(preview).create(recursive: true);
        await File('$preview/server-connection.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
  testWidgets(
      'failed probe preserves address and allows retry, success returns normalized address',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    String? selected;
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
          builder: (context) => Scaffold(
                  body: TextButton(
                child: const Text('open'),
                onPressed: () async {
                  selected = await showDialog<String>(
                      context: context,
                      builder: (_) => ServerConnectionDialog(
                          initialAddress: 'https://example.com',
                          probe: (value) async {
                            expect(value, 'https://example.com');
                            attempts++;
                            if (attempts == 1) {
                              throw const FormatException('无法连接，请重试');
                            }
                            return 'https://example.com/api/agent-bus/v1';
                          }));
                },
              ))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检测并连接'));
    await tester.pumpAndSettle();
    expect(find.text('无法连接，请重试'), findsOneWidget);
    expect(find.text('https://example.com'), findsOneWidget);
    await tester.tap(find.text('检测并连接'));
    await tester.pumpAndSettle();
    expect(selected, 'https://example.com/api/agent-bus/v1');
    expect(tester.takeException(), isNull);
  });
}
