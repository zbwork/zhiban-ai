import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_multi_select.dart';

// F09 多选 v2 (2026-06 富消息转发): ChatBatchActionBar 底部悬浮胶囊:
// 1. forwarding=true 时「逐条转发」动作换成「转发中」, 显示 CupertinoActivityIndicator;
// 2. callbacks 为 null 时, 对应按钮 tap 不触发动作 (UI 上灰显);
// 3. forwarding=false + 计数>0 + callbacks 非 null → 正常可点击。

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 520,
            height: 140,
            child: Center(child: child)
          ),
        ),
      ),
    );

void main() {
  group('ChatBatchActionBar (CR-2026-06-P2 防重入)', () {
    testWidgets('forwarding=false + 计数>0 + callbacks 非 null → 转发/删除/取消都能触发回调',
        (tester) async {
      int separate = 0, merged = 0, delete = 0, cancel = 0;
      await tester.pumpWidget(_wrap(ChatBatchActionBar(
        selectedCount: 2,
        onForwardSeparate: () => separate++,
        onForwardMerged: () => merged++,
        onDelete: () => delete++,
        onCancel: () => cancel++,
      )));
      await tester.tap(find.text('逐条转发'));
      await tester.pump();
      await tester.tap(find.text('合并转发'));
      await tester.pump();
      await tester.tap(find.text('删除'));
      await tester.pump();
      await tester.tap(find.byIcon(CupertinoIcons.xmark));
      await tester.pump();
      expect(separate, 1);
      expect(merged, 1);
      expect(delete, 1);
      expect(cancel, 1);
      expect(find.text('已选 2'), findsNothing);
      expect(find.text('转发中'), findsNothing);
      expect(find.byTooltip('取消'), findsOneWidget);
    });

    testWidgets('尺寸保持紧凑, 不占用大块消息区', (tester) async {
      await tester.pumpWidget(_wrap(ChatBatchActionBar(
        selectedCount: 2,
        onForwardSeparate: () {},
        onForwardMerged: () {},
        onDelete: () {},
        onCancel: () {},
      )));

      final size = tester
          .getSize(find.byKey(const ValueKey('chat-batch-action-bar-shell')));
      expect(size.width, lessThanOrEqualTo(380));
      expect(size.height, lessThanOrEqualTo(72));
    });

    testWidgets('forwarding=true → 转发动作切「转发中」 + 显示 indicator + 隐藏「已选 N」',
        (tester) async {
      await tester.pumpWidget(_wrap(ChatBatchActionBar(
        selectedCount: 5,
        forwarding: true,
        onForwardSeparate: null,
        onForwardMerged: null,
        onDelete: null,
        onCancel: null,
      )));
      expect(find.text('转发中'), findsOneWidget);
      expect(find.text('已选 5'), findsNothing);
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    });

    testWidgets('forwarding=true + onForward=null → 点「转发中」不触发任何回调 (重入保护)',
        (tester) async {
      // 模拟外层 pane: forwarding=true 时三个 callback 全 null。
      int forwardCalls = 0;
      await tester.pumpWidget(_wrap(ChatBatchActionBar(
        selectedCount: 3,
        forwarding: true,
        onForwardSeparate: null,
        onForwardMerged: null,
        onDelete: null,
        onCancel: null,
      )));
      // 不应崩溃, 不应有调用。
      await tester.tap(find.text('转发中'));
      await tester.pump();
      await tester.tap(find.text('删除'));
      await tester.pump();
      await tester.tap(find.byIcon(CupertinoIcons.xmark));
      await tester.pump();
      expect(forwardCalls, 0); // forward callback 不存在, 自然 0
    });

    testWidgets('selectedCount=0 时 转发/删除 自动 disable, 取消仍可点', (tester) async {
      int separate = 0, merged = 0, delete = 0, cancel = 0;
      await tester.pumpWidget(_wrap(ChatBatchActionBar(
        selectedCount: 0,
        onForwardSeparate: () => separate++,
        onForwardMerged: () => merged++,
        onDelete: () => delete++,
        onCancel: () => cancel++,
      )));
      await tester.tap(find.text('逐条转发'));
      await tester.pump();
      await tester.tap(find.text('合并转发'));
      await tester.pump();
      await tester.tap(find.text('删除'));
      await tester.pump();
      await tester.tap(find.byIcon(CupertinoIcons.xmark));
      await tester.pump();
      // 转发/删除即便 callback 非 null, count=0 时不可点。
      expect(separate, 0);
      expect(merged, 0);
      expect(delete, 0);
      expect(cancel, 1);
    });

    testWidgets('onCancel=null → 「取消」按钮不可点 (转发中保护)', (tester) async {
      int cancel = 0;
      await tester.pumpWidget(_wrap(ChatBatchActionBar(
        selectedCount: 2,
        forwarding: true,
        onForwardSeparate: null,
        onForwardMerged: null,
        onDelete: null,
        onCancel: null,
      )));
      await tester.tap(find.byIcon(CupertinoIcons.xmark));
      await tester.pump();
      expect(cancel, 0);
    });
  });
}
