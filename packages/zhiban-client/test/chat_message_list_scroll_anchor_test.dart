import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/chat_message_list.dart';

void main() {
  group('ChatMessageList scroll anchors', () {
    testWidgets('message rows use local keys after history is prepended',
        (tester) async {
      final initialMessages = [
        _message('m-2', 'second'),
        _message('m-3', 'third'),
      ];
      final prependedMessages = [
        _systemMessage('sys-0', 'system'),
        _message('m-1', 'first'),
        ...initialMessages,
      ];

      await tester.pumpWidget(_wrap(initialMessages));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_wrap(prependedMessages));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('chat-message-row:sys-0')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('chat-message-row:m-1')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('chat-message-row:m-2')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('chat-message-row:m-3')), findsOneWidget);
    });

    testWidgets('duplicate message ids get unique row keys', (tester) async {
      await tester.pumpWidget(_wrap([
        _message('dup-1', 'first copy'),
        _message('dup-1', 'second copy'),
      ]));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('chat-message-row:dup-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-message-row:dup-1#2')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

Widget _wrap(
  List<ChatMessage> messages, {
  String? highlightMessageUuid,
  int highlightToken = 0,
  double height = 520,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 720,
        height: height,
        child: ChatMessageList(
          activeConversationId: 'conv-1',
          messages: messages,
          hasMoreHistory: true,
          isLoadingHistory: false,
          isSending: false,
          maxBubbleWidth: 520,
          bottomContentInset: 0,
          onLoadMoreHistory: () {},
          highlightMessageUuid: highlightMessageUuid,
          highlightToken: highlightToken,
        ),
      ),
    ),
  );
}

ChatMessage _message(String id, String content) {
  return ChatMessage(
    messageId: id,
    role: ChatRole.question,
    content: content
  );
}

ChatMessage _systemMessage(String id, String content) {
  return ChatMessage(
    messageId: id,
    role: ChatRole.system,
    content: content
  );
}
