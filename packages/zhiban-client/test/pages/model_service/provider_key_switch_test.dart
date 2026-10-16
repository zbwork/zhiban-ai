import 'dart:async';
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/providers/model_service_providers.dart';
import 'package:zhiban_client/pages/model_service/providers/managed_model_service_provider.dart';
import 'package:zhiban_client/pages/model_service/widgets/provider_detail_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeProviders extends ModelProvidersNotifier {
  final pending = <Completer<String?>>[];
  final writes = <String>[];
  @override
  Future<List<AiProviderConfig>> build() async => [
        AiProviderConfig(
            id: 'bee',
            name: 'BeeBridge',
            catalogId: 'beebridge',
            baseUrl: 'https://example.com'),
        AiProviderConfig(
            id: 'ali', name: '阿里云百炼', baseUrl: 'https://example.com'),
      ];
  @override
  Future<String?> readApiKey(String id) {
    final c = Completer<String?>();
    pending.add(c);
    return c.future;
  }

  @override
  Future<void> setApiKey(String id, String value) async {
    writes.add('$id:$value');
  }
}

void main() {
  testWidgets(
      'switching from managed key never saves old text; actual edits still save',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fake = FakeProviders();
    final selected = ValueNotifier('bee');
    addTearDown(selected.dispose);
    final container = ProviderContainer(overrides: [
      modelProvidersProvider.overrideWith(() => fake),
      managedModelServiceProvider.overrideWith((ref) async =>
          const ManagedModelService(
              status: 'ready', keyReady: true, models: [], message: '')),
      managedModelKeyProvider.overrideWith((ref) async => 'managed-key'),
    ]);
    addTearDown(container.dispose);
    await container.read(modelProvidersProvider.future);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            builder: BotToastInit(),
            home: Scaffold(
                body: ValueListenableBuilder<String>(
              valueListenable: selected,
              builder: (_, id, __) => ProviderDetailPanel.existing(
                  providerId: id, onMaterialized: (_) {}),
            )))));
    await tester.pumpAndSettle();
    // Initial provider data may not yet exist when initState starts the read.
    for (final c in fake.pending) {
      if (!c.isCompleted) c.complete('managed-key');
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField).first);
    selected.value = 'ali';
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller!.text, isEmpty);
    field.focusNode!.unfocus();
    await tester.pump();
    expect(fake.writes, isEmpty);
    expect(find.text('API 密钥已保存'), findsNothing);
    fake.pending.last.complete('ali-key');
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField).first);
    tester.widget<TextField>(find.byType(TextField).first).focusNode!.unfocus();
    await tester.pump();
    expect(fake.writes, isEmpty);
    await tester.enterText(find.byType(TextField).first, 'edited-key');
    tester.widget<TextField>(find.byType(TextField).first).focusNode!.unfocus();
    await tester.pumpAndSettle();
    expect(fake.writes, ['ali:edited-key']);
    expect(find.text('API 密钥已保存'), findsOneWidget);
  });
}
