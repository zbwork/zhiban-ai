import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_selection.dart';

/// 桌面右键「一律自研菜单接管」的回归测试(2026-07 重做)。
///
/// 三个历史坑固化在此:
/// 1. [ChatSelectableSurface] 的 `contextMenuBuilder` 在 [ChatMessageSelectionScope]
///    内**恒定**返回空 widget —— 不再有"武装/解除"状态机,系统选区工具条在
///    气泡内任何触发路径下都不出现;不在任何 scope 内(独立展示场景)时退化为
///    普通可选中区域,系统工具条照常。
/// 2. 右键前的真实选区在 pointer-down 读走后,自研菜单「复制」复制选中片段。
/// 3. `SelectableRegion` 必须传实现了 `TextSelectionHandleControls` 的新版
///    controls(`cupertinoTextSelectionHandleControls`),旧版
///    `CupertinoTextSelectionControls` 会让它走 legacy buildToolbar 路径,
///    完全绕过 contextMenuBuilder。
/// 见 `docs/contracts/agent-bus-client-contract.md` §「消息操作菜单」。
void main() {
  const fullText = 'hello world example';

  Future<void> secondaryClick(WidgetTester tester, Offset pos) async {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.down(pos);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// 真实的人↔agent region:自研「复制」项 (isCopy) 整条复制固定写 WHOLE 哨兵,
  /// 便于区分片段复制路径。
  Widget hostRegion() {
    return MaterialApp(
      builder: BotToastInit(),
      home: Scaffold(
        body: ChatLocalMessageActionRegion(
          items: [
            ChatLocalMenuItem(
              icon: CupertinoIcons.doc_on_doc,
              label: '复制',
              isCopy: true,
              onSelected: () {
                // ignore: discarded_futures
                copyChatMessageText('WHOLE');
              },
            ),
          ],
          child: const ChatSelectableSurface(child: Text(fullText)),
        ),
      ),
    );
  }

  testWidgets('气泡内右键:只弹自研菜单,无系统工具条/箭头工具条', (tester) async {
    await tester.pumpWidget(hostRegion());

    await secondaryClick(tester, tester.getCenter(find.text(fullText)));

    // 新版 handle controls 下 contextMenuBuilder 生效:既没有 Material/桌面
    // 自适应工具条,也没有旧版 Cupertino 箭头工具条,只有自研菜单。
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    expect(find.byType(CupertinoTextSelectionToolbar), findsNothing);
    expect(find.text('复制'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('不在任何消息 region 内:系统工具条照常弹出(独立展示场景行为不变)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatSelectableSurface(child: Text(fullText))
        ),
      ),
    );

    await secondaryClick(tester, tester.getCenter(find.text(fullText)));

    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('region 无选区右键:只弹自研菜单,「复制」走整条复制', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(hostRegion());
    await secondaryClick(tester, tester.getCenter(find.text(fullText)));

    // 只出现自研菜单,系统工具条永不出现。
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    expect(find.text('复制'), findsOneWidget);

    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copied, 'WHOLE');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('region 拖选片段后右键:只弹自研菜单,「复制」复制选中片段', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(hostRegion());

    // 鼠标拖选一段文字。
    final textBox = tester.getRect(find.text(fullText));
    final start = Offset(textBox.left + 2, textBox.center.dy);
    final drag =
        await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await drag.moveBy(const Offset(60, 0));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    await secondaryClick(tester, tester.getCenter(find.text(fullText)));

    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    expect(find.text('复制'), findsOneWidget);

    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();

    // 复制的是选中片段:非空、非整条哨兵、且是原文的子串。
    expect(copied, isNotNull);
    expect(copied, isNot('WHOLE'));
    expect(copied!.trim(), isNotEmpty);
    expect(fullText.contains(copied!), isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
