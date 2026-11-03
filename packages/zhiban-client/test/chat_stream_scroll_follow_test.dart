import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_answer_reveal.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_scroll.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_message_list.dart';

/// 混合停跟（docs/standards/chat-stream-rendering-standard.md 规则 8-10）：
/// 细粒度揭示阶段（正文 < fineGrainedRuneBudget）打字伴随平滑跟滚；
/// 预算耗尽整批铺出时停跟，视口停在当前阅读位置。
void main() {
  group('nextStreamFollowOffset', () {
    test('moves part-way toward a distant target', () {
      expect(
        nextStreamFollowOffset(current: 100, target: 200),
        closeTo(115, 0.001),
      );
    });

    test('snaps to target inside the stop epsilon', () {
      expect(
        nextStreamFollowOffset(current: 199.7, target: 200),
        200
      );
    });

    test('also follows a target that moved upward', () {
      expect(
        nextStreamFollowOffset(current: 200, target: 100),
        closeTo(185, 0.001),
      );
    });
  });

  group('ChatMessageList hybrid stream follow', () {
    testWidgets('local send aligns question at top once, including first turn',
        (tester) async {
      final question = ChatMessage(messageId: 'first-question',
          role: ChatRole.question, content: '第一轮发出的问题');
      final answer = ChatMessage(messageId: 'first-answer',
          role: ChatRole.answer, content: '正在回复', status: BubbleStatus.loading);
      await tester.pumpWidget(_wrap([question, answer], autoScroll: false));
      await tester.pumpAndSettle();
      final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
      expect(tester.getTopLeft(find.text(question.content)).dy - viewportTop,
          inInclusiveRange(0, 45));
      final next = ChatMessage(messageId: 'next-question',
          role: ChatRole.question, content: '新一轮发出的问题');
      final messages = [question, answer.copyWith(
          content: List.filled(25, '已完成内容').join('\n'),
          status: BubbleStatus.success), next,
        ChatMessage(messageId: 'next-answer', role: ChatRole.answer,
            content: '正在回复', status: BubbleStatus.loading)];
      await tester.pumpWidget(_wrap(messages, autoScroll: false));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text(next.content)).dy - viewportTop,
          inInclusiveRange(0, 45));
      final position = _scrollPosition(tester);
      final offset = position.pixels;
      await tester.pumpWidget(_wrap([
        ...messages.take(messages.length - 1),
        messages.last.copyWith(content: List.filled(40, '继续回复').join('\n'))
      ], autoScroll: false));
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(offset, 0.5));
    });

    testWidgets('local replies preserve position through growth and completion',
        (tester) async {
      final initial = _conversation();
      await tester.pumpWidget(_wrap(initial, autoScroll: false));
      await tester.pumpAndSettle();
      final position = _scrollPosition(tester);
      final originalOffset = position.pixels;
      final grown = [
        ...initial.take(initial.length - 1),
        initial.last.copyWith(content: List.generate(35, (i) => '新增回复第 $i 行').join('\n')),
      ];
      await tester.pumpWidget(_wrap(grown, autoScroll: false));
      await tester.pumpAndSettle();
      expect(position.maxScrollExtent, greaterThan(originalOffset));
      expect(position.pixels, closeTo(originalOffset, 0.5));
      final completed = [
        ...grown.take(grown.length - 1),
        grown.last.copyWith(status: BubbleStatus.success),
        ChatMessage(messageId: 'extra-answer', role: ChatRole.answer,
            content: List.filled(15, '后续回复').join('\n')),
      ];
      await tester.pumpWidget(_wrap(completed, autoScroll: false));
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(originalOffset, 0.5));
      tester.state<ChatMessageListState>(find.byType(ChatMessageList)).scrollToBottom();
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    });

    testWidgets('follows smoothly while the answer is still short',
        (tester) async {
      final initialMessages = _conversation();
      await tester.pumpWidget(_wrap(initialMessages));
      await tester.pumpAndSettle();

      final position = _scrollPosition(tester);
      final oldPixels = position.pixels;
      final oldMaxScrollExtent = position.maxScrollExtent;
      expect(oldMaxScrollExtent, greaterThan(0));
      expect(oldPixels, closeTo(oldMaxScrollExtent, 0.5));

      // 增长后的正文必须仍在 fineGrainedRuneBudget 内，否则跟随阶段会关闭。
      final updatedMessages = [
        ...initialMessages.take(initialMessages.length - 1),
        initialMessages.last.copyWith(
          content: '${initialMessages.last.content}\n\n'
              '${List.generate(20, (index) => '新增流式正文第 $index 行。').join('\n')}',
        ),
      ];
      expect(
        updatedMessages.last.content.runes.length,
        lessThan(ChatAnswerRevealBuffer.fineGrainedRuneBudget),
      );
      await tester.pumpWidget(_wrap(updatedMessages));
      await tester.pump(const Duration(milliseconds: 16));

      expect(position.maxScrollExtent, greaterThan(oldMaxScrollExtent));
      expect(position.pixels, greaterThan(oldPixels));
      expect(position.pixels, lessThan(position.maxScrollExtent));
    });

    testWidgets('stops following once the revealed answer exceeds the budget',
        (tester) async {
      final initialMessages = _conversation();
      await tester.pumpWidget(_wrap(initialMessages));
      await tester.pumpAndSettle();

      final position = _scrollPosition(tester);
      final pixelsBeforeDump = position.pixels;

      // 预算耗尽时 provider 一次性铺出剩余正文：模拟越过
      // fineGrainedRuneBudget 的整批增长，列表必须停跟。
      final dumped = [
        ...initialMessages.take(initialMessages.length - 1),
        initialMessages.last.copyWith(
          content: '${initialMessages.last.content}\n\n'
              '${List.filled(ChatAnswerRevealBuffer.fineGrainedRuneBudget + 500, '尾').join()}',
        ),
      ];
      await tester.pumpWidget(_wrap(dumped));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(position.maxScrollExtent, greaterThan(pixelsBeforeDump));
      expect(position.pixels, closeTo(pixelsBeforeDump, 0.5));

      // 铺出后继续到达的 delta 也不得再拉动视口。
      final more = [
        ...dumped.take(dumped.length - 1),
        dumped.last.copyWith(
          content: '${dumped.last.content}\n继续生成的尾部内容。'
        ),
      ];
      await tester.pumpWidget(_wrap(more));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(position.pixels, closeTo(pixelsBeforeDump, 0.5));

      // “回到最新”仍可一次跳到当前底部。
      tester
          .state<ChatMessageListState>(find.byType(ChatMessageList))
          .scrollToBottom();
      await tester.pump();
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    });

    testWidgets('user scrolling upward stops follow during the short phase',
        (tester) async {
      final initialMessages = _conversation();
      await tester.pumpWidget(_wrap(initialMessages));
      await tester.pumpAndSettle();

      final scrollable = find.descendant(
        of: find.byType(ChatMessageList),
        matching: find.byType(Scrollable),
      );
      await tester.drag(scrollable, const Offset(0, 180));
      await tester.pumpAndSettle();

      final position = _scrollPosition(tester);
      final userSelectedPixels = position.pixels;
      expect(
        position.maxScrollExtent - userSelectedPixels,
        greaterThan(4)
      );

      final updatedMessages = [
        ...initialMessages.take(initialMessages.length - 1),
        initialMessages.last.copyWith(
          content: '${initialMessages.last.content}\n\n'
              '${List.generate(24, (index) => '用户阅读期间新增第 $index 行。').join('\n')}',
        ),
      ];
      await tester.pumpWidget(_wrap(updatedMessages));
      await tester.pump(const Duration(milliseconds: 80));

      expect(position.pixels, closeTo(userSelectedPixels, 0.5));
    });
  });
}

Widget _wrap(List<ChatMessage> messages, {bool autoScroll = true}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 720,
        height: 320,
        child: ChatMessageList(
          autoScrollOnMessageUpdate: autoScroll,
          activeConversationId: 'stream-follow-conversation',
          messages: messages,
          hasMoreHistory: false,
          isLoadingHistory: false,
          isSending: true,
          maxBubbleWidth: 520,
          bottomContentInset: 0,
          onLoadMoreHistory: () {},
        ),
      ),
    ),
  );
}

List<ChatMessage> _conversation() {
  final messages = <ChatMessage>[];
  for (var index = 0; index < 5; index++) {
    messages
      ..add(
        ChatMessage(
          messageId: 'question-$index',
          role: ChatRole.question,
          content: '第 $index 个问题',
        ),
      )
      ..add(
        ChatMessage(
          messageId: 'answer-$index',
          role: ChatRole.answer,
          content: List.generate(
            4,
            (line) => '第 $index 个回答的第 $line 行。',
          ).join('\n'),
          status: index == 4 ? BubbleStatus.loading : BubbleStatus.success,
        ),
      );
  }
  return messages;
}

ScrollPosition _scrollPosition(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byType(ChatMessageList),
    matching: find.byType(Scrollable),
  );
  expect(scrollable, findsOneWidget);
  return tester.state<ScrollableState>(scrollable).position;
}
