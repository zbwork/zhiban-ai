// F09 Phase B PR7 (B3-08): OrchestrationBlock widget 单测.
//
// 覆盖:
//  - 折叠态默认: header "💼 幕后协作 (N 步)" + 不展示 steps.
//  - 点击 header → 展开, 3 个 step 可见 (planner / worker / reducer).
//  - role 中文化 (planner=规划 / worker=执行 / reducer=汇总).
//  - status 'done' → '✓' 显示.
//  - 总计行: latency + tokens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zhiban_client/emp/blocks/orchestration_block.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('OrchestrationBlock', () {
    final data = <String, dynamic>{
      'plan_summary': '拆分用户问题为 3 个子任务',
      'default_collapsed': true,
      'total_tokens_in': 200,
      'total_tokens_out': 600,
      'total_latency_ms': 1200,
      'steps': <Map<String, dynamic>>[
        {
          'step_index': 1,
          'role': 'planner',
          'agent_name': '主控 Agent',
          'status': 'done',
          'tokens_in': 50,
          'tokens_out': 150,
        },
        {
          'step_index': 2,
          'role': 'worker',
          'agent_name': '调研 Agent',
          'status': 'done',
          'tokens_in': 100,
          'tokens_out': 300,
        },
        {
          'step_index': 3,
          'role': 'reducer',
          'agent_name': '汇总 Agent',
          'status': 'done',
          'tokens_in': 50,
          'tokens_out': 150,
        },
      ],
    };

    testWidgets('default_collapsed=true → header 可见, steps 不可见', (tester) async {
      await tester.pumpWidget(_wrap(OrchestrationBlock(data: data)));
      expect(find.text('幕后协作 (3 步)'), findsOneWidget);
      expect(find.text('主控 Agent'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
    });

    testWidgets('点击 header → 展开, 3 step 全见', (tester) async {
      await tester.pumpWidget(_wrap(OrchestrationBlock(data: data)));
      await tester.tap(find.text('幕后协作 (3 步)'));
      await tester.pumpAndSettle();
      expect(find.text('主控 Agent'), findsOneWidget);
      expect(find.text('调研 Agent'), findsOneWidget);
      expect(find.text('汇总 Agent'), findsOneWidget);
      // role chips 中文化
      expect(find.text('规划'), findsOneWidget);
      expect(find.text('执行'), findsOneWidget);
      expect(find.text('汇总'), findsOneWidget);
      // done status 显示 ✓
      expect(find.text('✓'), findsNWidgets(3));
      // 总计行: latency + tokens
      expect(find.text('1.2s · 800 tokens'), findsOneWidget);
      expect(find.byIcon(Icons.expand_less), findsOneWidget);
    });

    testWidgets('default_collapsed=false → 直接展开', (tester) async {
      final openData = Map<String, dynamic>.from(data)..['default_collapsed'] = false;
      await tester.pumpWidget(_wrap(OrchestrationBlock(data: openData)));
      // 不需点击; step 已可见
      expect(find.text('主控 Agent'), findsOneWidget);
    });

    testWidgets('latency<1000ms 显示 ms; ≥1000 显示 s 一位小数', (tester) async {
      final fastData = <String, dynamic>{
        'plan_summary': 't',
        'default_collapsed': false,
        'total_latency_ms': 750,
        'steps': <Map<String, dynamic>>[],
      };
      await tester.pumpWidget(_wrap(OrchestrationBlock(data: fastData)));
      expect(find.text('750ms'), findsOneWidget);
    });

    testWidgets('step.status=failed → ✗', (tester) async {
      final failData = <String, dynamic>{
        'plan_summary': 't',
        'default_collapsed': false,
        'steps': <Map<String, dynamic>>[
          {'step_index': 1, 'role': 'worker', 'agent_name': 'A', 'status': 'failed'},
        ],
      };
      await tester.pumpWidget(_wrap(OrchestrationBlock(data: failData)));
      expect(find.text('✗'), findsOneWidget);
    });
  });
}
