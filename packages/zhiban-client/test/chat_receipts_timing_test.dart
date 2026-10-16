import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/providers/chat_receipts_controller.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_read_receipt.dart';

class DeferredReceipts extends OpenClawChatService {
  final reads = <int>[];
  final queries = <List<int>>[];
  final responses = <Completer<List<Map<String, dynamic>>>>[];
  Completer<void>? holdRead;
  int failReadCount = 0;
  @override
  Future<void> markConversationRead(String conversationId,
      {int lastReadMessageSeq = 0}) async {
    reads.add(lastReadMessageSeq);
    if (failReadCount-- > 0) throw StateError('offline');
    await holdRead?.future;
  }

  @override
  Future<List<Map<String, dynamic>>> getReadReceipts(
      {required String conversationId, required List<int> messageSeqs}) {
    queries.add(messageSeqs);
    final response = Completer<List<Map<String, dynamic>>>();
    responses.add(response);
    return response.future;
  }
}

Map<String, dynamic> receipt(int seq, {bool read = true}) => {
      'message_seq': seq,
      'read_count': read ? 1 : 0,
      'unread_count': read ? 0 : 1,
      'all_read': read
    };

void main() {
  setUp(ChatReceiptsController.debugClearMemoryCache);
  testWidgets('initial receipt query does not block opened read watermark',
      (tester) async {
    final svc = DeferredReceipts()..holdRead = Completer<void>();
    final c = ChatReceiptsController(
        conversationUuid: 'c', service: svc, cacheScope: 'a');
    var ready = false;
    final prepare =
        c.prepareInitial([1], readThrough: 5).then((_) => ready = true);
    await tester.pump();
    expect(svc.reads, [5]);
    expect(ready, false);
    c.prepareInitial([1, 2], readThrough: 8);
    expect(svc.reads, [5]);
    svc.holdRead!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 201));
    expect(svc.reads, [5, 8]);
    expect(ready, false);
    svc.responses.first.complete([receipt(1)]);
    await tester.pump();
    svc.responses.last.complete([receipt(2)]);
    await tester.pump();
    await prepare;
    expect(ready, true);
    c.dispose();
  });

  testWidgets('mixed cache entry revalidates cached and missing receipts',
      (tester) async {
    final svc = DeferredReceipts();
    final first = ChatReceiptsController(
        conversationUuid: 'c', service: svc, cacheScope: 'a');
    final initial = first.prepareInitial([1]);
    await tester.pump();
    svc.responses.first.complete([receipt(1, read: false)]);
    await tester.pump();
    await initial;
    first.dispose();
    final reopened = ChatReceiptsController(
        conversationUuid: 'c', service: svc, cacheScope: 'a');
    final ready = reopened.prepareInitial([1, 2]);
    await tester.pump();
    expect(svc.queries.last, [1, 2]);
    expect(reopened.snapshotFor(1)!.allRead, false);
    svc.responses.last.complete([receipt(1), receipt(2)]);
    await tester.pump();
    await ready;
    expect(reopened.snapshotFor(1)!.allRead, true);
    expect(reopened.snapshotFor(2)!.allRead, true);
    reopened.dispose();
  });

  testWidgets('disposed initial preparation cannot report or fetch',
      (tester) async {
    final svc = DeferredReceipts();
    final c = ChatReceiptsController(
        conversationUuid: 'c', service: svc, cacheScope: 'a');
    final ready = c.prepareInitial([1], readThrough: 5);
    c.dispose();
    await tester.pump();
    await ready;
    await c.prepareInitial([2], readThrough: 6);
    expect(svc.reads, isEmpty);
    expect(svc.queries, isEmpty);
  });

  testWidgets(
      'first read is immediate, burst advances without debounce starvation',
      (tester) async {
    final svc = DeferredReceipts()..holdRead = Completer<void>();
    final c = ChatReceiptsController(
        conversationUuid: 'c', service: svc, cacheScope: 'a');
    c.reportReadWatermark(1);
    expect(svc.reads, [1]);
    for (var seq = 2; seq <= 20; seq++) {
      c.reportReadWatermark(seq);
    }
    expect(svc.reads, [1]);
    svc.holdRead!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 201));
    expect(svc.reads, [1, 20]);
    c.dispose();
  });
  testWidgets(
      'failed read retries without a new message and dispose cancels retry',
      (tester) async {
    final svc = DeferredReceipts()..failReadCount = 1;
    final c = ChatReceiptsController(
        conversationUuid: 'c', service: svc, cacheScope: 'a');
    c.reportReadWatermark(5);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(svc.reads, [5, 5]);
    svc.failReadCount = 1;
    c.reportReadWatermark(6);
    await tester.pump();
    c.dispose();
    await tester.pump(const Duration(seconds: 2));
    expect(svc.reads, [5, 5, 6]);
  });
  testWidgets(
      'initial gate displays message and real receipt on the same frame',
      (tester) async {
    final svc = DeferredReceipts();
    final c = ChatReceiptsController(
        conversationUuid: 'c', service: svc, cacheScope: 'a');
    final ready = c.prepareInitial([1]);
    await tester.pumpWidget(MaterialApp(
        home: FutureBuilder<void>(
            future: ready,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Text('loading');
              }
              return Row(children: [
                const Text('message'),
                ChatReadReceiptIndicator(
                    controller: c, messageSeq: 1, isGroup: false)
              ]);
            })));
    expect(find.text('message'), findsNothing);
    expect(find.byType(ChatReceiptReadCheck), findsNothing);
    expect(svc.queries, [
      [1]
    ]);
    svc.responses.single.complete([receipt(1)]);
    await tester.pump();
    expect(find.text('message'), findsOneWidget);
    expect(find.byType(ChatReceiptReadCheck), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets(
      'cached entry returns immediately then refreshes; another user cannot see it',
      (tester) async {
    final svc = DeferredReceipts();
    final first = ChatReceiptsController(
        conversationUuid: 'c', service: svc, cacheScope: 'a');
    var ready = false;
    final prepare = first.prepareInitial([1]).then((_) => ready = true);
    await tester.pump();
    svc.responses.single.complete([receipt(1)]);
    await tester.pump();
    await prepare;
    expect(ready, true);
    first.dispose();
    final next = ChatReceiptsController(
        conversationUuid: 'c', service: svc, cacheScope: 'a');
    ready = false;
    next.prepareInitial([1]).then((_) => ready = true);
    await tester.pump();
    expect(ready, true);
    expect(next.snapshotFor(1)?.allRead, true);
    await tester.pump(const Duration(milliseconds: 101));
    expect(svc.queries.length, 2);
    svc.responses.last.complete([receipt(1, read: false)]);
    await tester.pump();
    expect(next.snapshotFor(1)?.allRead, false);
    final other = ChatReceiptsController(
        conversationUuid: 'c', service: svc, cacheScope: 'b');
    expect(other.snapshotFor(1), isNull);
    other.dispose();
    next.dispose();
  });
  testWidgets('missing receipts time out as unknown, not fabricated unread',
      (tester) async {
    final svc = DeferredReceipts();
    final c = ChatReceiptsController(
        conversationUuid: 'c',
        service: svc,
        cacheScope: 'a',
        initialTimeout: const Duration(milliseconds: 50));
    var ready = false;
    c.prepareInitial([1]).then((_) => ready = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 51));
    expect(ready, true);
    expect(c.snapshotFor(1), isNull);
    svc.responses.single.complete([]);
    await tester.pump();
    c.dispose();
  });
  testWidgets(
      'event during request is serialized; revoked receipt cannot resurrect',
      (tester) async {
    final svc = DeferredReceipts();
    final c = ChatReceiptsController(
        conversationUuid: 'c', service: svc, cacheScope: 'a');
    c.recordSentSeqs([1]);
    await tester.pump(const Duration(milliseconds: 101));
    c.refreshReadThrough(1);
    await tester.pump(const Duration(milliseconds: 101));
    expect(svc.queries.length, 1);
    svc.responses.first.complete([receipt(1, read: false)]);
    await tester.pump();
    expect(svc.queries.length, 2);
    c.invalidate(1);
    svc.responses.last.complete([receipt(1)]);
    await tester.pump();
    expect(c.snapshotFor(1), isNull);
    c.dispose();
  });
  testWidgets('new initial messages join the gate during an in-flight request',
      (tester) async {
    final svc = DeferredReceipts();
    final c = ChatReceiptsController(
        conversationUuid: 'c', service: svc, cacheScope: 'a');
    var ready = false;
    c.prepareInitial([1]).then((_) => ready = true);
    await tester.pump();
    c.prepareInitial([1, 2]);
    svc.responses.first.complete([receipt(1)]);
    await tester.pump();
    expect(ready, false);
    expect(svc.queries, [
      [1],
      [2]
    ]);
    svc.responses.last.complete([receipt(2)]);
    await tester.pump();
    expect(ready, true);
    expect(c.snapshotFor(1), isNotNull);
    expect(c.snapshotFor(2), isNotNull);
    c.dispose();
  });
}
