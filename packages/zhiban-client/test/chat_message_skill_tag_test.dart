import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/message_bubble/message_bubble.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';

void main() {
  testWidgets('sent user message keeps selected skill as read-only tag',
      (tester) async {
    final message = ChatMessage(
      role: ChatRole.question,
      content: '这是什么技能',
      status: BubbleStatus.success,
      empBlocks: const [
        {'type': 'skill', 'slug': 'forge-persona', 'name': '蒸馏.skill'},
        {'type': 'text', 'text': '这是什么技能'},
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            item: message,
            skillIconUrls: const {
              'forge-persona':
                  '/api/agent-bus/v1/assets/skill-icons/forge-persona.png',
            },
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('chat_message_skill_tag_蒸馏.skill')),
        findsOneWidget);
    expect(find.text('蒸馏.skill'), findsOneWidget);
    expect(find.text('这是什么技能'), findsOneWidget);
    expect(
      tester.widget<UiNetworkImage>(find.byType(UiNetworkImage)).imageUrl,
      endsWith('/skill-icons/forge-persona.png'),
    );
  });
}
