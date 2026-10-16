import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';

void main() {
  // doc-13 §A: create-on-first-send 哨兵会话辅助函数（卡片点击新会话 → 哨兵 → 首条 /chat/send 建会话后 adopt）。
  group('pending conversation sentinel', () {
    test('pendingConversationFor / agentUuidFromPending round-trip', () {
      final id = pendingConversationFor('de-uuid-123');
      expect(id, 'pending:de-uuid-123');
      expect(isPendingConversation(id), isTrue);
      expect(agentUuidFromPending(id), 'de-uuid-123');
    });

    test('real conversation uuid is NOT pending', () {
      expect(isPendingConversation('conv-abc'), isFalse);
      expect(isPendingConversation(null), isFalse);
      expect(isPendingConversation(''), isFalse);
    });
  });
}
