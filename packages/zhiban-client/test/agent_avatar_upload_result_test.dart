import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';

void main() {
  group('AgentAvatarUploadResult', () {
    test('keeps storage URI separate from signed display URL', () {
      final result = AgentAvatarUploadResult.fromJson({
        'storage_uri': 'oss://agent-avatars/avatar.png',
        'signed_url': 'https://oss.example/avatar.png?signature=short-lived',
      });

      expect(result.storageUri, 'oss://agent-avatars/avatar.png');
      expect(
        result.displayUrl,
        'https://oss.example/avatar.png?signature=short-lived',
      );
    });

    test('rejects an upload response without a displayable URL', () {
      expect(
        () => AgentAvatarUploadResult.fromJson({
          'storage_uri': 'oss://agent-avatars/avatar.png',
          'signed_url': 'oss://agent-avatars/avatar.png',
        }),
        throwsException,
      );
    });
  });

  group('selectAgentAvatarForDisplay', () {
    test('uses upload signed URL instead of the persisted OSS URI', () {
      final selected = selectAgentAvatarForDisplay(
        draftDisplayUrl: 'https://oss.example/new.png?signature=1',
        draftAvatarUrl: 'oss://agent-avatars/new.png',
        agentAvatarUrl: 'oss://agent-avatars/new.png',
        fallbackAvatarUrl: 'https://oss.example/old.png?signature=0',
      );

      expect(selected, 'https://oss.example/new.png?signature=1');
    });

    test('skips unsigned OSS references and keeps a loadable fallback', () {
      final selected = selectAgentAvatarForDisplay(
        draftAvatarUrl: 'oss://agent-avatars/new.png',
        agentAvatarUrl: 'oss://agent-avatars/new.png',
        fallbackAvatarUrl: '/api/agent-bus/v1/assets/agent-avatars/default.jpg',
      );

      expect(
        selected,
        '/api/agent-bus/v1/assets/agent-avatars/default.jpg'
      );
    });

    test('returns empty when no candidate is displayable', () {
      final selected = selectAgentAvatarForDisplay(
        draftAvatarUrl: 'oss://agent-avatars/new.png',
        agentAvatarUrl: 'oss://agent-avatars/new.png',
      );

      expect(selected, isEmpty);
    });
  });
}
