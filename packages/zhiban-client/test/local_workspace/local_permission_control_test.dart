import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/widgets/local_agent_controls.dart';
import 'package:zhiban_client/pages/local_workspace/local_chat_model_control.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';

class EmptyProviders extends ModelProvidersNotifier {
  @override
  Future<List<AiProviderConfig>> build() async => [];
}

void main() {
  testWidgets(
      'local permissions reuse original menu and require explicit full confirmation',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final choices = <String>[];
    var mode = 'assist';
    var busy = false;
    late StateSetter update;
    await tester.pumpWidget(ProviderScope(
        overrides: [
          modelProvidersProvider.overrideWith(EmptyProviders.new),
        ],
        child: MaterialApp(
            home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
          update = setState;
          return Align(
              alignment: Alignment.bottomLeft,
              child: LocalChatModelControl(
                employee: const {'id': 'employee'},
                busy: busy,
                permissionMode: mode,
                onPermission: (value) async {
                  choices.add(value);
                  setState(() => mode = value);
                },
                onSelect: (_, __) async {},
              ));
        })))));
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('local-chat-permission-button'));
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(AgentMenuRow), findsNWidgets(3));
    await tester.tap(find.text('请求批准'));
    await tester.pumpAndSettle();
    expect(choices, ['ask']);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('完全访问'));
    await tester.pumpAndSettle();
    expect(find.byType(FullLocalAccessDialog), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认开启'))
            .onPressed,
        isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(choices, ['ask']);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('完全访问'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我了解并接受上述风险'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认开启'));
    await tester.pumpAndSettle();
    expect(choices, ['ask', 'full']);
    update(() => busy = true);
    await tester.pump();
    expect(tester.widget<AgentControlButton>(button).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
