import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/skills/services/skill_binding_actions.dart';

void main() {
  test('legacy contact skill summary without installed flag stays bound', () {
    final contact = ContactAgent.fromJson({
      'id': 'agent-1',
      'displayName': '产品运营专家',
      'source': 'personal',
      'lifecycleStatus': 'published',
      'canChat': true,
      'skills': [
        {
          'id': 'skill-1',
          'slug': 'markdown',
          'name': '文档转Markdown'
        },
      ],
    });

    final agent = contact.toAgentItem();

    expect(agent.skills.single.isInstalled, isTrue);
    expect(installedSkillSlugs(agent), const ['markdown']);
  });

  test('explicit uninstalled agent skill state is preserved', () {
    final skill = AgentSkillItem.fromJson(const {
      'slug': 'markdown',
      'name': '文档转Markdown',
      'isInstalled': false,
    });

    expect(skill.isInstalled, isFalse);
  });
}
