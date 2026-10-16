import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_im_history.dart';

// 聊天历史抽屉(P2)纯过滤 / 摘要逻辑。

ImMessage _m(
  String id,
  int seq, {
  String text = '',
  ImMediaKind mediaKind = ImMediaKind.none,
  String mediaName = '',
  String mediaMime = '',
  String fromUid = 'me',
  int? timestamp,
  List<ImMessageBlock> blocks = const <ImMessageBlock>[],
}) =>
    ImMessage(
      messageId: id,
      clientMsgNo: '',
      fromUid: fromUid,
      channelId: 'c',
      channelType: 2,
      timestamp: timestamp ?? 1700000000 + seq,
      text: text,
      messageSeq: seq,
      mediaKind: mediaKind,
      mediaName: mediaName,
      mediaMime: mediaMime,
      blocks: blocks,
    );

void main() {
  // 输入按 messageSeq 升序(controller 口径):旧→新。
  final msgs = <ImMessage>[
    _m('m1', 1, text: 'Hello World'),
    _m('m2', 2, mediaKind: ImMediaKind.image, mediaName: 'photo.png'),
    _m('m3', 3, mediaKind: ImMediaKind.file, mediaName: 'Report.PDF'),
    _m('m4', 4, text: 'goodbye'),
  ];

  group('filterHistoryMessages', () {
    test('全部 tab + 空搜索 → 全量,正序(旧到新)', () {
      final r = filterHistoryMessages(msgs, ImHistoryTab.all, '');
      expect(r.map((m) => m.messageId).toList(), ['m1', 'm2', 'm3', 'm4']);
    });

    test('文件 tab → 仅 file', () {
      final r = filterHistoryMessages(msgs, ImHistoryTab.file, '');
      expect(r.map((m) => m.messageId).toList(), ['m3']);
    });

    test('图片与视频 tab → image + 视频 (P2 2026-06: 视频已纳入 media tab)', () {
      // 加一条视频 file 消息, media tab 应同时返回 image + 视频。
      final withVideo = [
        ...msgs,
        _m('mv', 5, mediaKind: ImMediaKind.file, mediaName: 'clip.mp4'),
      ];
      final r = filterHistoryMessages(withVideo, ImHistoryTab.media, '');
      // 正序: 图片 m2 在前, 视频 mv 最新在后; 报告 PDF / 文本不在 media tab。
      expect(r.map((m) => m.messageId).toList(), ['m2', 'mv']);
    });

    test('文件 tab 仍包含视频 (视频底层 wire 仍是 file)', () {
      final withVideo = [
        ...msgs,
        _m('mv', 5, mediaKind: ImMediaKind.file, mediaName: 'clip.mp4'),
      ];
      final r = filterHistoryMessages(withVideo, ImHistoryTab.file, '');
      expect(r.map((m) => m.messageId).toSet(), {'m3', 'mv'});
    });

    test('搜索 text(大小写不敏感、包含)', () {
      final r = filterHistoryMessages(msgs, ImHistoryTab.all, 'hello');
      expect(r.map((m) => m.messageId).toList(), ['m1']);
    });

    test('搜索 mediaName(大小写不敏感)', () {
      final r = filterHistoryMessages(msgs, ImHistoryTab.file, 'report');
      expect(r.map((m) => m.messageId).toList(), ['m3']);
    });

    test('搜索空白 = 当前 tab 全量', () {
      final r = filterHistoryMessages(msgs, ImHistoryTab.all, '   ');
      expect(r.length, 4);
    });

    test('无匹配 → 空', () {
      final r = filterHistoryMessages(msgs, ImHistoryTab.all, 'zzz-none');
      expect(r, isEmpty);
    });

    test('发送人筛选与关键词按 AND 组合', () {
      final source = [
        _m('peer-hit', 1, text: '季度报告', fromUid: 'peer'),
        _m('me-hit', 2, text: '季度报告', fromUid: 'me'),
        _m('peer-miss', 3, text: '周报', fromUid: 'peer'),
      ];
      final r = filterHistoryMessages(
        source,
        ImHistoryTab.all,
        '季度',
        senderUid: 'peer',
      );
      expect(r.map((m) => m.messageId), ['peer-hit']);
    });

    test('文件类型筛选兼容顶层 file 与 mixed file block', () {
      final source = [
        _m(
          'pdf',
          1,
          mediaKind: ImMediaKind.file,
          mediaName: '合同.PDF'
        ),
        _m(
          'video',
          2,
          mediaKind: ImMediaKind.file,
          mediaName: '演示文件',
          mediaMime: 'video/mp4',
        ),
        _m(
          'mixed-excel',
          3,
          blocks: const [
            ImMessageBlock(
              kind: ImMessageBlockKind.file,
              name: '预算表',
              mime:
                  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            ),
          ],
        ),
        _m(
          'other',
          4,
          mediaKind: ImMediaKind.file,
          mediaName: '说明.txt'
        ),
      ];

      expect(
        filterHistoryMessages(
          source,
          ImHistoryTab.file,
          '',
          fileType: ImHistoryFileType.pdf,
        ).map((m) => m.messageId),
        ['pdf'],
      );
      expect(
        filterHistoryMessages(
          source,
          ImHistoryTab.file,
          '',
          fileType: ImHistoryFileType.video,
        ).map((m) => m.messageId),
        ['video'],
      );
      expect(
        filterHistoryMessages(
          source,
          ImHistoryTab.file,
          '',
          fileType: ImHistoryFileType.excel,
        ).map((m) => m.messageId),
        ['mixed-excel'],
      );
      expect(
        filterHistoryMessages(
          source,
          ImHistoryTab.file,
          '',
          fileType: ImHistoryFileType.other,
        ).map((m) => m.messageId),
        ['other'],
      );
    });

    test('日期筛选按本地自然日计算且边界互斥', () {
      final now = DateTime(2026, 6, 4, 20);
      final source = [
        _m(
          'today',
          1,
          timestamp: DateTime(2026, 6, 4, 0).millisecondsSinceEpoch,
        ),
        _m(
          'yesterday',
          2,
          timestamp: DateTime(2026, 6, 3, 23, 59).millisecondsSinceEpoch,
        ),
        _m(
          'seven-days-start',
          3,
          timestamp: DateTime(2026, 5, 29, 0).millisecondsSinceEpoch,
        ),
        _m(
          'older',
          4,
          timestamp: DateTime(2026, 5, 28, 23, 59).millisecondsSinceEpoch,
        ),
      ];

      expect(
        filterHistoryMessages(
          source,
          ImHistoryTab.all,
          '',
          dateFilter: ImHistoryDateFilter.today,
          now: now,
        ).map((m) => m.messageId),
        ['today'],
      );
      expect(
        filterHistoryMessages(
          source,
          ImHistoryTab.all,
          '',
          dateFilter: ImHistoryDateFilter.yesterday,
          now: now,
        ).map((m) => m.messageId),
        ['yesterday'],
      );
      expect(
        filterHistoryMessages(
          source,
          ImHistoryTab.all,
          '',
          dateFilter: ImHistoryDateFilter.last7Days,
          now: now,
        ).map((m) => m.messageId),
        ['today', 'yesterday', 'seven-days-start'],
      );
    });

    test('mixed 消息参与文件/图片 tab 与搜索', () {
      final mixed = _m(
        'mixed',
        9,
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.text, text: '学习计划说明'),
          ImMessageBlock(
            kind: ImMessageBlockKind.file,
            name: '30天英语学习计划.xlsx'
          ),
          ImMessageBlock(
            kind: ImMessageBlockKind.image,
            name: '截图.png'
          ),
        ],
      );
      expect(
        filterHistoryMessages([mixed], ImHistoryTab.file, '')
            .map((m) => m.messageId),
        ['mixed'],
      );
      expect(
        filterHistoryMessages([mixed], ImHistoryTab.media, '')
            .map((m) => m.messageId),
        ['mixed'],
      );
      expect(
        filterHistoryMessages([mixed], ImHistoryTab.file, '英语')
            .map((m) => m.messageId),
        ['mixed'],
      );
      expect(
        filterHistoryMessages([mixed], ImHistoryTab.all, '截图')
            .map((m) => m.messageId),
        ['mixed'],
      );
    });
  });

  group('historyMessageSummary mixed', () {
    test('按 block 顺序生成可读摘要', () {
      final m = _m(
        'mixed',
        9,
        blocks: const [
          ImMessageBlock(kind: ImMessageBlockKind.text, text: '先说一句'),
          ImMessageBlock(kind: ImMessageBlockKind.image, name: 'a.png'),
          ImMessageBlock(kind: ImMessageBlockKind.file, name: '计划表.xlsx'),
          ImMessageBlock(kind: ImMessageBlockKind.text, text: '再补一句'),
        ],
      );
      expect(historyMessageSummary(m), '先说一句 [图片] 计划表.xlsx 再补一句');
    });
  });

  group('imMessageIdentity (定位匹配键)', () {
    test('优先 clientMsgNo', () {
      final m = ImMessage(
        messageId: 'srv-9',
        clientMsgNo: 'cmn-1',
        fromUid: 'me',
        channelId: 'c',
        channelType: 2,
        timestamp: 1,
        text: 'x',
      );
      expect(imMessageIdentity(m), 'cmn:cmn-1');
    });
    test('无 clientMsgNo → 服务端 messageId', () {
      final m = ImMessage(
        messageId: 'srv-9',
        clientMsgNo: '',
        fromUid: 'me',
        channelId: 'c',
        channelType: 2,
        timestamp: 1,
        text: 'x',
      );
      expect(imMessageIdentity(m), 'srv:srv-9');
    });
    test('本地预留态(local-/0)→ loc:messageId', () {
      final local = ImMessage(
        messageId: 'local-abc',
        clientMsgNo: '',
        fromUid: 'me',
        channelId: 'c',
        channelType: 2,
        timestamp: 1,
        text: 'x',
      );
      expect(imMessageIdentity(local), 'loc:local-abc');
      final zero = ImMessage(
        messageId: '0',
        clientMsgNo: '',
        fromUid: 'me',
        channelId: 'c',
        channelType: 2,
        timestamp: 1,
        text: 'x',
      );
      expect(imMessageIdentity(zero), 'loc:0');
    });
  });

  group('findImMessageIndex', () {
    final list = <ImMessage>[
      _m('srv-1', 1, text: 'a', fromUid: 'peer'),
      ImMessage(
        messageId: '',
        clientMsgNo: 'cmn-2',
        fromUid: 'me',
        channelId: 'c',
        channelType: 2,
        timestamp: 2,
        text: 'b',
      ),
      _m('local-3', 3, text: 'c'),
    ];
    test('命中 clientMsgNo', () {
      final target = ImMessage(
        messageId: '',
        clientMsgNo: 'cmn-2',
        fromUid: 'me',
        channelId: 'c',
        channelType: 2,
        timestamp: 2,
        text: 'b',
      );
      expect(findImMessageIndex(list, target), 1);
    });
    test('命中服务端 messageId', () {
      expect(findImMessageIndex(list, _m('srv-1', 1, fromUid: 'peer')), 0);
    });
    test('命中本地 messageId', () {
      expect(findImMessageIndex(list, _m('local-3', 3)), 2);
    });
    test('未命中 → -1', () {
      expect(findImMessageIndex(list, _m('nope', 9)), -1);
    });
  });

  group('estimateHistoryScrollOffset (离屏近似滚动)', () {
    test('index 0 → 0', () {
      expect(
          estimateHistoryScrollOffset(
              index: 0, itemCount: 11, maxScrollExtent: 1000),
          0);
    });
    test('中间 index → 比例 offset', () {
      expect(
          estimateHistoryScrollOffset(
              index: 5, itemCount: 11, maxScrollExtent: 1000),
          500);
    });
    test('末尾 index → maxScrollExtent', () {
      expect(
          estimateHistoryScrollOffset(
              index: 10, itemCount: 11, maxScrollExtent: 1000),
          1000);
    });
    test('itemCount<=1 或 max<=0 → 0', () {
      expect(
          estimateHistoryScrollOffset(
              index: 0, itemCount: 1, maxScrollExtent: 1000),
          0);
      expect(
          estimateHistoryScrollOffset(
              index: 3, itemCount: 11, maxScrollExtent: 0),
          0);
    });
    test('任意 index 的 offset 都落在 [0, max]', () {
      for (var i = 0; i < 20; i++) {
        final off = estimateHistoryScrollOffset(
            index: i, itemCount: 20, maxScrollExtent: 800);
        expect(off, greaterThanOrEqualTo(0));
        expect(off, lessThanOrEqualTo(800));
      }
    });
  });

  group('runLocateAttempt (离屏 retry 策略)', () {
    test('context 在屏 → onVisible,不滚动,返回 true', () {
      var visible = 0, scroll = 0;
      final r = runLocateAttempt(
        attempt: 0,
        probeContext: () => true,
        onVisible: () => visible++,
        onApproxScroll: () => scroll++,
      );
      expect(r, isTrue);
      expect(visible, 1);
      expect(scroll, 0);
    });
    test('离屏且未达上限 → 近似滚动,返回 false', () {
      var visible = 0, scroll = 0;
      final r = runLocateAttempt(
        attempt: 0,
        probeContext: () => false,
        onVisible: () => visible++,
        onApproxScroll: () => scroll++,
      );
      expect(r, isFalse);
      expect(visible, 0);
      expect(scroll, 1);
    });
    test('达到上限 → 不再滚动,返回 false(用尽)', () {
      var visible = 0, scroll = 0;
      final r = runLocateAttempt(
        attempt: kLocateMaxAttempts,
        probeContext: () => false,
        onVisible: () => visible++,
        onApproxScroll: () => scroll++,
      );
      expect(r, isFalse);
      expect(visible, 0);
      expect(scroll, 0);
    });
    test('先离屏触发滚动,再上屏 → 第二次命中 onVisible(模拟 build 后)', () {
      var visible = 0, scroll = 0;
      var hasContext = false; // 初始离屏
      bool attempt(int n) => runLocateAttempt(
            attempt: n,
            probeContext: () => hasContext,
            onVisible: () => visible++,
            onApproxScroll: () {
              scroll++;
              hasContext = true; // 近似滚动后目标 build 出来
            },
          );
      expect(attempt(0), isFalse); // 离屏 → 滚动
      expect(scroll, 1);
      expect(visible, 0);
      expect(attempt(1), isTrue); // build 后 → 命中
      expect(visible, 1);
      expect(scroll, 1);
    });
  });

  group('expandingProbeOffset (± 扩张搜索)', () {
    test('attempt 0 → 中心 estimated', () {
      expect(
          expandingProbeOffset(
              estimated: 500, attempt: 0, viewport: 400, maxScrollExtent: 1000),
          500);
    });
    test('attempt 1/2 → ±½视口', () {
      expect(
          expandingProbeOffset(
              estimated: 500, attempt: 1, viewport: 400, maxScrollExtent: 1000),
          700);
      expect(
          expandingProbeOffset(
              estimated: 500, attempt: 2, viewport: 400, maxScrollExtent: 1000),
          300);
    });
    test('attempt 3/4 → ±1视口', () {
      expect(
          expandingProbeOffset(
              estimated: 500, attempt: 3, viewport: 400, maxScrollExtent: 1000),
          900);
      expect(
          expandingProbeOffset(
              estimated: 500, attempt: 4, viewport: 400, maxScrollExtent: 1000),
          100);
    });
    test('clamp 到 [0, max]', () {
      expect(
          expandingProbeOffset(
              estimated: 950, attempt: 1, viewport: 400, maxScrollExtent: 1000),
          1000);
      expect(
          expandingProbeOffset(
              estimated: 50, attempt: 2, viewport: 400, maxScrollExtent: 1000),
          0);
    });
    test('相邻 attempt 偏移互不相同(不重复跳同一点,修复 Codex P2)', () {
      final seen = <double>{};
      for (var i = 0; i < 5; i++) {
        seen.add(expandingProbeOffset(
            estimated: 500, attempt: i, viewport: 400, maxScrollExtent: 1000));
      }
      expect(seen.length, 5);
    });
    test('可变高度:估算偏差大 → 扩张到目标邻域后命中(模拟离屏 retry)', () {
      // 目标真实在 ~860,但比例估算只给 500(消息高度可变导致偏差)。
      // 扩张搜索到 +1视口(offset 900)落入目标邻域 → context build 出 → 命中。
      const target = 860.0;
      var visible = 0;
      var scroll = 0;
      var lastOffset = -1.0; // 尚未滚动
      bool attempt(int n) => runLocateAttempt(
            attempt: n,
            // 仅当上一次滚动落点在目标 ±80(视口缓冲)内,item 才 build 出 context。
            probeContext: () => (lastOffset - target).abs() <= 80,
            onVisible: () => visible++,
            onApproxScroll: () {
              scroll++;
              lastOffset = expandingProbeOffset(
                  estimated: 500,
                  attempt: n,
                  viewport: 400,
                  maxScrollExtent: 1000);
            },
          );
      var hit = false;
      for (var n = 0; n <= kLocateMaxAttempts && !hit; n++) {
        hit = attempt(n);
      }
      expect(hit, isTrue); // 扩张搜索最终命中(而非一直跳同一估算点)
      expect(visible, 1);
      expect(scroll, greaterThan(1)); // 第一次估算未命中,确实做了多次不同偏移的滚动
    });
  });

  group('historyMessageSummary', () {
    test('文本 → 原文', () {
      expect(historyMessageSummary(_m('a', 1, text: '你好')), '你好');
    });
    test('图片有名 → 名;无名 → [图片]', () {
      expect(
          historyMessageSummary(
              _m('a', 1, mediaKind: ImMediaKind.image, mediaName: 'p.png')),
          'p.png');
      expect(historyMessageSummary(_m('a', 1, mediaKind: ImMediaKind.image)),
          '[图片]');
    });
    test('文件 → 文件名', () {
      expect(
          historyMessageSummary(
              _m('a', 1, mediaKind: ImMediaKind.file, mediaName: 'r.pdf')),
          'r.pdf');
    });
  });

  group('historyMessageSummary call_event (FE-05)', () {
    test('call_event block → 卡片文案', () {
      final m = _m('a', 1, blocks: const [
        ImMessageBlock(
            kind: ImMessageBlockKind.callEvent,
            text: '未接听',
            callEndReason: 'timeout'),
      ]);
      expect(historyMessageSummary(m), '未接听');
    });

    test('call_event 空 text → 兜底「语音通话」(不显示 [非文本消息])', () {
      final m = _m('a', 1, blocks: const [
        ImMessageBlock(kind: ImMessageBlockKind.callEvent)],
      );
      final s = historyMessageSummary(m);
      expect(s, '语音通话');
      expect(s, isNot('[非文本消息]'));
    });

    test('普通 text/image/file 摘要不回退', () {
      expect(historyMessageSummary(_m('a', 1, text: 'hi')), 'hi');
      expect(
          historyMessageSummary(_m('a', 1, blocks: const [
            ImMessageBlock(kind: ImMessageBlockKind.image, url: 'u'),
          ])),
          '[图片]');
    });
  });
}
