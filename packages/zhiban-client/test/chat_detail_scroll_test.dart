import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_scroll.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_message_list.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_conversation_pair_view.dart';

void main() {
  testWidgets('first send concurrent animated scroll must reveal list',
      (tester) async {
    final key = GlobalKey<ChatMessageListState>();
    var conversation = 'pending:agent';
    Widget host() => MaterialApp(
            home: Scaffold(
                body: ChatMessageList(
          key: key,
          activeConversationId: conversation,
          messages: [
            ChatMessage(role: ChatRole.question, content: '你好'),
            ChatMessage(role: ChatRole.answer, content: '回复')
          ],
          hasMoreHistory: false,
          isLoadingHistory: false,
          isSending: true,
          maxBubbleWidth: 300,
          bottomContentInset: 120,
          onLoadMoreHistory: () {},
        )));
    await tester.pumpWidget(host());
    // ChatSessionView schedules this callback when the first send mounts the list.
    key.currentState!.scrollToBottom(animated: true);
    await tester.pumpAndSettle();
    final listOpacity = find
        .descendant(
            of: find.byType(ChatMessageList), matching: find.byType(Opacity))
        .first;
    expect(tester.widget<Opacity>(listOpacity).opacity, 1);
    expect(tester.takeException(), isNull);
    conversation = 'server-conversation';
    await tester.pumpWidget(host());
    key.currentState!.scrollToBottom(animated: true);
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(listOpacity).opacity, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('keyboard resize concurrent immediate scroll must reveal list',
      (tester) async {
    final key = GlobalKey<ChatMessageListState>();
    var conversation = 'pending:agent';
    Widget host() => MaterialApp(
            home: Scaffold(
                body: ChatMessageList(
          key: key,
          activeConversationId: conversation,
          messages: [
            ChatMessage(role: ChatRole.question, content: '你好'),
            ChatMessage(role: ChatRole.answer, content: '回复')
          ],
          hasMoreHistory: false,
          isLoadingHistory: false,
          isSending: true,
          maxBubbleWidth: 300,
          bottomContentInset: 120,
          onLoadMoreHistory: () {},
        )));
    await tester.pumpWidget(host());
    // ChatSessionView schedules this callback when the first send mounts the list.
    key.currentState!.scrollToBottom();
    await tester.pumpAndSettle();
    final listOpacity = find
        .descendant(
            of: find.byType(ChatMessageList), matching: find.byType(Opacity))
        .first;
    expect(tester.widget<Opacity>(listOpacity).opacity, 1);
    expect(tester.takeException(), isNull);
    conversation = 'server-conversation';
    await tester.pumpWidget(host());
    key.currentState!.scrollToBottom();
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(listOpacity).opacity, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('agent send acknowledgement preserves the message element',
      (tester) async {
    final question = ChatMessage(role: ChatRole.question, content: '新消息');
    final answer = ChatMessage(role: ChatRole.answer, content: '回复');
    var messages = [question, answer];
    Widget host() => MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: Scaffold(
              body: ChatMessageList(
            activeConversationId: 'stable',
            messages: messages,
            hasMoreHistory: false,
            isLoadingHistory: false,
            isSending: true,
            maxBubbleWidth: 450,
            bottomContentInset: 0,
            onLoadMoreHistory: () {},
          )),
        );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final pair = tester.element(find.byType(ChatConversationPairView));
    messages = [
      question.copyWith(messageId: 'server-question'),
      answer.copyWith(messageId: 'server-answer')
    ];
    await tester.pumpWidget(host());
    expect(tester.element(find.byType(ChatConversationPairView)), same(pair));
    await tester.pumpAndSettle();
    // A history refresh creates model objects with new local IDs.
    messages = [
      ChatMessage(
          role: ChatRole.question,
          content: '新消息',
          messageId: 'server-question'),
      ChatMessage(
          role: ChatRole.answer, content: '回复', messageId: 'server-answer'),
    ];
    await tester.pumpWidget(host());
    expect(tester.element(find.byType(ChatConversationPairView)), same(pair));
    await tester.pumpAndSettle();
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.iOS,
    TargetPlatform.android
  ]) {
    testWidgets('$platform short IM starts at top and grows down',
        (tester) async {
      final scroll = ChatBottomScrollController();
      addTearDown(scroll.dispose);
      var ids = ['first'];
      Widget host() => MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
              body: ChatHistoryList(
                  scrollController: scroll,
                  hasMore: false,
                  onLoadOlder: () {},
                  itemIds: ids,
                  padding: const EdgeInsets.all(12),
                  itemBuilder: (_, i) =>
                      SizedBox(height: 80, child: Text(ids[i])))));
      await tester.pumpWidget(host());
      scroll.scrollToLatest();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('first')).dy, closeTo(12, 1));
      ids = ['first', 'second'];
      await tester.pumpWidget(host());
      scroll.scrollToLatest();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('first')).dy, closeTo(12, 1));
      expect(tester.getTopLeft(find.text('second')).dy, closeTo(92, 1));
      ids = [...ids, ...List.generate(20, (i) => 'long-$i')];
      await tester.pumpWidget(host());
      scroll.scrollToLatest();
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
      expect(find.text('long-19'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mobile short history prepend clamps anchor to valid range',
      (tester) async {
    final scroll = ChatBottomScrollController();
    addTearDown(scroll.dispose);
    var ids = ['last'];
    Widget host() => MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
            body: ChatHistoryList(
                scrollController: scroll,
                hasMore: false,
                onLoadOlder: () {},
                itemIds: ids,
                padding: const EdgeInsets.all(12),
                itemBuilder: (_, i) =>
                    SizedBox(height: 80, child: Text(ids[i])))));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('last')).dy, closeTo(12, 1));
    ids = [...List.generate(20, (i) => 'older-$i'), 'last'];
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(scroll.position.minScrollExtent, 0);
    expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
    expect(tester.getTopLeft(find.text('last')).dy, greaterThanOrEqualTo(0));
    expect(tester.getBottomLeft(find.text('last')).dy, lessThan(600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('IM send and acknowledgement preserve mounted message rows',
      (tester) async {
    final scroll = ChatBottomScrollController();
    addTearDown(scroll.dispose);
    var ids = ['existing'];
    var sent = false;
    Widget host() => MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: Scaffold(
              body: ChatHistoryList(
            scrollController: scroll,
            hasMore: false,
            onLoadOlder: () {},
            itemIds: ids,
            padding: const EdgeInsets.all(12),
            itemBuilder: (_, i) => SizedBox(
                height: 60,
                child: Text('${ids[i]}-${sent ? "sent" : "pending"}')),
          )),
        );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final existing = tester.element(find.text('existing-pending'));
    ids = [...ids, 'new'];
    await tester.pumpWidget(host());
    scroll.scrollToLatest();
    await tester.pumpAndSettle();
    final added = tester.element(find.text('new-pending'));
    expect(tester.element(find.text('existing-pending')), same(existing));
    sent = true;
    await tester.pumpWidget(host());
    expect(tester.element(find.text('existing-sent')), same(existing));
    expect(tester.element(find.text('new-sent')), same(added));
    await tester.pumpAndSettle();
  });

  for (final mobile in [false, true]) {
    for (final agent in [false, true]) {
      for (final short in [false, true]) {
        testWidgets(
            '${mobile ? 'mobile' : 'desktop'} ${agent ? 'agent' : 'IM'} short=$short user scroll dismisses keyboard only',
            (tester) async {
          final focus = FocusNode();
          final input = TextEditingController(text: '保留未发送的草稿');
          final scroll = ChatBottomScrollController();
          addTearDown(focus.dispose);
          addTearDown(input.dispose);
          addTearDown(scroll.dispose);
          final count = short ? 1 : 30;
          await tester.pumpWidget(MaterialApp(
            theme: ThemeData(
                platform: mobile ? TargetPlatform.iOS : TargetPlatform.macOS),
            home: Scaffold(
              body: Column(children: [
                Expanded(
                  child: agent
                      ? ChatMessageList(
                          activeConversationId: 'keyboard',
                          messages: List.generate(count, _message),
                          hasMoreHistory: false,
                          isLoadingHistory: false,
                          isSending: false,
                          maxBubbleWidth: 450,
                          bottomContentInset: 0,
                          onLoadMoreHistory: () {},
                        )
                      : ChatHistoryList(
                          scrollController: scroll,
                          hasMore: false,
                          onLoadOlder: () {},
                          itemIds: List.generate(count, (i) => '$i'),
                          itemBuilder: (_, i) =>
                              SizedBox(height: 80, child: Text('message-$i')),
                          padding: const EdgeInsets.all(12),
                        ),
                ),
                TextField(
                  focusNode: focus,
                  controller: input,
                  onTapOutside: (_) {},
                ),
              ]),
            ),
          ));
          await tester.pumpAndSettle();
          await tester.showKeyboard(find.byType(TextField));
          final timeline = find
              .descendant(
                  of: find.byType(ChatHistoryRefresh),
                  matching: find.byType(Scrollable))
              .first;
          final position = tester.state<ScrollableState>(timeline).position;
          final middle =
              (position.minScrollExtent + position.maxScrollExtent) / 2;
          position.jumpTo(middle);
          await tester.pumpAndSettle();
          final animated = position.animateTo(position.minScrollExtent,
              duration: const Duration(milliseconds: 80), curve: Curves.linear);
          await tester.pumpAndSettle();
          await animated;
          expect(focus.hasFocus, isTrue);
          expect(tester.testTextInput.isVisible, isTrue);
          position.jumpTo(middle);
          await tester.pumpAndSettle();
          await tester.tapAt(tester.getCenter(timeline));
          await tester.pump();
          expect(focus.hasFocus, isTrue);

          await tester.drag(timeline, const Offset(0, 100));
          await tester.pumpAndSettle();
          expect(focus.hasFocus, isFalse);
          expect(tester.testTextInput.isVisible, isFalse);
          expect(input.text, '保留未发送的草稿');

          if (!mobile && !short) {
            await tester.showKeyboard(find.byType(TextField));
            position.jumpTo(middle);
            await tester.pumpAndSettle();
            expect(focus.hasFocus, isTrue);
            await tester.sendEventToBinding(PointerScrollEvent(
              position: tester.getCenter(timeline),
              scrollDelta: const Offset(0, -50),
            ));
            await tester.pumpAndSettle();
            expect(focus.hasFocus, isFalse);
            expect(input.text, '保留未发送的草稿');
          }
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('agent conversation switch and send supersede pending history',
      (tester) async {
    final key = GlobalKey<ChatMessageListState>();
    var conversation = 'a';
    var messages = List.generate(20, (i) => _message(i + 20));
    final requests = [Completer<void>(), Completer<void>()];
    var loads = 0;
    Widget host() => MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Scaffold(
            body: SizedBox(
                height: 400,
                child: ChatMessageList(
                  key: key,
                  activeConversationId: conversation,
                  messages: messages,
                  hasMoreHistory: true,
                  isLoadingHistory: false,
                  isSending: false,
                  maxBubbleWidth: 450,
                  bottomContentInset: 0,
                  onLoadMoreHistory: () => requests[loads++].future,
                ))));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final finder = find.descendant(
        of: find.byType(ChatMessageList), matching: find.byType(Scrollable));
    ScrollPosition position() => tester.state<ScrollableState>(finder).position;
    position().jumpTo(60);
    await tester.drag(finder, const Offset(0, 65));
    await tester.pumpAndSettle();
    expect(loads, 1);
    conversation = 'b';
    messages = List.generate(20, (i) => _message(i + 100));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(position().pixels, closeTo(position().maxScrollExtent, 1));
    position().jumpTo(60);
    await tester.drag(finder, const Offset(0, 65));
    await tester.pumpAndSettle();
    expect(loads, 2);
    final historyPosition = position().pixels;
    requests[0].complete();
    await tester.pumpAndSettle();
    expect(position().pixels, closeTo(historyPosition, 1));
    messages = [...messages, _message(120)];
    await tester.pumpWidget(host());
    key.currentState!.scrollToBottom(animated: true);
    await tester.pumpAndSettle();
    messages = [...List.generate(20, (i) => _message(i + 80)), ...messages];
    await tester.pumpWidget(host());
    requests[1].complete();
    await tester.pumpAndSettle();
    expect(position().pixels, closeTo(position().maxScrollExtent, 1));
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform anchored IM history pulls down and retains its row',
        (tester) async {
      final scroll = ChatBottomScrollController();
      addTearDown(scroll.dispose);
      var ids = List.generate(12, (i) => '${40 + i}');
      var pending = Completer<void>();
      var loads = 0;
      Widget host() => MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
              body: ChatHistoryList(
                  scrollController: scroll,
                  hasMore: true,
                  padding: const EdgeInsets.all(12),
                  itemIds: ids,
                  itemBuilder: (_, i) =>
                      SizedBox(height: 80, child: Text('message-${ids[i]}')),
                  onLoadOlder: () {
                    loads++;
                    return pending.future;
                  })));
      await tester.pumpWidget(host());
      scroll.jumpTo(scroll.position.minScrollExtent);
      await tester.pumpAndSettle();
      expect(loads, 0);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 250));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(loads, 1);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 250));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(loads, 1);
      final y = tester.getTopLeft(find.text('message-40')).dy;
      ids = [...List.generate(40, (i) => '$i'), ...ids];
      await tester.pumpWidget(host());
      pending.complete();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('message-40')).dy, closeTo(y, 2));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      pending = Completer<void>();
      scroll.jumpTo(scroll.position.minScrollExtent);
      await tester.pumpAndSettle();
      expect(loads, 1);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 250));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(loads, 2);
      pending.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text('加载失败，请重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'entry and send settle at real bottom of variable-height lazy list',
      (tester) async {
    final scroll = ChatBottomScrollController();
    addTearDown(scroll.dispose);
    var count = 160;
    Widget host() => MaterialApp(
        home: Scaffold(
            body: SizedBox(
                height: 400,
                child: ListView.builder(
                    controller: scroll,
                    itemCount: count,
                    itemBuilder: (_, i) => SizedBox(
                        height: 35.0 + (i % 7) * 23,
                        child: Text('message-$i'))))));
    await tester.pumpWidget(host());
    scroll.scrollToLatest();
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
    expect(find.text('message-159'), findsOneWidget);
    scroll.jumpTo(0);
    count++;
    await tester.pumpWidget(host());
    scroll.scrollToLatest(animated: true);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
    expect(find.text('message-160'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancel and disposal invalidate scheduled scroll requests',
      (tester) async {
    final scroll = ChatBottomScrollController();
    await tester.pumpWidget(MaterialApp(
        home: ListView(
            controller: scroll, children: const [SizedBox(height: 2400)])));
    scroll.scrollToLatest();
    scroll.cancelScrollToLatest();
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    scroll.scrollToLatest();
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'agent entry lands latest and older page preserves exact message position',
      (tester) async {
    var messages = List.generate(20, (i) => _message(i + 20));
    final pending = Completer<void>();
    var loads = 0;
    Widget host() => MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Scaffold(
            body: SizedBox(
                height: 400,
                width: 600,
                child: ChatMessageList(
                    activeConversationId: 'conv',
                    messages: messages,
                    hasMoreHistory: true,
                    isLoadingHistory: false,
                    isSending: false,
                    maxBubbleWidth: 450,
                    bottomContentInset: 0,
                    onLoadMoreHistory: () {
                      loads++;
                      return pending.future;
                    }))));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final finder = find.descendant(
        of: find.byType(ChatMessageList), matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(finder).position;
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    position.jumpTo(60);
    await tester.drag(finder, const Offset(0, 65));
    await tester.pump();
    expect(loads, 1);
    final anchor = find.byKey(const ValueKey('chat-message-row:m20'));
    final y = tester.getTopLeft(anchor).dy;
    messages = [...List.generate(20, _message), ...messages];
    await tester.pumpWidget(host());
    pending.complete();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(anchor).dy, closeTo(y, 2));
    expect(loads, 1);
    expect(position.pixels, lessThan(position.maxScrollExtent));
  });

  testWidgets('mobile short history can pull to load once while pending',
      (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final pending = Completer<void>();
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
            body: ChatHistoryRefresh(
                scrollController: scroll,
                hasMore: true,
                onLoadOlder: () {
                  loads++;
                  return pending.future;
                },
                child: ListView(
                    controller: scroll,
                    children: const [Text('only message')])))));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 250));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(loads, 1);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 250));
    await tester.pump(const Duration(milliseconds: 500));
    expect(loads, 1);
    pending.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

ChatMessage _message(int i) => ChatMessage(
    messageId: 'm$i',
    role: ChatRole.question,
    content: 'message $i\n${'line\n' * (i % 3)}');
