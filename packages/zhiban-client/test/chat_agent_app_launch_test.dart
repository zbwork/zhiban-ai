import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_session_view.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/rich_prompt_controller.dart';

void main() {
  testWidgets('agent app chip launches app instead of inserting text',
      (tester) async {
    AgentAppItem? launched;
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 620,
              child: ChatSessionView(
                state: const ChatState.initial().copyWith(
                  activeConversationId: 'conv-a',
                ),
                controller: RichPromptController(),
                focusNode: focusNode,
                agentApps: const [
                  AgentAppItem(
                    id: 'app-calendar',
                    slug: 'calendar',
                    name: '日程',
                    iconUrl: '',
                  ),
                ],
                onLaunchApp: (app, _) => launched = app,
                onPickAttachment: (_) {},
                onPickFromDrive: () {},
                onSend: (_, __) {},
                onStop: () {},
                onLoadMoreHistory: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('日程'));
    await tester.pump();

    expect(launched?.id, 'app-calendar');
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, isEmpty);
  });

  testWidgets('agent app chip shows loading and ignores repeated taps',
      (tester) async {
    final launchCompleted = Completer<void>();
    var launchCount = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 620,
              child: ChatSessionView(
                state: const ChatState.initial().copyWith(
                  activeConversationId: 'conv-a',
                ),
                agentApps: const [
                  AgentAppItem(
                    id: 'app-calendar',
                    slug: 'calendar',
                    name: '日程',
                    iconUrl: '',
                  ),
                ],
                onLaunchApp: (_, __) {
                  launchCount++;
                  return launchCompleted.future;
                },
                onPickAttachment: (_) {},
                onPickFromDrive: () {},
                onSend: (_, __) {},
                onStop: () {},
                onLoadMoreHistory: () {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('日程'));
    await tester.pump();
    await tester.tap(find.text('日程'));
    await tester.pump();

    expect(launchCount, 1);
    expect(
      find.byKey(const ValueKey('capability_loading_日程')),
      findsOneWidget
    );

    launchCompleted.complete();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('capability_loading_日程')),
      findsNothing
    );
  });

  testWidgets(
      'agent app chip stops loading when presented but stays locked until close',
      (tester) async {
    final closed = Completer<void>();
    VoidCallback? markPresented;
    var launchCount = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 620,
              child: ChatSessionView(
                state: const ChatState.initial().copyWith(
                  activeConversationId: 'conv-a',
                ),
                agentApps: const [
                  AgentAppItem(
                    id: 'app-company',
                    slug: 'company',
                    name: '我的企业',
                    iconUrl: '',
                  ),
                ],
                onLaunchApp: (_, onPresented) {
                  launchCount++;
                  markPresented = onPresented;
                  return closed.future;
                },
                onPickAttachment: (_) {},
                onPickFromDrive: () {},
                onSend: (_, __) {},
                onStop: () {},
                onLoadMoreHistory: () {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('我的企业'));
    await tester.pump();
    expect(launchCount, 1);
    expect(
      find.byKey(const ValueKey('capability_loading_我的企业')),
      findsOneWidget,
    );

    markPresented!();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('capability_loading_我的企业')),
      findsNothing,
    );

    await tester.tap(find.text('我的企业'));
    await tester.pump();
    expect(launchCount, 1);

    closed.complete();
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('我的企业'));
    await tester.pump();
    expect(launchCount, 2);
  });
}
