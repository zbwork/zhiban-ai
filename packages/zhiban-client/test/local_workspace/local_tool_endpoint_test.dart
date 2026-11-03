import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/models/ai_endpoint_type.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';
import 'package:zhiban_client/pages/model_service/services/model_catalog_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('BeeBridge tool protocols share provider but use correct base paths', () async {
    final catalog = await const ModelCatalogLoader().load();
    const provider = AiProviderConfig(id: 'fixture', name: 'BeeBridge',
        catalogId: 'beebridge', baseUrl: 'https://api.airick.cn/v1');
    expect(catalog.localToolBaseUrlFor(provider, AiEndpointType.openaiCompatible),
        'https://api.airick.cn/v1');
    expect(catalog.localToolBaseUrlFor(provider, AiEndpointType.anthropicMessages),
        'https://api.airick.cn');
    expect(catalog.localToolBaseUrlFor(provider.copyWith(baseUrl: 'https://other.example/v1'),
        AiEndpointType.anthropicMessages), isNull);
    expect(catalog.localToolBaseUrlFor(const AiProviderConfig(id: 'custom', name: 'custom',
        baseUrl: 'https://custom.example/v1'), AiEndpointType.anthropicMessages), isNull);
    expect(catalog.localToolBaseUrlFor(const AiProviderConfig(id: 'native', name: 'Anthropic',
        catalogId: 'anthropic', baseUrl: 'https://api.anthropic.com'),
        AiEndpointType.anthropicMessages), 'https://api.anthropic.com');
  });
}
