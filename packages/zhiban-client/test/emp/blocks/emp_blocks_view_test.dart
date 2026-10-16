// emp_blocks_view_test.dart — Plan 16 Batch 2 (2026-06-08) widget tests.
//
// 锁住 EmpBlocksView 的关键纪律 (与 emp_block_readable_text_test 互补):
//   - 只读: form / approval / action 的所有按钮 / 输入都 disabled, 不能伪造提交;
//   - 字段不规范 best-effort: malformed block (Map/String 错型) 不抛, 仍能绘制其它 block;
//   - 顺序保留: markdown + chart + table 混排顺序与输入 blocks 数组一致;
//   - 空 blocks → 不挂任何子 widget (避免在气泡里挤出空白)。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_chart/fl_chart.dart' as fl;
import 'package:zhiban_client/emp/blocks/emp_blocks_view.dart';
import 'package:zhiban_core/chat/chat_message_tree.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_assistant_message_view.dart';
import 'package:zhiban_client/pages/chat/widgets/file_attachment_icon.dart';
import 'package:zhiban_client/pages/chat/widgets/file_preview/chat_artifact_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Tests run in a 800x600 viewport; some block lists are taller. Wrap in scroll view
// so we can verify content existence without RenderFlex overflow noise. Production
// 使用方 (chat 气泡) 本来就在 ListView/Column 中, 不会撞 600px 限制。
Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('EmpBlocksView read-only rendering', () {
    testWidgets('empty blocks → SizedBox.shrink (不挤气泡)', (tester) async {
      await tester.pumpWidget(_wrap(const EmpBlocksView(blocks: [])));
      // 不应找到任何 Card / Text 显式渲染
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('markdown + chart + table 混排顺序与输入一致', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {'type': 'markdown', 'text': '# 月度报告'},
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'title': '月度数据',
          'data': [
            {'label': '一月', 'value': 10},
            {'label': '二月', 'value': 24},
          ],
        },
        {
          'type': 'table',
          'title': '明细',
          'headers': ['部门', '人数'],
          'rows': [
            ['财务', 12],
            ['法务', 8],
          ],
        },
      ])));
      // 各 type 都至少有标志性文本可见 (区别是它们是真渲染, 不只是 readable text)
      expect(find.text('月度数据 · bar'), findsOneWidget);
      expect(find.text('明细'), findsOneWidget);
      // markdown 内容会被 markdown 渲染器拆 token, 不一定整段命中; 看 chart bar label
      expect(find.text('一月'), findsOneWidget);
      expect(find.text('二月'), findsOneWidget);
      expect(find.text('部门'), findsOneWidget);
      expect(find.text('财务'), findsOneWidget);
    });

    testWidgets('form 渲染: 字段 disabled + 提交按钮 disabled + 独立禁用原因',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'form',
          'title': '请假申请',
          'description': '请填写理由和起止日期',
          'submit_label': '提交请假申请',
          'fields': [
            {'label': '理由', 'type': 'text', 'placeholder': '请输入'},
            {'label': '起止日期', 'type': 'date'},
          ],
        },
      ])));
      // submit_label 是按钮动作文案; 不可提交原因单独展示。
      expect(find.text('提交请假申请'), findsOneWidget);
      expect(find.text('需在客户端最新版查看完整组件'), findsNothing);
      expect(find.text('当前客户端版本暂不支持填写此表单，请升级后重试'), findsOneWidget);
      // 提交按钮存在但 disabled (onPressed == null)
      final btn = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(btn.onPressed, isNull);
      // 字段 TextField 也 disabled
      final tf = tester.widgetList<TextField>(find.byType(TextField)).first;
      expect(tf.enabled, isFalse);
    });

    testWidgets('form 字段 value 初始值 seed 进表单态 (契约 §3.0a 草稿回填)', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'form',
          'title': '修改注册信息',
          'fields': [
            {'name': 'brand', 'label': '字号', 'type': 'text', 'value': '知未'},
            {'name': 'city', 'label': '城市', 'type': 'text'},
          ],
        },
      ])));
      // 带 value 的字段显示回填值; 不带的保持空白。断言走 EditableText
      // (控件无关——实现已从 TextFormField 换成 TextField, 旧断言锈死)。
      expect(find.text('知未'), findsOneWidget);
      final editables =
          tester.widgetList<EditableText>(find.byType(EditableText)).toList();
      expect(editables, hasLength(2));
      expect(editables[0].controller.text, '知未');
      expect(editables[1].controller.text, isEmpty); // 无 value 字段保持空白
    });

    testWidgets('approval 渲染: 同意/拒绝按钮都 disabled, 不触发任何回调', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'approval',
          'title': '差旅 3500',
          'summary': '请审批本次差旅费用'
        },
      ])));
      // 同意 + 拒绝 button 都 disabled
      final outlined =
          tester.widget<OutlinedButton>(find.byType(OutlinedButton));
      expect(outlined.onPressed, isNull);
      final elevated =
          tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(elevated.onPressed, isNull);
      expect(find.text('同意'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
      expect(find.textContaining('暂不支持'), findsOneWidget);
    });

    testWidgets('action 渲染: 每个 button disabled', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'action',
          'title': '请选择',
          'actions': [
            {'label': '继续'},
            {'label': '中止'},
          ],
        },
      ])));
      final buttons = tester.widgetList<TextButton>(find.byType(TextButton));
      expect(buttons.length, greaterThanOrEqualTo(2));
      for (final b in buttons) {
        expect(b.onPressed, isNull, reason: 'action 按钮必须全部 disabled (B2 只读)');
      }
    });

    testWidgets('artifact / source / app_card / progress / plan / error 都能渲染',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {'type': 'artifact', 'artifact_kind': 'image', 'name': 'cover.png'},
        {'type': 'source', 'title': 'wiki', 'url': 'https://example.com/x'},
        {'type': 'app_card', 'title': '审批中心', 'summary': '本月待审 5 单'},
        {'type': 'progress', 'percent': 42, 'label': '上传'},
        {
          'type': 'plan',
          'title': 'OA',
          'steps': [
            {'title': '提交申请'},
            {'title': '主管审批'},
          ],
        },
        {'type': 'error', 'message': '生成失败'},
      ])));
      expect(find.text('cover.png'), findsOneWidget);
      // source 渲染 — 应可见 title
      expect(find.text('wiki'), findsOneWidget);
      // app_card summary
      expect(find.text('本月待审 5 单'), findsOneWidget);
      // progress percent
      expect(find.text('42%'), findsOneWidget);
      // plan 步骤序号 + 标题
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('提交申请'), findsOneWidget);
      // error
      expect(find.text('生成失败'), findsOneWidget);
    });

    testWidgets('artifact 内嵌 text → 可点文档卡, 点击弹框显示全文 (协议卡)', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'artifact',
          'artifact_kind': 'agreement',
          'name': '《企业注册代办服务协议》',
          'text': '**第一条** 服务内容弹框测试正文',
        },
      ])));
      expect(find.text('《企业注册代办服务协议》'), findsOneWidget);
      expect(find.text('查看全文'), findsOneWidget);
      expect(find.textContaining('弹框测试正文'), findsNothing); // 未点击不展开
      await tester.tap(find.text('查看全文'));
      await tester.pumpAndSettle();
      expect(find.textContaining('服务内容弹框测试正文'), findsWidgets); // 弹框内全文
    });

    testWidgets('tool_call / tool_result / reasoning 不在正文 EMP 区渲染',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'tool_call',
          'tool': 'policy_lookup',
          'status': 'running',
          'summary': '正在查询接待制度',
        },
        {'type': 'tool_result', 'name': 'search_kb', 'status': 'done'},
        {'type': 'reasoning', 'text': '先确认制度，再生成行政服务申请表。'},
        {'type': 'markdown', 'text': '最终答复'},
      ])));
      expect(find.text('工具调用 · policy_lookup'), findsNothing);
      expect(find.text('工具结果 · search_kb'), findsNothing);
      expect(find.text('推理过程'), findsNothing);
      expect(find.text('最终答复'), findsOneWidget);
    });

    testWidgets('suggestion / mermaid / flowchart 终态都能可见展示', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'suggestion',
          'suggestions': [
            {'label': '填写行政服务申请'},
            {'text': '查询可用会议室'},
          ],
        },
        {'type': 'mermaid', 'source': 'graph TD; A-->B;'},
        {'type': 'flowchart', 'code': 'start=>start: 开始'},
      ])));

      expect(find.text('填写行政服务申请'), findsOneWidget);
      expect(find.text('查询可用会议室'), findsOneWidget);
      expect(find.text('图表源码 · mermaid'), findsOneWidget);
      expect(find.text('graph TD; A-->B;'), findsOneWidget);
      expect(find.text('图表源码 · flowchart'), findsOneWidget);
      expect(find.text('start=>start: 开始'), findsOneWidget);
    });

    testWidgets(
        'malformed: action.actions 是 Map / form.fields 是 String → 不崩, 仍渲染 card',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'action',
          'title': '坏 action',
          'actions': {'oops': 'should be list'},
        },
        {
          'type': 'form',
          'title': '坏 form',
          'fields': 'not-a-list'
        },
        {
          'type': 'plan',
          'title': '坏 plan',
          'steps': 'invalid'
        },
        {'type': 'markdown', 'text': '尾部 markdown 仍可见'},
      ])));
      // 4 个 block 都不应该让 pump 抛异常; 末尾 markdown 必须可见
      expect(find.text('尾部 markdown 仍可见'), findsOneWidget);
      // 即便 action 的 actions 错型, 也至少显示 card title
      expect(find.text('操作 · 坏 action'), findsOneWidget);
    });

    testWidgets('unknown type → 走 readable text fallback, 不抽空', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {'type': 'super_widget_v9', 'title': '未来组件'},
      ])));
      // unknown 走 empBlocksToReadableText → "[super_widget_v9] 未来组件"
      expect(find.textContaining('[super_widget_v9]'), findsOneWidget);
    });

    testWidgets('chart 没有 data 也不崩, 显示 placeholder (round-9 富 fallback)',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {'type': 'chart', 'chart_kind': 'line', 'title': 'X'},
      ])));
      expect(find.text('X · line'), findsOneWidget);
      // round-9 改成 banner 文案 "暂无可视化数据 · 已退化为可读视图" (替代旧的 "数据为空")
      expect(find.textContaining('暂无可视化数据'), findsOneWidget);
    });

    testWidgets('非 markdown/plain block 中的字段类型错 (chart.data 是 String) 不崩',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {'type': 'chart', 'title': 'C', 'data': 'not-a-list'},
        {'type': 'markdown', 'text': 'after'},
      ])));
      expect(find.text('after'), findsOneWidget);
    });
  });

  // ADR-0028 §4.9 — HITL 可交互回调 4 条件 enable + 提交语义。
  group('EmpBlocksView HITL 可交互', () {
    EmpBlocksRespondHandler fakeHandler({
      bool approvalOk = true,
      bool confirmOk = true,
      bool formOk = true,
      bool actionOk = true,
      void Function(String decision, String? reason)? onApprovalCall,
      void Function(bool confirmed)? onConfirmCall,
      void Function(Map<String, dynamic> fields)? onFormCall,
      void Function(String actionId)? onActionCall,
    }) {
      return EmpBlocksRespondHandler(
        onApproval: ({
          required String agentMessageUuid,
          required String decision,
          String? reason,
        }) async {
          onApprovalCall?.call(decision, reason);
          return approvalOk;
        },
        onConfirm: ({
          required String agentMessageUuid,
          required bool confirmed,
        }) async {
          onConfirmCall?.call(confirmed);
          return confirmOk;
        },
        onForm: ({
          required String agentMessageUuid,
          required Map<String, dynamic> fields,
        }) async {
          onFormCall?.call(fields);
          return formOk;
        },
        onAction: ({
          required String agentMessageUuid,
          required String actionId,
          Map<String, dynamic>? params,
        }) async {
          onActionCall?.call(actionId);
          return actionOk;
        },
      );
    }

    testWidgets('approval: 4 条件不满足 (无 handler) → 同意/拒绝按钮 disabled',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'approval', 'title': 'A'},
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        // respondHandler 为 null → 不允许交互 (B1+B2 旧行为)。
      )));
      final agree = find.widgetWithText(ElevatedButton, '同意');
      final reject = find.widgetWithText(OutlinedButton, '拒绝');
      expect(agree, findsOneWidget);
      expect(reject, findsOneWidget);
      expect(tester.widget<ElevatedButton>(agree).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(reject).onPressed, isNull);
    });

    testWidgets(
        'approval: status != awaiting_user → 按钮 disabled (即使 handler 装齐)',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'approval', 'title': 'A'},
        ],
        agentMessageStatus: 'final', // 已 final, 不再 awaiting
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(),
      )));
      expect(
        tester
            .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '同意'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('approval: 4 条件全满足 → 点同意调 handler, decision=approve',
        (tester) async {
      String? capturedDecision;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'approval', 'title': 'A'},
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          onApprovalCall: (d, _) => capturedDecision = d,
        ),
      )));
      await tester.tap(find.widgetWithText(ElevatedButton, '同意'));
      await tester.pump(); // 启动 future
      await tester.pump(const Duration(milliseconds: 10));
      expect(capturedDecision, 'approve');
    });

    testWidgets(
        'approval reject 两阶段 (round-8): 第一次点拒绝 → 展开 reason 输入框, 第二次"确认拒绝"才提交',
        (tester) async {
      String? capturedDecision;
      String? capturedReason;
      var callCount = 0;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'approval', 'title': 'A'},
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          onApprovalCall: (d, r) {
            callCount++;
            capturedDecision = d;
            capturedReason = r;
          },
        ),
      )));
      // 第一次点"拒绝" → 不直接提交; 应展开 reason 输入框并切到 "确认拒绝"
      await tester.tap(find.widgetWithText(OutlinedButton, '拒绝'));
      await tester.pump();
      expect(callCount, 0, reason: '第一次点拒绝不应立即提交');
      expect(find.widgetWithText(ElevatedButton, '确认拒绝'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      // 填原因
      await tester.enterText(find.byType(TextField), '差旅超预算');
      await tester.pump();
      // 第二次点 "确认拒绝" → 真提交
      await tester.tap(find.widgetWithText(ElevatedButton, '确认拒绝'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(callCount, 1);
      expect(capturedDecision, 'reject');
      expect(capturedReason, '差旅超预算');
    });

    testWidgets('approval reject 两阶段: 用户在 reason 输入区点"取消"回到第一阶段 (不提交)',
        (tester) async {
      var callCount = 0;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'approval', 'title': 'A'},
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          onApprovalCall: (_, __) => callCount++),
        ),
      ),);
      await tester.tap(find.widgetWithText(OutlinedButton, '拒绝'));
      await tester.pump();
      expect(find.widgetWithText(ElevatedButton, '确认拒绝'), findsOneWidget);
      // 点 "取消" — 应回到第一阶段; 主按钮恢复 "同意"
      await tester.tap(find.widgetWithText(OutlinedButton, '取消'));
      await tester.pump();
      expect(find.widgetWithText(ElevatedButton, '同意'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(callCount, 0);
    });

    testWidgets(
        'approval reject 两阶段: reason 留空也允许提交, decision=reject + reason=null',
        (tester) async {
      String? capturedDecision;
      String? capturedReason;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'approval', 'title': 'A'},
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          onApprovalCall: (d, r) {
            capturedDecision = d;
            capturedReason = r;
          },
        ),
      )));
      await tester.tap(find.widgetWithText(OutlinedButton, '拒绝'));
      await tester.pump();
      // 不填 reason, 直接确认
      await tester.tap(find.widgetWithText(ElevatedButton, '确认拒绝'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(capturedDecision, 'reject');
      expect(capturedReason, isNull); // 空 trim → null
    });

    testWidgets('approval reject 两阶段: handler 返 false 解锁, reason 输入框仍保留以便重试',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'approval', 'title': 'A'},
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          approvalOk: false,
          onApprovalCall: (_, __) => calls++,
        ),
      )));
      await tester.tap(find.widgetWithText(OutlinedButton, '拒绝'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '原因');
      await tester.pump();
      // 第一次提交 → 失败 → 解锁
      await tester.tap(find.widgetWithText(ElevatedButton, '确认拒绝'));
      await tester.pump(const Duration(milliseconds: 30));
      // reason 输入框仍在
      expect(find.byType(TextField), findsOneWidget);
      // 重新提交 → 又一次 call
      await tester.tap(find.widgetWithText(ElevatedButton, '确认拒绝'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(calls, 2);
    });

    testWidgets('approval: handler 返 false (失败) → 按钮重新可点 (解锁)', (tester) async {
      var calls = 0;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'approval', 'title': 'A'},
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          approvalOk: false,
          onApprovalCall: (_, __) => calls++,
        ),
      )));
      await tester.tap(find.widgetWithText(ElevatedButton, '同意'));
      // 第一次启动: 文本切到"处理中"
      await tester.pump();
      // 等 future 完成 + setState
      await tester.pump(const Duration(milliseconds: 30));
      // 再点一次, 因为失败已解锁。
      await tester.tap(find.widgetWithText(ElevatedButton, '同意'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(calls, 2);
    });

    // ----- confirm 类型 (后端 response_kind='confirm' + payload={confirmed: bool}) -----
    //
    // 后端 [buildRespondReplyBlock](services/agent-bus/internal/service/chat/respond.go):
    //   - approval → reads `decision` (`approve`/`reject`)
    //   - confirm  → reads `confirmed` (true/false)
    // 客户端如果把 confirm 错误映射成 approval, runtime 会拿到 `{decision:'approve'}`,
    // confirm 业务需要的 `confirmed` 字段缺失 → 业务卡死。下面三个 case 锁住语义。

    testWidgets(
        'confirm: 点确认 (positive) → 调 onConfirm, confirmed=true; 不调 onApproval',
        (tester) async {
      var approvalCalls = 0;
      bool? capturedConfirmed;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'confirm', 'title': '是否确认重启服务？'},
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          onApprovalCall: (_, __) => approvalCalls++,
          onConfirmCall: (c) => capturedConfirmed = c,
        ),
      )));
      // confirm 类型按 ADR 视觉沿用同款 button row, 但文案是 "确认 / 取消" (而非 "同意 / 拒绝")。
      // positive 按钮文案 = "确认"
      await tester.tap(find.widgetWithText(ElevatedButton, '确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(capturedConfirmed, isTrue);
      expect(approvalCalls, 0, reason: 'confirm 类型不得回退到 approval 回调');
      // 也不应该意外渲染出 "同意"/"拒绝" 文案
      expect(find.text('同意'), findsNothing);
      expect(find.text('拒绝'), findsNothing);
    });

    testWidgets('confirm: 点取消 (negative) → 调 onConfirm, confirmed=false',
        (tester) async {
      bool? capturedConfirmed;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'confirm', 'title': '清空购物车？'},
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          onConfirmCall: (c) => capturedConfirmed = c,
        ),
      )));
      await tester.tap(find.widgetWithText(OutlinedButton, '取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(capturedConfirmed, isFalse);
    });

    testWidgets('confirm: 自定义 confirm_label/cancel_label 渲染动词按钮 (避免双重否定)',
        (tester) async {
      bool? capturedConfirmed;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'confirm',
            'title': '取消申请',
            'summary': '确定取消吗？已支付的服务费将原路退回。',
            'confirm_label': '取消申请',
            'cancel_label': '继续办理',
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          onConfirmCall: (c) => capturedConfirmed = c,
        ),
      )));
      // 默认"确认/取消"文案不应出现在按钮上
      expect(find.widgetWithText(ElevatedButton, '取消申请'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '继续办理'), findsOneWidget);
      // 点主按钮「取消申请」= positive = confirmed:true (真取消)
      await tester.tap(find.widgetWithText(ElevatedButton, '取消申请'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(capturedConfirmed, isTrue);
    });

    testWidgets('action >2 项 → 竖排选项列表 (序号徽标), 点击回调收到 action_id',
        (tester) async {
      String? capturedId;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'action',
            'actions': [
              {'id': 'a1', 'label': '注册公司（全程代办）'},
              {'id': 'a2', 'label': '代理记账'},
              {'id': 'a3', 'label': '其他创业帮助'},
              {'id': 'a4', 'label': '自主办理指南（免费）'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          onActionCall: (id) => capturedId = id),
        ),
      ),);
      // 序号徽标 1-4 都在（列表模式）
      for (final n in ['1', '2', '3', '4']) {
        expect(find.text(n), findsOneWidget);
      }
      expect(find.text('代理记账'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '自主办理指南（免费）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(capturedId, 'a4');
    });

    testWidgets('approval / approval_request 不会误调 onConfirm (回归保护)',
        (tester) async {
      var approvalDecision = '';
      var confirmCalls = 0;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'approval_request', 'title': '请审批'},
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          onApprovalCall: (d, _) => approvalDecision = d,
          onConfirmCall: (_) => confirmCalls++,
        ),
      )));
      await tester.tap(find.widgetWithText(ElevatedButton, '同意'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(approvalDecision, 'approve');
      expect(confirmCalls, 0,
          reason: 'approval / approval_request 必须走 onApproval');
    });

    testWidgets('form: 简单字段填写 (text/number/checkbox) → 提交 payload 携带 fields',
        (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'submit_label': '提交资料',
            'fields': [
              {'name': 'who', 'type': 'text', 'label': '姓名'},
              {'name': 'count', 'type': 'number', 'label': '数量'},
              {'name': 'agree', 'type': 'checkbox', 'placeholder': '同意条款'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          onFormCall: (f) => captured = f),
        ),
      ),);
      // 填 text 字段
      await tester.enterText(find.byType(TextField).at(0), 'Alice');
      // 填 number 字段
      await tester.enterText(find.byType(TextField).at(1), '42');
      // 勾 checkbox
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      // 提交
      await tester.tap(find.widgetWithText(ElevatedButton, '提交资料'));
      await tester.pump(const Duration(milliseconds: 30));

      expect(captured, isNotNull);
      expect(captured!['who'], 'Alice');
      expect(captured!['count'], 42); // number 转 num
      expect(captured!['agree'], true);
    });

    testWidgets('form: handler null → 按钮 disabled + 字段不可点 + 显示 submit_label',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'submit_label': '马上批准',
            'fields': [
              {'name': 'who', 'type': 'text'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        // 没有 handler → 不交互。
      )));
      // submit_label 是按钮动作文案; handler 缺失只影响是否可点。
      expect(find.text('马上批准'), findsOneWidget);
      expect(find.text('当前客户端版本暂不支持填写此表单，请升级后重试'), findsOneWidget);
      final btn = tester
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '马上批准'));
      expect(btn.onPressed, isNull);
    });

    testWidgets('action: 点击 action 按钮 → handler 收到 action_id', (tester) async {
      String? capturedId;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'action',
            'title': '后续操作',
            'actions': [
              {'id': 'restart', 'label': '重启'},
              {'id': 'cancel', 'label': '取消'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(
          onActionCall: (id) => capturedId = id),
        ),
      ),);
      await tester.tap(find.widgetWithText(TextButton, '重启'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(capturedId, 'restart');
    });

    testWidgets('messageId 空 → 即使其它 3 条满足, 按钮仍 disabled', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'approval', 'title': 'A'},
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: '', // 空
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(),
      )));
      expect(
        tester
            .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '同意'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('conversationUuid 空 → 即使其它 3 条满足, 按钮仍 disabled',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {'type': 'approval', 'title': 'A'},
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: '',
        respondHandler: fakeHandler(),
      )));
      expect(
        tester
            .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, '同意'))
            .onPressed,
        isNull,
      );
    });
  });

  // ---------------- Plan 17 round-5: form 全字段类型 ----------------
  //
  // 测试全部走 EmpBlocksView 的内部 _FormBlockView。新增 switch / radio /
  // multiselect / date / time / datetime / file 字段类型 + required 校验。
  group('EmpBlocksView form full demo (round-5)', () {
    EmpBlocksRespondHandler formHandler({
      void Function(Map<String, dynamic> fields)? onFormCall,
      Future<Map<String, dynamic>?> Function({
        required String fieldName,
        required String fieldLabel,
      })? onFileCall,
      bool ok = true,
    }) {
      return EmpBlocksRespondHandler(
        onApproval: ({
          required String agentMessageUuid,
          required String decision,
          String? reason,
        }) async =>
            true,
        onConfirm: ({
          required String agentMessageUuid,
          required bool confirmed,
        }) async =>
            true,
        onForm: ({
          required String agentMessageUuid,
          required Map<String, dynamic> fields,
        }) async {
          onFormCall?.call(fields);
          return ok;
        },
        onFile: onFileCall,
        onAction: ({
          required String agentMessageUuid,
          required String actionId,
          Map<String, dynamic>? params,
        }) async =>
            true,
      );
    }

    Widget fullFormView({EmpBlocksRespondHandler? handler}) => _wrap(
          EmpBlocksView(
            blocks: const [
              {
                'type': 'form',
                'title': '完整表单',
                'fields': [
                  {
                    'name': 'subject',
                    'type': 'text',
                    'label': '主题',
                    'required': true
                  },
                  {'name': 'detail', 'type': 'textarea', 'label': '说明'},
                  {
                    'name': 'amount',
                    'type': 'number',
                    'label': '金额',
                    'required': true
                  },
                  {
                    'name': 'dept',
                    'type': 'select',
                    'label': '部门',
                    'required': true,
                    'options': ['技术', '产品']
                  },
                  {
                    'name': 'priority',
                    'type': 'radio',
                    'label': '优先级',
                    'required': true,
                    'options': [
                      {'label': '低', 'value': 'low'},
                      {'label': '高', 'value': 'high'},
                    ]
                  },
                  {
                    'name': 'collaborators',
                    'type': 'multiselect',
                    'label': '协作人',
                    'options': ['alice', 'bob', 'carol']
                  },
                  {'name': 'urgent', 'type': 'switch', 'label': '是否加急'},
                  {
                    'name': 'confirmed',
                    'type': 'checkbox',
                    'label': '我已确认',
                    'required': true,
                  },
                  {
                    'name': 'start_date',
                    'type': 'date',
                    'label': '开始日期',
                    'required': true
                  },
                  {'name': 'start_time', 'type': 'time', 'label': '开始时间'},
                  {'name': 'deadline', 'type': 'datetime', 'label': '截止时间'},
                  {'name': 'attachment', 'type': 'file', 'label': '附件'},
                ],
              },
            ],
            agentMessageStatus: 'awaiting_user',
            agentMessageUuid: 'm-1',
            conversationUuid: 'c-1',
            respondHandler: handler,
          ),
        );

    testWidgets('full form 渲染全部 12 个字段的 label', (tester) async {
      await tester.pumpWidget(fullFormView(handler: formHandler()));
      for (final label in [
        '主题',
        '说明',
        '金额',
        '部门',
        '优先级',
        '协作人',
        '是否加急',
        '我已确认',
        '开始日期',
        '开始时间',
        '截止时间',
        '附件',
      ]) {
        expect(find.text(label), findsOneWidget, reason: 'label 缺失: $label');
      }
    });

    testWidgets('form controls have visible bordered input chrome',
        (tester) async {
      await tester.pumpWidget(fullFormView(handler: formHandler()));

      final firstTextField =
          tester.widget<TextField>(find.byType(TextField).first);
      expect(
          firstTextField.decoration?.enabledBorder, isA<OutlineInputBorder>());
      expect(
          firstTextField.decoration?.focusedBorder, isA<OutlineInputBorder>());

      final selectDecorator =
          tester.widget<InputDecorator>(find.byType(InputDecorator).first);
      expect(
          selectDecorator.decoration.enabledBorder, isA<OutlineInputBorder>());

      // date/time/datetime picker use the shared bordered picker chrome. Flutter
      // renders OutlinedButton.icon as a private subtype in this SDK, so assert
      // the stable visible affordance instead of the internal widget type.
      expect(find.text('选择日期'), findsOneWidget);

      final chips = tester.widgetList<FilterChip>(find.byType(FilterChip));
      expect(chips, isNotEmpty);
      expect(chips.first.side, isNotNull);
    });

    testWidgets('file 字段缺少上传回调时保持只读, 不伪造 payload', (tester) async {
      await tester.pumpWidget(fullFormView(handler: formHandler()));
      expect(find.text('当前状态暂不可上传'), findsOneWidget);
      // round-8: 按钮文案改成 "选择附件上传" (TextButton.icon);
      // onFile 缺失 → 按钮 onPressed=null 保持禁用。
      final addButton = find.byKey(const ValueKey('file-upload-add'));
      expect(addButton, findsOneWidget);
      final btn = tester.widget(addButton);
      expect((btn as dynamic).onPressed, isNull);
    });

    testWidgets('file 字段上传后显示文件名, 提交 payload 携带文件引用 list (round-8)',
        (tester) async {
      Map<String, dynamic>? captured;
      var uploadCalls = 0;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              {'name': 'subject', 'type': 'text', 'label': '主题'},
              {
                'name': 'attachment',
                'type': 'file',
                'label': '附件',
                'required': true,
              },
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: formHandler(
          onFormCall: (f) => captured = f,
          onFileCall: ({
            required String fieldName,
            required String fieldLabel,
          }) async {
            uploadCalls++;
            expect(fieldName, 'attachment');
            expect(fieldLabel, '附件');
            return {
              'file_id': 'file-123',
              'name': '报销单.pdf',
              'size': 2048,
              'mime_type': 'application/pdf',
              'url': '/message-files/file-123/download',
            };
          },
        ),
      )));

      await tester.enterText(find.byType(TextField).first, '出差');
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured, isNull);
      expect(find.textContaining('请先填写必填字段'), findsOneWidget);

      // round-8: 多附件 widget 用 ValueKey 而非纯文本; 点 "选择附件上传" 按钮。
      await tester.ensureVisible(find.byKey(const ValueKey('file-upload-add')));
      await tester.tap(find.byKey(const ValueKey('file-upload-add')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(uploadCalls, 1);
      expect(find.text('报销单.pdf'), findsOneWidget);
      expect(find.text('已上传'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured, isNotNull);
      expect(captured!['subject'], '出差');
      // round-8: payload 改为 List<Map> — 即使只有 1 份附件, 也是 list 形态。
      expect(captured!['attachment'], isA<List>());
      final refs = captured!['attachment'] as List;
      expect(refs.length, 1);
      final attachment = refs.first as Map;
      expect(attachment['file_id'], 'file-123');
      expect(attachment['name'], '报销单.pdf');
      expect(attachment['size'], 2048);
      expect(attachment['mime_type'], 'application/pdf');
      expect(attachment['url'], '/message-files/file-123/download');
    });

    testWidgets('file 上传失败显示失败 chip + 重试按钮, payload 不含此附件 (round-8)',
        (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              {'name': 'attachment', 'type': 'file', 'label': '附件'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: formHandler(
          onFormCall: (f) => captured = f,
          onFileCall: ({
            required String fieldName,
            required String fieldLabel,
          }) async {
            throw StateError('boom');
          },
        ),
      )));
      await tester.tap(find.byKey(const ValueKey('file-upload-add')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      // round-8: 失败 slot 现在显示 "失败" chip + "重试" 按钮 (不再是行内 "上传失败，请重试" 文本)。
      expect(find.text('失败'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured, isNotNull);
      // 失败 slot 不计入 payload — 与旧单文件行为口径一致 (没有 uploaded 即视为未填写;
      // 此处 attachment 要么不在 map, 要么为 null, runtime 两者等价处理)。
      expect(captured!['attachment'], isNull);
    });

    testWidgets('file 多附件: 添加两份, payload 携带 list of refs (round-8)',
        (tester) async {
      Map<String, dynamic>? captured;
      var seq = 0;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              {'name': 'attachments', 'type': 'file', 'label': '附件'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: formHandler(
          onFormCall: (f) => captured = f,
          onFileCall: ({
            required String fieldName,
            required String fieldLabel,
          }) async {
            seq++;
            return {
              'file_id': 'file-$seq',
              'name': '附件-$seq.pdf',
              'size': 1024 * seq,
              'mime_type': 'application/pdf',
              'url': '/message-files/file-$seq/download',
            };
          },
        ),
      )));

      // 第一次添加 → 1 份 uploaded
      await tester.tap(find.byKey(const ValueKey('file-upload-add')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('附件-1.pdf'), findsOneWidget);
      expect(find.text('继续添加附件'), findsOneWidget);

      // 第二次添加 → 2 份 uploaded
      await tester.tap(find.byKey(const ValueKey('file-upload-add')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('附件-2.pdf'), findsOneWidget);
      expect(find.text('已上传'), findsNWidgets(2));

      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured, isNotNull);
      expect(captured!['attachments'], isA<List>());
      final refs = captured!['attachments'] as List;
      expect(refs.length, 2);
      expect((refs[0] as Map)['file_id'], 'file-1');
      expect((refs[1] as Map)['file_id'], 'file-2');
      expect((refs[0] as Map)['size'], 1024);
      expect((refs[1] as Map)['size'], 2048);
    });

    testWidgets(
        'file 失败重试 (round-8): 第一次抛错 → "重试" 按钮 → 第二次成功 → slot 变 uploaded',
        (tester) async {
      var calls = 0;
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              {'name': 'attachment', 'type': 'file', 'label': '附件'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: formHandler(
          onFormCall: (f) => captured = f,
          onFileCall: ({
            required String fieldName,
            required String fieldLabel,
          }) async {
            calls++;
            if (calls == 1) throw StateError('flaky');
            return {
              'file_id': 'file-r',
              'name': 'retry.pdf',
              'size': 4096,
              'mime_type': 'application/pdf',
            };
          },
        ),
      )));

      await tester.tap(find.byKey(const ValueKey('file-upload-add')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('失败'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '重试'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(calls, 2);
      expect(find.text('已上传'), findsOneWidget);
      expect(find.text('retry.pdf'), findsOneWidget);
      expect(find.text('失败'), findsNothing);

      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured, isNotNull);
      expect((captured!['attachment'] as List).first['file_id'], 'file-r');
    });

    testWidgets('file 已上传 slot 可移除 (round-8): 点 × 后 payload 不再含此附件',
        (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              {'name': 'attachment', 'type': 'file', 'label': '附件'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: formHandler(
          onFormCall: (f) => captured = f,
          onFileCall: ({
            required String fieldName,
            required String fieldLabel,
          }) async =>
              {
            'file_id': 'file-x',
            'name': 'x.pdf',
            'size': 256,
            'mime_type': 'application/pdf',
          },
        ),
      )));

      await tester.tap(find.byKey(const ValueKey('file-upload-add')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('x.pdf'), findsOneWidget);

      // 点 slot 内的 ×
      final removeBtn = find.byWidgetPredicate((w) =>
          w is IconButton &&
          (w.key is ValueKey) &&
          (w.key as ValueKey).value.toString().startsWith('file-slot-remove-'));
      expect(removeBtn, findsOneWidget);
      await tester.tap(removeBtn);
      await tester.pump();
      expect(find.text('x.pdf'), findsNothing);

      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured, isNotNull);
      // 移除后无 uploaded slot → 字段值为 null (或不在 map; 两者等价)。
      expect(captured!['attachment'], isNull);
    });

    testWidgets(
        'required 缺失 → 提交不触发 handler + 错误提示; 填齐后通过 (小 fixture, 无 picker)',
        (tester) async {
      Map<String, dynamic>? captured;
      // 小 fixture: 验"required 缺失阻拦 + 填齐解锁" 这一条规则, 不混入 picker。
      // date/time/datetime 的 payload 格式由专门测试覆盖。
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              {
                'name': 'subject',
                'type': 'text',
                'label': '主题',
                'required': true
              },
              {
                'name': 'amount',
                'type': 'number',
                'label': '金额',
                'required': true
              },
              {
                'name': 'confirmed',
                'type': 'checkbox',
                'label': '我已确认',
                'required': true,
              },
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: formHandler(onFormCall: (f) => captured = f),
      )));
      // 直接点提交 (什么都没填) → handler 不应被调
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured, isNull);
      // 错误提示出现, 内容包含字段名
      expect(find.textContaining('请先填写必填字段'), findsOneWidget);
      expect(find.textContaining('主题'), findsWidgets);
      expect(find.textContaining('金额'), findsWidgets);

      // 填齐
      await tester.enterText(find.byType(TextField).at(0), 'subject 值');
      await tester.enterText(find.byType(TextField).at(1), '99'); // amount
      await tester.tap(find.byType(Checkbox).first); // confirmed
      await tester.pump();
      // 再提交
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured, isNotNull, reason: '填齐 required 后 handler 必须被调');
      // 错误提示消失
      expect(find.textContaining('请先填写必填字段'), findsNothing);
      // 各字段值落到 payload
      expect(captured!['subject'], 'subject 值');
      expect(captured!['amount'], 99);
      expect(captured!['confirmed'], true);
    });

    testWidgets('date picker → payload YYYY-MM-DD (小 fixture)', (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              {'name': 'start_date', 'type': 'date', 'label': '开始日期'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: formHandler(onFormCall: (f) => captured = f),
      )));
      await tester.tap(find.text('选择日期'));
      await tester.pumpAndSettle();
      // 关 dialog: 最末 TextButton (跨 locale 都是 OK/确定)
      await tester.tap(find.byType(TextButton).last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured!['start_date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    testWidgets('switch 拨开 → payload 是 true (与 checkbox 同形)', (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              {
                'name': 'subject',
                'type': 'text',
                'label': '主题',
                'required': true
              },
              {'name': 'urgent', 'type': 'switch', 'label': '是否加急'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: formHandler(onFormCall: (f) => captured = f),
      )));
      await tester.enterText(find.byType(TextField).first, 'X');
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured!['urgent'], true);
    });

    testWidgets('multiselect: 选两个 → payload 是 List<String>, 顺序按 options 顺序',
        (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              {
                'name': 'who',
                'type': 'multiselect',
                'options': ['alice', 'bob', 'carol'],
              },
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: formHandler(onFormCall: (f) => captured = f),
      )));
      // 故意按"反向顺序"点: 先 carol 再 alice; payload 必须按 options 顺序排
      // (alice, carol), 不按用户点击顺序 — runtime 看到的 multiselect 稳定可重放。
      await tester.tap(find.widgetWithText(FilterChip, 'carol'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilterChip, 'alice'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured!['who'], ['alice', 'carol']);
    });

    testWidgets('time picker → payload HH:mm', (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              {'name': 'start_time', 'type': 'time', 'label': '开始时间'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: formHandler(onFormCall: (f) => captured = f),
      )));
      // OutlinedButton.icon 构造的是内部子类 _OutlinedButtonWithIcon, find.widgetWithText
      // 找不到, 改用 find.text 直接定位 Text 子节点 (tap 仍冒泡到 button).
      await tester.tap(find.text('选择时间'));
      await tester.pumpAndSettle();
      // 关 dialog (默认按"OK"/"确定") — 用当前时间
      // 关闭 dialog: date/time picker 的"确定"按钮是 dialog 内最末一个 TextButton,
      // 跨 locale (en/zh) 都成立; 不直接 find.text('OK'/'确定') 避免本地化漂移。
      await tester.tap(find.byType(TextButton).last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured!['start_time'], matches(RegExp(r'^\d{2}:\d{2}$')));
    });

    testWidgets(
        'radio options: 既支持 [{label,value}] 也支持 [str], 选中后 payload = value',
        (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              // 对象形式 — 选"高"应该提交 value='high', **不**是 label '高'
              {
                'name': 'priority',
                'type': 'radio',
                'options': [
                  {'label': '低', 'value': 'low'},
                  {'label': '高', 'value': 'high'},
                ],
              },
              // 字符串形式 — 选"B" 应该提交 'B'
              {
                'name': 'team',
                'type': 'radio',
                'options': ['A', 'B'],
              },
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: formHandler(onFormCall: (f) => captured = f),
      )));
      await tester.tap(find.text('高'));
      await tester.pump();
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured!['priority'], 'high');
      expect(captured!['team'], 'B');
    });

    testWidgets('malformed options / malformed field 不崩, 显示占位行',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              // options 是 String (而非 list) — 应当 best-effort 跳过, 不抛
              {
                'name': 'broken_radio',
                'type': 'radio',
                'options': 'not-a-list'
              },
              {'name': 'broken_msel', 'type': 'multiselect', 'options': 42},
              // field 本身是 String — best-effort 跳过 (上层 _asMap 守护)
              'not-a-map',
              // 未知 type — 走 disabledPlaceholder
              {'name': 'mystery', 'type': 'noSuchType'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: formHandler(),
      )));
      // 没崩, 提交按钮还在
      expect(find.widgetWithText(ElevatedButton, '提交'), findsOneWidget);
    });
  });

  // ---------------- Plan 17 round-7: chart dispatch + media block ----------------
  //
  // 锁住 _ChartBlockView 按 chart_kind 分发到不同真渲染 widget; 媒体类 image/
  // video/audio/file 走 _MediaBlockView; 未知 chart_kind 不崩, 退化为 mini-bar +
  // 默认提示。
  group('EmpBlocksView chart dispatch (round-7)', () {
    Widget chartBlock({
      required String kind,
      List<Map<String, Object>> data = const [
        {'label': 'A', 'value': 30},
        {'label': 'B', 'value': 70},
      ],
    }) =>
        _wrap(EmpBlocksView(blocks: [
          {
            'type': 'chart',
            'chart_kind': kind,
            'title': '$kind 示例',
            'data': data,
          },
        ]));

    testWidgets('chart bar → fl_chart BarChart', (tester) async {
      await tester.pumpWidget(chartBlock(kind: 'bar'));
      expect(find.byType(fl.BarChart), findsOneWidget);
      // X 轴 label 可见
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('chart bar 在真实 assistant 气泡内不塌成白屏', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 720,
            child: ChatAssistantMessageView(
              item: ChatAssistantMessageViewData(
                messageId: 'agent-message-1',
                uuid: 'agent-message-1',
                status: BubbleStatus.success,
                feedback: FeedbackType.none,
                files: const [],
                blocks: const [
                  ChatAssistantEmpBlocksBlock(blocks: [
                    {
                      'type': 'chart',
                      'chart_kind': 'bar',
                      'title': 'Bar Chart Demo',
                      'data': [
                        {'label': 'A', 'value': 3},
                        {'label': 'B', 'value': 7},
                      ],
                    },
                  ]),
                ],
              ),
            ),
          ),
        ),
      ));

      expect(find.text('Bar Chart Demo · bar'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('chart bar 多 series → 顶部图例 + fl_chart BarChart',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'title': '营收 vs 成本',
          'series': [
            {
              'name': '营收',
              'data': [
                {'label': '1月', 'value': 320},
                {'label': '2月', 'value': 280},
                {'label': '3月', 'value': 360},
              ],
            },
            {
              'name': '成本',
              'data': [
                {'label': '1月', 'value': 280},
                {'label': '2月', 'value': 240},
                {'label': '3月', 'value': 300},
              ],
            },
          ],
        },
      ])));
      // 图例: series name 都可见
      expect(find.text('营收'), findsOneWidget);
      expect(find.text('成本'), findsOneWidget);
      // 共享 X 轴 label
      expect(find.text('1月'), findsOneWidget);
      expect(find.text('3月'), findsOneWidget);
      expect(find.byType(fl.BarChart), findsOneWidget);
    });

    testWidgets('chart bar 多 series 缺 label 对齐: 第二个 series 没有"3月"应不画第 3 根, 但不崩',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'series': [
            {
              'name': 'A',
              'data': [
                {'label': '1月', 'value': 100},
                {'label': '2月', 'value': 200},
                {'label': '3月', 'value': 300},
              ],
            },
            {
              'name': 'B',
              'data': [
                {'label': '1月', 'value': 90},
                // 缺 2月、3月
              ],
            },
          ],
        },
      ])));
      // 不崩, label 仍然按第一个 series 顺序
      expect(find.text('1月'), findsOneWidget);
      expect(find.text('3月'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('chart line → fl_chart LineChart', (tester) async {
      await tester.pumpWidget(chartBlock(kind: 'line', data: const [
        {'label': '周一', 'value': 1},
        {'label': '周二', 'value': 5},
        {'label': '周三', 'value': 3},
      ]));
      expect(find.byType(fl.LineChart), findsOneWidget);
      expect(find.text('周一'), findsOneWidget);
    });

    testWidgets('chart area → 仍走 fl_chart LineChart', (tester) async {
      await tester.pumpWidget(chartBlock(kind: 'area'));
      expect(find.byType(fl.LineChart), findsOneWidget);
    });

    testWidgets('chart pie → fl_chart PieChart', (tester) async {
      await tester.pumpWidget(chartBlock(kind: 'pie', data: const [
        {'label': '搜索', 'value': 42},
        {'label': '推广', 'value': 28},
        {'label': '其它', 'value': 30},
      ]));
      expect(find.byType(fl.PieChart), findsOneWidget);
      // 图例显示百分比
      expect(find.textContaining('%'), findsWidgets);
      expect(find.text('搜索'), findsOneWidget);
    });

    testWidgets('chart donut → 仍走 fl_chart PieChart', (tester) async {
      await tester.pumpWidget(chartBlock(kind: 'donut'));
      expect(find.byType(fl.PieChart), findsOneWidget);
    });

    testWidgets('chart kpi → 主指标大字号 + 副指标 (无 CustomPaint 图)', (tester) async {
      await tester.pumpWidget(chartBlock(kind: 'kpi', data: const [
        {'label': '本月营收', 'value': 640},
        {'label': '环比', 'value': 15.6},
        {'label': '同比', 'value': 28},
      ]));
      // 主指标必须可见
      expect(find.text('640'), findsOneWidget);
      expect(find.text('本月营收'), findsOneWidget);
      // 副指标 label / value 都在 (非整数走 toStringAsFixed(2) → '15.60')
      expect(find.text('环比'), findsOneWidget);
      expect(find.text('15.60'), findsOneWidget);
    });

    testWidgets('chart scatter → fl_chart ScatterChart', (tester) async {
      await tester.pumpWidget(chartBlock(kind: 'scatter'));
      expect(find.byType(fl.ScatterChart), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('chart radar → fl_chart RadarChart', (tester) async {
      await tester.pumpWidget(chartBlock(kind: 'radar', data: const [
        {'label': '性能', 'value': 88},
        {'label': '体验', 'value': 76},
        {'label': '稳定性', 'value': 92},
      ]));
      expect(find.byType(fl.RadarChart), findsOneWidget);
    });

    testWidgets('chart unknown_kind → unsupported fallback, 不崩',
        (tester) async {
      await tester.pumpWidget(chartBlock(kind: 'super_chart_v9'));
      expect(find.textContaining('复杂图表已按可读数据预览展示'), findsOneWidget);
      // title 仍可见
      expect(find.textContaining('super_chart_v9'), findsWidgets);
    });

    testWidgets('chart 数据为空 → 显示占位文案, 不崩 (round-9 富 fallback)', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {'type': 'chart', 'chart_kind': 'line', 'title': 'X'},
      ])));
      // round-9 改成 banner "暂无可视化数据"
      expect(find.textContaining('暂无可视化数据'), findsOneWidget);
    });

    testWidgets('chart 数据 malformed (字符串 / 非 Map) → 跳过坏元素, 不崩', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'title': '坏数据',
          'data': [
            'not-a-map',
            {'label': '正常', 'value': 10},
            null,
            {'value': 'string-not-num'},
            {'label': '又一个', 'value': 5},
          ],
        },
      ])));
      // 不崩, 正常 entries 仍可见
      expect(find.text('正常'), findsOneWidget);
      expect(find.text('又一个'), findsOneWidget);
    });
  });

  // Plan 18 round-9: Inline Visualization 2.0 — header / summary (markdown) /
  // insights chips / footer (source · updated_at) / 单 series legend / unit 轴单位 /
  // 富 fallback (含原始数据预览) / 小宽度不溢出 / 顶层 try/catch。
  group('EmpBlocksView chart inline-visualization 2.0 (round-9)', () {
    testWidgets('header: title + chart_kind 标签 + 数据点数量 + 单位 chip',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'title': '近 6 个月营收',
          'unit': '万元',
          'data': [
            {'label': '1月', 'value': 320},
            {'label': '2月', 'value': 280},
            {'label': '3月', 'value': 360},
          ],
        },
      ])));
      // 标题 = "近 6 个月营收 · bar"
      expect(find.text('近 6 个月营收 · bar'), findsOneWidget);
      // header meta chips
      expect(find.text('3 个数据点'), findsOneWidget);
      expect(find.text('单位 · 万元'), findsOneWidget);
    });

    testWidgets('insights chips: 最多展示 3 个 + 余下走 "+N"', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'title': 'X',
          'insights': [
            'Q2 反弹',
            '6 月峰值',
            '同比 +28%',
            '已超额完成 67%', // 第 4 个不显示
          ],
          'data': [
            {'label': 'A', 'value': 1},
          ],
        },
      ])));
      expect(find.text('Q2 反弹'), findsOneWidget);
      expect(find.text('6 月峰值'), findsOneWidget);
      expect(find.text('同比 +28%'), findsOneWidget);
      // 第 4 个 chip 不显示, 改用 "+1" 数字提示
      expect(find.text('已超额完成 67%'), findsNothing);
      expect(find.text('+1'), findsOneWidget);
    });

    testWidgets('footer: 同时给出 source + updated_at 时显示 "数据源: ... · 更新: ..."',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'title': 'X',
          'source': '财务系统 · 内部 fixture',
          'updated_at': '2 分钟前',
          'data': [
            {'label': 'A', 'value': 1},
          ],
        },
      ])));
      expect(find.textContaining('数据源: 财务系统 · 内部 fixture'), findsOneWidget);
      expect(find.textContaining('更新: 2 分钟前'), findsOneWidget);
    });

    testWidgets('单 series bar 也显示 legend chip ("数据 (万元)")', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'title': 'X',
          'unit': '万元',
          'data': [
            {'label': 'A', 'value': 10},
            {'label': 'B', 'value': 20},
          ],
        },
      ])));
      // round-9: 单 series 也要显示 legend (round-7 只在 multi-series 时显示)
      expect(find.text('数据 (万元)'), findsOneWidget);
    });

    testWidgets('单 series line 也显示 legend chip', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'chart',
          'chart_kind': 'line',
          'title': 'X',
          'unit': 'DAU',
          'data': [
            {'label': '一', 'value': 12},
            {'label': '二', 'value': 18},
          ],
        },
      ])));
      expect(find.text('数据 (DAU)'), findsOneWidget);
    });

    testWidgets('kpi 主指标后面追加 unit', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'chart',
          'chart_kind': 'kpi',
          'title': '本月营收',
          'unit': '万元',
          'data': [
            {'label': '本月营收', 'value': 640},
            {'label': '环比', 'value': 15.6},
          ],
        },
      ])));
      // 大数字 640 + 单位 "万元" + label "本月营收" 都在
      expect(find.text('640'), findsOneWidget);
      expect(find.text('万元'), findsOneWidget);
      expect(find.text('本月营收'), findsOneWidget);
    });

    testWidgets('unknown chart_kind → 富 fallback: banner + summary + 原始数据预览',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'chart',
          'chart_kind': 'mixed',
          'title': '营收 vs 利润',
          'summary': '本期客户端暂无混合图专用 widget; 已退化为可读视图。',
          'insights': ['营收 6 月达峰值', '利润率本月最高'],
          'table': {
            'headers': ['月份', '营收(万)', '利润(万)', '利润率%'],
            'rows': [
              ['1月', 320, 32, 10.0],
              ['2月', 280, 22, 7.9],
              ['3月', 360, 40, 11.1],
              ['4月', 420, 50, 11.9],
              ['5月', 510, 64, 12.5],
              ['6月', 640, 96, 15.0],
            ],
          },
          'data': [
            {'label': '1月', 'value': 320},
          ],
        },
      ])));
      // 标题保留
      expect(find.textContaining('营收 vs 利润 · mixed'), findsOneWidget);
      // banner 文案 (面向用户, 不暴露 Dart 异常)
      expect(find.textContaining('复杂图表已按可读数据预览展示'), findsOneWidget);
      expect(find.textContaining('chart_kind=mixed'), findsOneWidget);
      // summary 走 markdown (compact) 渲染, 文本依然可见
      expect(find.textContaining('混合图专用 widget'), findsWidgets);
      // 表头来自 block.table.headers
      expect(find.text('月份'), findsOneWidget);
      expect(find.text('营收(万)'), findsOneWidget);
      expect(find.text('利润(万)'), findsOneWidget);
      expect(find.text('利润率%'), findsOneWidget);
      // 5 行 × 4 列预览; 6 行 → 截到 5 行 + "另有 1 行未展示"
      expect(find.textContaining('另有 1 行未展示'), findsOneWidget);
      // 真不崩
      expect(tester.takeException(), isNull);
    });

    testWidgets('known chart_kind 但 data 空 → 走富 fallback (banner = 暂无可视化数据)',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'title': '空数据',
          'summary': 'fixture 当前无可视化数据。',
        },
      ])));
      expect(find.textContaining('暂无可视化数据'), findsOneWidget);
      expect(find.textContaining('chart_kind=bar'), findsOneWidget);
    });

    testWidgets(
        'known chart_kind + data 全 malformed → 走富 fallback (banner = 数据格式不合法)',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'title': '坏 fixture',
          'data': ['x', 'y', 'z'], // 全是非 Map / 非 num, 抽不到任何 entry
        },
      ])));
      expect(find.textContaining('数据格式不合法'), findsOneWidget);
    });

    testWidgets('小宽度 (320) chart 不 overflow (回归)', (tester) async {
      // 在窄宽度容器下检验 LayoutBuilder + clamp 不会让 chart 超出父宽度。
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: EmpBlocksView(blocks: const [
              {
                'type': 'chart',
                'chart_kind': 'bar',
                'title': 'narrow',
                'data': [
                  {'label': 'A', 'value': 10},
                  {'label': 'B', 'value': 20},
                  {'label': 'C', 'value': 30},
                ],
              },
            ]),
          ),
        ),
      ));
      // 不抛 overflow 异常
      expect(tester.takeException(), isNull);
      // chart 渲染了
      expect(find.byType(fl.BarChart), findsOneWidget);
    });
  });

  group('EmpBlocksView media blocks (round-7)', () {
    testWidgets('同一 file_id 的 Markdown 文件卡与 EMP 附件卡只展示后者', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'markdown',
          'text':
              '可以，文件路径再发你一次：\n\n[financial-company-homepage-v1.html](/message-files/8818ab80-cfcc-4053-a393-ce801f8c59d1/download)\n\n下面是附件。',
        },
        {
          'type': 'file',
          'file_id': '8818ab80-cfcc-4053-a393-ce801f8c59d1',
          'name': 'financial-company-homepage-v1.html',
          'mime': 'text/html; charset=utf-8',
          'size': 17035,
          'url': '/message-files/8818ab80-cfcc-4053-a393-ce801f8c59d1/download',
        },
      ])));

      expect(find.text('financial-company-homepage-v1.html'), findsOneWidget);
      expect(find.text('附件'), findsNothing);
      expect(find.byTooltip('预览'), findsOneWidget);
      expect(find.byTooltip('下载'), findsOneWidget);
      expect(find.textContaining('下面是附件'), findsOneWidget);
    });

    testWidgets('image block 渲染可鉴权网络预览 + 文件名', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'image',
          'name': 'cover.png',
          'preview_url': '/message-files/img-1/preview',
          'mime_type': 'image/png',
        },
      ])));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      // 图片统一通过授权字节加载器，不把业务 token 传入图片渲染器。
      expect(find.byType(ChatArtifactCard), findsOneWidget);
      // 标题里有文件名
      expect(find.textContaining('cover.png'), findsWidgets);
    });

    testWidgets('video block 渲染图标 + 文件名 + 元数据', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'video',
          'name': 'demo.mp4',
          'size': 4096000,
          'mime_type': 'video/mp4',
        },
      ])));
      expect(find.textContaining('demo.mp4'), findsWidgets);
      // size 与 mime 显示
      expect(find.textContaining('MB'), findsWidgets);
      // 提示真实播放需新版
      expect(find.text('暂无可下载地址'), findsOneWidget);
    });

    testWidgets('audio block 渲染', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {'type': 'audio', 'name': 'voice.mp3', 'size': 128000},
      ])));
      expect(find.textContaining('voice.mp3'), findsWidgets);
      expect(find.textContaining('KB'), findsWidgets);
    });

    testWidgets(
        'video block (round-8): 有 URL → 真播放器 widget 不崩 (platform 缺失时 fail-soft)',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'video',
          'name': 'demo.mp4',
          'url': 'https://example.com/demo.mp4',
          'size': 4096000,
          'mime_type': 'video/mp4',
        },
      ])));
      await tester.pump(const Duration(milliseconds: 30));
      // 不论 controller 是否能在 test env 初始化, widget 都不应抛异常,
      // 且文件名应在标题中出现 (无论是真播放器 card 还是 fail-soft fallback)。
      expect(tester.takeException(), isNull);
      expect(find.textContaining('demo.mp4'), findsWidgets);
    });

    testWidgets('video block (round-8): 无 URL → fail-soft 退化到文件卡 (回归保护)',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'video',
          'name': 'demo.mp4',
          'size': 4096000,
          'mime_type': 'video/mp4',
        },
      ])));
      await tester.pump(const Duration(milliseconds: 20));
      // 文件卡兜底文案
      expect(find.text('暂无可下载地址'), findsOneWidget);
      expect(find.textContaining('demo.mp4'), findsWidgets);
    });

    testWidgets('audio block (round-8): 有 URL → 真播放器 widget (Slider + 播放按钮) 不崩',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'audio',
          'name': 'voice.mp3',
          'url': 'https://example.com/voice.mp3',
          'size': 128000,
          'mime_type': 'audio/mpeg',
        },
      ])));
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.takeException(), isNull);
      // 真播放器: Slider + 播放按钮 + 标题里文件名
      expect(find.byType(Slider), findsOneWidget);
      expect(find.textContaining('voice.mp3'), findsWidgets);
      // 00:00 起始时长 (位置 + 总时长 各一行)
      expect(find.text('00:00'), findsWidgets);
    });

    testWidgets('audio block (round-8): 无 URL → fail-soft 退化到文件卡 (无 Slider)',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {'type': 'audio', 'name': 'voice.mp3', 'size': 128000},
      ])));
      await tester.pump(const Duration(milliseconds: 20));
      // 文件卡兜底
      expect(find.byType(Slider), findsNothing);
      expect(find.textContaining('voice.mp3'), findsWidgets);
    });

    testWidgets('file block 渲染文件图标和下载入口', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'file',
          'name': 'spec.pdf',
          'size': 184320,
          'mime_type': 'application/pdf',
          'download_url': '/message-files/file-1/download',
        },
      ])));
      expect(find.text('附件'), findsNothing);
      expect(find.text('附件 · spec.pdf'), findsNothing);
      expect(find.byIcon(Icons.attach_file), findsNothing);
      expect(find.text('spec.pdf'), findsOneWidget);
      expect(find.text('PDF · 180.0 KB'), findsOneWidget);
      expect(find.textContaining('application/pdf'), findsNothing);
      expect(find.byType(FileAttachmentIcon), findsOneWidget);
      final icon = tester.widget<FileAttachmentIcon>(
        find.byType(FileAttachmentIcon),
      );
      expect(icon.size, FileAttachmentIconSize.md);
      expect(icon.customDimension, 30);
      final fileTitle = tester.widget<Text>(find.text('spec.pdf'));
      expect(fileTitle.style?.fontSize, 14);
      expect(find.byTooltip('预览'), findsOneWidget);
      expect(find.byTooltip('下载'), findsOneWidget);
      expect(find.byType(ChatArtifactCard), findsOneWidget);
      expect(find.textContaining('完整播放'), findsNothing);
    });

    testWidgets('Office 文件沿用可用的统一预览和下载按钮', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {
          'type': 'file',
          'name': 'report.xlsx',
          'size': 486400,
          'mime_type':
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          'download_url': '/message-files/file-2/download',
        },
      ])));
      expect(find.text('report.xlsx'), findsOneWidget);
      expect(find.text('XLSX · 475.0 KB'), findsOneWidget);
      expect(find.byTooltip('预览'), findsOneWidget);
      expect(find.byTooltip('下载'), findsOneWidget);
      final preview = tester.widget<IconButton>(
          find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '预览'));
      expect(preview.onPressed, isNotNull);
    });

    testWidgets('media block malformed (size 是 String) → 不崩, 仅省略 size',
        (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(blocks: const [
        {'type': 'file', 'name': 'x.pdf', 'size': 'not-a-number'},
      ])));
      expect(find.textContaining('x.pdf'), findsWidgets);
    });
  });

  group('EmpBlocksView form allowCustom 下拉自填', () {
    EmpBlocksRespondHandler makeHandler({
      void Function(Map<String, dynamic> fields)? onFormCall,
    }) {
      return EmpBlocksRespondHandler(
        onApproval: (
                {required String agentMessageUuid,
                required String decision,
                String? reason}) async =>
            true,
        onConfirm: (
                {required String agentMessageUuid,
                required bool confirmed}) async =>
            true,
        onForm: (
            {required String agentMessageUuid,
            required Map<String, dynamic> fields}) async {
          onFormCall?.call(fields);
          return true;
        },
        onAction: (
                {required String agentMessageUuid,
                required String actionId,
                Map<String, dynamic>? params}) async =>
            true,
      );
    }

    Widget customForm({bool required = false}) {
      return _wrap(EmpBlocksView(
        blocks: [
          {
            'type': 'form',
            'title': '注册',
            'fields': [
              {
                'name': 'city',
                'label': '注册城市',
                'type': 'select',
                'required': required,
                'allowCustom': true,
                'options': const ['北京', '上海']
              },
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-c',
        conversationUuid: 'c-c',
        respondHandler: makeHandler(),
      ));
    }

    testWidgets('选「其他」展开输入框，输入值作为提交值', (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'title': '注册',
            'fields': [
              {
                'name': 'city',
                'label': '注册城市',
                'type': 'select',
                'allowCustom': true,
                'options': ['北京', '上海']
              },
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-c',
        conversationUuid: 'c-c',
        respondHandler: makeHandler(onFormCall: (f) => captured = f),
      )));
      // 打开下拉，应有「其他（手动输入）」项
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('其他（手动输入）'), findsOneWidget);
      await tester.tap(find.text('其他（手动输入）').last);
      await tester.pumpAndSettle();
      // 展开输入框，输入自定义城市
      expect(find.byType(TextFormField), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '珠海');
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured?['city'], '珠海'); // 不受 options 限制
    });

    testWidgets('选「其他」未输入 → required 拦截 + 不提交哨兵', (tester) async {
      await tester.pumpWidget(customForm(required: true));
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('其他（手动输入）').last);
      await tester.pumpAndSettle();
      // 没输入就提交 → 必填拦截
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump();
      expect(find.textContaining('请先填写必填字段'), findsOneWidget);
    });
  });

  group('EmpBlocksView form 字段 tooltip', () {
    testWidgets('带 tooltip 的字段渲染问号图标，点击弹解释', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'title': '注册',
            'fields': [
              {
                'name': 'industry',
                'label': '行业表述',
                'type': 'text',
                'tooltip': '公司全称里体现主营业务的词'
              },
              {'name': 'plain', 'label': '普通字段', 'type': 'text'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-tt',
        conversationUuid: 'c-tt',
      )));
      // 有 tooltip 的字段出现问号图标；无 tooltip 的不出现（两字段共 1 个图标）
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
      // 点击问号弹出解释文案
      await tester.tap(find.byIcon(Icons.help_outline));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('公司全称里体现主营业务的词'), findsWidgets);
    });
  });

  group('EmpBlocksView form 多步向导 (form.steps)', () {
    // fakeHandler 是「HITL 可交互」group 的闭包内函数，这里用本地精简版（只关心 onForm）。
    EmpBlocksRespondHandler fakeHandler({
      void Function(Map<String, dynamic> fields)? onFormCall,
    }) {
      return EmpBlocksRespondHandler(
        onApproval: ({
          required String agentMessageUuid,
          required String decision,
          String? reason,
        }) async =>
            true,
        onConfirm: ({
          required String agentMessageUuid,
          required bool confirmed,
        }) async =>
            true,
        onForm: ({
          required String agentMessageUuid,
          required Map<String, dynamic> fields,
        }) async {
          onFormCall?.call(fields);
          return true;
        },
        onAction: ({
          required String agentMessageUuid,
          required String actionId,
          Map<String, dynamic>? params,
        }) async =>
            true,
      );
    }

    const wizardBlock = {
      'type': 'form',
      'title': '公司注册信息',
      'steps': [
        {
          'key': 's1',
          'title': '名称',
          'fields': [
            {'name': 'city', 'type': 'text', 'label': '注册城市', 'required': true},
          ],
        },
        {
          'key': 's2',
          'title': '法人',
          'description': '与身份证一致',
          'fields': [
            {
              'name': 'rep_name',
              'type': 'text',
              'label': '姓名',
              'required': true
            },
          ],
        },
      ],
      // 契约: steps 表单必须同时携带拍平 fields (老客户端回落)
      'fields': [
        {'name': 'city', 'type': 'text', 'label': '注册城市', 'required': true},
        {'name': 'rep_name', 'type': 'text', 'label': '姓名', 'required': true},
      ],
    };

    testWidgets('分步渲染: 步骤指示 + 当前步字段 + 下一步/上一步导航', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [wizardBlock],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(onFormCall: (_) {}),
      )));
      expect(find.textContaining('第 1/2 步'), findsOneWidget);
      expect(find.textContaining('注册城市'), findsWidgets);
      expect(find.textContaining('姓名'), findsNothing); // 第二步字段不渲染
      expect(find.widgetWithText(OutlinedButton, '上一步'), findsNothing);

      await tester.enterText(find.byType(TextField).first, '杭州');
      await tester.tap(find.widgetWithText(ElevatedButton, '下一步'));
      await tester.pump();
      expect(find.textContaining('第 2/2 步'), findsOneWidget);
      expect(find.textContaining('与身份证一致'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '上一步'), findsOneWidget);

      // 上一步回退, 已填值保留
      await tester.tap(find.widgetWithText(OutlinedButton, '上一步'));
      await tester.pump();
      expect(find.textContaining('第 1/2 步'), findsOneWidget);
      expect(find.text('杭州'), findsOneWidget);
    });

    testWidgets('required 拦截下一步 + 最后一步统一提交全量并集', (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [wizardBlock],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(onFormCall: (f) => captured = f),
      )));
      // 必填未填 → 下一步被拦
      await tester.tap(find.widgetWithText(ElevatedButton, '下一步'));
      await tester.pump();
      expect(find.textContaining('请先填写必填字段'), findsOneWidget);
      expect(find.textContaining('第 1/2 步'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '杭州');
      await tester.tap(find.widgetWithText(ElevatedButton, '下一步'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, '张三');
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));

      expect(captured, isNotNull);
      expect(captured!['city'], '杭州'); // 跨步字段并集一次提交
      expect(captured!['rep_name'], '张三');
    });

    testWidgets('steps 非法 → fail-soft 退化单页 (顶层 fields 全渲染)', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'title': '坏 steps',
            'steps': 'not-a-list',
            'fields': [
              {'name': 'a', 'type': 'text', 'label': '字段A'},
              {'name': 'b', 'type': 'text', 'label': '字段B'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(onFormCall: (_) {}),
      )));
      expect(find.textContaining('第 1/'), findsNothing);
      expect(find.textContaining('字段A'), findsWidgets);
      expect(find.textContaining('字段B'), findsWidgets); // 单页全渲染
      expect(find.widgetWithText(ElevatedButton, '提交'), findsOneWidget);
    });
  });

  // 追问引导 chip（「猜你想问」）：点击 = 发一条普通用户消息，不走 respond
  // 回灌（2026-07-15 交互修订）；不受 awaiting_user 四条件门控，历史消息可点。
  group('EmpBlocksView suggestion chip 点击即发消息', () {
    EmpBlocksRespondHandler sendTextHandler(void Function(String text) onSend) {
      return EmpBlocksRespondHandler(
        onApproval: ({
          required String agentMessageUuid,
          required String decision,
          String? reason,
        }) async =>
            true,
        onConfirm: ({
          required String agentMessageUuid,
          required bool confirmed,
        }) async =>
            true,
        onForm: ({
          required String agentMessageUuid,
          required Map<String, dynamic> fields,
        }) async =>
            true,
        onAction: ({
          required String agentMessageUuid,
          required String actionId,
          Map<String, dynamic>? params,
        }) async =>
            true,
        onSendText: (text) async => onSend(text),
      );
    }

    testWidgets('装配 onSendText → chip 可点，点击回传问题原文', (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'suggestion',
            'items': ['开户选哪家银行好', '基本户和一般户有什么区别'],
          },
        ],
        // 刻意不给 awaiting_user——suggestion 点击不受四条件门控（历史消息也可点）。
        agentMessageStatus: 'completed',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: sendTextHandler(sent.add),
      )));
      // pill 形态是 Material+InkWell 胶囊（非 TextButton），断言可点交互本身。
      final chip = find.ancestor(
        of: find.text('开户选哪家银行好'),
        matching: find.byType(InkWell),
      );
      expect(chip, findsOneWidget);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(sent, ['开户选哪家银行好']);
    });

    testWidgets('未装配 onSendText → 只读 chips（无可点按钮）', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'suggestion',
            'items': ['开户选哪家银行好'],
          },
        ],
      )));
      expect(find.text('开户选哪家银行好'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('开户选哪家银行好'),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );
    });
  });

  group('EmpBlocksView form 字段 pattern (契约 §3.0a 2026-07-20)', () {
    EmpBlocksRespondHandler fakeHandler({
      void Function(Map<String, dynamic> fields)? onFormCall,
    }) {
      return EmpBlocksRespondHandler(
        onApproval: ({
          required String agentMessageUuid,
          required String decision,
          String? reason,
        }) async =>
            true,
        onConfirm: ({
          required String agentMessageUuid,
          required bool confirmed,
        }) async =>
            true,
        onForm: ({
          required String agentMessageUuid,
          required Map<String, dynamic> fields,
        }) async {
          onFormCall?.call(fields);
          return true;
        },
        onAction: ({
          required String agentMessageUuid,
          required String actionId,
          Map<String, dynamic>? params,
        }) async =>
            true,
      );
    }

    testWidgets('单页 form: pattern 不匹配 → 提交拦截 + 显示 patternHint; 修正后放行',
        (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              {
                'name': 'mobile',
                'type': 'text',
                'label': '手机号',
                'required': true,
                'pattern': r'1[3-9]\d{9}',
                'patternHint': '需为 11 位大陆手机号（1 开头）',
              },
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(onFormCall: (f) => captured = f),
      )));
      await tester.enterText(find.byType(TextField).first, '188532283');
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump();
      expect(captured, isNull); // 被拦, 未提交
      expect(find.textContaining('需为 11 位大陆手机号'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '18853228368');
      await tester.pump();
      expect(find.textContaining('需为 11 位大陆手机号'), findsNothing); // 改动即清提示
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured, isNotNull);
      expect(captured!['mobile'], '18853228368');
    });

    testWidgets('向导: 步内 pattern 错 → 「下一步」拦在当前步; 改对才翻页', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'steps': [
              {
                'key': 's1',
                'title': '法人',
                'fields': [
                  {
                    'name': 'idn',
                    'type': 'text',
                    'label': '身份证号',
                    'required': true,
                    'pattern': r'\d{17}[0-9Xx]',
                    'patternHint': '需为 18 位身份证号（末位可为 X）',
                  },
                ],
              },
              {
                'key': 's2',
                'title': '资本',
                'fields': [
                  {'name': 'cap', 'type': 'number', 'label': '注册资本'},
                ],
              },
            ],
            'fields': [
              {'name': 'idn', 'type': 'text', 'label': '身份证号'},
              {'name': 'cap', 'type': 'number', 'label': '注册资本'},
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(),
      )));
      await tester.enterText(find.byType(TextField).first, '4213811994082152');
      await tester.tap(find.widgetWithText(ElevatedButton, '下一步'));
      await tester.pump();
      // 拦在第 1 步: hint 可见, 第 2 步字段未出现
      expect(find.textContaining('需为 18 位身份证号'), findsOneWidget);
      expect(find.text('注册资本'), findsNothing);

      await tester.enterText(
          find.byType(TextField).first, '42138119940821527X');
      await tester.tap(find.widgetWithText(ElevatedButton, '下一步'));
      await tester.pump();
      expect(find.text('注册资本'), findsOneWidget); // 已翻页
    });

    testWidgets('空值不触发 pattern (归 required 管); 非法正则 fail-soft 不拦',
        (tester) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'form',
            'fields': [
              {
                // 选填 + pattern: 空值应放行
                'name': 'email',
                'type': 'text',
                'label': '邮箱',
                'pattern': r'[^@\s]+@[^@\s]+\.[^@\s]+',
              },
              {
                // 非法正则: fail-soft 跳过 (回落服务端校验)
                'name': 'brand',
                'type': 'text',
                'label': '字号',
                'pattern': r'([',
              },
            ],
          },
        ],
        agentMessageStatus: 'awaiting_user',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: fakeHandler(onFormCall: (f) => captured = f),
      )));
      await tester.enterText(find.byType(TextField).at(1), '任意值!!');
      await tester.tap(find.widgetWithText(ElevatedButton, '提交'));
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured, isNotNull); // 空邮箱 + 坏正则字段都不拦
      expect(captured!['brand'], '任意值!!');
    });
  });

  // ---------------- F24 收款线上化: open_payment 本地动作 ----------------
  //
  // open_payment: 前缀 action = 客户端本地打开支付页, 豁免 awaiting_user 门控
  // (历史消息上的「去支付」持续可点); 同块普通 action 仍受门控。
  group('EmpBlocksView open_payment local action', () {
    EmpBlocksRespondHandler payHandler({
      void Function(String actionId)? onOpenPaymentCall,
      bool withOpenPayment = true,
    }) {
      return EmpBlocksRespondHandler(
        onApproval: ({
          required String agentMessageUuid,
          required String decision,
          String? reason,
        }) async =>
            true,
        onConfirm: ({
          required String agentMessageUuid,
          required bool confirmed,
        }) async =>
            true,
        onForm: ({
          required String agentMessageUuid,
          required Map<String, dynamic> fields,
        }) async =>
            true,
        onAction: ({
          required String agentMessageUuid,
          required String actionId,
          Map<String, dynamic>? params,
        }) async =>
            true,
        onOpenPayment: withOpenPayment
            ? (actionId) async => onOpenPaymentCall?.call(actionId)
            : null,
      );
    }

    testWidgets('去支付使用不小于 120x44 的强调按钮', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'action',
            'actions': [
              {
                'id': 'open_payment:registration_fee:case-1',
                'label': '去支付',
              },
            ],
          },
        ],
        agentMessageStatus: 'completed',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: payHandler(),
      )));

      final button = find.widgetWithText(TextButton, '去支付');
      expect(button, findsOneWidget);
      final size = tester.getSize(button);
      expect(size.width, greaterThanOrEqualTo(120));
      expect(size.height, greaterThanOrEqualTo(44));
    });

    testWidgets('非 awaiting_user 消息上「去支付」仍可点, 普通 action 保持置灰', (tester) async {
      String? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'action',
            'actions': [
              {'id': 'open_payment:bookkeeping_fee:case-1', 'label': '去支付'},
              {'id': 'other', 'label': '其他操作'},
            ],
          },
        ],
        // 主动推送/历史消息: 不满足 awaiting_user 门控
        agentMessageStatus: 'completed',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: payHandler(onOpenPaymentCall: (id) => captured = id),
      )));
      final payBtn =
          tester.widget<TextButton>(find.widgetWithText(TextButton, '去支付'));
      expect(payBtn.onPressed, isNotNull, reason: '支付按钮豁免 awaiting_user 门控');
      final otherBtn =
          tester.widget<TextButton>(find.widgetWithText(TextButton, '其他操作'));
      expect(otherBtn.onPressed, isNull, reason: '普通 action 仍受门控');

      await tester.tap(find.widgetWithText(TextButton, '去支付'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured, 'open_payment:bookkeeping_fee:case-1');
    });

    testWidgets('onOpenPayment 未装配 → 「去支付」按普通 action 门控置灰', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'action',
            'actions': [
              {'id': 'open_payment:bookkeeping_fee:case-1', 'label': '去支付'},
            ],
          },
        ],
        agentMessageStatus: 'completed',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: payHandler(withOpenPayment: false),
      )));
      final payBtn =
          tester.widget<TextButton>(find.widgetWithText(TextButton, '去支付'));
      expect(payBtn.onPressed, isNull);
    });
  });

  // ---------------- F26 助手间衔接: open_employee 本地动作 ----------------
  //
  // open_employee: 前缀 action = 客户端本地切到指定数字员工聊天框, 与
  // open_payment 同理豁免 awaiting_user 门控 (历史消息上的「找财税助手」持续可点)。
  group('EmpBlocksView open_employee local action', () {
    EmpBlocksRespondHandler empHandler({
      void Function(String actionId)? onOpenEmployeeCall,
      bool withOpenEmployee = true,
    }) {
      return EmpBlocksRespondHandler(
        onApproval: ({
          required String agentMessageUuid,
          required String decision,
          String? reason,
        }) async =>
            true,
        onConfirm: ({
          required String agentMessageUuid,
          required bool confirmed,
        }) async =>
            true,
        onForm: ({
          required String agentMessageUuid,
          required Map<String, dynamic> fields,
        }) async =>
            true,
        onAction: ({
          required String agentMessageUuid,
          required String actionId,
          Map<String, dynamic>? params,
        }) async =>
            true,
        onOpenEmployee: withOpenEmployee
            ? (actionId) async => onOpenEmployeeCall?.call(actionId)
            : null,
      );
    }

    testWidgets('非 awaiting_user 消息上「找财税助手」仍可点并回传 actionId', (tester) async {
      String? captured;
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'action',
            'actions': [
              {'id': 'open_employee:财税助手', 'label': '找财税助手'},
            ],
          },
        ],
        // 主动推送/历史消息: 不满足 awaiting_user 门控
        agentMessageStatus: 'completed',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: empHandler(onOpenEmployeeCall: (id) => captured = id),
      )));
      final btn =
          tester.widget<TextButton>(find.widgetWithText(TextButton, '找财税助手'));
      expect(btn.onPressed, isNotNull, reason: '衔接按钮豁免 awaiting_user 门控');

      await tester.tap(find.widgetWithText(TextButton, '找财税助手'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(captured, 'open_employee:财税助手');
    });

    testWidgets('onOpenEmployee 未装配 → 按普通 action 门控置灰', (tester) async {
      await tester.pumpWidget(_wrap(EmpBlocksView(
        blocks: const [
          {
            'type': 'action',
            'actions': [
              {'id': 'open_employee:财税助手', 'label': '找财税助手'},
            ],
          },
        ],
        agentMessageStatus: 'completed',
        agentMessageUuid: 'm-1',
        conversationUuid: 'c-1',
        respondHandler: empHandler(withOpenEmployee: false),
      )));
      final btn =
          tester.widget<TextButton>(find.widgetWithText(TextButton, '找财税助手'));
      expect(btn.onPressed, isNull);
    });
  });
}
