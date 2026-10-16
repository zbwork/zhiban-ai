import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/models/catalog_entry.dart';
import 'package:zhiban_client/pages/model_service/services/provider_model_fetcher.dart';
import 'package:zhiban_client/pages/model_service/widgets/add_model_dialog.dart';

class _FakeProviderModelFetcher extends ProviderModelFetcher {
  const _FakeProviderModelFetcher(this.result);

  final ProviderModelFetchResult result;

  @override
  Future<ProviderModelFetchResult> fetch({
    required AiEndpointType endpointType,
    required String baseUrl,
    required String apiKey,
    Map<String, String> customHeaders = const <String, String>{},
    String? catalogId,
  }) async =>
      result;
}

/// 「获取模型列表」和「添加模型」现在是两个独立入口（照抄 Cherry Studio 服务
/// 商详情页的按钮布局，2026-09-03 反馈）：前者打开统一模型管理列表，后者传
/// `AddModelDialogMode.manual` 直接落到手动表单。
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const provider = AiProviderConfig(
    id: 'provider-1',
    name: 'Example',
    baseUrl: 'https://api.example.com/v1',
  );

  testWidgets(
    '"获取模型列表" has no source switch and falls back to the catalog',
    (tester) async {
      const catalogModel = CatalogModelEntry(
        providerId: 'provider-1',
        modelId: 'catalog-model',
        displayName: '内置模型',
        groupName: 'Example',
        capabilities: {},
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAddModelDialog(
                  context,
                  provider: provider,
                  endpointType: AiEndpointType.custom,
                  catalogModels: const [catalogModel],
                  apiKey: 'test-key',
                  baseUrl: provider.baseUrl,
                  ensureLocalId: () async => provider.id,
                ),
                child: const Text('获取模型列表'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('获取模型列表'));
      await tester.pumpAndSettle();

      expect(find.text('内置模型'), findsOneWidget);
      expect(find.text('模型标识'), findsNothing);
      expect(find.byTooltip('内置目录'), findsNothing);
      expect(find.byTooltip('从服务商拉取'), findsNothing);
      expect(find.byTooltip('手动添加'), findsNothing);
    }
  );

  testWidgets(
    'successful discovery shows only live models without catalog or stale rows',
    (tester) async {
      var materializeCalls = 0;
      const providerWithLocalModel = AiProviderConfig(
        id: 'provider-1',
        name: 'Example',
        baseUrl: 'https://api.example.com/v1',
        models: [
          AiModelConfig(
            id: 'local-model-id',
            modelId: 'local-only-model',
            displayName: '本地模型',
          ),
        ],
      );
      const catalogModels = [
        CatalogModelEntry(
          providerId: 'provider-1',
          modelId: 'overlap-model',
          displayName: '目录重名模型',
          groupName: 'Example',
          capabilities: {},
        ),
        CatalogModelEntry(
          providerId: 'provider-1',
          modelId: 'catalog-only-model',
          displayName: '目录补齐模型',
          groupName: 'Example',
          capabilities: {},
        ),
      ];
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAddModelDialog(
                  context,
                  provider: providerWithLocalModel,
                  endpointType: AiEndpointType.openaiCompatible,
                  catalogModels: catalogModels,
                  apiKey: 'test-key',
                  baseUrl: providerWithLocalModel.baseUrl,
                  ensureLocalId: () async {
                    materializeCalls += 1;
                    return provider.id;
                  },
                  modelFetcher: const _FakeProviderModelFetcher(
                    ProviderModelFetchResult.ok([
                      FetchedModel(
                        modelId: 'overlap-model',
                        displayName: 'overlap-model',
                      ),
                      FetchedModel(
                        modelId: 'live-only-model',
                        displayName: 'live-only-model',
                      ),
                    ]),
                  ),
                ),
                child: const Text('获取模型列表'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('获取模型列表'));
      await tester.pumpAndSettle();

      expect(find.text('overlap-model'), findsOneWidget);
      expect(find.text('目录重名模型'), findsNothing);
      expect(find.text('live-only-model'), findsOneWidget);
      expect(find.text('目录补齐模型'), findsNothing);
      expect(find.text('本地模型'), findsNothing);
      expect(materializeCalls, 0);
    },
  );

  testWidgets(
    '"添加模型" opens straight into the manual form without extra taps',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAddModelDialog(
                  context,
                  provider: provider,
                  endpointType: AiEndpointType.openaiCompatible,
                  catalogModels: const <CatalogModelEntry>[],
                  apiKey: 'test-key',
                  baseUrl: provider.baseUrl,
                  ensureLocalId: () async => provider.id,
                  mode: AddModelDialogMode.manual,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('模型标识'), findsOneWidget);
    }
  );
}
