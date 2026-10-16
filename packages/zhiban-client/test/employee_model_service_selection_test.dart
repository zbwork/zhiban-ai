import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/widgets/create_agent_dialog.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/providers/managed_model_service_provider.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

class FakeChat extends OpenClawChatService {
  int legacyLists = 0;
  @override
  Future<List<RuntimeEnvironmentOption>> listRuntimeEnvironments() async =>
      const [
        RuntimeEnvironmentOption(
            uuid: 'dsh',
            name: 'DSH',
            framework: 'dsh',
            hostingKind: 'external_endpoint',
            status: 'active',
            enabled: true),
      ];
  @override
  Future<List<LlmModelOption>> listLlmModels(
      {String? runtimeEnvironmentUuid}) async {
    legacyLists++;
    throw StateError('Legacy model list must not be used');
  }
}

class FakeStore extends ModelServiceStore {
  final keyReads = <String>[];
  @override
  Future<List<String>> loadProviderOrder() async => [];
  @override
  Future<List<AiProviderConfig>> loadProviders() async => const [
        AiProviderConfig(
            id: 'bee',
            catalogId: 'beebridge',
            name: 'BeeBridge',
            baseUrl: 'https://api.beeaicloud.com/v1',
            enabled: true,
            models: [
              AiModelConfig(
                  id: 'gpt', modelId: 'gpt-6-astra', displayName: 'GPT'),
              AiModelConfig(
                  id: 'old',
                  modelId: 'old-tenant-model',
                  displayName: 'Old tenant'),
              AiModelConfig(
                  id: 'disabled',
                  modelId: 'disabled-model',
                  displayName: 'Disabled',
                  enabled: false),
              AiModelConfig(
                  id: 'embed',
                  modelId: 'text-embedding-3-small',
                  displayName: 'Embedding'),
            ]),
        AiProviderConfig(
            id: 'custom',
            name: 'Custom',
            baseUrl: 'https://example.invalid/v1',
            enabled: true,
            models: [
              AiModelConfig(
                  id: 'c', modelId: 'custom-chat', displayName: 'Custom Chat')
            ]),
      ];
  @override
  Future<String?> getApiKey(String providerId) async {
    keyReads.add(providerId);
    if (providerId == 'bee') {
      throw StateError('Must not read managed key from BYOK store');
    }
    return 'synthetic-byok-key';
  }
}

const ready = ManagedModelService(
    status: 'ready',
    keyReady: true,
    models: ['gpt-6-astra', 'disabled-model', 'text-embedding-3-small'],
    message: '');

class Harness {
  final chat = FakeChat();
  final store = FakeStore();
  final nav = GlobalKey<NavigatorState>();
  CreateAgentDraft? result;
  Future<void> open(WidgetTester tester,
      {CreateAgentDraft? initial, ManagedModelService status = ready}) async {
    tester.view.physicalSize = const Size(1600, 1800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(ProviderScope(overrides: [
      chatServiceProvider.overrideWith((ref) => chat),
      modelServiceStoreProvider.overrideWithValue(store),
      modelCatalogProvider.overrideWith((ref) async =>
          const ModelCatalog(providers: [], modelsByProviderId: {})),
      managedModelServiceProvider.overrideWith((ref) async => status),
      managedModelAutoSetupProvider.overrideWith((ref) async {}),
    ], child: MaterialApp(navigatorKey: nav, home: const Scaffold())));
    nav.currentState!
        .push<CreateAgentDraft>(MaterialPageRoute(
            builder: (_) => Scaffold(
                body: CreateAgentEditor(
                    compact: false,
                    initialDraft: initial,
                    submitLabel: '保存员工'))))
        .then((value) => result = value);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('高级设置'));
    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
  }

  UiSelect<String> picker(WidgetTester tester) => tester
      .widgetList<UiSelect<String>>(find.byType(UiSelect<String>))
      .firstWhere((s) => s.placeholder == '请选择模型');
  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.text('保存员工'));
    await tester.tap(find.text('保存员工'));
    await tester.pumpAndSettle();
  }
}

CreateAgentDraft draft({String model = 'gpt-6-astra', bool byok = false}) =>
    CreateAgentDraft(
      name: '测试员工',
      description: '',
      avatarUrl: '',
      modelPrimary: model,
      modelSource: byok ? 'byok' : 'platform_whitelist',
      modelServiceEndpointType: byok ? 'openai-compatible' : '',
      modelServiceBaseUrl: byok ? 'https://example.invalid/v1' : '',
      modelServiceModelId: byok ? 'custom-chat' : '',
    );

void main() {
  testWidgets(
      'new employee defaults to member BeeBridge models without a source toggle or legacy request',
      (tester) async {
    addTearDown(tester.view.reset);
    final h = Harness();
    await h.open(tester);
    expect(find.text('平台模型'), findsNothing);
    expect(find.byType(UiSegmentedTabs<String>), findsNothing);
    final picker = h.picker(tester);
    expect(picker.value, 'bee::gpt');
    expect(picker.options.map((o) => o.value), ['bee::gpt', 'custom::c']);
    expect(h.chat.legacyLists, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'editing a BeeBridge employee returns only its model and no BYOK key',
      (tester) async {
    addTearDown(tester.view.reset);
    final h = Harness();
    await h.open(tester, initial: draft());
    await h.save(tester);
    expect(h.result?.modelPrimary, 'gpt-6-astra');
    expect(h.result?.modelServiceApiKey, isNull);
    expect(h.result?.modelSource, 'platform_whitelist');
    expect(h.store.keyReads, isEmpty);
  });

  testWidgets(
      'custom provider still submits its own key and model configuration',
      (tester) async {
    addTearDown(tester.view.reset);
    final h = Harness();
    await h.open(tester, initial: draft(byok: true));
    await h.save(tester);
    expect(h.result?.modelSource, 'byok');
    expect(h.result?.modelServiceModelId, 'custom-chat');
    expect(h.result?.modelServiceApiKey, 'synthetic-byok-key');
    expect(h.store.keyReads, ['custom']);
  });

  testWidgets('another tenant stale model cannot be retained or submitted',
      (tester) async {
    addTearDown(tester.view.reset);
    final h = Harness();
    await h.open(tester, initial: draft(model: 'old-tenant-model'));
    expect(h.picker(tester).value, isNull);
    await h.save(tester);
    expect(h.result, isNull);
    expect(find.text('请选择一个当前可用的模型服务对话模型'), findsOneWidget);
    expect(h.store.keyReads, isEmpty);
  });

  testWidgets(
      'unavailable member catalogue never falls back to local BeeBridge models',
      (tester) async {
    addTearDown(tester.view.reset);
    final h = Harness();
    await h.open(tester,
        initial: draft(),
        status: const ManagedModelService(
            status: 'unavailable',
            keyReady: true,
            models: [],
            message: 'unavailable'));
    expect(h.picker(tester).options.map((o) => o.value), ['custom::c']);
    await h.save(tester);
    expect(h.result, isNull);
  });
  testWidgets(
      'switching a custom employee to BeeBridge clears BYOK fields without reading its key',
      (tester) async {
    addTearDown(tester.view.reset);
    final h = Harness();
    await h.open(tester, initial: draft(byok: true));
    h.picker(tester).onChanged('bee::gpt');
    await tester.pumpAndSettle();
    await h.save(tester);
    expect(h.result?.modelPrimary, 'gpt-6-astra');
    expect(h.result?.modelSource, 'platform_whitelist');
    expect(h.result?.modelServiceBaseUrl, isEmpty);
    expect(h.result?.modelServiceModelId, isEmpty);
    expect(h.result?.modelServiceApiKey, isNull);
    expect(h.store.keyReads, isEmpty);
  });

  testWidgets(
      'switching a BeeBridge employee to a custom provider uses that provider key',
      (tester) async {
    addTearDown(tester.view.reset);
    final h = Harness();
    await h.open(tester, initial: draft());
    h.picker(tester).onChanged('custom::c');
    await tester.pumpAndSettle();
    await h.save(tester);
    expect(h.result?.modelSource, 'byok');
    expect(h.result?.modelPrimary, isEmpty);
    expect(h.result?.modelServiceModelId, 'custom-chat');
    expect(h.store.keyReads, ['custom']);
  });
}
