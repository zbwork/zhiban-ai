import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_reply_reference.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_reply_locate.dart';

// F09 引用回复 v1 (2026-06 best-effort 跨页定位增量):
// 见 docs/contracts/agent-bus-client-contract.md §「消息操作菜单 v2」.

ImMessage _m({
  required int seq,
  String? cmn,
  String? mid,
  String text = ''
}) =>
    ImMessage(
      messageId: mid ?? 'sid-$seq',
      clientMsgNo: cmn ?? 'cmn-$seq',
      fromUid: 'u',
      channelId: 'c',
      channelType: 2,
      timestamp: 1700000000 + seq,
      text: text,
      messageSeq: seq,
    );

ChatReplyReference _ref({
  String mid = '',
  String cmn = '',
  int seq = 0
}) =>
    ChatReplyReference(
      messageId: mid,
      clientMsgNo: cmn,
      messageSeq: seq,
      senderUid: '',
      senderName: '',
      summary: '',
    );

void main() {
  group('findMessageIndexByReplyRef', () {
    test('按 clientMsgNo 命中 (优先级最高)', () {
      final msgs = [_m(seq: 1), _m(seq: 2, cmn: 'wanted'), _m(seq: 3)];
      expect(
        findMessageIndexByReplyRef(msgs, _ref(cmn: 'wanted', seq: 99)),
        1
      );
    });

    test('clientMsgNo 不命中 → 回退 messageId', () {
      final msgs = [_m(seq: 1), _m(seq: 2, mid: 'srv-2'), _m(seq: 3)];
      expect(
        findMessageIndexByReplyRef(msgs, _ref(mid: 'srv-2')),
        1
      );
    });

    test('clientMsgNo / messageId 都不命中 → 回退 messageSeq', () {
      final msgs = [_m(seq: 10), _m(seq: 20), _m(seq: 30)];
      expect(
        findMessageIndexByReplyRef(msgs, _ref(seq: 20)),
        1
      );
    });

    test('全不命中 → -1', () {
      final msgs = [_m(seq: 1), _m(seq: 2)];
      expect(
        findMessageIndexByReplyRef(msgs, _ref(seq: 99)),
        -1
      );
    });
  });

  group('shouldLoadOlderForReplyRef', () {
    test('ref 在更早页且 hasMore → true', () {
      expect(
        shouldLoadOlderForReplyRef(
          earliestMessageSeq: 50,
          hasMoreHistory: true,
          refMessageSeq: 30,
        ),
        isTrue,
      );
    });

    test('ref 不在更早页 (ref >= earliest) → false (应该是没找到但不该向更早翻)', () {
      expect(
        shouldLoadOlderForReplyRef(
          earliestMessageSeq: 50,
          hasMoreHistory: true,
          refMessageSeq: 50,
        ),
        isFalse,
      );
      expect(
        shouldLoadOlderForReplyRef(
          earliestMessageSeq: 50,
          hasMoreHistory: true,
          refMessageSeq: 80,
        ),
        isFalse,
      );
    });

    test('hasMore=false → false (无更早页可拉)', () {
      expect(
        shouldLoadOlderForReplyRef(
          earliestMessageSeq: 50,
          hasMoreHistory: false,
          refMessageSeq: 10,
        ),
        isFalse,
      );
    });

    test('ref.messageSeq <= 0 → false (无锚点判断)', () {
      expect(
        shouldLoadOlderForReplyRef(
          earliestMessageSeq: 50,
          hasMoreHistory: true,
          refMessageSeq: 0,
        ),
        isFalse,
      );
    });

    test('earliestMessageSeq=0 (窗口里没有 ack 消息) → false', () {
      expect(
        shouldLoadOlderForReplyRef(
          earliestMessageSeq: 0,
          hasMoreHistory: true,
          refMessageSeq: 10,
        ),
        isFalse,
      );
    });
  });

  group('loadOlderUntilFoundForReplyRef', () {
    test('当前窗口已有 ref → 不拉历史, 直接返回下标', () async {
      var loadCalls = 0;
      // earliest=10, ref.seq=20 (已在窗口); shouldLoad=false 因为 ref>=earliest;
      // findIndex 立即命中。
      final ctl = ReplyLocateController(
        earliestMessageSeq: () => 10,
        hasMoreHistory: () => true,
        loadMoreHistory: () async => loadCalls++,
      );
      final ref = _ref(cmn: 'x', seq: 20);
      var hits = 0;
      final found = await loadOlderUntilFoundForReplyRef(
        controller: ctl,
        ref: ref,
        findIndex: () {
          hits++;
          return 3; // 第 0 次就命中
        },
      );
      expect(found, 3);
      expect(loadCalls, 0);
      expect(hits, greaterThanOrEqualTo(1));
    });

    test('ref 在更早页 → 拉一页后命中, 不再继续拉', () async {
      var loadCalls = 0;
      int earliest = 50;
      bool hasMore = true;
      // 第一次拉 → 把 earliest 推到 5; 然后 findIndex 命中。
      final ctl = ReplyLocateController(
        earliestMessageSeq: () => earliest,
        hasMoreHistory: () => hasMore,
        loadMoreHistory: () async {
          loadCalls++;
          earliest = 5;
        },
      );
      final ref = _ref(seq: 10);
      final found = await loadOlderUntilFoundForReplyRef(
        controller: ctl,
        ref: ref,
        findIndex: () => loadCalls >= 1 ? 0 : -1,
      );
      expect(found, 0);
      expect(loadCalls, 1);
    });

    test('拉满 5 页都没找到 → 返回 -1, 不再继续拉', () async {
      var loadCalls = 0;
      int earliest = 100;
      bool hasMore = true;
      final ctl = ReplyLocateController(
        earliestMessageSeq: () => earliest,
        hasMoreHistory: () => hasMore,
        loadMoreHistory: () async {
          loadCalls++;
          earliest -= 10; // 每页前进 10, 仍然 > ref.seq=1
        },
      );
      final ref = _ref(seq: 1);
      final found = await loadOlderUntilFoundForReplyRef(
        controller: ctl,
        ref: ref,
        findIndex: () => -1,
      );
      expect(found, -1);
      expect(loadCalls, kReplyLocateMaxPages); // 5 页
    });

    test('hasMoreHistory=false → 不拉, -1', () async {
      var loadCalls = 0;
      final ctl = ReplyLocateController(
        earliestMessageSeq: () => 50,
        hasMoreHistory: () => false,
        loadMoreHistory: () async => loadCalls++,
      );
      final ref = _ref(seq: 1);
      final found = await loadOlderUntilFoundForReplyRef(
        controller: ctl,
        ref: ref,
        findIndex: () => -1,
      );
      expect(found, -1);
      expect(loadCalls, 0);
    });

    test('ref.messageSeq=0 → 不拉, -1 (无锚点可判)', () async {
      var loadCalls = 0;
      final ctl = ReplyLocateController(
        earliestMessageSeq: () => 50,
        hasMoreHistory: () => true,
        loadMoreHistory: () async => loadCalls++,
      );
      final ref = _ref(seq: 0);
      final found = await loadOlderUntilFoundForReplyRef(
        controller: ctl,
        ref: ref,
        findIndex: () => -1,
      );
      expect(found, -1);
      expect(loadCalls, 0);
    });

    test('loadMoreHistory 网络故障没推进 earliest → 立刻退出避免死循环', () async {
      var loadCalls = 0;
      final ctl = ReplyLocateController(
        earliestMessageSeq: () => 50, // 不前进
        hasMoreHistory: () => true,
        loadMoreHistory: () async => loadCalls++,
      );
      final ref = _ref(seq: 10);
      final found = await loadOlderUntilFoundForReplyRef(
        controller: ctl,
        ref: ref,
        findIndex: () => -1,
      );
      expect(found, -1);
      expect(loadCalls, 1); // 试了一次发现没进展立刻退出
    });
  });
}
