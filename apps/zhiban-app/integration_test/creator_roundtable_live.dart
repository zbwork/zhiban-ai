import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/community_workspace_app.dart';
// The desktop plugin is supplied by zhiban_client.
// ignore: depend_on_referenced_packages
import 'package:window_manager/window_manager.dart';
import 'package:zhiban_client/layout/widgets/sidebar_nav_item.dart';
import 'package:zhiban_client/window/window_controller.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final key = GlobalKey();
  await WindowController.instance.init(hasToken: true);
  runApp(RepaintBoundary(key: key, child: const CommunityWorkspaceApp()));
  final controller = LiveWidgetController(binding);
  final output = await Directory.systemTemp.createTemp('roundtable-ui-');

  Future<void> waitFor(Finder finder) async {
    final until = DateTime.now().add(const Duration(seconds: 20));
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(until)) {
      await controller.pump(const Duration(milliseconds: 100));
    }
    if (finder.evaluate().length != 1) {
      throw StateError('Expected one: $finder');
    }
  }

  Future<void> tap(Finder finder) async {
    await waitFor(finder);
    await controller.tap(finder);
    await controller.pump(const Duration(milliseconds: 300));
  }

  Future<void> capture(String name) async {
    await controller.pump(const Duration(milliseconds: 300));
    await binding.endOfFrame;
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('${output.path}/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  }

  await tap(find.ancestor(
      of: find.text('博主圆桌'), matching: find.byType(SidebarNavItem)));
  const narrow = bool.fromEnvironment('ROUNDTABLE_NARROW');
  await windowManager
      .setSize(narrow ? const Size(900, 859) : const Size(1512, 859));
  await controller.pump(const Duration(milliseconds: 400));
  final stage = find.byKey(const ValueKey('roundtable-scene'));
  await waitFor(find.descendant(
    of: stage,
    matching: find.byWidgetPredicate(
        (widget) => widget is RawImage && widget.image != null),
  ));
  if (narrow) {
    final scene = stage.evaluate().single.renderObject! as RenderBox;
    if ((scene.size.aspectRatio - 1586 / 992).abs() > .01) {
      throw StateError('Tall window layout invalid: ${scene.size}');
    }
    await waitFor(find.text('向圆桌专家提问…'));
    await capture('roundtable-narrow');
    await tap(find.byKey(const ValueKey('roundtable-open-creators')));
    await waitFor(find.byKey(const ValueKey('roundtable-creators-drawer')));
    await capture('roundtable-narrow-creator-drawer');
    await tap(find.byTooltip('收起博主列表'));
    debugPrint('ROUNDTABLE_UI_PASSED ${output.path}');
    return;
  }
  await capture('roundtable');
  await tap(find.byKey(const ValueKey('roundtable-open-creators')));
  await tap(find.text('+ 添加博主'));
  await waitFor(find.text('粘贴链接或分享文案 *'));
  await capture('add-creator');
  await tap(find.text('读取作品'));
  await waitFor(find.text('请粘贴一条抖音作品链接或分享文本。'));
  await tap(find.text('取消'));
  await tap(find.text('知识资产'));
  await waitFor(find.text('暂无知识图谱'));
  await capture('knowledge');
  await tap(find.text('圆桌专家团'));
  await waitFor(stage);
  debugPrint('ROUNDTABLE_UI_PASSED ${output.path}');
}
