import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/agent_mention.dart';

const _all = kMentionAll;
const _zhang =
    MentionCandidate(type: MentionType.human, id: 'acc-1', displayName: '张三');
const _chen =
    MentionCandidate(type: MentionType.agent, id: 'ag-1', displayName: '陈启航');
const _cands = <MentionCandidate>[_all, _zhang, _chen];

void main() {
  group('Agent 群回复定向 mention', () {
    test('按 human account uuid 使用当前群成员显示名', () {
      final names = groupReplyHumanMentionNames(const [
        {'type': 'human', 'id': 'acc-1', 'name': '旧名字'},
      ], const {
        'acc-1': '李强'},
      );
      expect(names, ['李强']);
      expect(groupReplyMentionPrefix(names), '@李强');
    });

    test('非 human、非 active 成员和重复 id 不展示', () {
      final names = groupReplyHumanMentionNames(const [
        {'type': 'agent', 'id': 'ag-1', 'name': '测试001'},
        {'type': 'human', 'id': 'removed', 'name': '已退群'},
        {'type': 'human', 'id': 'acc-1', 'name': '李强'},
        {'type': 'human', 'id': 'acc-1', 'name': '李强'},
      ], const {
        'acc-1': '李强'},
      );
      expect(names, ['李强']);
    });

    test('文本和 markdown 首块与 mention 共用首行', () {
      expect(
        groupReplyMentionCanShareFirstLine(const [
          {'type': 'markdown', 'text': '现在是 17:51。'},
        ]),
        isTrue,
      );
      expect(
        groupReplyMentionCanShareFirstLine(const [
          {'type': 'plain', 'text': '你好'},
        ]),
        isTrue,
      );
    });

    test('独立富组件不与 mention 强行同行', () {
      expect(
        groupReplyMentionCanShareFirstLine(const [
          {'type': 'form', 'title': '申请表'},
        ]),
        isFalse,
      );
      expect(groupReplyMentionCanShareFirstLine(const []), isFalse);
    });
  });

  group('detectMention 输入候选触发', () {
    test('行首 @ 命中', () {
      final q = detectMention('@陈', 2);
      expect(q?.query, '陈');
      expect(q?.start, 0);
    });
    test('空白后 @ 命中', () {
      const t = '你好 @启';
      expect(detectMention(t, t.length)?.query, '启');
    });
    test('普通正文后无空格 @ 命中', () {
      const t = '今晚@';
      final q = detectMention(t, t.length);
      expect(q?.query, '');
      expect(q?.start, 2);
    });
    test('中文逗号后 @ 命中', () {
      const t = '通知，@所';
      expect(detectMention(t, t.length)?.query, '所');
    });
    test('英文句号后 @ 命中', () {
      const t = 'ok.@a';
      expect(detectMention(t, t.length)?.query, 'a');
    });
    test('候选开关不承担 email 解析', () {
      const t = 'mail a@b';
      expect(detectMention(t, t.length)?.query, 'b');
    });
    test('@ 后空格→token 结束', () {
      expect(detectMention('@陈启航 你好', 8), isNull);
    });
  });

  group('filterCandidates / sort', () {
    test('空 query → 全部', () {
      expect(filterCandidates(_cands, '').length, 3);
    });
    test('按名字包含', () {
      final r = filterCandidates(_cands, '陈');
      expect(r.length, 1);
      expect(r.first.displayName, '陈启航');
    });
    test('排序: 所有人置顶, 再员工, 再数字员工', () {
      final sorted =
          sortMentionCandidates(<MentionCandidate>[_chen, _zhang, _all]);
      expect(sorted[0].type, MentionType.all);
      expect(sorted[1].type, MentionType.human);
      expect(sorted[2].type, MentionType.agent);
    });
    test('tab 过滤:全部/成员/数字员工', () {
      expect(visibleMentionCandidates(_cands, MentionCandidateTab.all), _cands);
      final humans =
          visibleMentionCandidates(_cands, MentionCandidateTab.human);
      expect(humans, hasLength(1));
      expect(humans.single.type, MentionType.human);
      final agents =
          visibleMentionCandidates(_cands, MentionCandidateTab.agent);
      expect(agents, hasLength(1));
      expect(agents.single.type, MentionType.agent);
    });
    test('Tab 顺序:全部→成员→数字员工, Shift+Tab 反向', () {
      expect(nextMentionCandidateTab(MentionCandidateTab.all),
          MentionCandidateTab.human);
      expect(nextMentionCandidateTab(MentionCandidateTab.human),
          MentionCandidateTab.agent);
      expect(nextMentionCandidateTab(MentionCandidateTab.agent),
          MentionCandidateTab.all);
      expect(
        nextMentionCandidateTab(MentionCandidateTab.all, reverse: true),
        MentionCandidateTab.agent,
      );
    });
  });

  group('applyMention', () {
    test('替换 @token 为 @名字 + 空格', () {
      const text = '帮我问 @陈';
      final q = detectMention(text, text.length)!;
      final r = applyMention(text, text.length, q, '陈启航');
      expect(r.text, '帮我问 @陈启航 ');
      expect(r.caret, r.text.length);
    });
    test('保留普通正文后无空格 mention', () {
      const text = '今晚@陈';
      final q = detectMention(text, text.length)!;
      final r = applyMention(text, text.length, q, '陈启航');
      expect(r.text, '今晚@陈启航 ');
      expect(r.caret, r.text.length);
    });
  });

  group('mention popup anchor', () {
    test('后面输入 @ 时, anchor x 跟随 @ token 位置', () {
      const shortText = '@';
      const longText = '这是一段很长的输入内容 @';
      final shortAnchor = measureMentionTokenOffset(
        text: shortText,
        textOffset: 0,
        maxWidth: 600,
      );
      final longAnchor = measureMentionTokenOffset(
        text: longText,
        textOffset: longText.indexOf('@'),
        maxWidth: 600,
      );

      expect(longAnchor.dx, greaterThan(shortAnchor.dx + 120));
    });
    test('换行后行首 @ 的 anchor 回到左侧', () {
      const text = '第一段很长的输入内容\n@';
      final anchor = measureMentionTokenOffset(
        text: text,
        textOffset: text.indexOf('@'),
        maxWidth: 600,
      );
      expect(anchor.dx, lessThan(4));
      expect(anchor.dy, greaterThan(0));
    });
    test('靠右时 popup 横向在输入框边界内收', () {
      final left = resolveMentionPopupLeft(
        desiredLeft: 360,
        popupWidth: 160,
        boundaryLeft: 40,
        boundaryRight: 420,
      );
      expect(left, 252);
      expect(left + 160, 412);
    });
    test('输入框太窄时 popup 保底贴左边界', () {
      final left = resolveMentionPopupLeft(
        desiredLeft: 180,
        popupWidth: 400,
        boundaryLeft: 40,
        boundaryRight: 260,
      );
      expect(left, 48);
    });
  });

  group('mentionsFromText → 结构化 payload', () {
    test('@张三 @陈启航 → human + agent metadata', () {
      final ms = mentionsFromText('@张三 @陈启航 帮看下', _cands);
      expect(ms.length, 2);
      expect(ms[0].typeString, 'human');
      expect(ms[0].id, 'acc-1');
      expect(ms[1].typeString, 'agent');
      expect(ms[1].id, 'ag-1');
      // toPayload 结构。
      expect(ms[1].toPayload(), {'type': 'agent', 'id': 'ag-1', 'name': '陈启航'});
    });
    test('@所有人 → all metadata', () {
      final ms = mentionsFromText('@所有人 通知', _cands);
      expect(ms.length, 1);
      expect(ms.first.typeString, 'all');
    });
    test('普通正文后无空格 @已知名字 → 结构化 metadata', () {
      final ms = mentionsFromText('今晚@陈启航 请安排', _cands);
      expect(ms, hasLength(1));
      expect(ms.single.typeString, 'agent');
      expect(ms.single.id, 'ag-1');
    });
    test('@不存在 → 空(不产生 mention)', () {
      expect(mentionsFromText('@幽灵 hi', _cands), isEmpty);
    });
    test('email 不产生 mention', () {
      expect(mentionsFromText('mail a@b.com', _cands), isEmpty);
      const domainLikeCandidates = <MentionCandidate>[
        MentionCandidate(
          type: MentionType.human,
          id: 'acc-example',
          displayName: 'example',
        ),
        MentionCandidate(
          type: MentionType.agent,
          id: 'ag-example-domain',
          displayName: 'example.com',
        ),
      ];
      expect(
        mentionsFromText('mail a@example.com', domainLikeCandidates),
        isEmpty,
      );
    });
  });

  group('mentionsForSend(picked 优先,解决同名歧义)', () {
    // human 和 agent 同名:候选里 human 在前(名字正则会先命中 human)。
    const humanChen = MentionCandidate(
        type: MentionType.human, id: 'acc-9', displayName: '陈启航');
    const agentChen = MentionCandidate(
        type: MentionType.agent, id: 'ag-9', displayName: '陈启航');
    const sameName = <MentionCandidate>[humanChen, agentChen];

    // 构造 picked,绑定到 @名字 在文本中的 occurrence 区间 [start, start+token.length)。
    PickedMention pick(MentionCandidate c, {int start = 0}) {
      final token = '@${c.displayName}';
      return PickedMention(
          candidate: c, token: token, start: start, end: start + token.length);
    }

    test('选中 agent 候选后发送 → 必须是 agent,不被名字正则解析成 human', () {
      final ms = mentionsForSend('@陈启航 帮看下', [pick(agentChen)], sameName);
      expect(ms.length, 1);
      expect(ms.first.typeString, 'agent');
      expect(ms.first.id, 'ag-9');
    });

    test('picked 被删除(区间不再是原 token)→ 不发送该 picked', () {
      final ms = mentionsForSend('改主意了，不at了', [pick(agentChen)], sameName);
      expect(ms, isEmpty);
    });

    test('picked agent + 文本兜底识别同一 agent → 只保留一条', () {
      final ms = mentionsForSend('@陈启航 在吗', [pick(_chen)], const [_chen]);
      expect(ms.length, 1);
      expect(ms.first.id, 'ag-1');
    });

    test('picked agent + 手打 @张三 合并:agent(picked 优先) + 张三(兜底),无同名 human', () {
      final cands = <MentionCandidate>[humanChen, agentChen, _zhang];
      final ms = mentionsForSend('@陈启航 @张三 一起看', [pick(agentChen)], cands);
      expect(ms.length, 2);
      expect(ms[0].typeString, 'agent'); // picked 优先
      expect(ms[0].id, 'ag-9');
      expect(ms.any((c) => c.id == 'acc-1'), isTrue); // 张三 兜底
      expect(ms.any((c) => c.id == 'acc-9'), isFalse); // 同名 human 陈启航 不应混入
    });

    test('无 picked、纯手打 @名字 → 文本兜底', () {
      final ms = mentionsForSend('@张三 hi', const [], const [_zhang]);
      expect(ms.length, 1);
      expect(ms.first.id, 'acc-1');
    });

    // P2: picked 删除后重新手打同名 @名字 → 旧 picked 区间不再匹配 → 不复活旧 agent 身份,
    // 改走普通文本兜底(命中第一个候选 human),不被 resurrect。
    test('picked 删除后在别处重新手打同名 @名字 → 不复活旧 picked,走文本兜底', () {
      // 原 picked 是 agent 陈启航 在 [0,4];当前文本里 @陈启航 在偏移 3,原区间子串≠token → 失效。
      final ms =
          mentionsForSend('你好 @陈启航 hi', [pick(agentChen, start: 0)], sameName);
      expect(ms.length, 1);
      expect(ms.first.typeString, 'human'); // 文本兜底命中第一个候选 human
      expect(ms.first.id, 'acc-9');
    });

    // P2: picked 区间原位仍是原 token → 保留真实 agent 身份,不被同名 human 抢走。
    test('picked 区间原位匹配 → 保留真实 agent 身份', () {
      final ms =
          mentionsForSend('@陈启航 hi', [pick(agentChen, start: 0)], sameName);
      expect(ms.length, 1);
      expect(ms.first.typeString, 'agent');
      expect(ms.first.id, 'ag-9');
    });

    // P2: 编辑维护 picked occurrence 区间。
    test('在 mention 前插入文本 → 区间平移, 仍发 agent(不被同名 human 抢走)', () {
      const oldText = '@陈启航 帮看下';
      const newText = '你好 @陈启航 帮看下'; // 在 mention 前插入 "你好 "(3 字符)
      final reconciled = reconcilePickedMentions(
          [pick(agentChen, start: 0)], oldText, newText);
      expect(reconciled, hasLength(1));
      expect(reconciled.first.start, 3); // [0,4] → [3,7]
      expect(reconciled.first.end, 7);
      final ms = mentionsForSend(newText, reconciled, sameName);
      expect(ms.length, 1);
      expect(ms.first.typeString, 'agent');
      expect(ms.first.id, 'ag-9');
    });

    test('在 mention 后编辑 → 区间不变', () {
      const oldText = '@陈启航 hi';
      const newText = '@陈启航 hello world'; // 在 mention 后改
      final reconciled = reconcilePickedMentions(
          [pick(agentChen, start: 0)], oldText, newText);
      expect(reconciled, hasLength(1));
      expect(reconciled.first.start, 0);
      expect(reconciled.first.end, 4);
    });

    test('编辑 mention token 本身 → picked 失效', () {
      const oldText = '@陈启航 hi';
      const newText = '@陈启 hi'; // 删掉 "航"
      final reconciled = reconcilePickedMentions(
          [pick(agentChen, start: 0)], oldText, newText);
      expect(reconciled, isEmpty); // 与 token 相交 → 失效
      final ms = mentionsForSend(newText, reconciled, sameName);
      expect(ms, isEmpty); // @陈启 不匹配任何候选名
    });

    test('平移后跨多次编辑仍正确(先前插入再后插入)', () {
      var picks = [pick(agentChen, start: 0)]; // @陈启航 帮看下 → [0,4]
      // 前插 "你好 "
      picks = reconcilePickedMentions(picks, '@陈启航 帮看下', '你好 @陈启航 帮看下');
      expect(picks.single.start, 3);
      // 再在末尾追加(token 后)→ 不变
      picks = reconcilePickedMentions(picks, '你好 @陈启航 帮看下', '你好 @陈启航 帮看下啊');
      expect(picks.single.start, 3);
      final ms = mentionsForSend('你好 @陈启航 帮看下啊', picks, sameName);
      expect(ms.single.id, 'ag-9');
    });
  });

  group('expandPartialMentionDeletion', () {
    PickedMention pick(MentionCandidate c, {required int start}) {
      final token = '@${c.displayName}';
      return PickedMention(
          candidate: c, token: token, start: start, end: start + token.length);
    }

    test('退格删到 token 最后一个字 → 整个 token(含尾随空格)一起删', () {
      const oldText = '@陈启航 帮看下';
      const newText = '@陈启 帮看下';
      final expansion = expandPartialMentionDeletion(
          [pick(_chen, start: 0)], oldText, newText);
      expect(expansion, isNotNull);
      expect(expansion!.text, '帮看下');
      expect(expansion.caret, 0);
    });

    test('正向删除挖到 token 中间 → 整个 token(含尾随空格)一起删', () {
      const oldText = '@陈启航 帮看下';
      const newText = '@航 帮看下';
      final expansion = expandPartialMentionDeletion(
          [pick(_chen, start: 0)], oldText, newText);
      expect(expansion, isNotNull);
      expect(expansion!.text, '帮看下');
      expect(expansion.caret, 0);
    });

    test('退格删到 token 后紧跟的空格 → 连同 token 一起删', () {
      const oldText = '@陈启航 帮看下';
      const newText = '@陈启航帮看下';
      final expansion = expandPartialMentionDeletion(
          [pick(_chen, start: 0)], oldText, newText);
      expect(expansion, isNotNull);
      expect(expansion!.text, '帮看下');
      expect(expansion.caret, 0);
    });

    test('删除范围覆盖 token 但漏了尾随空格 → 补删空格', () {
      const oldText = '@陈启航 帮看下';
      const newText = ' 帮看下';
      final expansion = expandPartialMentionDeletion(
          [pick(_chen, start: 0)], oldText, newText);
      expect(expansion, isNotNull);
      expect(expansion!.text, '帮看下');
      expect(expansion.caret, 0);
    });

    test('删除范围已完整覆盖 token 和尾随空格 → 不需要再扩展', () {
      const oldText = '@陈启航 帮看下';
      const newText = '帮看下';
      final expansion = expandPartialMentionDeletion(
          [pick(_chen, start: 0)], oldText, newText);
      expect(expansion, isNull);
    });

    test('编辑跟 token 无关 → 不触发', () {
      const oldText = '@陈启航 帮看下';
      const newText = '@陈启航 帮看';
      final expansion = expandPartialMentionDeletion(
          [pick(_chen, start: 0)], oldText, newText);
      expect(expansion, isNull);
    });
  });

  group('mentionHighlightSpans', () {
    final names = {'张三', '陈启航', '所有人'};
    final hi = const TextStyle(color: Color(0xFF2563EB));
    final base = const TextStyle(color: Color(0xFF1D2129));

    List<TextSpan> spansOf(String t) =>
        mentionHighlightSpans(t, names, base: base, highlight: hi);

    test('@员工 @数字员工 @所有人 各高亮', () {
      for (final t in [
        '@张三 hi',
        '帮 @陈启航 看',
        '今晚@陈启航 请安排',
        '@所有人 通知'
      ]) {
        final spans = spansOf(t);
        final hasHi = spans.any((s) =>
            s.style?.color == const Color(0xFF2563EB) &&
            (s.text ?? '').startsWith('@'));
        expect(hasHi, isTrue, reason: 'should highlight in: $t');
      }
    });
    test('普通文本无高亮', () {
      final spans = spansOf('纯文本无提及');
      expect(spans.every((s) => s.style?.color != const Color(0xFF2563EB)),
          isTrue);
    });
    test('@未知名字不高亮', () {
      final spans = spansOf('@路人甲 hi');
      expect(spans.every((s) => s.style?.color != const Color(0xFF2563EB)),
          isTrue);
    });
    test('email 中的候选名片段不高亮', () {
      final spans = mentionHighlightSpans(
        'mail a@example.com',
        {'example', 'example.com'},
        base: base,
        highlight: hi,
      );
      expect(
        spans.every((s) => s.style?.color != const Color(0xFF2563EB)),
        isTrue,
      );
    });
  });

  group('MentionBar widget', () {
    testWidgets('渲染 所有人/员工/数字员工 三行 + 点击回调', (tester) async {
      MentionCandidate? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            child: MentionBar(
              candidates: _cands,
              selected: _all,
              onPick: (c) => picked = c,
            ),
          ),
        ),
      ));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('mention-popup-surface')))
            .width,
        lessThanOrEqualTo(420),
      );
      expect(find.text('全部 3'), findsOneWidget);
      expect(find.text('成员 1'), findsOneWidget);
      expect(find.text('数字员工 1'), findsOneWidget);
      expect(find.text('所有人'), findsWidgets); // 名字 + 类型标签都含"所有人"
      expect(find.text('张三'), findsOneWidget);
      expect(find.text('陈启航'), findsOneWidget);
      // 类型标签存在。
      expect(find.text('数字员工'), findsOneWidget);
      expect(find.text('员工'), findsOneWidget);
      final selectedLabel = tester.widget<Text>(
        find
            .descendant(
              of: find.byKey(const ValueKey('mention-selected-row')),
              matching: find.text('所有人'),
            )
            .first,
      );
      expect(selectedLabel.style?.color, Colors.white);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('mention-selected-row')))
            .height,
        lessThanOrEqualTo(38),
      );
      await tester.tap(find.text('陈启航'));
      await tester.pump();
      expect(picked?.type, MentionType.agent);
    });

    testWidgets('鼠标点击 tab 后只显示当前类型候选,并可点击候选', (tester) async {
      MentionCandidate? picked;
      MentionCandidateTab activeTab = MentionCandidateTab.all;

      Widget host() => MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                child: MentionBar(
                  candidates: _cands,
                  activeTab: activeTab,
                  selected: _chen,
                  onTabChange: (tab) => activeTab = tab,
                  onPick: (c) => picked = c,
                ),
              ),
            ),
          );

      await tester.pumpWidget(host());
      await tester.tap(find.text('成员 1'));
      await tester.pumpWidget(host());
      expect(activeTab, MentionCandidateTab.human);
      expect(find.text('张三'), findsOneWidget);
      expect(find.text('陈启航'), findsNothing);

      await tester.tap(find.text('张三'));
      await tester.pump();
      expect(picked?.type, MentionType.human);
      expect(picked?.id, 'acc-1');

      await tester.tap(find.text('数字员工 1'));
      await tester.pumpWidget(host());
      expect(activeTab, MentionCandidateTab.agent);
      expect(find.text('张三'), findsNothing);
      expect(find.text('陈启航'), findsOneWidget);
    });

    testWidgets('无候选 → 不显示(高度 0)', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: MentionBar(candidates: [], onPick: _noop)),
      ));
      expect(tester.getSize(find.byType(MentionBar)).height, 0);
    });
  });
}

void _noop(MentionCandidate _) {}
