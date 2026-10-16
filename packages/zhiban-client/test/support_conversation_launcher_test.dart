import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/services/agent_conversation_launcher.dart';
import 'package:zhiban_core/contacts/contact_models.dart';

void main() {
  test('已有知办客服单聊时直接复用会话里的数字员工身份', () {
    final agent = findZhibanSupportAgentFromConversations([
      const ConversationItem(
        conversationId: 'conv-support',
        title: '知办客服',
        agentId: 'agent-support',
        agentName: '知办客服',
        agentAvatarUrl: 'support.png',
        kind: 'agent_direct',
      ),
      const ConversationItem(
        conversationId: 'group-support',
        title: '知办客服',
        agentId: 'agent-in-group',
        agentName: '知办客服',
        kind: 'group',
      ),
    ]);

    expect(agent?.agentId, 'agent-support');
    expect(agent?.agentKey, zhibanSupportAgentKey);
    expect(agent?.avatarUrl, 'support.png');
  });

  test('无会话时优先选择目录中的非个人知办客服副本', () {
    ContactAgent contact({
      required String id,
      required String source,
      bool canChat = true,
    }) {
      return ContactAgent(
        id: id,
        displayName: zhibanSupportAgentName,
        avatarUrl: '',
        subtitle: '',
        positionLabel: '',
        departmentName: '',
        source: source,
        skills: const [],
        apps: const [],
        lifecycleStatus: 'published',
        canChat: canChat,
      );
    }

    final agent = findZhibanSupportAgentFromContacts([
      contact(id: 'personal-copy', source: 'personal'),
      contact(id: 'tenant-copy', source: 'enterprise'),
    ]);

    expect(agent?.agentId, 'tenant-copy');
    expect(agent?.agentKey, zhibanSupportAgentKey);
    expect(
      findZhibanSupportAgentFromContacts([
        contact(id: 'personal-only', source: 'personal'),
      ]),
      isNull,
      reason: '不得把用户自建的同名数字员工冒充平台知办客服',
    );
  });
}
