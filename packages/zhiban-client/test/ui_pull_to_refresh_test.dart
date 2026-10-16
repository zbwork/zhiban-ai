import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/widgets/ui/ui_pull_to_refresh.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';

void main() {
  for (final failed in [false, true]) {
    testWidgets('下拉刷新等待真实请求后显示${failed ? '失败' : '完成'}', (tester) async {
      final controller = RefreshController();
      final request = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: UiPullToRefresh(
        controller: controller,
        onRefresh: () async {
          calls++;
          await request.future;
          if (failed) {
            controller.refreshFailed();
          } else {
            controller.refreshCompleted();
          }
        },
        child: ListView(
            children: const [SizedBox(height: 100, child: Text('列表内容'))]),
      ))));
      await tester.dragFrom(
          tester.getTopLeft(find.byType(SmartRefresher)) +
              const Offset(150, 50),
          const Offset(0, 350));
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (calls > 0) break;
      }
      expect(calls, 1);
      expect(controller.headerStatus, RefreshStatus.refreshing);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.headerStatus, RefreshStatus.refreshing);
      request.complete();
      await tester.pump();
      expect(controller.headerStatus,
          failed ? RefreshStatus.failed : RefreshStatus.completed);
      // ClassicHeader keeps completion feedback visible for 600 ms.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(
          tester
              .widget<SmartRefresher>(find.byType(SmartRefresher))
              .enablePullUp,
          isFalse);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('上拉分页保留无更多状态，刷新可重置', (tester) async {
    final controller = RefreshController();
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: UiPullToRefresh(
      controller: controller,
      enablePullUp: true,
      onRefresh: () {
        controller.refreshCompleted();
        controller.resetNoData();
      },
      onLoading: () {
        loads++;
        controller.loadNoData();
      },
      child: ListView(
          children: const [SizedBox(height: 1000, child: Text('列表内容'))]),
    ))));
    await tester.drag(find.byType(SmartRefresher), const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(controller.footerStatus, LoadStatus.noMore);
    await tester.drag(find.byType(SmartRefresher), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(loads, 1);
    await tester.drag(find.byType(SmartRefresher), const Offset(0, 1500));
    await tester.pumpAndSettle();
    await tester.dragFrom(
        tester.getTopLeft(find.byType(SmartRefresher)) + const Offset(150, 50),
        const Offset(0, 350));
    await tester.pumpAndSettle();
    expect(controller.footerStatus, LoadStatus.idle);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    expect(tester.takeException(), isNull);
  });
}
