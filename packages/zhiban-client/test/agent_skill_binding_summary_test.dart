import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/skills/services/skill_binding_actions.dart';

void main() {
  test('authoritative empty bindings clear stale labels before editing', () {
    final agent = AgentItem.fromJson({
      'uuid': 'agent',
      'apps': <Object>[],
      'knowledge_bases': <Object>[],
      'metadata': {
        'selected_app_labels': {'old-app': 'Old app'},
        'selected_knowledge_base_labels': {'old-kb': 'Old knowledge'},
      },
    });
    final draft = CreateAgentDraft.fromAgentItem(agent);
    expect(agent.configuredAppLabels, isEmpty);
    expect(agent.configuredKnowledgeBaseLabels, isEmpty);
    expect(draft.appUuids, isEmpty);
    expect(draft.knowledgeBaseUuids, isEmpty);
  });

  test('legacy labels remain available only when binding arrays are absent', () {
    final agent = AgentItem.fromJson({
      'uuid': 'legacy',
      'metadata': {
        'selected_app_labels': {'app': 'Calendar'},
        'selected_knowledge_base_labels': {'kb': 'Reference'},
      },
    });
    expect(CreateAgentDraft.fromAgentItem(agent).appUuids, ['app']);
    expect(CreateAgentDraft.fromAgentItem(agent).knowledgeBaseUuids, ['kb']);
  });

  test('real app and knowledge summaries replace stale metadata in edit draft', () {
    final agent = AgentItem.fromJson({
      'uuid': 'agent',
      'apps': [
        {'uuid': 'calendar', 'code': 'schedule', 'name': 'Calendar',
          'icon_url': 'calendar.png'},
      ],
      'knowledge_bases': [
        {'uuid': 'reference', 'name': 'Reference'},
      ],
      'metadata': {
        'selected_app_labels': {'old-app': 'Old app'},
        'selected_knowledge_base_labels': {'old-kb': 'Old knowledge'},
      },
    });
    expect(agent.apps.single.id, 'calendar');
    expect(agent.apps.single.iconUrl, 'calendar.png');
    final draft = CreateAgentDraft.fromAgentItem(agent);
    expect(draft.appUuids, ['calendar']);
    expect(draft.appLabels, {'calendar': 'Calendar'});
    expect(draft.knowledgeBaseUuids, ['reference']);
    expect(draft.knowledgeBaseLabels, {'reference': 'Reference'});
  });

  test('contact conversion preserves department and execution identity', () {
    final contact = ContactAgent.fromJson({
      'id': 'local-codex',
      'displayName': 'Legal assistant',
      'departmentName': 'Legal',
      'positionLabel': 'Adviser',
      'execution_locus': 'local',
      'local_engine': 'codex_app_server',
    });
    final agent = contact.toAgentItem();
    expect(agent.departmentName, 'Legal');
    expect(agent.positionLabel, 'Adviser');
    expect(agent.localEngine, 'codex_app_server');
    final restored = ContactAgent.fromAgentItem(agent);
    expect(restored.departmentName, 'Legal');
    expect(restored.localEngine, 'codex_app_server');
  });

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
