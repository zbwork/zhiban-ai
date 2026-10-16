import 'package:zhiban_client/network/network.dart';

/// F09 群聊 metadata 客户端。
///
/// 端契约见 docs/contracts/agent-bus-client-contract.md。
///
/// 注意：**消息收发不走本接口**。客户端消息链路走 WuKongIM，
/// 本服务仅提供"群信息 / 成员 / Speaker 策略元数据"等业务层视角的读接口。
class Room {
  Room({
    required this.uuid,
    required this.tenantID,
    required this.title,
    required this.type,
    required this.status,
    required this.speakerStrategy,
    required this.memberCount,
    required this.agentCount,
    required this.metadata,
  });

  final String uuid;
  final int tenantID;
  final String title;
  final String type;
  final String status;
  final String speakerStrategy;
  final int memberCount;
  final int agentCount;
  final Map<String, dynamic> metadata;

  bool get isFrozen => status == 'frozen' || metadata['frozen'] == true;

  factory Room.fromJson(Map<String, dynamic> json) {
    return Room(
      uuid: (json['uuid'] ?? '').toString(),
      tenantID: int.tryParse((json['tenant_id'] ?? '0').toString()) ?? 0,
      title: (json['title'] ?? json['name'] ?? '').toString(),
      type: (json['type'] ?? 'group').toString(),
      status: (json['status'] ?? 'active').toString(),
      speakerStrategy: (json['speaker_strategy'] ?? 'manager').toString(),
      memberCount: int.tryParse((json['member_count'] ?? '0').toString()) ?? 0,
      agentCount: int.tryParse((json['agent_count'] ?? '0').toString()) ?? 0,
      metadata: (json['metadata'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
  }
}

class RoomParticipant {
  RoomParticipant({
    required this.actorKind,
    required this.actorID,
    required this.role,
    required this.displayName,
    required this.avatarURL,
  });

  /// `human` / `agent` / `system`
  final String actorKind;
  final String actorID;
  final String role;
  final String displayName;
  final String avatarURL;

  factory RoomParticipant.fromJson(Map<String, dynamic> json) {
    return RoomParticipant(
      actorKind: (json['actor_kind'] ?? '').toString(),
      actorID: (json['actor_id'] ?? '').toString(),
      role: (json['role'] ?? '').toString(),
      displayName: (json['display_name'] ?? '').toString(),
      avatarURL: (json['avatar_url'] ?? '').toString(),
    );
  }
}

/// POST /direct-rooms 返回结构: 普通员工 human ↔ human 1v1。
class DirectRoom {
  DirectRoom({
    required this.roomUuid,
    required this.conversationUuid,
    required this.pairUuid,
    required this.pairCreated,
    required this.imSubstrate,
    this.wukongChannelId,
    this.wukongChannelType,
    this.clearedAt,
  });

  final String roomUuid;
  final String conversationUuid;
  final String pairUuid;
  final bool pairCreated;
  final String imSubstrate;
  // ADR-0026: WuKong 启用时由后端 /direct-rooms 返回(客户端不自行拼 channel_id)。
  final String? wukongChannelId;
  final int? wukongChannelType;
  final String? clearedAt;

  factory DirectRoom.fromJson(Map<String, dynamic> json) {
    final wkCh = json['wukong_channel_id'];
    final wkType = json['wukong_channel_type'];
    return DirectRoom(
      roomUuid: (json['room_uuid'] ?? '').toString(),
      conversationUuid: (json['conversation_uuid'] ?? '').toString(),
      pairUuid: (json['pair_uuid'] ?? '').toString(),
      pairCreated: json['pair_created'] == true,
      imSubstrate: (json['im_substrate'] ?? '').toString(),
      wukongChannelId:
          (wkCh == null || wkCh.toString().isEmpty) ? null : wkCh.toString(),
      wukongChannelType:
          wkType is int ? wkType : (wkType is num ? wkType.toInt() : null),
      clearedAt:
          json['clearedAt']?.toString() ?? json['cleared_at']?.toString(),
    );
  }
}

/// P2.3a: POST /rooms (roomKind=group) 返回结构（WuKong-first 群聊）。
class GroupRoom {
  GroupRoom({
    required this.roomUuid,
    required this.conversationUuid,
    required this.title,
    required this.wukongChannelId,
    required this.wukongChannelType,
    required this.participants,
  });

  final String roomUuid;
  final String conversationUuid;
  final String title;
  // ADR-0026: WuKong 启用时后端返回; 客户端用它打开 WuKong 群 pane（不自行拼 channel_id）。
  final String? wukongChannelId;
  final int? wukongChannelType;
  final List<GroupRoomParticipant> participants;

  factory GroupRoom.fromJson(Map<String, dynamic> json) {
    final wkCh = json['wukong_channel_id'];
    final wkType = json['wukong_channel_type'];
    final rawParts = (json['participants'] as List?) ?? const [];
    return GroupRoom(
      roomUuid: (json['uuid'] ?? json['room_uuid'] ?? '').toString(),
      conversationUuid: (json['conversation_uuid'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      wukongChannelId:
          (wkCh == null || wkCh.toString().isEmpty) ? null : wkCh.toString(),
      wukongChannelType:
          wkType is int ? wkType : (wkType is num ? wkType.toInt() : null),
      participants: rawParts
          .whereType<Map>()
          .map((e) => GroupRoomParticipant.fromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }
}

class GroupRoomParticipant {
  GroupRoomParticipant({
    required this.kind,
    required this.id,
    required this.displayName,
    this.email = '',
    this.departmentName = '',
    this.companyName = '',
  });

  /// `human` / `agent`
  final String kind;

  /// human → account_uuid; agent → digital_employee_uuid
  final String id;
  final String displayName;
  final String email;
  final String departmentName;
  final String companyName;

  factory GroupRoomParticipant.fromJson(Map<String, dynamic> json) {
    return GroupRoomParticipant(
      kind: (json['kind'] ?? '').toString(),
      id: (json['id'] ?? '').toString(),
      displayName: (json['displayName'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      departmentName: (json['department_name'] ?? '').toString(),
      companyName:
          (json['company_name'] ?? json['companyName'] ?? '').toString(),
    );
  }
}

/// P2.3a: `GET /rooms/{uuid}` 群详情(供群成员面板;含成员头像 + 群主)。
class GroupRoomDetail {
  GroupRoomDetail({
    required this.roomUuid,
    required this.conversationUuid,
    required this.title,
    required this.wukongChannelId,
    required this.wukongChannelType,
    required this.creatorAccountUuid,
    required this.members,
  });

  final String roomUuid;
  final String conversationUuid;
  final String title;
  final String? wukongChannelId;
  final int? wukongChannelType;
  final String creatorAccountUuid;
  final List<GroupMember> members;

  /// 该成员是否群主(创建者)。
  bool isOwner(GroupMember m) =>
      m.kind == 'human' &&
      creatorAccountUuid.isNotEmpty &&
      m.id == creatorAccountUuid;

  factory GroupRoomDetail.fromJson(Map<String, dynamic> json) {
    final wkType = json['wukong_channel_type'];
    final rawParts = (json['participants'] as List?) ?? const [];
    final wkCh = json['wukong_channel_id'];
    return GroupRoomDetail(
      roomUuid: (json['uuid'] ?? json['room_uuid'] ?? '').toString(),
      conversationUuid: (json['conversation_uuid'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      wukongChannelId:
          (wkCh == null || wkCh.toString().isEmpty) ? null : wkCh.toString(),
      wukongChannelType:
          wkType is int ? wkType : (wkType is num ? wkType.toInt() : null),
      creatorAccountUuid: (json['creator_account_uuid'] ?? '').toString(),
      members: rawParts
          .whereType<Map>()
          .map((e) => GroupMember.fromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }
}

class GroupMember {
  GroupMember({
    required this.participantUuid,
    required this.kind,
    required this.id,
    required this.displayName,
    required this.avatar,
    required this.roleInRoom,
    this.email = '',
    this.departmentName = '',
    this.companyName = '',
    this.canDirectChat = false,
    this.skills = const <GroupAgentSkill>[],
  });

  final String participantUuid;
  final String kind; // human / agent
  final String id; // account_uuid / agent_uuid
  final String displayName;
  final String avatar;
  final String roleInRoom;
  final String email;
  final String departmentName;
  final String companyName;
  final bool canDirectChat;
  final List<GroupAgentSkill> skills;

  factory GroupMember.fromJson(Map<String, dynamic> json) {
    return GroupMember(
      participantUuid: (json['participant_uuid'] ?? '').toString(),
      kind: (json['kind'] ?? '').toString(),
      id: (json['id'] ?? '').toString(),
      displayName: (json['displayName'] ?? '').toString(),
      avatar: (json['avatar'] ?? '').toString(),
      roleInRoom: (json['role_in_room'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      departmentName: (json['department_name'] ?? '').toString(),
      companyName:
          (json['company_name'] ?? json['companyName'] ?? '').toString(),
      canDirectChat: json['can_direct_chat'] == true,
      skills: ((json['skills'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => GroupAgentSkill.fromJson(item.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }
}

class GroupAgentSkill {
  const GroupAgentSkill({required this.name, required this.slug});

  final String name;
  final String slug;

  factory GroupAgentSkill.fromJson(Map<String, dynamic> json) {
    return GroupAgentSkill(
      name: (json['name'] ?? '').toString(),
      slug: (json['slug'] ?? '').toString(),
    );
  }
}

class RoomsService {
  /// 取群 metadata。
  /// 客户端用法：`getOneConversation` 之前先调一次拿到 speaker 策略 + 成员名单缓存，
  /// 避免每条消息都得反查后端解释 sender。
  Future<Room> getRoom(String uuid) async {
    final response = await request.get('/rooms/$uuid');
    final data = response.data as Map<String, dynamic>;
    return Room.fromJson(data);
  }

  /// 创建 (或返回已有) 普通员工 1v1 direct room。
  ///
  /// 返回 WuKong channel 后，UI 用 WuKongIM direct channel 打开会话。
  Future<DirectRoom> createDirectRoom({
    required String peerAccountUuid,
    String? title,
  }) async {
    final response = await request.post(
      '/direct-rooms',
      data: <String, dynamic>{
        'peer_account_uuid': peerAccountUuid,
        if (title != null && title.isNotEmpty) 'title': title,
      },
    );
    return DirectRoom.fromJson(response.data as Map<String, dynamic>);
  }

  /// P2.3a: 创建多人群聊。`POST /rooms`（roomKind=group, WuKong-first）。
  ///
  /// [participantAccountUuids] 是被邀请 human 的 account uuid（不含自己；后端自动把 caller 入群）。
  /// [agentUuids]（doc-13 §B）是被邀请的数字员工 digital_employee uuid（`participants[].kind='agent'`）；
  /// 后端 `precheckCanCreateGroup` + `resolveParticipants` 按可见性 / `allow_invite_to_group` fail-closed 校验。
  /// caller 自动入群；还需至少 2 个非 caller participant，human / agent 均计数（群总人数 ≥3）。
  /// 成功返回 room/conversation/wukong channel link。
  ///
  /// 注：这是"群聊多个数字员工**作为参与者**"，**不是**编排型数字员工（见 doc-14）。
  Future<GroupRoom> createGroup({
    required String title,
    required List<String> participantAccountUuids,
    List<String> agentUuids = const [],
  }) async {
    final response = await request.post(
      '/rooms',
      data: <String, dynamic>{
        'roomKind': 'group',
        'title': title,
        'speakerPolicy': 'manual',
        'participants': [
          for (final uuid in participantAccountUuids)
            <String, dynamic>{'kind': 'human', 'id': uuid},
          for (final uuid in agentUuids)
            <String, dynamic>{'kind': 'agent', 'id': uuid},
        ],
      },
    );
    return GroupRoom.fromJson(response.data as Map<String, dynamic>);
  }

  /// P2.3a: 取群详情(`GET /rooms/{uuid}`),含成员头像 + 群主,供群成员面板。
  Future<GroupRoomDetail> getGroupRoom(String uuid) async {
    final response = await request.get('/rooms/$uuid');
    return GroupRoomDetail.fromJson(response.data as Map<String, dynamic>);
  }

  /// P2.3a: 给群添加成员(`POST /rooms/{uuid}/participants`)。
  /// [accountUuids] = human account_uuid;[agentUuids] = 数字员工 agent_uuid
  /// (后端 `resolveParticipants` 支持 `kind ∈ {human, agent}`,见 client-contract §A 拉成员)。
  /// 后端同步 room_participants(+ human 的 WuKong subscriber_add)。
  Future<void> addGroupParticipants({
    required String roomUuid,
    required List<String> accountUuids,
    List<String> agentUuids = const [],
  }) async {
    await request.post(
      '/rooms/$roomUuid/participants',
      data: <String, dynamic>{
        'participants': [
          for (final uuid in accountUuids)
            <String, dynamic>{'kind': 'human', 'id': uuid},
          for (final uuid in agentUuids)
            <String, dynamic>{'kind': 'agent', 'id': uuid},
        ],
      },
    );
  }

  /// 取群成员列表（含 actor_kind / role 对应关系）。
  Future<List<RoomParticipant>> listParticipants(String uuid) async {
    final response = await request.get('/rooms/$uuid/participants');
    final raw = response.data;
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => RoomParticipant.fromJson(e.cast<String, dynamic>()))
          .toList();
    }
    if (raw is Map<String, dynamic>) {
      final items = (raw['items'] as List?) ?? const [];
      return items
          .whereType<Map>()
          .map((e) => RoomParticipant.fromJson(e.cast<String, dynamic>()))
          .toList();
    }
    return const <RoomParticipant>[];
  }
}
