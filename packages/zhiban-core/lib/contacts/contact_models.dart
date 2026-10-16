import 'package:zhiban_core/chat/chat_models.dart';

class ContactDepartment {
  const ContactDepartment({
    required this.id,
    required this.name,
    required this.parentId,
    required this.depth,
    required this.humanCount,
    required this.agentCount,
    required this.children,
  });

  final String id;
  final String name;
  final String parentId;
  final int depth;
  final int humanCount;
  final int agentCount;
  final List<ContactDepartment> children;

  ContactDepartment copyWith({
    List<ContactDepartment>? children,
  }) {
    return ContactDepartment(
      id: id,
      name: name,
      parentId: parentId,
      depth: depth,
      humanCount: humanCount,
      agentCount: agentCount,
      children: children ?? this.children,
    );
  }

  factory ContactDepartment.fromJson(Map<String, dynamic> json) {
    final rawChildren = json['children'];
    return ContactDepartment(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      parentId: (json['parentId'] ?? json['parent_id'] ?? '').toString(),
      depth: (json['depth'] as num?)?.toInt() ?? 0,
      humanCount: (json['humanCount'] as num?)?.toInt() ?? 0,
      agentCount: (json['agentCount'] as num?)?.toInt() ?? 0,
      children: rawChildren is List
          ? rawChildren
              .whereType<Map>()
              .map((e) => ContactDepartment.fromJson(e.cast<String, dynamic>()))
              .toList(growable: false)
          : const <ContactDepartment>[],
    );
  }

  /// 本地缓存用(扁平, 不含 children——落盘的是拉树前的扁平列表)。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'parentId': parentId,
        'depth': depth,
        'humanCount': humanCount,
        'agentCount': agentCount,
      };
}

List<ContactDepartment> buildContactDepartmentTree(
  List<ContactDepartment> flat,
) {
  if (flat.isEmpty) return const <ContactDepartment>[];
  final childrenByParent = <String, List<ContactDepartment>>{};
  final ids = flat.map((item) => item.id).toSet();
  for (final item in flat) {
    childrenByParent.putIfAbsent(item.parentId, () => []).add(item);
  }

  ContactDepartment attach(ContactDepartment item) {
    final children = childrenByParent[item.id] ?? const <ContactDepartment>[];
    return item.copyWith(
      children: children.map(attach).toList(growable: false),
    );
  }

  return flat
      .where((item) => item.parentId.isEmpty || !ids.contains(item.parentId))
      .map(attach)
      .toList(growable: false);
}

class ContactPerson {
  const ContactPerson({
    required this.kind,
    required this.id,
    required this.displayName,
    required this.avatarUrl,
    required this.subtitle,
    required this.positionLabel,
    required this.departmentId,
    required this.departmentName,
    required this.source,
    required this.skills,
    required this.apps,
    required this.lifecycleStatus,
    required this.canChat,
    this.canInviteToRoom = true,
  });

  final String kind;
  final String id;
  final String displayName;
  final String avatarUrl;
  final String subtitle;
  final String positionLabel;
  final String departmentId;
  final String departmentName;
  final String source;
  final List<AgentSkillItem> skills;
  final List<AgentAppItem> apps;
  final String lifecycleStatus;
  final bool canChat;

  /// 后端 /contacts 字段 canInviteToRoom: 是否允许把该成员拉进群聊。
  /// 来源 (后端 isInvitableAgentContact / CanInviteHuman):
  ///   - agent: 当前用户可见 + allow_invite_to_group + 租户 policy 允许
  ///   - human: 成员 metadata.allow_invite_to_group + 租户 policy (HumansDefaultInvitable 兜底)
  /// false → create_group_dialog 必须把对应卡片**禁用/不可勾选**, 否则提交时 CanCreateGroup
  /// 会被后端拒, 错误码区分 agent_not_invitable / agent_not_visible / member_not_invitable。
  final bool canInviteToRoom;

  bool get isAgent => kind == 'agent';
  bool get isHuman => kind == 'human';

  factory ContactPerson.fromJson(Map<String, dynamic> json) {
    final rawSkills = json['skills'];
    final rawApps = json['apps'];
    return ContactPerson(
      kind: (json['kind'] ?? '').toString(),
      id: (json['id'] ?? '').toString(),
      displayName: (json['displayName'] ?? '').toString(),
      avatarUrl: (json['avatarUrl'] ?? '').toString(),
      subtitle: (json['subtitle'] ?? '').toString(),
      positionLabel: (json['positionLabel'] ?? '').toString(),
      departmentId:
          (json['departmentId'] ?? json['department_id'] ?? '').toString(),
      departmentName: (json['departmentName'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
      skills: rawSkills is List
          ? rawSkills
              .whereType<Map<String, dynamic>>()
              .map(AgentSkillItem.fromJson)
              .toList(growable: false)
          : const <AgentSkillItem>[],
      apps: rawApps is List
          ? rawApps
              .whereType<Map<String, dynamic>>()
              .map(AgentAppItem.fromJson)
              .toList(growable: false)
          : const <AgentAppItem>[],
      lifecycleStatus: (json['lifecycleStatus'] ?? '').toString(),
      canChat: json['canChat'] == true,
      // 后端默认带回；老接口没透传时按 true 兼容，实际提交仍由服务端预检。
      canInviteToRoom: json['canInviteToRoom'] == false ? false : true,
    );
  }

  /// 本地缓存用。skills/apps 不进本地缓存(通讯录/群成员选择器都不渲染这两个
  /// 字段——渲染它们的数字员工广场走独立的 contactAgentsProvider/ContactAgent，
  /// 不经过这个缓存)，磁盘快照里留空、等下一次后台 refresh 用网络数据整体替换。
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'id': id,
        'displayName': displayName,
        'avatarUrl': avatarUrl,
        'subtitle': subtitle,
        'positionLabel': positionLabel,
        'departmentId': departmentId,
        'departmentName': departmentName,
        'source': source,
        'lifecycleStatus': lifecycleStatus,
        'canChat': canChat,
        'canInviteToRoom': canInviteToRoom,
      };
}

class ContactAgent {
  const ContactAgent({
    required this.id,
    required this.displayName,
    required this.avatarUrl,
    required this.subtitle,
    required this.positionLabel,
    required this.departmentName,
    required this.source,
    required this.skills,
    required this.apps,
    required this.lifecycleStatus,
    required this.canChat,
    this.canInviteToRoom = false,
    this.executionLocus = 'cloud',
    this.localEngine = 'dsh',
    this.supportsModelSelection = false,
    this.modelSource = 'platform_whitelist',
    this.modelServiceModelId = '',
    this.configuredAppLabels = const {},
    this.configuredKnowledgeBaseLabels = const {},
  });

  final String id;
  final String displayName;
  final String avatarUrl;
  final String subtitle;
  final String positionLabel;
  final String departmentName;
  final String source;
  final List<AgentSkillItem> skills;
  final List<AgentAppItem> apps;
  final String lifecycleStatus;
  final bool canChat;
  final String executionLocus, localEngine, modelSource, modelServiceModelId;
  final bool supportsModelSelection;

  /// 真实绑定的应用 / 知识库 {uuid: name}（后端 hydrate）。数字员工画廊的
  /// 卡片经 [toAgentItem] 消费；此前转换链路丢掉这两个字段，导致卡片上
  /// 知识库行消失（编辑回显却正常，因为编辑走 GET /agents/{uuid} 直读）。
  final Map<String, String> configuredAppLabels;
  final Map<String, String> configuredKnowledgeBaseLabels;

  /// 后端 `/contacts/agents` 的 `canInviteToRoom` 字段:
  ///  - false: 数字员工不允许被拉入群聊（不可见、`allow_invite_to_group=false` 或租户 policy
  ///    禁用数字员工群聊）。create_group_dialog 据此**置灰**对应卡片并禁止勾选；
  ///    异常提交仍由后端 CanCreateGroup 拒绝。
  ///  - true: 可以勾选 + 提交; CanCreateGroup 同口径放行。
  final bool canInviteToRoom;

  bool get editable => source == 'personal';

  AgentItem toAgentItem() {
    return AgentItem(
      agentId: id,
      executionLocus: executionLocus,
      localEngine: localEngine,
      supportsModelSelection: supportsModelSelection,
      modelSource: modelSource,
      modelServiceModelId: modelServiceModelId,
      name: displayName,
      description: subtitle,
      avatarUrl: avatarUrl,
      position: '',
      positionLabel: positionLabel.isNotEmpty ? positionLabel : departmentName,
      skills: skills,
      apps: apps,
      configuredAppLabels: configuredAppLabels,
      configuredKnowledgeBaseLabels: configuredKnowledgeBaseLabels,
      status: lifecycleStatus,
      isDefault: false,
      syncStatus: '',
      lastSyncedAt: null,
    );
  }

  factory ContactAgent.fromJson(Map<String, dynamic> json) {
    final rawSkills = json['skills'];
    final rawApps = json['apps'];
    return ContactAgent(
      id: (json['id'] ?? '').toString(),
      localEngine:
          (json['local_engine'] ?? json['LocalEngine'] ?? 'dsh').toString(),
      executionLocus: (json['execution_locus'] ?? 'cloud').toString(),
      supportsModelSelection: json['supports_model_selection'] == true,
      modelSource: (json['model_source'] ?? 'platform_whitelist').toString(),
      modelServiceModelId: (json['model_service_model_id'] ?? '').toString(),
      displayName: (json['displayName'] ?? '').toString(),
      avatarUrl: (json['avatarUrl'] ?? '').toString(),
      subtitle: (json['subtitle'] ?? '').toString(),
      positionLabel: (json['positionLabel'] ?? '').toString(),
      departmentName: (json['departmentName'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
      skills: rawSkills is List
          ? rawSkills
              .whereType<Map<String, dynamic>>()
              .map(AgentSkillItem.fromJson)
              .toList(growable: false)
          : const <AgentSkillItem>[],
      apps: rawApps is List
          ? rawApps
              .whereType<Map<String, dynamic>>()
              .map(AgentAppItem.fromJson)
              .toList(growable: false)
          : const <AgentAppItem>[],
      lifecycleStatus: (json['lifecycleStatus'] ?? '').toString(),
      canChat: json['canChat'] == true,
      canInviteToRoom: json['canInviteToRoom'] == true,
      // /contacts/agents 卡片 DTO 若带 hydrate 的应用/知识库则透传（uuid+name 列表）。
      configuredAppLabels: _uuidNameMap(json['apps']),
      configuredKnowledgeBaseLabels: _uuidNameMap(json['knowledge_bases']),
    );
  }

  factory ContactAgent.fromAgentItem(AgentItem item) {
    return ContactAgent(
      id: item.agentId,
      executionLocus: item.executionLocus,
      localEngine: item.localEngine,
      supportsModelSelection: item.supportsModelSelection,
      modelSource: item.modelSource,
      modelServiceModelId: item.modelServiceModelId,
      displayName: item.displayName,
      avatarUrl: item.avatarUrl,
      subtitle: item.description,
      positionLabel: item.positionLabel,
      departmentName: '',
      source: 'personal',
      skills: item.skills,
      apps: item.apps,
      lifecycleStatus: item.status,
      canChat: true,
      // AgentItem 来自老链路(本地用户自建草稿)默认可邀请;
      // /contacts/agents fromJson 才是后端权威值。
      canInviteToRoom: true,
      configuredAppLabels: item.configuredAppLabels,
      configuredKnowledgeBaseLabels: item.configuredKnowledgeBaseLabels,
    );
  }

  /// 解析后端 hydrate 的 `[{uuid,name}]` 为 {uuid: name}；非法形态返回空表。
  static Map<String, String> _uuidNameMap(dynamic raw) {
    if (raw is! List) return const <String, String>{};
    final out = <String, String>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final uuid = (item['uuid'] ?? item['id'] ?? '').toString().trim();
      if (uuid.isEmpty) continue;
      final name = (item['name'] ?? '').toString().trim();
      out[uuid] = name.isEmpty ? uuid : name;
    }
    return out;
  }
}

class ContactAgentsSnapshot {
  const ContactAgentsSnapshot({
    required this.personal,
    required this.enterprise,
    required this.platform,
  });

  final List<ContactAgent> personal;
  final List<ContactAgent> enterprise;
  final List<ContactAgent> platform;

  List<ContactAgent> get all => [
        ...personal,
        ...enterprise,
        ...platform,
      ];

  int get total => personal.length + enterprise.length + platform.length;
}
