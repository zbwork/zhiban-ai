// emp_block_readable_text_test.dart — Plan 16 Phase 3 minimal closed-loop。
//
// 覆盖典型 EMP block 类型在 zhiban-app `_blocksToText` / `_agentBusBlocksToText` 收口后的
// "只读 fallback 文本" 行为, 锁住"typed 富 block 不再抽空"这条 Phase 2 review 收尾承诺。
//
// **不**测试富组件 UI 渲染 — 那是 Phase 3 widget 上线后的工作; 本文件只测 helper 文本输出。

import 'package:test/test.dart';
import 'package:zhiban_core/emp/emp_block_readable_text.dart';

void main() {
  group('empBlocksToReadableText', () {
    test('markdown / plain → 原样输出 text/markdown', () {
      expect(
        empBlocksToReadableText(const [
          {'type': 'markdown', 'text': 'hello'},
          {'type': 'plain', 'text': 'world'},
        ]),
        'hello\nworld',
      );
    });

    test('chart 不再抽空, 含 [图表] 前缀 + title', () {
      final out = empBlocksToReadableText(const [
        {'type': 'chart', 'title': '月度数据', 'chart_kind': 'bar'},
      ]);
      expect(out, contains('[图表]'));
      expect(out, contains('月度数据'));
    });

    test('chart 没 title 时也不抽空 (用 chart_kind 兜底)', () {
      final out = empBlocksToReadableText(const [
        {'type': 'chart', 'chart_kind': 'line'},
      ]);
      expect(out.isNotEmpty, isTrue);
      expect(out, contains('[图表]'));
    });

    test(
        'chart round-9: summary + unit + source + updated_at 进 readable, '
        '但 insights / table / data 不进 (避免污染历史正文)', () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'chart',
          'chart_kind': 'bar',
          'title': '近 6 个月营收',
          'summary': 'Q2 反弹',
          'unit': '万元',
          'source': '财务系统',
          'updated_at': '2 分钟前',
          // 以下不应进 readable 文本
          'insights': ['I1', 'I2', 'I3'],
          'data': [
            {'label': '1月', 'value': 320},
          ],
          'table': {
            'headers': ['A'],
            'rows': [
              ['1']
            ],
          },
        },
      ]);
      expect(out, contains('近 6 个月营收'));
      expect(out, contains('Q2 反弹'));
      expect(out, contains('单位: 万元'));
      expect(out, contains('来源: 财务系统'));
      expect(out, contains('更新: 2 分钟前'));
      expect(out, isNot(contains('I1')));
      expect(out, isNot(contains('320')));
    });

    test('form 只读: 提示 "需在客户端最新版查看完整组件" 不伪造提交按钮', () {
      final out = empBlocksToReadableText(const [
        {'type': 'form', 'title': '请假申请'},
      ]);
      expect(out, contains('[表单]'));
      expect(out, contains('请假申请'));
      expect(out, contains('需在客户端最新版查看完整组件'));
      // 必须不出现"提交 / Submit / 确定"等会让用户误以为能提交的字
      expect(out.contains('提交'), isFalse);
    });

    // form 只读 fallback 严格规则:
    //   - submit_label 即使存在也**不**读 (避免误导用户能点 "提交");
    //   - description 优先级高于固定占位; submit_label 永远被忽略。
    test('form: submit_label="提交" 不暴露; 走固定占位文案', () {
      final out = empBlocksToReadableText(const [
        {'type': 'form', 'title': '请假申请', 'submit_label': '提交'},
      ]);
      expect(out.contains('提交'), isFalse,
          reason: 'submit_label 不可暴露 (会误导用户能点击提交), got "$out"');
      expect(out, contains('[表单]'));
      expect(out, contains('请假申请'));
      expect(out, contains('需在客户端最新版查看完整组件'));
    });

    test(
        'form: description + submit_label 同时存在 → 仅输出 description, 不输出 submit_label',
        () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'form',
          'title': '请假申请',
          'description': '请填写理由和起止日期',
          'submit_label': '提交',
        },
      ]);
      expect(out, contains('[表单]'));
      expect(out, contains('请假申请'));
      expect(out, contains('请填写理由和起止日期'));
      expect(out.contains('提交'), isFalse);
      // 既然 description 存在就不该走"需在客户端最新版查看完整组件"占位
      expect(out.contains('需在客户端最新版查看完整组件'), isFalse);
    });

    test('form: 无 title 也固定占位 ("[表单] · 需在...")', () {
      final out = empBlocksToReadableText(const [
        {'type': 'form'},
      ]);
      expect(out.startsWith('[表单]'), isTrue);
      expect(out, contains('需在客户端最新版查看完整组件'));
    });

    test('action / action_bar 仅展示 button 文案 (只读, 不可点)', () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'action',
          'title': '请确认',
          'actions': [
            {'label': '同意'},
            {'label': '拒绝'},
          ],
        },
      ]);
      expect(out, contains('[操作栏]'));
      expect(out, contains('请确认'));
      expect(out, contains('同意'));
      expect(out, contains('拒绝'));
    });

    test('approval / confirm / approval_request 三同名映射都展示', () {
      for (final t in const ['approval', 'confirm', 'approval_request']) {
        final out = empBlocksToReadableText([
          {'type': t, 'title': '审批 $t'},
        ]);
        expect(out, contains('[审批]'), reason: 'type=$t');
        expect(out, contains('审批 $t'));
      }
    });

    test('artifact 展示 artifact_kind + name', () {
      final out = empBlocksToReadableText(const [
        {'type': 'artifact', 'artifact_kind': 'image', 'name': 'cover.png'},
      ]);
      expect(out, contains('[附件'));
      expect(out, contains('image'));
      expect(out, contains('cover.png'));
    });

    test('source / citation 同义都被识别', () {
      for (final t in const ['source', 'citation']) {
        final out = empBlocksToReadableText([
          {'type': t, 'title': 'wikipedia', 'url': 'https://x.example/page'},
        ]);
        expect(out, contains('[来源]'), reason: 'type=$t');
        expect(out, contains('wikipedia'));
      }
    });

    test('progress 含百分比', () {
      final out = empBlocksToReadableText(const [
        {'type': 'progress', 'percent': 42, 'label': '上传中'},
      ]);
      expect(out, contains('[进度]'));
      expect(out, contains('上传中'));
      expect(out, contains('42%'));
    });

    test('app_card 展示标题 + summary', () {
      final out = empBlocksToReadableText(const [
        {'type': 'app_card', 'title': '审批中心', 'summary': '本月待审 5 单'},
      ]);
      expect(out, contains('[卡片]'));
      expect(out, contains('审批中心'));
      expect(out, contains('本月待审 5 单'));
    });

    test('plan 展示 step 数', () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'plan',
          'title': 'OA 走流程',
          'steps': [
            {'title': 'a'},
            {'title': 'b'},
            {'title': 'c'},
          ],
        },
      ]);
      expect(out, contains('[计划]'));
      expect(out, contains('3 步'));
    });

    test('tool_result 不进入正文/会话预览 (2026-07-08 A2A 收口)', () {
      final out = empBlocksToReadableText(const [
        {'type': 'tool_result', 'name': 'search_kb', 'status': 'ok'},
        {'type': 'markdown', 'text': '最终回答内容'},
      ]);
      expect(out, isNot(contains('[工具结果]')));
      expect(out, isNot(contains('search_kb')));
      expect(out, contains('最终回答内容'));
    });

    test('tool_call 不污染最终回答正文', () {
      final out = empBlocksToReadableText(const [
        {'type': 'tool_call', 'tool': 'session_status'},
        {'type': 'markdown', 'text': '今天 AI 圈的重点如下'},
      ]);
      expect(out, isNot(contains('[tool_call]')));
      expect(out, isNot(contains('session_status')));
      expect(out, contains('今天 AI 圈的重点如下'));
    });

    test('x_source=a2a_timeline 过程块不进入正文/会话预览', () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'tool_call',
          'tool': 'a2a.invoke',
          'tool_call_id': 'a2a:e1',
          'x_source': 'a2a_timeline'
        },
        {
          'type': 'tool_result',
          'tool': '法务顾问',
          'status': 'done',
          'x_source': 'a2a_timeline'
        },
        // 即便过程块被标成 markdown，只要 x_source=a2a_timeline 也必须过滤。
        {'type': 'markdown', 'text': '协作中间过程', 'x_source': 'a2a_timeline'},
        {'type': 'markdown', 'text': '行政专员最终回复'},
      ]);
      expect(out, '行政专员最终回复');
      expect(out, isNot(contains('法务顾问')));
      expect(out, isNot(contains('协作中间过程')));
      expect(out, isNot(contains('[工具结果]')));
    });

    test('x_source=a2a_approval 审批块保留 (交给 EMP renderer)', () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'approval',
          'title': '需要确认协作',
          'x_source': 'a2a_approval',
          'approval_request_id': 'ap-1'
        },
      ]);
      // a2a_approval 不被 a2a_timeline 过滤误伤：readable fallback 仍给审批提示。
      expect(out, contains('[审批]'));
    });

    test('reasoning 不进正文/预览，suggestion / mermaid / flowchart 有可读兜底', () {
      final out = empBlocksToReadableText(const [
        {'type': 'reasoning', 'text': '先检查制度，再生成表单'},
        {
          'type': 'suggestion',
          'suggestions': [
            {'label': '填写行政服务申请'},
            {'text': '查询接待制度'},
          ],
        },
        {'type': 'mermaid', 'source': 'graph TD; A-->B;'},
        {'type': 'flowchart', 'code': 'start=>start: 开始'},
      ]);
      expect(out, isNot(contains('[推理]')));
      expect(out, isNot(contains('先检查制度')));
      expect(out, contains('[建议]'));
      expect(out, contains('填写行政服务申请'));
      expect(out, contains('查询接待制度'));
      expect(out, contains('[图表源码] mermaid'));
      expect(out, contains('graph TD'));
      expect(out, contains('[图表源码] flowchart'));
      expect(out, contains('start=>start'));
    });

    test('code 用 markdown code fence 渲染 (现有 markdown 渲染器可吃)', () {
      final out = empBlocksToReadableText(const [
        {'type': 'code', 'language': 'go', 'text': 'fmt.Println("hi")'},
      ]);
      expect(out, contains('```go'));
      expect(out, contains('fmt.Println'));
      expect(out, contains('```'));
    });

    test('table 至少透出行数', () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'table',
          'title': '员工表',
          'rows': [
            [1, 2],
            [3, 4],
          ],
        },
      ]);
      expect(out, contains('[表格]'));
      expect(out, contains('员工表'));
      expect(out, contains('2 行'));
    });

    test('inline error 透出 message', () {
      final out = empBlocksToReadableText(const [
        {'type': 'error', 'message': 'agent runtime returned an error'},
      ]);
      expect(out, contains('[错误]'));
      expect(out, contains('agent runtime returned an error'));
    });

    test('unknown type 也不抽空: 至少给 [type] 兜底', () {
      final out = empBlocksToReadableText(const [
        {'type': 'super_widget_v9', 'title': '未来组件'},
      ]);
      expect(out, contains('[super_widget_v9]'));
      expect(out, contains('未来组件'));
    });

    test('markdown 与 typed 富 block 混排都保留 (顺序一致)', () {
      final out = empBlocksToReadableText(const [
        {'type': 'markdown', 'text': '请审批以下事项:'},
        {'type': 'approval', 'title': '差旅报销 3500'},
        {'type': 'markdown', 'text': '审批结束后会发邮件。'},
      ]);
      expect(out, contains('请审批以下事项:'));
      expect(out, contains('[审批]'));
      expect(out, contains('差旅报销 3500'));
      expect(out, contains('审批结束后会发邮件。'));
    });

    test('完全空 / 非 list 输入安全返 ""', () {
      expect(empBlocksToReadableText(null), '');
      expect(empBlocksToReadableText('not a list'), '');
      expect(empBlocksToReadableText(const []), '');
    });
  });

  // ----- F1 hardening: malformed typed block 字段不能 throw -----
  //
  // ZAP runtime / 第三方 agent 平台 给的 typed block 字段类型可能不规范 (例: actions 字段被
  // 写成 Map / String 而不是 List)。helper 必须用 safe coerce, 单 block 异常不能 kill 整条
  // message 的其余 block 输出。所有 assertion 关键是"不 throw + 有合理只读 fallback"。
  group('empBlocksToReadableText malformed typed-block tolerance', () {
    test('action.actions 是 Map 不 throw, 至少返回 [操作栏]...', () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'action',
          'title': '请确认',
          'actions': {'oops': 'this should be a list'}, // Map 而不是 List
        },
      ]);
      expect(out.startsWith('[操作栏]'), isTrue,
          reason: 'expected [操作栏] prefix, got "$out"');
      expect(out, contains('请确认'));
      // 没法解析按钮 → 退化到 fallback "需在客户端最新版查看完整组件"
      expect(out, contains('需在客户端最新版查看完整组件'));
    });

    test('action.actions 是 String 不 throw', () {
      final out = empBlocksToReadableText(const [
        {'type': 'action', 'title': '请确认', 'actions': 'not-a-list'},
      ]);
      expect(out.startsWith('[操作栏]'), isTrue);
      expect(out, contains('请确认'));
    });

    test('action.actions 是 List 但里面是 String/null 不 throw', () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'action',
          'title': '请确认',
          'actions': ['just a string', null, 42],
        },
      ]);
      expect(out.startsWith('[操作栏]'), isTrue);
      expect(out, contains('请确认'));
      // 非 Map 元素被跳过 → fallback
      expect(out, contains('需在客户端最新版查看完整组件'));
    });

    test('source.items 是 Map 不 throw', () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'source',
          'items': {'count': 3}, // 错型
        },
      ]);
      expect(out.startsWith('[来源]'), isTrue);
    });

    test('source.items 是 String 不 throw', () {
      final out = empBlocksToReadableText(const [
        {'type': 'source', 'items': 'see references'},
      ]);
      expect(out.startsWith('[来源]'), isTrue);
    });

    test('plan.steps 是 Map 不 throw', () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'plan',
          'title': 'OA 走流程',
          'steps': {'oops': 'should be list'},
        },
      ]);
      expect(out.startsWith('[计划]'), isTrue);
      expect(out, contains('OA 走流程'));
      // 错型 → 不再 count step 数量, 退化到只显示 head, 不抛
      expect(out.contains('步'), isFalse);
    });

    test('plan.steps 是 String 不 throw', () {
      final out = empBlocksToReadableText(const [
        {'type': 'plan', 'title': 'OA 走流程', 'steps': 'invalid'},
      ]);
      expect(out.startsWith('[计划]'), isTrue);
      expect(out, contains('OA 走流程'));
    });

    test('chart 字段类型错 (title 是 Map) 不 throw, 走最小兜底', () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'chart',
          'title': {'oops': 'should be string'},
          'chart_kind': 'bar',
        },
      ]);
      expect(out.startsWith('[图表]'), isTrue);
      // title 错型 → _asString 返 ""; 用 chart_kind 兜底
      expect(out, contains('bar'));
    });

    test('整个 block 是 Map 但 type 字段是 Map 不 throw', () {
      final out = empBlocksToReadableText(const [
        {
          'type': {'oops': true}, // 极端: type 是 Map
          'text': 'fallback markdown',
        },
      ]);
      // type 取 string 失败 → _asString 返 "" → 走 markdown 分支
      expect(out, contains('fallback markdown'));
    });

    test('mixed list: 中间某个 block 字段坏了不影响前后 markdown/plain', () {
      final out = empBlocksToReadableText(const [
        {'type': 'markdown', 'text': '前置说明'},
        {
          'type': 'action',
          'actions': {'oops': 'map not list'}, // 故意错型
        },
        {'type': 'plain', 'text': '后置说明'},
        {
          'type': 'plan',
          'steps': 'not a list',
        },
        {'type': 'markdown', 'text': '末尾说明'},
      ]);
      // 前后 markdown/plain 必须保留
      expect(out, contains('前置说明'));
      expect(out, contains('后置说明'));
      expect(out, contains('末尾说明'));
      // 坏 block 也输出了占位 (不抛, 不抽空)
      expect(out, contains('[操作栏]'));
      expect(out, contains('[计划]'));
    });

    test('artifact.kind / source.url 是 Map 不 throw', () {
      final out = empBlocksToReadableText(const [
        {
          'type': 'artifact',
          'artifact_kind': {'oops': 'map'},
          'name': 'cover.png',
        },
        {
          'type': 'source',
          'url': {'oops': 'map'},
          'title': 'wikipedia',
        },
      ]);
      expect(out, contains('[附件'));
      expect(out, contains('cover.png'));
      expect(out, contains('[来源]'));
      expect(out, contains('wikipedia'));
    });

    test('progress.percent 是 String 不 throw, 退化到无百分比', () {
      final out = empBlocksToReadableText(const [
        {'type': 'progress', 'percent': 'forty-two', 'label': '上传中'},
      ]);
      expect(out.startsWith('[进度]'), isTrue);
      expect(out, contains('上传中'));
      // percent 不是 num → 退化, 不带百分号
      expect(out.contains('%'), isFalse);
    });
  });
}
