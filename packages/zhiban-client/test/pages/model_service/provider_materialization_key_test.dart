import 'dart:async';
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/models/catalog_entry.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/widgets/provider_detail_panel.dart';

class _MaterializingProviders extends ModelProvidersNotifier {
  final started = Completer<void>();
  final finish = Completer<void>();
  final writes = <String>[];
  var materializations = 0;
  @override
  Future<List<AiProviderConfig>> build() async => [];
  @override
  Future<String> materializeFromCatalog(CatalogProviderEntry entry) async {
    materializations++;
    if (!started.isCompleted) started.complete();
    await finish.future;
    return 'created';
  }

  void publishCreatedRecord() {
    state = const AsyncData([
      AiProviderConfig(
        id: 'created',
        name: 'Test provider',
        catalogId: 'test-provider',
        baseUrl: 'https://default.example.test/v1',
      )
    ]);
  }

  @override
  Future<String?> readApiKey(String id) async => null;
  @override
  Future<void> setApiKey(String id, String value) async {
    writes.add('$id:$value');
  }

  @override
  Future<void> updateProvider(AiProviderConfig value) async {
    state = AsyncData([value]);
  }
}

void main() {
  testWidgets(
      'materializing the selected catalog provider preserves a typed key',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final providers = _MaterializingProviders();
    final container = ProviderContainer(
        overrides: [modelProvidersProvider.overrideWith(() => providers)]);
    addTearDown(container.dispose);
    await container.read(modelProvidersProvider.future);
    const entry = CatalogProviderEntry(
        id: 'test-provider',
        name: 'Test provider',
        endpointType: AiEndpointType.openaiCompatible,
        baseUrl: 'https://default.example.test/v1');
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: BotToastInit(),
          home: Scaffold(body: Consumer(builder: (context, ref, _) {
            final local = ref.watch(modelProvidersProvider).value ?? [];
            return local.isEmpty
                ? ProviderDetailPanel.draft(
                    catalogEntry: entry, onMaterialized: (_) {})
                : ProviderDetailPanel.existing(
                    providerId: local.single.id, onMaterialized: (_) {});
          })),
        )));
    await tester.pumpAndSettle();
    final keyField = find.byType(TextField).at(0);
    final addressField = find.byType(TextField).at(1);
    await tester.enterText(addressField, 'https://member.example.test/v1');
    await tester.tap(keyField);
    await tester.pump();
    expect(providers.started.isCompleted, isTrue);
    await tester.enterText(keyField, 'typed-fixture-key');
    tester.widget<TextField>(keyField).focusNode!.unfocus();
    await tester.pump();
    expect(providers.materializations, 1);
    providers.publishCreatedRecord();
    await tester.pump();
    await tester.pump();
    expect(tester.widget<TextField>(keyField).controller!.text,
        'typed-fixture-key');
    providers.finish.complete();
    await tester.pumpAndSettle();
    tester.widget<TextField>(keyField).focusNode!.unfocus();
    await tester.pumpAndSettle();
    expect(providers.writes, ['created:typed-fixture-key']);
    expect(providers.materializations, 1);
  });
}
