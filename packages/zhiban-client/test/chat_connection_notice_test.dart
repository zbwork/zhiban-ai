import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_connection_notice.dart';

// kicked / 连接异常用户侧提示条(P3)。人↔人与群聊 pane 共用本组件,故 widget 测试覆盖两端。
// pane 是否显示由 controller.isConnectionKicked 门控(在 controller 测试覆盖),这里只测组件本身。

void main() {
  Future<void> pump(WidgetTester tester, VoidCallback onReLogin) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatConnectionNotice(onReLogin: onReLogin)),
      ),
    );
  }

  testWidgets('点击「重新登录」触发 onReLogin', (tester) async {
    var taps = 0;
    await pump(tester, () => taps++);
    expect(find.textContaining('其他设备登录'), findsOneWidget);
    expect(find.text('重新登录'), findsOneWidget);
    await tester.tap(find.text('重新登录'));
    expect(taps, 1);
  });
}
