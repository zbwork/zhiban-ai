import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/human_direct_im_controller.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/providers/chat_receipts_controller.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/chat/services/chat_local_store.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/widgets/group_chat_pane.dart';
import 'package:zhiban_client/pages/chat/widgets/human_direct_chat_pane.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_read_receipt.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_messages_shimmer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    for (final channel in [
      'easyo/rtc/incoming_panel/events',
      'easyo/rtc/meeting/events'
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
    ChatLocalStore.setSharedForTesting(_Store());
    ChatCacheScope.resetSession();
    ChatReceiptsController.debugClearMemoryCache();
    final claims =
        base64Url.encode(utf8.encode(jsonEncode({'aid': 'a', 'act_tid': 't'})));
    SharedPreferences.setMockInitialValues({'token': 'x.$claims.x'});
    await ChatCacheScope.current();
  });
  for (final status in [ImConnectionStatus.connected, ImConnectionStatus.disconnected, ImConnectionStatus.noNetwork]) {
  for (final group in [false, true]) {
    testWidgets(
        '$status ${group ? "group" : "direct"} fast disk and warm first frame show messages with receipts',
        (tester) async {
      ChatLocalStore.setSharedForTesting(_Store());
      final im = _Im()..status = status..hold = Completer<List<ImMessage>>();
      final service = _Receipts();
      final shown = ValueNotifier(true);
      final generation = ValueNotifier(0);
      addTearDown(im.events.close);
      Widget pane() => group
          ? GroupChatPane(
              key: ValueKey(generation.value),
              roomUuid: '',
              title: 'group',
              channelId: 'channel',
              channelType: 2,
              conversationUuid: 'c',
              showHeader: false)
          : HumanDirectChatPane(
              key: ValueKey(generation.value),
              channelId: 'channel',
              channelType: 2,
              conversationUuid: 'c',
              showHeader: false);
      await tester.pumpWidget(ProviderScope(
          overrides: [
            wukongImClientProvider.overrideWithValue(im),
            conversationsProvider.overrideWith(_Conversations.new),
            chatServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
              home: Scaffold(
                  body: ValueListenableBuilder<bool>(
                      valueListenable: shown,
                      builder: (_, show, child) =>
                          show ? pane() : const SizedBox())))));
      expect(find.byType(ChatMessagesShimmer), findsNothing);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(ChatMessagesShimmer), findsNothing);
      im.hold!.complete([_message]);
      await tester.pump();
      await tester.pump();
      expect(find.text('cached message'), findsOneWidget);
      expect(find.textContaining('连接已断开'), findsNothing);
      expect(find.textContaining('网络不可用'), findsNothing);
      expect(find.byType(ChatMessagesShimmer), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(ChatReadReceiptIndicator), findsOneWidget);
      shown.value = false;
      await tester.pumpAndSettle();
      im.hold = Completer<List<ImMessage>>();
      generation.value++;
      shown.value = true;
      await tester.pump();
      expect(find.text('cached message'), findsOneWidget);
      expect(find.byType(ChatMessagesShimmer), findsNothing);
      final indicator = tester.widget<ChatReadReceiptIndicator>(
          find.byType(ChatReadReceiptIndicator));
      expect(indicator.controller.snapshotFor(1)?.allRead, isFalse);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('cached message'), findsOneWidget);
      expect(find.byType(ChatMessagesShimmer), findsNothing);
      await tester.pumpWidget(const SizedBox());
      im.hold!.complete([_message]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      shown.dispose();
      generation.dispose();
    });
  }
  }
  testWidgets(
      'fast local load has no skeleton; slow load displays it after grace',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: DeferredChatMessagesShimmer()));
    expect(find.byType(ChatMessagesShimmer), findsNothing);
    await tester.pump(const Duration(milliseconds: 149));
    expect(find.byType(ChatMessagesShimmer), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(ChatMessagesShimmer), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  test('offline history timeout retains the warm window across re-entry', () async {
    final im = _Im();
    addTearDown(im.events.close);
    HumanDirectImController create() => HumanDirectImController(
        client: im, presetChannelId: 'channel', presetChannelType: 2,
        presetConversationUuid: 'c');
    final first = create();
    await first.open();
    first.dispose();
    im.status = ImConnectionStatus.noNetwork;
    im.hold = Completer<List<ImMessage>>();
    final reopened = create();
    final opening = reopened.open();
    expect(reopened.messages.single.text, 'cached message');
    im.hold!.completeError(TimeoutException('history callback missing'));
    await opening;
    expect(reopened.loading, isFalse);
    expect(reopened.error, isNull);
    expect(reopened.messages.single.text, 'cached message');
    reopened.dispose();
    final again = create();
    expect(again.messages.single.text, 'cached message');
    again.dispose();
  });

  test('warm window preserves failed messages while excluding in-flight sends',
      () async {
    final im = _Im();
    addTearDown(im.events.close);
    HumanDirectImController create() => HumanDirectImController(
        client: im,
        presetChannelId: 'channel',
        presetChannelType: 2,
        presetConversationUuid: 'c');
    final first = create();
    await first.open();
    im.events.add(const ImMessage(
        messageId: 'failed',
        clientMsgNo: 'failed',
        fromUid: 'self',
        channelId: 'channel',
        channelType: 2,
        timestamp: 100001,
        messageSeq: 0,
        text: 'failed',
        sendStatus: ImSendStatus.failed));
    im.events.add(const ImMessage(
        messageId: 'pending',
        clientMsgNo: 'pending',
        fromUid: 'self',
        channelId: 'channel',
        channelType: 2,
        timestamp: 100002,
        messageSeq: 0,
        text: 'pending',
        sendStatus: ImSendStatus.pending));
    await Future<void>.delayed(Duration.zero);
    first.dispose();
    final reopened = create();
    expect(reopened.messages.map((m) => m.text), ['cached message', 'failed']);
    reopened.dispose();
  });
  test('warm window invalidates on clear boundary, denied access and logout',
      () async {
    final im = _Im();
    addTearDown(im.events.close);
    HumanDirectImController create({String? cleared}) =>
        HumanDirectImController(
            client: im,
            presetChannelId: 'channel',
            presetChannelType: 2,
            presetConversationUuid: 'c',
            presetClearedAt: cleared);
    final first = create();
    await first.open();
    first.dispose();
    final warm = create();
    expect(warm.messages, hasLength(1));
    warm.dispose();
    final cleared = create(cleared: '2026-10-09T00:00:00Z');
    expect(cleared.messages, isEmpty);
    cleared.dispose();
    final denied = create();
    denied.discardWarmHistory();
    denied.dispose();
    final afterDenied = create();
    expect(afterDenied.messages, isEmpty);
    await afterDenied.open();
    afterDenied.dispose();
    ChatCacheScope.resetSession();
    final logout = create();
    expect(logout.messages, isEmpty);
    logout.dispose();
  });
}

class _Conversations extends ConversationsNotifier {
  @override
  Future<List<ConversationItem>> build() async => [];
}

class _Receipts extends OpenClawChatService {
  @override
  Future<void> markConversationRead(String conversationId,
      {int lastReadMessageSeq = 0}) async {}
  @override
  Future<List<Map<String, dynamic>>> getReadReceipts(
          {required String conversationId,
          required List<int> messageSeqs}) async =>
      [
        for (final seq in messageSeqs)
          {
            'message_seq': seq,
            'read_count': 0,
            'unread_count': 1,
            'all_read': false
          }
      ];
}

const _message = ImMessage(
    messageId: '1',
    clientMsgNo: 'cm1',
    fromUid: 'self',
    channelId: 'channel',
    channelType: 2,
    timestamp: 100000,
    messageSeq: 1,
    text: 'cached message');

class _Im implements ImClient {
  final events = StreamController<ImMessage>.broadcast();
  Completer<List<ImMessage>>? hold;
  @override
  String get connectedUid => 'self';
  @override
  ImConnectionStatus get connectionStatus => status;
  ImConnectionStatus status = ImConnectionStatus.connected;
  @override
  bool get isRealtimeConnected => true;
  @override
  Stream<ImMessage> listenMessages() => events.stream;
  @override
  Stream<ImConnectionStatus> listenConnectionStatus() => const Stream.empty();
  @override
  Future<void> markRead(String channelId, int channelType) async {}
  @override
  Future<List<ImMessage>> getHistoryMessages(String channelId, int channelType,
          {int limit = 40,
          int beforeMessageSeq = 0,
          String? conversationUuid,
          String? clearedAt}) async =>
      hold == null ? [_message] : await hold!.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store implements ChatLocalStore {
  @override
  int revision(String scope, String conversation) => 0;
  @override
  Future<Map<String, dynamic>?> read(
          String scope, String conversation, String kind) async =>
      {
        'items': [
          {
            'message_seq': 1,
            'read_count': 0,
            'unread_count': 1,
            'all_read': false
          }
        ]
      };
  @override
  Future<void> write(String scope, String conversation, String kind,
      Map<String, dynamic> payload,
      {required int expectedRevision}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
