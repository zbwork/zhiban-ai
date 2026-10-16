import 'package:flutter_test/flutter_test.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';

void main() {
  group('DigitalEmployeeCatalog.withPersonalAgent', () {
    test('adds created agent to the front of personal list', () {
      final existing = _agent('agent-existing', 'Existing');
      final created = _agent('agent-created', 'Created');
      const catalog = DigitalEmployeeCatalog(
        personal: [],
        enterprise: []
      );

      final next = catalog.withPersonalAgent(created);

      expect(next.personal.map((item) => item.agent.agentId), [
        'agent-created',
      ]);
      expect(next.enterprise, isEmpty);

      final nextAgain = DigitalEmployeeCatalog(
        personal: [DigitalEmployeeCatalogItem.personal(existing)],
        enterprise: [],
      ).withPersonalAgent(created);

      expect(nextAgain.personal.map((item) => item.agent.agentId), [
        'agent-created',
        'agent-existing',
      ]);
    });

    test('moves a matching enterprise item into personal only once', () {
      final created = _agent('agent-created', 'Created');
      final otherEnterprise = _agent('agent-enterprise', 'Enterprise');
      final catalog = DigitalEmployeeCatalog(
        personal: [DigitalEmployeeCatalogItem.personal(_agent('p1', 'P1'))],
        enterprise: [
          DigitalEmployeeCatalogItem(
            agent: created,
            source: DigitalEmployeeCatalogSource.enterprise,
          ),
          DigitalEmployeeCatalogItem(
            agent: otherEnterprise,
            source: DigitalEmployeeCatalogSource.enterprise,
          ),
        ],
      );

      final next = catalog.withPersonalAgent(created);

      expect(next.personal.map((item) => item.agent.agentId), [
        'agent-created',
        'p1',
      ]);
      expect(next.enterprise.map((item) => item.agent.agentId), [
        'agent-enterprise',
      ]);
    });
  });

  test('keeps platform employees in an independent read-only bucket', () {
    final platform = _agent('platform-1', 'Platform');
    final snapshot = ContactAgentsSnapshot(
      personal: const [],
      enterprise: const [],
      platform: [ContactAgent.fromAgentItem(platform)],
    );

    final catalog = DigitalEmployeeCatalog.fromContactsSnapshot(snapshot);

    expect(catalog.enterprise, isEmpty);
    expect(catalog.platform.single.agent.agentId, 'platform-1');
    expect(catalog.platform.single.sourceLabel, '官方创建');
    expect(catalog.platform.single.canEdit, isFalse);
    expect(catalog.itemsFor(DigitalEmployeeCatalogFilter.platform),
        catalog.platform);
    expect(catalog.all.single.agent.agentId, 'platform-1');
  });

  test('orders compact catalog tabs with official employees first', () {
    expect(
      DigitalEmployeeCatalogFilter.values,
      [
        DigitalEmployeeCatalogFilter.all,
        DigitalEmployeeCatalogFilter.platform,
        DigitalEmployeeCatalogFilter.enterprise,
        DigitalEmployeeCatalogFilter.personal,
      ]
    );
    expect(
      DigitalEmployeeCatalogFilter.values.map((filter) => filter.label),
      ['全部', '官方', '组织', '我的']
    );
  });

  group('AgentItem detail response', () {
    test('parses editable fields returned by /agents/{uuid}', () {
      final agent = AgentItem.fromJson({
        'uuid': 'agent-1',
        'name': '消防',
        'intro': '负责灭火',
        'avatar_url': 'https://cdn.example/avatar.png',
        'runtime_environment_uuid': 'rt-zap',
        'metadata': {
          'agent_key': 'main',
          'selected_app_labels': {'calendar': '日程'},
          'selected_knowledge_base_labels': {'kb-1': '消防知识库'},
        },
        'skills': [
          {
            'slug': 'fire_safety',
            'skillName': '消防问答',
            'status': 'active',
            'isInstalled': true,
          }
        ],
        'status': 'published',
      });

      expect(agent.avatarUrl, 'https://cdn.example/avatar.png');
      expect(agent.runtimeEnvironmentUuid, 'rt-zap');
      expect(agent.agentKey, 'main');
      expect(agent.skills.single.slug, 'fire_safety');
      expect(agent.configuredAppLabels, {'calendar': '日程'});
      expect(agent.configuredKnowledgeBaseLabels, {'kb-1': '消防知识库'});
    });
  });
}

AgentItem _agent(String id, String name) {
  return AgentItem(
    agentId: id,
    name: name,
    description: '',
    avatarUrl: '',
    status: 'published',
    isDefault: false,
    syncStatus: 'synced',
    lastSyncedAt: null,
  );
}
