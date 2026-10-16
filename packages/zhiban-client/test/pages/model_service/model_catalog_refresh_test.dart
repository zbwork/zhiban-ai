import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/services/model_service_store.dart';
import 'package:zhiban_client/pages/model_service/services/provider_model_fetcher.dart';
import 'package:zhiban_client/pages/model_service/widgets/add_model_dialog.dart';

const target = AiProviderConfig(id: 'bee', name: 'BeeBridge', models: [
  AiModelConfig(
      id: 'custom-id',
      modelId: 'keep',
      displayName: '我的名称',
      groupName: '我的分组',
      enabled: false),
  AiModelConfig(id: 'removed-id', modelId: 'gone', displayName: '已失效'),
]);
const other = AiProviderConfig(id: 'other', name: 'Other', models: [
  AiModelConfig(id: 'other-id', modelId: 'gone', displayName: '其他平台')],
);

class RefreshStore extends ModelServiceStore {
  List<AiProviderConfig> providers = [target, other];
  String scope = '1039:1';
  int writes = 0;
  @override
  Future<String?> managedScope() async => scope;
  @override
  Future<List<AiProviderConfig>> loadProviders() async => providers;
  @override
  Future<bool> saveManagedSetup(
      List<AiProviderConfig> next, String expected) async {
    if (expected != scope) return false;
    providers = next;
    writes++;
    return true;
  }
}

class RefreshFetcher extends ProviderModelFetcher {
  const RefreshFetcher(this.result, {this.beforeReturn});
  final ProviderModelFetchResult result;
  final VoidCallback? beforeReturn;
  @override
  Future<ProviderModelFetchResult> fetch(
      {required AiEndpointType endpointType,
      required String baseUrl,
      required String apiKey,
      Map<String, String> customHeaders = const {},
      String? catalogId}) async {
    beforeReturn?.call();
    return result;
  }
}

void main() {
  Future<void> open(WidgetTester tester, RefreshStore store,
      ProviderModelFetcher fetcher) async {
    await tester.pumpWidget(ProviderScope(
        overrides: [
          modelServiceStoreProvider.overrideWithValue(store)
        ],
        child: MaterialApp(
            home: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showAddModelDialog(context,
                        provider: target,
                        endpointType: AiEndpointType.openaiCompatible,
                        catalogModels: const [],
                        apiKey: 'fixture',
                        baseUrl: 'https://example.com/v1',
                        ensureLocalId: () async =>
                            throw StateError('must not materialize'),
                        modelFetcher: fetcher),
                    child: const Text('获取模型列表'))))));
    await tester.tap(find.text('获取模型列表'));
    await tester.pumpAndSettle();
  }

  const returned = ProviderModelFetchResult.ok([
    FetchedModel(modelId: 'keep', displayName: 'Remote name'),
    FetchedModel(modelId: 'new', displayName: '新模型'),
  ]);
  testWidgets(
      'click refresh prunes stale models, preserving valid settings and other providers',
      (tester) async {
    final store = RefreshStore();
    await open(tester, store, const RefreshFetcher(returned));
    expect(store.writes, 1);
    expect(store.providers.first.models.single.toJson(),
        target.models.first.toJson());
    expect(store.providers.last.toJson(), other.toJson());
    expect(find.text('已失效'), findsNothing);
    expect(find.text('新模型'), findsOneWidget);
    expect(
        store.providers.first.models.any((m) => m.modelId == 'new'), isFalse);
  });
  testWidgets('failed refresh does not delete configured models',
      (tester) async {
    final store = RefreshStore();
    await open(tester, store,
        const RefreshFetcher(ProviderModelFetchResult.fail('network failed')));
    expect(store.writes, 0);
    expect(store.providers.first.models.length, 2);
    expect(find.text('已失效'), findsOneWidget);
  });
  testWidgets('valid empty catalog clears only the selected provider',
      (tester) async {
    final store = RefreshStore();
    await open(
        tester, store, const RefreshFetcher(ProviderModelFetchResult.ok([])));
    expect(store.providers.first.models, isEmpty);
    expect(store.providers.last.toJson(), other.toJson());
    expect(find.text('没有可用模型'), findsOneWidget);
  });
  testWidgets(
      'late response after tenant switch cannot write the captured configuration',
      (tester) async {
    final store = RefreshStore();
    await open(tester, store,
        RefreshFetcher(returned, beforeReturn: () => store.scope = '1039:2'));
    expect(store.writes, 0);
    expect(store.providers.first.models.length, 2);
  });
}
