import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/human_direct_im_controller.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/chat/widgets/group_chat_pane.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_im_history_panel.dart';
import 'package:zhiban_client/pages/chat/widgets/human_direct_chat_pane.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('history errors reach refresh UI and leave pagination retryable',
      () async {
    final client = _ImClient();
    final controller = HumanDirectImController(
        client: client, presetChannelId: 'channel', presetChannelType: 2);
    addTearDown(controller.dispose);
    addTearDown(client.events.close);
    await controller.open();
    final failed = expectLater(
        controller.loadMoreHistory(reportErrors: true), throwsStateError);
    client.older.completeError(StateError('offline'));
    await failed;
    expect(controller.loadingMore, isFalse);
    expect(controller.hasMoreHistory, isTrue);
    expect(controller.error, isNull);
    client.older = Completer<List<ImMessage>>();
    final retried = controller.loadMoreHistory(reportErrors: true);
    client.older.complete([]);
    await retried;
    expect(client.olderCalls, 2);
    expect(controller.hasMoreHistory, isFalse);
  });
  for (final mobile in [false, true]) {
    for (final group in [false, true]) {
      testWidgets(
          '${mobile ? 'mobile' : 'desktop'} ${group ? 'group' : 'human'} entry, history, incoming and send focus',
          (tester) async {
        final client = _ImClient();
        addTearDown(client.events.close);
        await tester.pumpWidget(ProviderScope(
            overrides: [
              wukongImClientProvider.overrideWithValue(client),
              conversationsProvider.overrideWith(_EmptyConversations.new),
            ],
            child: MaterialApp(
                theme: ThemeData(
                    platform:
                        mobile ? TargetPlatform.iOS : TargetPlatform.macOS),
                home: Scaffold(
                    body: group
                        ? const GroupChatPane(
                            roomUuid: '',
                            channelId: 'channel',
                            channelType: 2,
                            title: 'group',
                            conversationUuid: '',
                            showHeader: false)
                        : const HumanDirectChatPane(
                            channelId: 'channel', showHeader: false)))));
        await tester.pumpAndSettle();
        final list = find.byType(CustomScrollView).first;
        final scrollable =
            find.descendant(of: list, matching: find.byType(Scrollable)).first;
        final position = tester.state<ScrollableState>(scrollable).position;
        expect(position.pixels, closeTo(position.minScrollExtent, 1));
        // Visiting the oldest rows resolves lazy variable-height estimates.
        for (var i = 0; i < 5; i++) {
          position.jumpTo(position.maxScrollExtent - 60);
          await tester.pump();
        }
        await tester.drag(scrollable, Offset(0, mobile ? 250 : 65));
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(client.olderCalls, 1);
        final anchor = find.textContaining('message-41').first;
        final beforeY = tester.getTopLeft(anchor).dy;
        client.older.complete(List.generate(40, (i) => _message(i + 1)));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(anchor).dy, closeTo(beforeY, 2));
        // The first original message must remain in the current viewport.
        expect(find.textContaining('message-41'), findsWidgets);
        final beforeIncoming = position.pixels;
        client.events.add(_message(81));
        await tester.pumpAndSettle();
        expect(position.pixels, closeTo(beforeIncoming, 1));
        await tester.enterText(find.byType(TextField), 'send from history');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        expect(client.sent, 1);
        expect(
            tester
                .widget<TextField>(find.byType(TextField))
                .focusNode!
                .hasFocus,
            isTrue);
        expect(position.pixels, closeTo(position.minScrollExtent, 1));
        // Keeping focus also permits edits while the previous send is pending.
        client.sendPending = Completer<void>();
        await tester.enterText(find.byType(TextField), 'in flight');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'next draft');
        client.sendPending!.complete();
        await tester.pumpAndSettle();
        final input = tester.widget<TextField>(find.byType(TextField));
        expect(input.controller!.text, 'next draft');
        expect(input.focusNode!.hasFocus, isTrue);
        // Existing history search still locates an offscreen message after
        // switching the timeline to a reversed viewport.
        ProviderScope.containerOf(tester.element(find.byType(Scaffold)))
            .read(chatHistoryPanelOpenProvider.notifier)
            .state = true;
        await tester.pumpAndSettle();
        tester
            .widget<ChatImHistoryPanel>(find.byType(ChatImHistoryPanel))
            .onSelectMessage!(_message(30));
        await tester.pumpAndSettle();
        final located = find.textContaining('message-30').first;
        expect(tester.getRect(scrollable).overlaps(tester.getRect(located)),
            isTrue);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}

class _EmptyConversations extends ConversationsNotifier {
  @override
  Future<List<ConversationItem>> build() async => [];
}

class _ImClient implements ImClient {
  final events = StreamController<ImMessage>.broadcast();
  int olderCalls = 0;
  int sent = 0;
  var older = Completer<List<ImMessage>>();
  Completer<void>? sendPending;
  @override
  String get connectedUid => 'self';
  @override
  ImConnectionStatus get connectionStatus => ImConnectionStatus.connected;
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
      String? clearedAt}) async {
    if (beforeMessageSeq > 0) {
      olderCalls++;
      return older.future;
    }
    return List.generate(40, (i) => _message(i + 41));
  }

  @override
  Future<void> sendTextMessage(String channelId, int channelType, String text,
      {List<Map<String, dynamic>>? mentions}) async {
    sent++;
    await sendPending?.future;
    events.add(_message(82, text: text, from: 'self'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ImMessage _message(int i, {String? text, String from = 'peer'}) => ImMessage(
    messageId: 'm$i',
    clientMsgNo: 'cm$i',
    fromUid: from,
    channelId: 'channel',
    channelType: 2,
    timestamp: 100000 + i * 1000,
    messageSeq: i,
    text: text ?? 'message-$i\n${'line\n' * (i % 5)}');
