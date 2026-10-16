import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_capability.dart';
import 'package:zhiban_client/pages/model_service/models/ai_model_config.dart';
import 'package:zhiban_client/pages/model_service/models/ai_provider_config.dart';

void main() {
  group('AiProviderConfig', () {
    test('serializes only the current single-endpoint provider shape', () {
      const provider = AiProviderConfig(
        id: 'provider-1',
        name: 'Example',
        baseUrl: 'https://api.example.com/v1',
        enabled: true,
        catalogId: 'example',
        models: [
          AiModelConfig(
            id: 'model-1',
            modelId: 'chat-model',
            displayName: 'Chat Model',
            capabilities: {AiModelCapability.vision},
          ),
        ],
        imageGenerationBaseUrl: 'https://image.example.com',
        imageEditBaseUrl: 'https://edit.example.com',
        customHeaders: {'X-Tenant': 'demo'},
      );

      final json = provider.toJson();

      expect(json['baseUrl'], 'https://api.example.com/v1');
      expect(json, isNot(contains('endpointType')));
      expect(json, isNot(contains('extraEndpointUrls')));
      expect(json['customHeaders'], {'X-Tenant': 'demo'});
    });

    test('round-trips the current provider fields', () {
      final provider = AiProviderConfig.fromJson(const {
        'id': 'provider-1',
        'name': 'Example',
        'baseUrl': 'https://api.example.com/v1',
        'enabled': true,
        'catalogId': 'example',
        'models': <Map<String, dynamic>>[],
        'imageGenerationBaseUrl': 'https://image.example.com',
        'imageEditBaseUrl': 'https://edit.example.com',
        'customHeaders': {'X-Tenant': 'demo'},
      });

      expect(provider.id, 'provider-1');
      expect(provider.baseUrl, 'https://api.example.com/v1');
      expect(provider.enabled, isTrue);
      expect(provider.catalogId, 'example');
      expect(provider.customHeaders, {'X-Tenant': 'demo'});
    });
  });
}
