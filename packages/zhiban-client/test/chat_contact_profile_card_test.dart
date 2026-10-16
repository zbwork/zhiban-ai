import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/contact_profile_card.dart';

void main() {
  testWidgets('contact profile card shows profile and runs actions',
      (tester) async {
    var messageTapped = false;
    var voiceTapped = false;
    var videoTapped = false;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showChatContactProfileCard(
            context,
            anchor: const Offset(20, 20),
            profile: const ChatContactProfile(
              kind: 'human',
              accountUuid: 'acct-1',
              displayName: '李娜',
              departmentName: '科技中心',
              positionLabel: '产品经理',
              email: 'lina@example.com',
              companyName: '宜信致诚',
            ),
            onMessage: () => messageTapped = true,
            onVoiceCall: () => voiceTapped = true,
            onVideoCall: () => videoTapped = true,
          ),
          child: const Text('open'),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('李娜'), findsOneWidget);
    expect(find.text('产品经理 · 科技中心'), findsOneWidget);
    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('lina@example.com'), findsOneWidget);
    expect(find.text('部门'), findsOneWidget);
    expect(find.text('科技中心'), findsOneWidget);
    expect(find.text('企业'), findsOneWidget);
    expect(find.text('宜信致诚'), findsOneWidget);
    expect(find.text('发消息'), findsOneWidget);
    expect(find.text('语音'), findsOneWidget);
    expect(find.text('视频'), findsOneWidget);

    await tester.tap(find.text('发消息'));
    await tester.pumpAndSettle();
    expect(messageTapped, isTrue);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('语音'));
    await tester.pumpAndSettle();
    expect(voiceTapped, isTrue);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('视频'));
    await tester.pumpAndSettle();
    expect(videoTapped, isTrue);
  });
}
