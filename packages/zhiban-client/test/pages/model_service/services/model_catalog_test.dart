import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/models/catalog_entry.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled catalog features BeeBridge without hard-coded models',
    () async {
      final catalog = await const ModelCatalogLoader().load();

      final provider = catalog.providers.first;
      expect(provider.id, 'beebridge');
      expect(provider.name, 'BeeBridge');
      expect(provider.endpointType, AiEndpointType.openaiCompatible);
      expect(provider.baseUrl, 'https://api.beeaicloud.com/v1');
      expect(provider.defaultFirst, isTrue);
      expect(provider.iconAssetPath, 'assets/icons/providers/beebridge.svg');
      expect(catalog.modelsFor(provider.id), isEmpty);
    },
  );

  group('ModelCatalog.endpointTypeFor', () {
    const catalog = ModelCatalog(
      providers: [
        CatalogProviderEntry(
          id: 'anthropic',
          name: 'Anthropic',
          endpointType: AiEndpointType.anthropicMessages,
          baseUrl: 'https://api.anthropic.com',
        ),
      ],
      modelsByProviderId: <String, List<CatalogModelEntry>>{},
    );

    test('uses read-only metadata for a catalog provider', () {
      const provider = AiProviderConfig(
        id: 'provider-1',
        name: 'Anthropic',
        catalogId: 'anthropic',
      );

      expect(
        catalog.endpointTypeFor(provider),
        AiEndpointType.anthropicMessages,
      );
    });

    test('defaults a custom provider to OpenAI-compatible', () {
      const provider = AiProviderConfig(
        id: 'provider-2',
        name: 'Private Gateway',
      );

      expect(
        catalog.endpointTypeFor(provider),
        AiEndpointType.openaiCompatible,
      );
    });
  });
}
