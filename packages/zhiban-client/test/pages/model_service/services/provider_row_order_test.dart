import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/models/catalog_entry.dart';
import 'package:zhiban_client/pages/model_service/services/provider_row_order.dart';

void main() {
  const beebridge = CatalogProviderEntry(
    id: 'beebridge',
    name: 'BeeBridge',
    endpointType: AiEndpointType.openaiCompatible,
    baseUrl: 'https://api.beeaicloud.com/v1',
    defaultFirst: true,
  );
  const other = CatalogProviderEntry(
    id: 'other',
    name: 'Other',
    endpointType: AiEndpointType.openaiCompatible,
    baseUrl: 'https://api.example.com/v1',
  );

  test('BeeBridge reuses the existing row without adding a second entry', () {
    const personal = AiProviderConfig(
        id: 'personal-bee',
        name: 'BeeBridge',
        catalogId: 'beebridge',
        enabled: true);
    final rows = sortProviderRows(
      localProviders: const [personal],
      catalogProviders: const [beebridge],
      persistedOrder: const [],
    );
    expect(rows.map((row) => row.key), ['personal-bee']);
    expect(rows.last.name, 'BeeBridge');
    expect(rows.last.provider, same(personal));
    expect(rows.last.enabled, isTrue);
  });

  test('puts default-first catalog entry before enabled providers', () {
    const enabledOther = AiProviderConfig(
      id: 'other-local',
      name: 'Other',
      enabled: true,
      catalogId: 'other',
    );

    final rows = sortProviderRows(
      localProviders: const [enabledOther],
      catalogProviders: const [other, beebridge],
      persistedOrder: const [],
    );

    expect(rows.map((row) => row.key), ['catalog:beebridge', 'other-local']);
  });

  test(
    'promotes a new default-first entry missing from an old saved order',
    () {
      final rows = sortProviderRows(
        localProviders: const [],
        catalogProviders: const [other, beebridge],
        persistedOrder: const ['catalog:other'],
      );

      expect(rows.map((row) => row.key), [
        'catalog:beebridge',
        'catalog:other',
      ]);
    },
  );

  test(
    'respects saved user position once it includes the default-first entry',
    () {
      final rows = sortProviderRows(
        localProviders: const [],
        catalogProviders: const [other, beebridge],
        persistedOrder: const ['catalog:other', 'catalog:beebridge'],
      );

      expect(rows.map((row) => row.key), [
        'catalog:other',
        'catalog:beebridge',
      ]);
    },
  );

  test(
    'keeps a materialized default-first entry promoted for an old order',
    () {
      const localBeeBridge = AiProviderConfig(
        id: 'beebridge-local',
        name: 'BeeBridge',
        catalogId: 'beebridge',
      );

      final rows = sortProviderRows(
        localProviders: const [localBeeBridge],
        catalogProviders: const [other, beebridge],
        persistedOrder: const ['catalog:other'],
      );

      expect(rows.map((row) => row.key), ['beebridge-local', 'catalog:other']);
    },
  );
}
