import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/cron_message_metadata.dart';
import 'package:zhiban_client/pages/chat/widgets/cron_message_chip.dart';

void main() {
  group('CronMessageChip widget (2026-06-12 设计稿头部行)', () {
    Future<void> pump(WidgetTester tester, CronMessageMetadata meta,
        {String? timeText, VoidCallback? onTap}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: CronMessageChip(
                meta: meta,
                timeText: timeText,
                onTap: onTap,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('trigger 头部: 定时任务 label + 任务名 pill + 已推送状态', (tester) async {
      final meta = CronMessageMetadata.tryParse({
        'triggered_by': 'cron',
        'cron_job_name': '销售日报',
      })!;
      await pump(tester, meta, timeText: '10:00');
      expect(find.byKey(const ValueKey('cron-message-chip')), findsOneWidget);
      expect(find.text('定时任务'), findsOneWidget);
      expect(find.text('销售日报'), findsOneWidget);
      expect(find.text('10:00'), findsOneWidget);
      expect(find.text('已推送'), findsOneWidget);
      expect(find.text('执行失败'), findsNothing);
      var tapped = 0;
      await pump(tester, meta, onTap: () => tapped++);
      expect(find.text('10:00'), findsNothing);
      expect(find.text('已推送'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cron-message-chip')));
      expect(tapped, 1);
    });

    testWidgets('failure notice 渲染红色失败状态', (tester) async {
      final meta = CronMessageMetadata.tryParse({
        'kind': 'cron_failure_notice',
        'cron_job_name': '销售日报',
      })!;
      await pump(tester, meta);
      expect(find.text('定时任务'), findsOneWidget);
      expect(find.text('销售日报'), findsOneWidget);
      expect(find.text('执行失败'), findsOneWidget);
      expect(find.text('已推送'), findsNothing);
      await pump(tester, CronMessageMetadata.tryParse({'kind': 'cron_failure_notice'})!);
      expect(find.text('定时任务'), findsNWidgets(2));
    });

    testWidgets('long job name uses ellipsis (no overflow exception)',
        (tester) async {
      // Flutter overflow 会 throw FlutterError; 这里塞超长任务名验证 ellipsis 生效.
      final longName = '这是一个非常非常非常非常非常非常非常非常非常非常长的任务名超出 chip 宽度' * 3;
      final meta = CronMessageMetadata.tryParse({
        'triggered_by': 'cron',
        'cron_job_name': longName,
      })!;
      await pump(tester, meta, timeText: '10:00');
      expect(tester.takeException(), isNull);
      final textFinder = find.byType(Text);
      expect(textFinder, findsWidgets);
    });

  });

}
