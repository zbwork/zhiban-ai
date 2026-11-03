import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexwork/pages/local_coding_tools/local_coding_api_settings_dialog.dart';
import 'package:zhiban_client/pages/local_coding_tools/models/local_coding_models.dart';
import 'package:zhiban_client/pages/local_coding_tools/services/local_coding_bridge_client.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';
import 'package:zhiban_ui/widgets/ui_input.dart';
import 'package:zhiban_ui/widgets/ui_search_field.dart';
import 'package:zhiban_client/pages/chat/widgets/model_picker_content.dart';
import 'package:zhiban_client/pages/chat/widgets/local_agent_controls.dart';

class FakeSession implements LocalCodingBridgeSession, LocalCodingBYOKSession {
  Map<String, dynamic>? saved;
  bool existing = false;
  @override
  Set<String> get supportedMethods => {'byok.settings'};
  @override
  Future<void> close() async {}
  @override
  Future<Map<String, dynamic>> byokSettings(
      {required LocalCodingTarget target,
      String? baseUrl,
      String? model,
      String? apiKey,
      bool save = false,
      bool delete = false}) async {
    if (save) saved = {'url': baseUrl, 'model': model, 'key': apiKey};
    return {
      'base_url': existing ? 'https://model.example/v1' : '',
      'model': existing ? 'gpt-demo' : '',
      'key_configured': existing
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeFactory implements LocalCodingBridgeSessionFactory {
  final session = FakeSession();
  @override
  Future<LocalCodingBridgeSession> open() async => session;
}

void main() {
  for (final scenario in [0, 1, 2, 3, 4, 5, 6]) {
    final claude = scenario == 3 || scenario == 4;
    final changeAddress = scenario == 1 || scenario == 2 || scenario == 4;
    final expectedUrl = claude ? 'https://api.airick.cn' : 'https://model.example/v1';
    testWidgets(
        changeAddress
            ? 'changed model service requires reselection'
            : 'imports configured model and reads key only on save',
        (tester) async {
      rootBundle.clear();
      SharedPreferences.setMockInitialValues({});
      ModelServiceStore.clearApiKeyMemoryCache();
      final root = Directory.systemTemp.createTempSync('api-settings-files-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => root.path);
      addTearDown(() {
        ModelServiceStore.clearApiKeyMemoryCache();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
        root.deleteSync(recursive: true);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel(
                  'plugins.it_nomads.com/flutter_secure_storage'),
              (call) async => null);
      const store = ModelServiceStore();
      await store.saveProviders([
        AiProviderConfig(
            catalogId: claude ? 'beebridge' : null,
            id: 'api-settings-test',
            name: '我的服务商',
            enabled: true,
            baseUrl: claude ? 'https://api.airick.cn/v1' : 'https://model.example/v1',
            models: [
              AiModelConfig(id: 'm', modelId: 'gpt-demo', displayName: '测试模型')
            ])
      ]);
      if (scenario != 6) await store.setApiKey('api-settings-test', 'test-only-key');
      if (scenario == 5) await store.saveProviders([]);
      final factory = FakeFactory();
      factory.session.existing = scenario == 2;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => TextButton(
                  onPressed: () => showLocalCodingApiSettings(
                      context, claude ? LocalCodingVendor.claude : LocalCodingVendor.codex,
                      sessionFactory: factory),
                  child: const Text('打开')))));
      await tester.runAsync(() async {
        await tester.tap(find.text('打开'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      for (var i = 0;
          i < 20 && find.byKey(const ValueKey('api-settings-model-button')).evaluate().isEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      if (scenario == 0 || scenario == 3) {
        expect(find.byType(AgentControlButton), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('api-settings-model-button')));
        await tester.pumpAndSettle();
        expect(find.byType(ModelPickerEntry), findsOneWidget);
        final search = find.descendant(of: find.byType(UiSearchField),
            matching: find.byType(TextField));
        await tester.enterText(search, 'gpt-demo');
        await tester.pumpAndSettle();
        expect(find.text('测试模型'), findsOneWidget);
        await tester.tap(find.text('测试模型'));
        await tester.pumpAndSettle();
        expect(find.byType(ModelPickerEntry), findsNothing);
      }
      expect(find.byType(UiInputField), findsNothing);
      expect(find.text('手动填写'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('管理模型服务'), findsOneWidget);
      if (scenario == 5) {
        expect(find.text('暂无兼容模型，请先在模型服务中配置并启用。'), findsOneWidget);
        expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
        return;
      }
      expect(find.text('我的服务商 / 测试模型'), findsOneWidget);
      expect(find.text(expectedUrl), findsOneWidget);
      expect(find.text('gpt-demo'), findsOneWidget);
      expect(find.text('test-only-key'), findsNothing);
      expect(factory.session.saved, isNull);
      if (changeAddress) {
        final providers = await store.loadProviders();
        await store.saveProviders([providers.single.copyWith(
            baseUrl: 'https://other.example/v1')]);
      }
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      if (changeAddress || scenario == 6) {
        expect(factory.session.saved, isNull);
      } else {
        expect(factory.session.saved, {
          'url': expectedUrl,
          'model': 'gpt-demo',
          'key': 'test-only-key'
        });
      }
    });
  }
}
