import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';

class OpenClawDigitalEmployeeService {
  OpenClawDigitalEmployeeService()
      : _chatService = OpenClawChatService(),
        _contactsService = const ContactsService();

  final OpenClawChatService _chatService;
  final ContactsService _contactsService;

  Future<List<AgentItem>> listAgents() => _chatService.listAgents();

  Future<DigitalEmployeeCatalog> listCatalog({String keyword = ''}) async {
    final snapshot = await _contactsService.agents(keyword: keyword);
    return DigitalEmployeeCatalog.fromContactsSnapshot(snapshot);
  }

  Future<AgentItem> createAgent({
    required String name,
    String? description,
    String? internalDescription,
    String? welcomeMsg,
    String? systemPrompt,
    List<String>? tags,
    String? modelPrimary,
    String? visibility,
    String? status,
    String? runtimeEnvironmentUuid,
    String? agentKey,
    bool allowInternetAccess = true,
    bool contactEnabled = true,
    bool allowInviteToGroup = true,
    String? avatarUrl,
    String? position,
    String? positionLabel,
    List<String>? skillSlugs,
    List<String>? appUuids,
    Map<String, String>? appLabels,
    List<String>? knowledgeBaseUuids,
    Map<String, String>? knowledgeBaseLabels,
  }) {
    return _chatService.createAgent(
      name: name,
      description: description,
      internalDescription: internalDescription,
      welcomeMsg: welcomeMsg,
      systemPrompt: systemPrompt,
      tags: tags,
      modelPrimary: modelPrimary,
      visibility: visibility,
      status: status,
      runtimeEnvironmentUuid: runtimeEnvironmentUuid,
      agentKey: agentKey,
      allowInternetAccess: allowInternetAccess,
      contactEnabled: contactEnabled,
      allowInviteToGroup: allowInviteToGroup,
      avatarUrl: avatarUrl,
      position: position,
      positionLabel: positionLabel,
      skillSlugs: skillSlugs,
      appUuids: appUuids,
      appLabels: appLabels,
      knowledgeBaseUuids: knowledgeBaseUuids,
      knowledgeBaseLabels: knowledgeBaseLabels,
    );
  }

  Future<AgentItem> updateAgent({
    required String agentId,
    String? name,
    String? description,
    String? internalDescription,
    String? welcomeMsg,
    String? systemPrompt,
    List<String>? tags,
    String? modelPrimary,
    String? visibility,
    String? status,
    String? runtimeEnvironmentUuid,
    String? agentKey,
    bool? allowInternetAccess,
    bool? contactEnabled,
    bool? allowInviteToGroup,
    String? avatarUrl,
    String? position,
    String? positionLabel,
    List<String>? skillSlugs,
    List<String>? appUuids,
    Map<String, String>? appLabels,
    List<String>? knowledgeBaseUuids,
    Map<String, String>? knowledgeBaseLabels,
  }) {
    return _chatService.updateAgent(
      agentId: agentId,
      name: name,
      description: description,
      internalDescription: internalDescription,
      welcomeMsg: welcomeMsg,
      systemPrompt: systemPrompt,
      tags: tags,
      modelPrimary: modelPrimary,
      visibility: visibility,
      status: status,
      runtimeEnvironmentUuid: runtimeEnvironmentUuid,
      agentKey: agentKey,
      allowInternetAccess: allowInternetAccess,
      contactEnabled: contactEnabled,
      allowInviteToGroup: allowInviteToGroup,
      avatarUrl: avatarUrl,
      position: position,
      positionLabel: positionLabel,
      skillSlugs: skillSlugs,
      appUuids: appUuids,
      appLabels: appLabels,
      knowledgeBaseUuids: knowledgeBaseUuids,
      knowledgeBaseLabels: knowledgeBaseLabels,
    );
  }

  Future<AgentItem> setDefaultAgent(String agentId) =>
      _chatService.setDefaultAgent(agentId);

  Future<void> deleteAgent(String agentId) => _chatService.deleteAgent(agentId);

  // doc-13 §A: createConversation 透传已移除 —— agent-bus 无创建会话端点；
  // 数字员工单聊会话由首条 /chat/send 建会话（create-on-first-send），见 chat_providers.dart。
}

enum DigitalEmployeeCatalogSource {
  personal,
  enterprise,
  platform
}

enum DigitalEmployeeCatalogFilter {
  all,
  platform,
  enterprise,
  personal
}

extension DigitalEmployeeCatalogFilterText on DigitalEmployeeCatalogFilter {
  String get label {
    switch (this) {
      case DigitalEmployeeCatalogFilter.all:
        return '全部';
      case DigitalEmployeeCatalogFilter.platform:
        return '官方';
      case DigitalEmployeeCatalogFilter.enterprise:
        return '组织';
      case DigitalEmployeeCatalogFilter.personal:
        return '我的';
    }
  }
}

class DigitalEmployeeCatalogItem {
  const DigitalEmployeeCatalogItem({
    required this.agent,
    required this.source
  });

  factory DigitalEmployeeCatalogItem.personal(AgentItem agent) {
    return DigitalEmployeeCatalogItem(
      agent: agent,
      source: DigitalEmployeeCatalogSource.personal,
    );
  }

  factory DigitalEmployeeCatalogItem.fromContact(
    ContactAgent contact,
    DigitalEmployeeCatalogSource source,
  ) {
    return DigitalEmployeeCatalogItem(
      agent: contact.toAgentItem(),
      source: source,
    );
  }

  final AgentItem agent;
  final DigitalEmployeeCatalogSource source;

  bool get canEdit => source == DigitalEmployeeCatalogSource.personal;

  String get sourceLabel {
    switch (source) {
      case DigitalEmployeeCatalogSource.personal:
        return '我创建的';
      case DigitalEmployeeCatalogSource.enterprise:
        return '组织创建';
      case DigitalEmployeeCatalogSource.platform:
        return '官方创建';
    }
  }
}

class DigitalEmployeeCatalog {
  const DigitalEmployeeCatalog({
    required this.personal,
    required this.enterprise,
    this.platform = const [],
  });

  /// 平台员工保持独立来源并只读展示；运行时直接引用平台当前发布配置。
  factory DigitalEmployeeCatalog.fromContactsSnapshot(
    ContactAgentsSnapshot snapshot,
  ) {
    return DigitalEmployeeCatalog(
      personal: snapshot.personal
          .map((item) => DigitalEmployeeCatalogItem.fromContact(
                item,
                DigitalEmployeeCatalogSource.personal,
              ))
          .toList(growable: false),
      enterprise: snapshot.enterprise
          .map((item) => DigitalEmployeeCatalogItem.fromContact(
                item,
                DigitalEmployeeCatalogSource.enterprise,
              ))
          .toList(growable: false),
      platform: snapshot.platform
          .map((item) => DigitalEmployeeCatalogItem.fromContact(
                item,
                DigitalEmployeeCatalogSource.platform,
              ))
          .toList(growable: false),
    );
  }

  final List<DigitalEmployeeCatalogItem> personal;
  final List<DigitalEmployeeCatalogItem> enterprise;
  final List<DigitalEmployeeCatalogItem> platform;

  List<DigitalEmployeeCatalogItem> get all => [
        ...personal,
        ...enterprise,
        ...platform,
      ];

  DigitalEmployeeCatalog withPersonalAgent(AgentItem agent) {
    final personalItem = DigitalEmployeeCatalogItem.personal(agent);
    return DigitalEmployeeCatalog(
      personal: [
        personalItem,
        ...personal.where((item) => item.agent.agentId != agent.agentId),
      ],
      enterprise: enterprise
          .where((item) => item.agent.agentId != agent.agentId)
          .toList(growable: false),
      platform: platform
          .where((item) => item.agent.agentId != agent.agentId)
          .toList(growable: false),
    );
  }

  List<DigitalEmployeeCatalogItem> itemsFor(
      DigitalEmployeeCatalogFilter filter) {
    switch (filter) {
      case DigitalEmployeeCatalogFilter.all:
        return all;
      case DigitalEmployeeCatalogFilter.personal:
        return personal;
      case DigitalEmployeeCatalogFilter.enterprise:
        return enterprise;
      case DigitalEmployeeCatalogFilter.platform:
        return platform;
    }
  }
}
