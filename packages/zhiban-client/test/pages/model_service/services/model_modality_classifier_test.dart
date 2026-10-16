import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/model_service/services/model_modality_classifier.dart';

void main() {
  group('guessVendorGroup', () {
    test('groups a dash-less base model with its dashed siblings', () {
      expect(guessVendorGroup('k3'), 'k3');
      expect(guessVendorGroup('k3-256k'), 'k3');
    });

    test('takes the prefix before the first dash', () {
      expect(guessVendorGroup('deepseek-v3.2'), 'deepseek');
    });

    test('strips a trailing version number before matching a family', () {
      expect(guessVendorGroup('qwen3-235b-a22b'), 'alibaba');
      expect(guessVendorGroup('qwen-max-latest'), 'alibaba');
    });

    test('canonicalizes known aliases to one shared group', () {
      expect(guessVendorGroup('chatgpt-4o-latest'), 'openai');
      expect(guessVendorGroup('gpt-4.1'), 'openai');
    });

    test('returns null for a namespaced modelId', () {
      expect(guessVendorGroup('Qwen/Qwen3.7-Plus'), isNull);
    });

    test('returns null for a leading-dash or too-short prefix', () {
      expect(guessVendorGroup('-oops'), isNull);
      expect(guessVendorGroup('a'), isNull);
      expect(guessVendorGroup('a-b'), isNull);
    });
  });
}
