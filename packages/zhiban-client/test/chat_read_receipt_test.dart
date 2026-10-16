// F09 P1 已读回执 v1 客户端单测:
// 1) ChatReceiptSnapshot.fromJson 解析.
// 2) ChatReceiptsController cache + debounce flush (requestSeqs / invalidate / refreshNow).
// 3) ChatReadReceiptIndicator 显示规则 (snapshot=null → 预留态 / allRead → check-circle / partial → 数字).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_read_receipt.dart';
import 'package:zhiban_client/pages/chat/providers/chat_receipts_controller.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_read_receipt.dart';

class _FakeChatSvc implements OpenClawChatService {
  _FakeChatSvc(this._items);
  final List<Map<String, dynamic>> _items;
  int calls = 0;
  List<int> lastSeqs = const [];
  Object? throwOnNext;

  @override
  Future<List<Map<String, dynamic>>> getReadReceipts({
    required String conversationId,
    required List<int> messageSeqs,
  }) async {
    calls++;
    lastSeqs = List.unmodifiable(messageSeqs);
    if (throwOnNext != null) {
      final e = throwOnNext!;
      throwOnNext = null;
      throw e;
    }
    return _items;
  }

  @override
  Future<void> markConversationRead(String conversationId,
      {int lastReadMessageSeq = 0}) async {}

  // 其它 OpenClawChatService 方法在本测试不用; noSuchMethod 兜底.
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  setUp(() {
    ChatReceiptsController.debugClearMemoryCache();
  });

  group('ChatReceiptSnapshot.fromJson', () {
    test('正常字段', () {
      final s = ChatReceiptSnapshot.fromJson({
        'message_seq': 12,
        'read_count': 2,
        'unread_count': 3,
        'all_read': false,
        'read_members': [
          {'account_uuid': 'a', 'display_name': 'Alice', 'avatar': 'av'}
        ],
        'unread_members': [
          {'account_uuid': 'b', 'display_name': 'Bob'},
          {'account_uuid': 'c', 'display_name': 'Carol'},
          {'account_uuid': 'd', 'display_name': 'Dan'},
        ],
      });
      expect(s.messageSeq, 12);
      expect(s.readCount, 2);
      expect(s.unreadCount, 3);
      expect(s.allRead, isFalse);
      expect(s.readMembers, hasLength(1));
      expect(s.readMembers.first.displayName, 'Alice');
    });
  });

  group('ChatReceiptsController', () {
    test('requestSeqs debounce + cache hit 不重复请求', () async {
      final svc = _FakeChatSvc([
        {
          'message_seq': 10,
          'read_count': 1,
          'unread_count': 0,
          'all_read': true,
          'read_members': [
            {'account_uuid': 'r1', 'display_name': 'R'}
          ],
          'unread_members': const <Map<String, dynamic>>[],
        }
      ]);
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 30),
      );
      c.requestSeqs([10, 0, -1]); // 仅 10 有效
      c.requestSeqs([10]); // 重复 → 还在 pending, 等同一次
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(svc.calls, 1, reason: 'debounce 合并; 仅一次请求');
      expect(svc.lastSeqs, [10]);
      expect(c.snapshotFor(10)?.allRead, isTrue);

      // 第二次再请求同 seq → cache hit, 不发请求.
      c.requestSeqs([10]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(svc.calls, 1, reason: 'cache hit 不重复请求');
      c.dispose();
    });

    test('failure 不写假数据 (snapshotFor 保持 null)', () async {
      final svc = _FakeChatSvc(const [])..throwOnNext = Exception('boom');
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 30),
      );
      c.requestSeqs([5]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(svc.calls, 1);
      expect(c.snapshotFor(5), isNull);
      c.dispose();
    });

    test('invalidate 清缓存 + notifyListeners', () async {
      final svc = _FakeChatSvc([
        {
          'message_seq': 7,
          'read_count': 0,
          'unread_count': 1,
          'all_read': false,
          'read_members': const <Map<String, dynamic>>[],
          'unread_members': [
            {'account_uuid': 'u1', 'display_name': 'U'}
          ],
        }
      ]);
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 30),
      );
      c.requestSeqs([7]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.snapshotFor(7), isNotNull);
      var notified = false;
      c.addListener(() => notified = true);
      c.invalidate(7);
      expect(c.snapshotFor(7), isNull);
      expect(notified, isTrue);
      c.dispose();
    });

    test('recordSentSeqs 会首拉缺失 snapshot, 不等待 markRead 成功', () async {
      final svc = _FakeChatSvc([
        {
          'message_seq': 21,
          'read_count': 1,
          'unread_count': 0,
          'all_read': true,
          'read_members': [
            {'account_uuid': 'u1', 'display_name': 'U'}
          ],
          'unread_members': const <Map<String, dynamic>>[],
        }
      ]);
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 5),
      );

      c.recordSentSeqs([21]);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(svc.calls, 1);
      expect(svc.lastSeqs, [21]);
      expect(c.snapshotFor(21)?.allRead, isTrue);
      c.dispose();
    });

    test('同 conversation 重建 controller 复用内存快照, 切换回来不闪灰圈', () async {
      final svc = _FakeChatSvc([
        {
          'message_seq': 31,
          'read_count': 1,
          'unread_count': 0,
          'all_read': true,
          'read_members': [
            {'account_uuid': 'u1', 'display_name': 'U'}
          ],
          'unread_members': const <Map<String, dynamic>>[],
        }
      ]);
      final first = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-switch-cache',
        service: svc,
        debounce: const Duration(milliseconds: 5),
      );
      first.requestSeqs([31]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(first.snapshotFor(31)?.allRead, isTrue);
      first.dispose();

      final second = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-switch-cache',
        service: svc,
        debounce: const Duration(milliseconds: 5),
      );
      expect(second.snapshotFor(31)?.allRead, isTrue,
          reason: '切换会话重建 pane/controller 时应先用同会话旧快照, 不让绿勾闪回灰圈');
      second.dispose();
    });

    test('refreshReadThrough 只刷新已登记且不超过已读水位的 sent seq', () async {
      final svc = _FakeChatSvc([
        {
          'message_seq': 12,
          'read_count': 0,
          'unread_count': 1,
          'all_read': false,
          'read_members': const <Map<String, dynamic>>[],
          'unread_members': [
            {'account_uuid': 'u1', 'display_name': 'U'}
          ],
        }
      ]);
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 5),
      );

      c.requestSeqs([12]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(c.snapshotFor(12)?.allRead, isFalse);

      svc._items[0] = {
        'message_seq': 12,
        'read_count': 1,
        'unread_count': 0,
        'all_read': true,
        'read_members': [
          {'account_uuid': 'u1', 'display_name': 'U'}
        ],
        'unread_members': const <Map<String, dynamic>>[],
      };
      c.recordSentSeqs([12]);
      c.refreshReadThrough(11);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(svc.calls, 1, reason: '水位未覆盖 seq=12, 不刷新');

      c.refreshReadThrough(12);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(svc.calls, 2);
      expect(svc.lastSeqs, [12]);
      expect(c.snapshotFor(12)?.allRead, isTrue);
      c.dispose();
    });

    test('refreshNow 请求期间/失败时保留旧 snapshot, 避免已读闪回未读', () async {
      final svc = _FakeChatSvc([
        {
          'message_seq': 12,
          'read_count': 1,
          'unread_count': 0,
          'all_read': true,
          'read_members': [
            {'account_uuid': 'u1', 'display_name': 'U'}
          ],
          'unread_members': const <Map<String, dynamic>>[],
        }
      ]);
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 30),
      );

      c.requestSeqs([12]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.snapshotFor(12)?.allRead, isTrue);

      svc.throwOnNext = Exception('boom');
      c.refreshNow([12]);
      expect(c.snapshotFor(12)?.allRead, isTrue,
          reason: '刷新请求发出前不能清旧快照,否则 UI 会从绿勾闪回灰圈');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.snapshotFor(12)?.allRead, isTrue,
          reason: '刷新失败也保留旧真值,等待下一次 SSE/点击触发刷新成功后再替换');
      c.dispose();
    });
  });

  group('shouldShowSelfReceiptStatusSlot', () {
    test('普通自己 sent 消息显示状态位', () {
      const msg = ImMessage(
        messageId: 'm-1',
        clientMsgNo: 'c-1',
        fromUid: 'me',
        channelId: 'ch',
        channelType: 1,
        timestamp: 1,
        text: '在吗',
        messageSeq: 10,
      );

      expect(
        shouldShowSelfReceiptStatusSlot(msg: msg, isPeer: false),
        isTrue
      );
    });

    test('通话时长消息不显示已读/未读状态位', () {
      const msg = ImMessage(
        messageId: 'm-call',
        clientMsgNo: 'c-call',
        fromUid: 'me',
        channelId: 'ch',
        channelType: 1,
        timestamp: 1,
        text: '通话时长 01:53',
        messageSeq: 11,
      );

      expect(
        shouldShowSelfReceiptStatusSlot(msg: msg, isPeer: false),
        isFalse
      );
    });
  });

  group('ChatReadReceiptIndicator widget', () {
    Widget host(ChatReceiptsController c, int seq, {bool isGroup = false}) =>
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ChatReadReceiptIndicator(
                controller: c,
                messageSeq: seq,
                isGroup: isGroup,
              ),
            ),
          ),
        );

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(); // postFrameCallback requestSeqs
      await tester.pump(const Duration(milliseconds: 30)); // flush debounce
      await tester.pump(); // notifyListeners → rebuild
    }

    testWidgets('snapshot=null → 弱灰占位 (稳定宽度, 不再零宽隐藏, 不显示假已读)', (tester) async {
      // service 返空 → snapshot 一直 null (拉取中 / 后端无数据)。
      final svc = _FakeChatSvc(const []);
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 5),
      );
      await tester.pumpWidget(host(c, 1));
      await settle(tester);
      expect(c.snapshotFor(1), isNull);
      // 弱灰占位 dot 出现, 无 check 图标 / 无数字。
      expect(find.byType(ChatReceiptStatusDot), findsOneWidget);
      expect(find.byType(ChatReceiptReadCheck), findsNothing);
      expect(find.text('1'), findsNothing);
      final box = tester.getSize(find.byType(ChatReadReceiptIndicator));
      expect(box.width, 14, reason: 'snapshot=null 时仍保留 14px 状态位, 不消失');
      expect(box.height, 14);
      c.dispose();
    });

    testWidgets('snapshot=null 占位不可点 → 不触发 refreshNow / 不弹假弹层', (tester) async {
      final svc = _FakeChatSvc(const []);
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 5),
      );
      await tester.pumpWidget(host(c, 1));
      await settle(tester);
      expect(svc.calls, 1, reason: '仅首帧自动请求一次');
      // 点占位 → 无 GestureDetector, 不触发 refreshNow, calls 不增。
      await tester.tap(find.byType(ChatReadReceiptIndicator));
      await tester.pump(const Duration(milliseconds: 30));
      expect(svc.calls, 1, reason: '占位态不可点, 不应再请求 / 不弹层');
      c.dispose();
    });

    testWidgets('请求失败时 snapshot 仍 null → 弱灰占位 (不刷屏, 不假已读)', (tester) async {
      final svc = _FakeChatSvc(const [])..throwOnNext = Exception('boom');
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 5),
      );
      await tester.pumpWidget(host(c, 1));
      await settle(tester);
      expect(c.snapshotFor(1), isNull);
      expect(find.byType(ChatReceiptStatusDot), findsOneWidget);
      final box = tester.getSize(find.byType(ChatReadReceiptIndicator));
      expect(box.width, 14);
      c.dispose();
    });

    testWidgets('allRead=true → 青绿 check-circle (单聊)', (tester) async {
      final svc = _FakeChatSvc([
        {
          'message_seq': 5,
          'read_count': 1,
          'unread_count': 0,
          'all_read': true,
          'read_members': const <Map<String, dynamic>>[],
          'unread_members': const <Map<String, dynamic>>[],
        }
      ]);
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 5),
      );
      await tester.pumpWidget(host(c, 5));
      await settle(tester);
      expect(c.snapshotFor(5)?.allRead, isTrue);
      expect(find.byType(ChatReceiptReadCheck), findsOneWidget);
      expect(find.byType(ChatReceiptStatusDot), findsNothing);
      c.dispose();
    });

    testWidgets('单聊未读 (snapshot present, !allRead) → 弱灰空心圆, 不显示数字 0',
        (tester) async {
      final svc = _FakeChatSvc([
        {
          'message_seq': 5,
          'read_count': 0,
          'unread_count': 1,
          'all_read': false,
          'read_members': const <Map<String, dynamic>>[],
          'unread_members': [
            {'account_uuid': 'u1', 'display_name': 'Alice'}
          ],
        }
      ]);
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 5),
      );
      await tester.pumpWidget(host(c, 5, isGroup: false));
      await settle(tester);
      expect(find.byType(ChatReceiptStatusDot), findsOneWidget);
      expect(find.text('0'), findsNothing, reason: '单聊不显示数字 0');
      expect(find.byType(ChatReceiptReadCheck), findsNothing);
      c.dispose();
    });

    testWidgets('群聊 read_count>0 → 圆形数字 badge', (tester) async {
      final svc = _FakeChatSvc([
        {
          'message_seq': 5,
          'read_count': 17,
          'unread_count': 3,
          'all_read': false,
          'read_members': const <Map<String, dynamic>>[],
          'unread_members': const <Map<String, dynamic>>[],
        }
      ]);
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 5),
      );
      await tester.pumpWidget(host(c, 5, isGroup: true));
      await settle(tester);
      expect(find.text('17'), findsOneWidget);
      expect(find.byType(ChatReceiptStatusDot), findsNothing);
      expect(find.byType(ChatReceiptReadCheck), findsNothing);
      c.dispose();
    });

    testWidgets('群聊 read_count==0 且有未读 → 弱灰空心圆 (不显示 0, 不消失)', (tester) async {
      final svc = _FakeChatSvc([
        {
          'message_seq': 5,
          'read_count': 0,
          'unread_count': 2,
          'all_read': false,
          'read_members': const <Map<String, dynamic>>[],
          'unread_members': const <Map<String, dynamic>>[],
        }
      ]);
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 5),
      );
      await tester.pumpWidget(host(c, 5, isGroup: true));
      await settle(tester);
      expect(find.byType(ChatReceiptStatusDot), findsOneWidget);
      expect(find.text('0'), findsNothing);
      c.dispose();
    });

    testWidgets('点击有真实 snapshot 的状态位 → 触发 controller.refreshNow → 二次请求',
        (tester) async {
      final svc = _FakeChatSvc([
        {
          'message_seq': 5,
          'read_count': 0,
          'unread_count': 2,
          'all_read': false,
          'read_members': const <Map<String, dynamic>>[],
          'unread_members': [
            {'account_uuid': 'u1', 'display_name': 'Alice'},
            {'account_uuid': 'u2', 'display_name': 'Bob'},
          ],
        }
      ]);
      final c = ChatReceiptsController(
        cacheScope: 'test-account',
        conversationUuid: 'conv-1',
        service: svc,
        debounce: const Duration(milliseconds: 5),
      );
      await tester.pumpWidget(host(c, 5, isGroup: true));
      await settle(tester);
      expect(svc.calls, 1, reason: '首次自动 requestSeqs 拉一次');
      expect(c.snapshotFor(5)?.readCount, 0);

      // 有 snapshot 的空心圆可点 → refreshNow → 再次请求.
      await tester.tap(find.byType(ChatReadReceiptIndicator));
      await tester.pump(const Duration(milliseconds: 30));
      expect(svc.calls, greaterThanOrEqualTo(2),
          reason: '点击有 snapshot 的状态位应触发 refreshNow → 新请求');
    });
  });
}
