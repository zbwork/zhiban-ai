import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/contact_profile_card.dart';
import 'package:zhiban_client/services/rooms_api.dart';

void main() {
  test('group member parses scoped agent profile without granting direct chat',
      () {
    final member = GroupMember.fromJson({
      'participant_uuid': 'participant-1',
      'kind': 'agent',
      'id': 'agent-1',
      'displayName': '识猫助手',
      'avatar': 'https://example.test/avatar.png',
      'role_in_room': 'member',
      'can_direct_chat': false,
      'skills': [
        {'name': '图片识别', 'slug': 'image-recognition'},
      ],
    });

    expect(member.avatar, contains('avatar.png'));
    expect(member.canDirectChat, isFalse);
    expect(member.skills.single.name, '图片识别');
    expect(member.skills.single.slug, 'image-recognition');
  });

  testWidgets('group-only agent card shows skills but hides direct actions',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showChatContactProfileCard(
              context,
              anchor: const Offset(20, 20),
              profile: const ChatContactProfile(
                kind: 'agent',
                accountUuid: 'agent-1',
                displayName: '识猫助手',
                capabilityNames: ['图片识别'],
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('技能'), findsOneWidget);
    expect(find.text('图片识别'), findsOneWidget);
    expect(find.text('发消息'), findsNothing);
    expect(find.text('语音'), findsNothing);
    expect(find.text('视频'), findsNothing);
  });
}
