// Local-only UI verification. Launch with an independent bundle ID.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexwork/community_workspace_app.dart';
import 'package:zhiban_client/layout/widgets/sidebar_nav_item.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/prompt_input.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_card.dart';
import 'package:zhiban_client/window/window_controller.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final screen = GlobalKey();
  await WindowController.instance.init(hasToken: true);
  runApp(RepaintBoundary(key: screen, child: const CommunityWorkspaceApp()));
  final controller = LiveWidgetController(binding);
  const live = bool.fromEnvironment('VERIFY_GITHUB');
  final dir = Directory(live
      ? '/tmp/github-online-resources-ui'
      : '/tmp/github-split-resources-ui');
  await dir.create(recursive: true);
  Future<void> wait(Finder f) async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (f.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await controller.pump(const Duration(milliseconds: 100));
    }
    if (f.evaluate().isEmpty) throw StateError('UI absent: $f');
  }

  Future<void> tap(Finder f) async {
    await wait(f);
    await controller.tap(f);
    await controller.pump(const Duration(milliseconds: 200));
  }

  Future<void> nav(String label) => tap(find.ancestor(
      of: find.text(label), matching: find.byType(SidebarNavItem)));
  Future<void> shot(String name) async {
    await controller.pump(const Duration(seconds: 1));
    // Asset placeholders also contain RawImage: require the network provider
    // and its decoded pixels, otherwise a default robot falsely passes.
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    bool decodedNetworkImage(Element image) => find
            .descendant(
                of: find.byWidget(image.widget),
                matching: find.byType(RawImage))
            .evaluate()
            .any((raw) {
          if ((raw.widget as RawImage).image == null) return false;
          // Image.frameBuilder nests the AssetImage fallback under the network
          // Image itself. Attribute pixels to their nearest Image owner.
          var sameOwner = false;
          raw.visitAncestorElements((ancestor) {
            if (ancestor.widget is! Image) return true;
            sameOwner = identical(ancestor, image);
            return false;
          });
          return sameOwner;
        });
    bool loaded() =>
        find.byType(CachedNetworkImage).evaluate().every((e) => find
            .descendant(
                of: find.byWidget(e.widget),
                matching: find.byWidgetPredicate(
                    (w) => w is Image && w.image is CachedNetworkImageProvider))
            .evaluate()
            .any(decodedNetworkImage));
    while (!loaded() && DateTime.now().isBefore(deadline)) {
      await controller.pump(const Duration(milliseconds: 150));
    }
    if (!loaded()) {
      throw StateError(
          'Resource image failed to decode or still shows fallback');
    }
    // Network decode completes before OctoImage removes its placeholder.
    // Let the next painted frame reach the capture boundary.
    await controller.pump(const Duration(milliseconds: 300));
    await controller.pump();
    await binding.endOfFrame;
    final image = await (screen.currentContext!.findRenderObject()!
            as RenderRepaintBoundary)
        .toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (live) {
      final urls = find
          .byType(CachedNetworkImage)
          .evaluate()
          .map((e) {
            final widget = e.widget as CachedNetworkImage;
            final uri = Uri.parse(widget.imageUrl);
            if (uri.host != 'zbwork.github.io' ||
                uri.scheme != 'https' ||
                (widget.httpHeaders ?? {})
                    .keys
                    .any((k) => k.toLowerCase() == 'authorization')) {
              throw StateError('Unexpected image source or credential header');
            }
            return widget.imageUrl;
          })
          .toSet()
          .toList();
      if (urls.isEmpty) throw StateError('No real resource images in view');
      await File('${dir.path}/$name-urls.json').writeAsString(jsonEncode(urls));
    }
    await File('${dir.path}/$name.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  }

  final result = <String, Object?>{};
  try {
    await nav('数字员工');
    await wait(find.text('个人任务规划专家'));
    await shot('employees');
    result['employeeCatalog'] = true;
    await tap(find.text('个人任务规划专家'));
    await shot('employee-detail');
    await tap(find.text('去聊天'));
    await wait(find.byType(PromptInput));
    await shot('employee-installed');
    result['employeeWithSkillsInstalled'] = true;
    await nav('技能广场');
    await wait(find.byType(SkillCard));
    await shot('skills');
    result['skillCatalog'] = true;
    await nav('数字员工');
    await wait(find.text('个人任务规划专家'));
    await shot('employees-reopened');
    result['status'] = 'passed';
  } catch (e, stack) {
    result['status'] = 'failed';
    result['error'] = e.toString();
    debugPrint('$e\n$stack');
    // Preserve the original failure even when screenshot capture also fails.
    result['stack'] = stack.toString();
  }
  await File('${dir.path}/checks.json').writeAsString(jsonEncode(result));
}
