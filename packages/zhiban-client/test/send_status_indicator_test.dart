import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/send_status_indicator.dart';

// 发送态 UI 最小闭环 (WuKongIM reliability P0)。
// 人↔人气泡 (_Bubble) 与群聊气泡 (_GroupBubble) 都通过同一个 [ChatSendStatusIndicator]
// 渲染发送态 —— 直接 pump 该组件即可覆盖两个 pane 的发送态展示与「仅自己/仅非 sent」门控。

Future<void> _pump(
  WidgetTester tester, {
  required bool isPeer,
  required ImSendStatus status,
  String errorMessage = '',
  VoidCallback? onRetry,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ChatSendStatusIndicator(
            isPeer: isPeer,
            status: status,
            errorMessage: errorMessage,
            onRetry: onRetry,
          ),
        ),
      ),
    ),
  );
}

Finder get _loading => find.byType(CupertinoActivityIndicator);
Finder get _failedIcon =>
    find.byIcon(CupertinoIcons.exclamationmark_circle_fill);

void main() {
  group('ChatSendStatusIndicator (人↔人)', () {
    testWidgets('自己 pending → 显示发送中 loading', (tester) async {
      await _pump(tester, isPeer: false, status: ImSendStatus.pending);
      expect(_loading, findsOneWidget);
      expect(_failedIcon, findsNothing);
    });

    testWidgets('自己 failed → 红色失败标识 + tooltip 用 errorMessage', (tester) async {
      await _pump(tester,
          isPeer: false, status: ImSendStatus.failed, errorMessage: '已被对方拉黑');
      expect(_failedIcon, findsOneWidget);
      expect(find.byTooltip('已被对方拉黑'), findsOneWidget);
      expect(_loading, findsNothing);
    });

    testWidgets('自己 failed 且 errorMessage 为空 → tooltip 回退「发送失败」',
        (tester) async {
      await _pump(tester, isPeer: false, status: ImSendStatus.failed);
      expect(find.byTooltip('发送失败'), findsOneWidget);
    });

    testWidgets('自己 sent → 不显示额外状态 (收缩不占位)', (tester) async {
      await _pump(tester, isPeer: false, status: ImSendStatus.sent);
      expect(_loading, findsNothing);
      expect(_failedIcon, findsNothing);
      final size = tester.getSize(find.byType(ChatSendStatusIndicator));
      expect(size, Size.zero); // SizedBox.shrink
    });
  });

  group('ChatSendStatusIndicator (对端不显示发送态)', () {
    testWidgets('对端 pending → 不显示发送态', (tester) async {
      await _pump(tester, isPeer: true, status: ImSendStatus.pending);
      expect(_loading, findsNothing);
      expect(_failedIcon, findsNothing);
    });

    testWidgets('对端 failed → 不显示发送态', (tester) async {
      await _pump(tester,
          isPeer: true, status: ImSendStatus.failed, errorMessage: '发送失败');
      expect(_failedIcon, findsNothing);
      expect(find.byTooltip('发送失败'), findsNothing);
    });
  });

  group('ChatSendStatusIndicator onRetry 重发 (P1)', () {
    testWidgets('自己 failed + onRetry → 点击失败标识触发重发', (tester) async {
      var taps = 0;
      await _pump(tester,
          isPeer: false,
          status: ImSendStatus.failed,
          errorMessage: '发送失败',
          onRetry: () => taps++);
      expect(_failedIcon, findsOneWidget);
      await tester.tap(_failedIcon);
      expect(taps, 1);
      // tooltip 仍保留
      expect(find.byTooltip('发送失败'), findsOneWidget);
    });

    testWidgets('自己 pending + onRetry → 无失败标识、不可点(onRetry 不触发)',
        (tester) async {
      var taps = 0;
      await _pump(tester,
          isPeer: false, status: ImSendStatus.pending, onRetry: () => taps++);
      expect(_failedIcon, findsNothing);
      expect(_loading, findsOneWidget);
      expect(taps, 0);
    });

    testWidgets('对端 failed + onRetry → 不显示、不可点', (tester) async {
      var taps = 0;
      await _pump(tester,
          isPeer: true, status: ImSendStatus.failed, onRetry: () => taps++);
      expect(_failedIcon, findsNothing);
      expect(taps, 0);
    });


  });
}
