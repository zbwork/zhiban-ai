import 'dart:async';
import 'package:flutter/material.dart';
import 'package:zhiban_client/services/conversation_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/pages/local_workspace/local_chat_model_control.dart';
import 'package:zhiban_client/pages/local_workspace/local_model_picker.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';
import 'package:zhiban_client/pages/chat/widgets/model_picker_content.dart';
import 'local_agent_design_test.dart' show host;

class _ChatPickerProviders extends ModelProvidersNotifier {
  @override
  Future<List<AiProviderConfig>> build() async => const [
        AiProviderConfig(
          id: 'bee',
          name: 'BeeBridge',
          enabled: true,
          models: [
            AiModelConfig(
                id: 'kimi', modelId: 'kimi-test', displayName: 'Kimi'),
            AiModelConfig(id: 'gpt', modelId: 'gpt-test', displayName: 'GPT'),
            AiModelConfig(
                id: 'speech', modelId: 'whisper-test', displayName: '语音模型'),
          ],
        ),
      ];
}

void main() {
  testWidgets('社区对话复用模型选择器并返回服务商及模型标识', (tester) async {
    (String, String)? selection;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        modelProvidersProvider.overrideWith(_ChatPickerProviders.new),
        modelCatalogProvider.overrideWith((ref) async =>
            const ModelCatalog(providers: [], modelsByProviderId: {})),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              LocalChatModelControl(
                employee: const {'provider_id': 'bee', 'model_id': 'kimi-test'},
                busy: false,
                permissionMode: 'assist',
                onPermission: (_) async {},
                onSelect: (provider, model) async =>
                    selection = (provider, model),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final trigger = find.byKey(const ValueKey('local-chat-model-button'));
    expect(tester.widget(trigger), isA<LocalModelPicker>());
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    final popup = find.byType(ModelPickerEntry);
    expect(tester.getBottomLeft(popup).dy,
        lessThan(tester.getTopLeft(trigger).dy));
    expect(find.text('语音模型'), findsNothing);
    await tester.tap(find.text('刷新列表'));
    await tester.pumpAndSettle();
    expect(find.text('2 个模型'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'gpt-test');
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPT'));
    await tester.pumpAndSettle();
    expect(selection, ('bee', 'gpt-test'));
    expect(popup, findsNothing);
  });

  for (final dark in [false, true]) {
    testWidgets(
        'model popup filters platforms and preserves model identity ($dark)',
        (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      String? selected;
      final models = [
        const LlmModelOption(
            id: 'bee-qwen',
            label: 'Qwen3 8B',
            modelId: 'Qwen/Qwen3-8B',
            providerId: 'bee',
            providerName: 'BeeBridge'),
        const LlmModelOption(
            id: 'silicon-qwen',
            label: 'Qwen3 8B',
            modelId: 'Qwen/Qwen3-8B',
            providerId: 'silicon',
            providerName: '硅基流动'),
        const LlmModelOption(
            id: 'raw-qwen',
            label: 'Qwen/Qwen3-VL-32B-Thinking',
            modelId: 'Qwen/Qwen3-VL-32B-Thinking',
            providerId: 'bee',
            providerName: 'BeeBridge'),
        for (var i = 0; i < 20; i++)
          LlmModelOption(
              id: 'gemini-$i',
              label: 'gemini-3.1-flash-lite-long-model-name-$i',
              modelId: 'gemini-$i',
              providerId: 'bee',
              providerName: 'BeeBridge'),
      ];
      await tester.pumpWidget(host(
          Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    selected = await showMenu<String>(
                        context: context,
                        position:
                            const RelativeRect.fromLTRB(200, 100, 200, 100),
                        constraints: const BoxConstraints.tightFor(width: 440),
                        items: [
                          ModelPickerEntry(
                            height: 600,
                            models: models,
                            onRefresh: () async => ConversationModelState(
                                models: models, selected: 'bee-qwen'),
                            selected: 'bee-qwen',
                            error: '',
                            modelIcon: (_) =>
                                const Icon(Icons.auto_awesome, size: 22),
                            platform: (model) => SizedBox(
                              width: 105,
                              child: Text(
                                model.providerName,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          ),
                        ]);
                  },
                  child: const Text('打开菜单'))),
          dark: dark));
      await tester.tap(find.text('打开菜单'));
      await tester.pumpAndSettle();
      expect(find.text('23 个模型'), findsOneWidget);
      expect(find.text('当前模型'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Qwen3 VL');
      await tester.pumpAndSettle();
      expect(find.text('Qwen3 VL 32B Thinking'), findsOneWidget);
      expect(find.text('Qwen/Qwen3-VL-32B-Thinking'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('model-platform-silicon')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('model-option-bee-qwen')), findsNothing);
      expect(find.byKey(const ValueKey('model-option-silicon-qwen')),
          findsOneWidget);
      await tester.enterText(find.byType(TextField), 'gemini');
      await tester.pumpAndSettle();
      expect(find.textContaining('未找到匹配的模型'), findsOneWidget);
      expect(find.text('刷新列表').hitTestable(), findsOneWidget);
      expect(find.text('管理模型服务').hitTestable(), findsOneWidget);
      await tester.enterText(find.byType(TextField), ' QWEN ');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('model-option-silicon-qwen')));
      await tester.pumpAndSettle();
      expect(selected, 'silicon-qwen');
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'refresh stays open, preserves filters, reports failures and tolerates dismissal',
      (tester) async {
    var pending = Completer<ConversationModelState>();
    var calls = 0;
    const old = LlmModelOption(
        id: 'old',
        label: 'GPT old',
        providerId: 'bee',
        providerName: 'BeeBridge');
    const added = LlmModelOption(
        id: 'new',
        label: 'GPT new',
        providerId: 'bee',
        providerName: 'BeeBridge');
    const other = LlmModelOption(
        id: 'other',
        label: 'GPT other',
        providerId: 'silicon',
        providerName: '硅基流动');
    await tester.pumpWidget(host(Builder(
        builder: (context) => TextButton(
            onPressed: () => showMenu<String>(
                    context: context,
                    position: const RelativeRect.fromLTRB(100, 10, 100, 10),
                    constraints: const BoxConstraints.tightFor(width: 440),
                    items: [
                      ModelPickerEntry(
                          height: 500,
                          models: const [old, other],
                          selected: 'old',
                          error: '',
                          modelIcon: (_) => const Icon(Icons.auto_awesome),
                          platform: (_) => null,
                          onRefresh: () {
                            calls++;
                            return pending.future;
                          })
                    ]),
            child: const Text('打开菜单')))));
    await tester.tap(find.text('打开菜单'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'GPT');
    await tester.tap(find.byKey(const ValueKey('model-platform-bee')));
    await tester.tap(find.text('刷新列表'));
    await tester.pump();
    expect(find.text('刷新中…'), findsOneWidget);
    await tester.tap(find.text('刷新中…'));
    await tester.tap(find.byKey(const ValueKey('model-option-old')));
    expect(calls, 1);
    expect(find.text('选择模型'), findsOneWidget);
    pending.complete(const ConversationModelState(
        models: [old, added, other], selected: 'old'));
    await tester.pumpAndSettle();
    expect(find.text('3 个模型'), findsOneWidget);
    expect(find.byKey(const ValueKey('model-option-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-option-other')), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'GPT');
    pending = Completer<ConversationModelState>();
    await tester.tap(find.text('刷新列表'));
    await tester.pump();
    pending.complete(const ConversationModelState(error: '模型列表刷新失败，请重试'));
    await tester.pumpAndSettle();
    expect(find.text('模型列表刷新失败，请重试'), findsOneWidget);
    expect(find.text('选择模型'), findsOneWidget);
    pending = Completer<ConversationModelState>();
    await tester.tap(find.text('刷新列表'));
    await tester.pump();
    pending.complete(const ConversationModelState(
        selected: 'old', error: '当前模型已不可用，请切换模型后重试。'));
    await tester.pumpAndSettle();
    expect(find.text('0 个模型'), findsOneWidget);
    expect(find.byKey(const ValueKey('model-option-old')), findsNothing);
    expect(find.text('当前模型已不可用，请切换模型后重试。'), findsOneWidget);
    pending = Completer<ConversationModelState>();
    await tester.tap(find.text('刷新列表'));
    await tester.pump();
    pending.complete(
        const ConversationModelState(models: [other], selected: 'other'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('model-option-other')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-platform-bee')), findsNothing);
    pending = Completer<ConversationModelState>();
    await tester.tap(find.text('刷新列表'));
    await tester.pump();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    pending.complete(const ConversationModelState(models: [added]));
    await tester.pumpAndSettle();
    expect(find.text('选择模型'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
