import 'package:dio/dio.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_core/emp/emp_block_readable_text.dart';
import 'dart:async';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:zhiban_client/services/conversation_models.dart';

import 'package:bot_toast/bot_toast.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:riverpod/riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;

import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/human_direct_im_controller.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/services/agent_direct_dual_channel.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/providers/chat_stream_runtime.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart'
    show wukongImClientProvider;
import 'package:zhiban_client/pages/contacts/contact_providers.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';
import 'package:zhiban_client/rtc/rtc_call_controller.dart';
import 'package:zhiban_client/services/billing_refresh_notifier.dart';
import 'package:zhiban_core/utils/error_utils.dart';
import 'package:zhiban_client/utils/file_picker_utils.dart';

final chatServiceProvider = Provider<OpenClawChatService>(
  (ref) => OpenClawChatService(),
);

/// 「聊天历史」右侧抽屉的开关状态。ChatDetailHeader 的历史图标 toggle 它,
/// chat_page 据此决定是否在右侧腾出 380px 渲染 ChatHistoryPanel。
/// 切换 active 会话不强制关闭——切了对话面板内容跟着 chatProvider.messages
/// 一起换,符合"看历史"语义。
final chatHistoryPanelOpenProvider = StateProvider<bool>((ref) => false);

/// 「对话」tab 是否是当前可见路由，由 MainLayout 按 GoRouter 的 matchedLocation
/// 更新。ChatNotifier.activeConversationId 只是"最后一次选中的会话"，切到自动
/// 任务等其它 tab 后不会被清空——单靠它判断"用户正在看这个会话"会把切走之后台
/// 收到的新消息也误标已读（2026-08-25 实测：停在自动任务页收到 cron 消息推送，
/// 后台仍把上次打开过的会话标记已读，红点消失但用户根本没看到）。
final isChatRouteActiveProvider = StateProvider<bool>((ref) => false);

/// P2.1(ADR-0026):当前选中的「人↔人 WuKong direct」会话。
/// 非空时 ChatPage 右栏渲染 HumanDirectChatPane(按 channel 打开,不重调 /direct-rooms)。
/// 选普通 agent 会话时由侧栏清掉,保证互斥。
class HumanDirectSelection {
  const HumanDirectSelection({
    required this.conversationId,
    required this.roomUuid,
    required this.peerAccountUuid,
    required this.channelId,
    required this.channelType,
    required this.title,
    this.peerAvatar,
    this.peerDepartmentName = '',
    this.peerEmail = '',
    this.peerCompanyName = '',
    this.clearedAt,
  });
  final String conversationId;
  final String roomUuid;
  final String peerAccountUuid;
  final String channelId;
  final int channelType;
  final String title;

  /// 对端头像 URL(列表 `avatar` / 通讯录 `avatarUrl`);空时 pane 回退默认用户头像。
  final String? peerAvatar;

  /// 对端所在部门名。后端 P2.1 conversations.list participants 聚合时按
  /// tenant_memberships.department_id → departments.name 透传过来,
  /// 客户端聊天顶栏副标题展示「部门」。会话列表点开时 sidebar 选取**非自己**的 human
  /// 参与者的 departmentName 填入(详见 chat_page.dart/mobile_chat_page.dart 里的会话选择逻辑)。
  final String peerDepartmentName;
  final String peerEmail;
  final String peerCompanyName;
  final String? clearedAt;
}

final selectedHumanDirectProvider =
    StateProvider<HumanDirectSelection?>((ref) => null);

/// P2.3a(ADR-0026):当前选中的「WuKong 群聊」会话(`kind=group`)。
/// 非空时 ChatPage 右栏渲染 GroupChatPane(按 channel type=2 打开,不走 legacy agent / 不走 /direct-rooms)。
class GroupSelection {
  const GroupSelection({
    required this.conversationId,
    required this.roomUuid,
    required this.channelId,
    required this.channelType,
    required this.title,
    required this.participants,
    this.clearedAt,
    this.canRenameGroup = false,
  });
  final String conversationId;

  /// 群 room uuid(取群详情 / 添加群成员 用 `/rooms/{room_uuid}`)。
  final String roomUuid;
  final String channelId;
  final int channelType;
  final String title;

  /// 群成员(用于消息气泡按 from_uid 反查发送者名/头像)。
  final List<ConversationParticipant> participants;
  final String? clearedAt;
  final bool canRenameGroup;

  GroupSelection copyWith({
    String? conversationId,
    String? roomUuid,
    String? channelId,
    int? channelType,
    String? title,
    List<ConversationParticipant>? participants,
    String? clearedAt,
    bool? canRenameGroup,
  }) {
    return GroupSelection(
      conversationId: conversationId ?? this.conversationId,
      roomUuid: roomUuid ?? this.roomUuid,
      channelId: channelId ?? this.channelId,
      channelType: channelType ?? this.channelType,
      title: title ?? this.title,
      participants: participants ?? this.participants,
      clearedAt: clearedAt ?? this.clearedAt,
      canRenameGroup: canRenameGroup ?? this.canRenameGroup,
    );
  }
}

final selectedGroupProvider = StateProvider<GroupSelection?>((ref) => null);

final activeImControllerProvider =
    StateProvider<HumanDirectImController?>((ref) => null);

/// 数字员工 create-on-first-send 期间当前正在展示的 pending 会话 id。
///
/// 不放进 [ChatNotifier] 里给 [ConversationsNotifier.refresh] 读取，是为了避免
/// conversationsProvider ↔ chatProvider 互相读取形成循环依赖。
final activePendingConversationProvider = StateProvider<String?>((ref) => null);

void openConversationByProvider(Ref ref, ConversationItem conv) {
  final ch = conv.wukongChannelId;
  if (conv.isGroup && ch != null && ch.isNotEmpty) {
    ref.read(activePendingConversationProvider.notifier).state = null;
    ref.read(selectedHumanDirectProvider.notifier).state = null;
    ref.read(selectedGroupProvider.notifier).state = GroupSelection(
      conversationId: conv.conversationId,
      roomUuid: conv.roomUuid ?? '',
      channelId: ch,
      channelType: conv.wukongChannelType ?? 2,
      title: conv.title,
      participants: conv.participants,
      clearedAt: conv.clearedAt,
      canRenameGroup: conv.canRenameGroup,
    );
  } else if (conv.isHumanDirect && ch != null && ch.isNotEmpty) {
    ref.read(activePendingConversationProvider.notifier).state = null;
    ref.read(selectedGroupProvider.notifier).state = null;
    String peerDept = '';
    String peerEmail = '';
    String peerCompanyName = '';
    String peerAccountUuid = '';
    for (final p in conv.participants) {
      if (p.kind == 'human' && p.displayName == conv.title) {
        peerDept = p.departmentName;
        peerEmail = p.email;
        peerCompanyName = p.companyName;
        peerAccountUuid = p.accountUuid;
        break;
      }
    }
    ref.read(selectedHumanDirectProvider.notifier).state = HumanDirectSelection(
      conversationId: conv.conversationId,
      roomUuid: conv.roomUuid ?? '',
      peerAccountUuid: peerAccountUuid,
      channelId: ch,
      channelType: conv.wukongChannelType ?? 2,
      title: conv.title,
      peerAvatar: conv.convAvatar,
      peerDepartmentName: peerDept,
      peerEmail: peerEmail,
      peerCompanyName: peerCompanyName,
      clearedAt: conv.clearedAt,
    );
  } else {
    ref.read(activePendingConversationProvider.notifier).state = null;
    ref.read(selectedHumanDirectProvider.notifier).state = null;
    ref.read(selectedGroupProvider.notifier).state = null;
    ref.read(chatProvider.notifier).selectConversation(conv.conversationId);
  }
  markConversationReadEverywhere(
    ref: ref,
    wukongClient: ref.read(wukongImClientProvider),
    conversationId: conv.conversationId,
    channelId: ch,
    channelType: conv.wukongChannelType ?? 2,
  );
}

/// 把一个会话标记为已读：本地 unreadCount 清零 + WuKong markRead + REST
/// markConversationRead。用户点开会话（[openConversationByProvider]）和已经
/// 在看某会话时又收到新消息（`conversation_realtime_bridge.dart`
/// `_markCurrentConversationRead`）都要保持本地/服务端已读状态一致，抽成一份
/// 复用，不各自维护一套。`wukongClient` 由调用方传入而不是内部
/// `ref.read(wukongImClientProvider)`——realtime bridge 测试用假 `ImClient`
/// 走构造函数注入，不经过这个 provider。
void markConversationReadEverywhere({
  required Ref ref,
  required ImClient wukongClient,
  required String conversationId,
  String? channelId,
  int? channelType,
}) {
  final conversations = ref.read(conversationsProvider.notifier);
  final readTicket = conversations.beginRead(conversationId);
  if (channelId != null && channelId.isNotEmpty) {
    unawaited(
      wukongClient
          .markRead(channelId, channelType ?? 2)
          .catchError((Object _) {}),
    );
  }
  unawaited(
    ref
        .read(chatServiceProvider)
        .markConversationRead(conversationId)
        .catchError((Object _) {})
        .whenComplete(() {
      if (ref.mounted) conversations.completeRead(conversationId, readTicket);
    }),
  );
}

final openClawInstanceProvider =
    AsyncNotifierProvider<OpenClawInstanceNotifier, OpenClawInstanceState>(
  OpenClawInstanceNotifier.new,
);

class OpenClawInstanceNotifier extends AsyncNotifier<OpenClawInstanceState> {
  static const _agentBusReadyState = OpenClawInstanceState(
    instanceStatus: 'running',
    message: 'OpenClaw bootstrap disabled after Agent Bus cutover',
    defaultAgentReady: true,
    gatewayReady: true,
  );

  @override
  Future<OpenClawInstanceState> build() async {
    return _agentBusReadyState;
  }

  Future<void> refresh() async {
    state = const AsyncData(_agentBusReadyState);
  }
}

final agentsProvider = AsyncNotifierProvider<AgentsNotifier, List<AgentItem>>(
  AgentsNotifier.new,
);

class AgentsNotifier extends AsyncNotifier<List<AgentItem>> {
  final Map<String, Future<void>> _missing = {};

  /// A conversation can arrive before the cached employee catalog is refreshed.
  Future<void> ensureAgent(String id) {
    if (id.isEmpty || state.asData?.value.any((a) => a.agentId == id) == true) {
      return Future.value();
    }
    return _missing.putIfAbsent(
      id,
      () => _loadMissingAgent(id).whenComplete(() {
        _missing.remove(id);
      }),
    );
  }

  Future<void> _loadMissingAgent(String id) async {
    try {
      // 会话里的员工可能由平台或组织创建，不属于当前账号的管理列表。
      // 单条补拉必须走可见性详情；/agents/{uuid} 是仅创建者可读的管理详情。
      final agent =
          (await ref.read(contactsServiceProvider).agent(id, silent: true))
              .toAgentItem();
      if (ref.mounted && agent.agentId == id) upsertAgent(agent);
    } catch (_) {
      // A removed or inaccessible employee must not replace another selection.
    }
  }

  @override
  Future<List<AgentItem>> build() async {
    final service = ref.read(chatServiceProvider);
    return service.listAgents();
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(() async {
      final service = ref.read(chatServiceProvider);
      return service.listAgents();
    });
  }

  /// 把 [updated] 直接合并进当前列表里，避免依赖后端 list 接口的最终一致性。
  ///
  /// 用于：编辑数字员工后，立刻让画廊里那张卡片显示新名称 / 新头像 / 新岗位，
  /// 不必等下一次 listAgents 回来覆盖。
  void upsertAgent(AgentItem updated) {
    // A successful visibility lookup must recover an initial list failure too.
    // Dropping it leaves conversation fallbacks without local runtime controls.
    final current = state.asData?.value ?? const <AgentItem>[];
    final next =
        current.map((a) => a.agentId == updated.agentId ? updated : a).toList();
    if (!next.any((a) => a.agentId == updated.agentId)) {
      next.add(updated);
    }
    state = AsyncData(next.toList(growable: false));
  }
}

final selectedAgentProvider =
    AsyncNotifierProvider<SelectedAgentNotifier, AgentItem?>(
  SelectedAgentNotifier.new,
);

final Stopwatch _avatarTraceClock = Stopwatch();
final Map<String, String> _avatarTraceLast = <String, String>{};

void _avatarTraceStart() {
  if (!kDebugMode) return;
  if (!_avatarTraceClock.isRunning) _avatarTraceClock.start();
}

String _avatarTraceUrl(String? raw) {
  final value = (raw ?? '').trim();
  if (value.isEmpty) return '-';
  final uri = Uri.tryParse(value);
  if (uri != null) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      final port = uri.hasPort ? ':${uri.port}' : '';
      return '$scheme://${uri.host}$port${uri.path}';
    }
    if (scheme.isEmpty && value.startsWith('/')) {
      return uri.path.isEmpty ? value : uri.path;
    }
  }
  return value.length > 120 ? '${value.substring(0, 120)}...' : value;
}

void _avatarTraceLog(String key, String message) {
  if (!kDebugMode) return;
  _avatarTraceStart();
  final previous = _avatarTraceLast[key];
  if (previous == message) return;
  _avatarTraceLast[key] = message;
}

void _avatarTraceAgent(String source, AgentItem? agent) {
  if (!kDebugMode || agent == null || agent.agentId.isEmpty) return;
  final msg =
      '$source agent=${agent.agentId} name=${agent.name} avatar=${_avatarTraceUrl(agent.avatarUrl)}';
  _avatarTraceLog('$source:${agent.agentId}', msg);
}

void _avatarTraceAgents(String source, List<AgentItem> agents) {
  if (!kDebugMode) return;
  for (final agent in agents) {
    if (agent.agentId.isEmpty) continue;
    _avatarTraceAgent(source, agent);
  }
}

void _avatarTraceConversations(String source, List<ConversationItem> items) {
  if (!kDebugMode) return;
  for (final item in items) {
    if (!_isAgentConversationForDedupe(item)) continue;
    var participantAvatar = '-';
    for (final p in item.participants) {
      if (p.kind == 'agent' && p.avatar.trim().isNotEmpty) {
        participantAvatar = _avatarTraceUrl(p.avatar);
        break;
      }
    }
    final msg = '$source conv=${item.conversationId} agent=${item.agentId} '
        'title=${item.title} convAvatar=${_avatarTraceUrl(item.convAvatar)} '
        'agentAvatar=${_avatarTraceUrl(item.agentAvatarUrl)} '
        'participantAvatar=$participantAvatar';
    _avatarTraceLog('$source:${item.conversationId}', msg);
  }
}

void _avatarTraceConversationPatch(
  List<ConversationItem> before,
  List<ConversationItem> after,
) {
  if (!kDebugMode) return;
  final previousById = {
    for (final item in before) item.conversationId: item
  };
  for (final next in after) {
    final old = previousById[next.conversationId];
    if (old == null) continue;
    if (old.agentAvatarUrl == next.agentAvatarUrl &&
        old.convAvatar == next.convAvatar &&
        old.title == next.title &&
        old.agentName == next.agentName) {
      continue;
    }
    final msg = 'enrichment patched conv=${next.conversationId} '
        'agent=${next.agentId} title ${old.title} -> ${next.title}; '
        'convAvatar ${_avatarTraceUrl(old.convAvatar)} -> ${_avatarTraceUrl(next.convAvatar)}; '
        'agentAvatar ${_avatarTraceUrl(old.agentAvatarUrl)} -> ${_avatarTraceUrl(next.agentAvatarUrl)}';
    _avatarTraceLog('patch:${next.conversationId}:$msg', msg);
  }
}

class SelectedAgentNotifier extends AsyncNotifier<AgentItem?> {
  @override
  Future<AgentItem?> build() async {
    // 故意不再 ref.watch(conversationsProvider)：那会让红点轮询 / 切菜单回来 /
    // 编辑数字员工触发的 conversationsProvider.refresh 都把这里的 selected
    // 重置成 conversations.first 的 agent（早期实现），症状是「在对话页选了
    // 第二个数字人，切到数字员工再切回来，左侧高亮没变但右侧顶栏头像/姓名
    // 变成了第一个数字人」。
    //
    // 现在的语义：build 时不预设 selected。首次没值时 UI 走 selectedAgent
    // OrFallback 的兜底（conversations.first 的 agent）；用户手动选会话或
    // 应用主动 select 后，selected 只由 select / selectByConversationId 改写，
    // 后台刷新不再覆盖。
    return null;
  }

  void select(AgentItem agent) {
    final current = state.asData?.value;
    if (current?.agentId == agent.agentId) {
      state = AsyncData(_preferRicherAgent(agent, current!));
      return;
    }
    state = AsyncData(agent);
  }

  void refreshCurrent(AgentItem agent) {
    state = AsyncData(agent);
  }

  void clear() {
    state = const AsyncData(null);
  }

  void selectByConversationId(
    String conversationId,
    List<ConversationItem> conversations,
    List<AgentItem> agents,
  ) {
    final conv = conversations.cast<ConversationItem?>().firstWhere(
          (c) => c!.conversationId == conversationId,
          orElse: () => null,
        );
    if (conv == null) return;
    final agent = agents.cast<AgentItem?>().firstWhere(
          (a) => a!.agentId == conv.agentId,
          orElse: () => null,
        );
    final current = state.asData?.value;
    if (agent == null) {
      unawaited(ref.read(agentsProvider.notifier).ensureAgent(conv.agentId));
      // agentsProvider 未含该 agent: **不要静默保留旧 selected**。若旧 selected 是别的 agent,
      // 清掉以免右侧串台(selectedAgentOrFallbackProvider 会以 active conversation 为准兜底);
      // 旧 selected 恰是同一 agent(如数字员工入口刚 select 的 rich 项)则保留。
      if (current != null && current.agentId != conv.agentId) {
        state = const AsyncData(null);
      }
      return;
    }
    if (current?.agentId == agent.agentId) return;
    state = AsyncData(agent);
  }
}

/// 用 capability-rich 的数字员工目录 (catalog) 按 agentId 补齐缺失的展示字段与 skills/apps。
/// 从会话列表进入 agent 会话时, _agentFromConversation / selectByConversationId 产出的 AgentItem
/// 可能没有 positionLabel / departmentName / skills/apps;此处只用**同 agentId** 的目录项补空值,
/// 不让旧 selected 的其它 agent 串台。仅丰富数据,不改任何展示判定:群聊/人↔人由各自 pane 渲染
/// (不展示 chips),故只影响数字员工单聊。
AgentItem _withCatalogCapabilities(
  AgentItem agent,
  DigitalEmployeeCatalog? catalog,
  List<AgentItem>? managedAgents,
) {
  if (agent.agentId.isEmpty) return agent;
  AgentItem? permissionSource;
  if (managedAgents != null) {
    for (final item in managedAgents) {
      if (item.agentId == agent.agentId) {
        permissionSource = item;
        break;
      }
    }
  }
  final supportsSkillBindings =
      permissionSource?.supportsSkillBindings ?? agent.supportsSkillBindings;
  final canManageSkills =
      permissionSource?.canManageSkills ?? agent.canManageSkills;
  String pick(String base, String fallback) =>
      base.trim().isNotEmpty ? base : fallback;
  final managedRuntimeEnvironmentUuid =
      permissionSource?.runtimeEnvironmentUuid ?? '';
  final welcomeMsg = permissionSource?.welcomeMsg ?? agent.welcomeMsg;
  if (catalog == null) {
    return (permissionSource ?? agent).copyWith(
      runtimeEnvironmentUuid: pick(
        agent.runtimeEnvironmentUuid,
        managedRuntimeEnvironmentUuid,
      ),
      welcomeMsg: welcomeMsg,
      supportsSkillBindings: supportsSkillBindings,
      canManageSkills: canManageSkills,
    );
  }
  for (final item in catalog.all) {
    if (item.agent.agentId != agent.agentId) continue;
    final rich = item.agent;
    String pickAvatar(String base, String fallback) =>
        pickAgentAvatarUrl(base, fallback) ?? '';
    return (permissionSource ?? agent).copyWith(
      agentId: agent.agentId,
      executionLocus: (permissionSource ?? rich).executionLocus,
      localEngine: (permissionSource ?? rich).localEngine,
      supportsModelSelection: (permissionSource ?? rich).supportsModelSelection,
      name: pick(agent.name, rich.name),
      description: pick(agent.description, rich.description),
      avatarUrl: pickAvatar(agent.avatarUrl, rich.avatarUrl),
      position: pick(agent.position, rich.position),
      positionLabel: pick(agent.positionLabel, rich.positionLabel),
      departmentName: pick(agent.departmentName, rich.departmentName),
      welcomeMsg: permissionSource != null
          ? permissionSource.welcomeMsg
          : pick(agent.welcomeMsg, rich.welcomeMsg),
      runtimeEnvironmentUuid: pick(
        agent.runtimeEnvironmentUuid,
        pick(managedRuntimeEnvironmentUuid, rich.runtimeEnvironmentUuid),
      ),
      // /agents 是正式能力绑定的权威源；空数组表示已全部解绑，不能被较旧的
      // /contacts/agents 目录缓存回填。目录只在 /agents 未返回该员工时补展示能力。
      skills: permissionSource?.skills ??
          (rich.skills.isNotEmpty ? rich.skills : agent.skills),
      apps: permissionSource?.apps ??
          (rich.apps.isNotEmpty ? rich.apps : agent.apps),
      // 权限字段只认 /agents；联系人目录只补展示资料，不能用 AgentItem 默认值覆盖。
      supportsSkillBindings: supportsSkillBindings,
      canManageSkills: canManageSkills,
      // ADR-0037 BYOK: 同上，模型配置只认 /agents，这里直接构造 AgentItem（不走
      // copyWith）此前漏传这几个字段，会被 AgentItem 构造函数的默认值
      // ('platform_whitelist'/空字符串) 悄悄顶掉，编辑框打开时误判成平台模型。
      modelPrimary: (permissionSource ?? rich).modelPrimary,
      modelSource: (permissionSource ?? rich).modelSource,
      modelServiceEndpointType:
          (permissionSource ?? rich).modelServiceEndpointType,
      modelServiceBaseUrl: (permissionSource ?? rich).modelServiceBaseUrl,
      modelServiceModelId: (permissionSource ?? rich).modelServiceModelId,
      modelServiceApiKeyPrefix:
          (permissionSource ?? rich).modelServiceApiKeyPrefix,
      status: agent.status,
      isDefault: agent.isDefault,
      syncStatus: agent.syncStatus,
      lastSyncedAt: agent.lastSyncedAt,
    );
  }
  return (permissionSource ?? agent).copyWith(
    runtimeEnvironmentUuid: pick(
      agent.runtimeEnvironmentUuid,
      managedRuntimeEnvironmentUuid,
    ),
    welcomeMsg: welcomeMsg,
    supportsSkillBindings: supportsSkillBindings,
    canManageSkills: canManageSkills,
  );
}

/// 同一 agent 时,用显式 selected 的更全字段(真人名/头像/部门/能力)补 base 的空缺;
/// **不同 agent 的旧 selected 绝不生效**(否则切会话后右侧停留在上一个数字员工)。
AgentItem _preferSelectedIfSameAgent(AgentItem base, AgentItem? selected) {
  if (selected == null || selected.agentId != base.agentId) return base;
  String pick(String a, String b) => a.isNotEmpty ? a : b;
  String pickAvatar(String a, String b) => pickAgentAvatarUrl(a, b) ?? '';
  return selected.copyWith(
    agentId: base.agentId,
    name: pick(selected.name, base.name),
    description: pick(selected.description, base.description),
    avatarUrl: pickAvatar(selected.avatarUrl, base.avatarUrl),
    position: pick(selected.position, base.position),
    positionLabel: pick(selected.positionLabel, base.positionLabel),
    departmentName: pick(selected.departmentName, base.departmentName),
    welcomeMsg: pick(selected.welcomeMsg, base.welcomeMsg),
    runtimeEnvironmentUuid: pick(
      selected.runtimeEnvironmentUuid,
      base.runtimeEnvironmentUuid,
    ),
    skills: selected.skills.isNotEmpty ? selected.skills : base.skills,
    apps: selected.apps.isNotEmpty ? selected.apps : base.apps,
    supportsSkillBindings: selected.supportsSkillBindings,
    canManageSkills: selected.canManageSkills,
    status: base.status,
    isDefault: base.isDefault,
    syncStatus: base.syncStatus,
    lastSyncedAt: base.lastSyncedAt,
  );
}

final selectedAgentOrFallbackProvider = Provider<AgentItem?>((ref) {
  // 右侧 header / 技能·应用 chips 的展示主语:**以当前 active conversation 为准**,
  // 不被残留的旧 selectedAgentProvider 带偏(切到许文博后不能停留在陈启航)。
  final catalog = ref.watch(digitalEmployeeCatalogProvider).asData?.value;
  final managedAgents = ref.watch(agentsProvider).asData?.value;

  // 1) 群聊 / 人↔人由各自 pane 渲染(不展示数字员工 chips)→ 返回 null,避免旧 selected 串台。
  if (ref.watch(selectedGroupProvider) != null ||
      ref.watch(selectedHumanDirectProvider) != null) {
    return null;
  }

  final selected = ref.watch(selectedAgentProvider).asData?.value;
  final conversations = ref.watch(conversationsProvider).asData?.value ??
      const <ConversationItem>[];
  final activeId = ref.watch(chatProvider).asData?.value.activeConversationId;

  // 2) 有 active 会话 → 以它为准。
  if (activeId != null && activeId.isNotEmpty) {
    for (final c in conversations) {
      if (c.conversationId == activeId) {
        // 同 agent 的 selected 更全则合并;catalog 补 skills/apps。
        final agent = _withCatalogCapabilities(
            _preferSelectedIfSameAgent(_agentFromConversation(c), selected),
            catalog,
            managedAgents);
        _avatarTraceAgent('selectedAgentOrFallback:active', agent);
        return agent;
      }
    }
    // pending:<uuid> 未在列表里:用哨兵 agentUuid 构最小 agent(只允许**同 agent** 的 selected 合并)。
    if (isPendingConversation(activeId)) {
      final pendingId = agentUuidFromPending(activeId);
      final agent = _withCatalogCapabilities(
        _preferSelectedIfSameAgent(
          AgentItem(
            agentId: pendingId,
            name: '',
            description: '',
            avatarUrl: '',
            status: 'active',
            isDefault: false,
            syncStatus: 'synced',
            lastSyncedAt: null,
          ),
          selected,
        ),
        catalog,
        managedAgents,
      );
      _avatarTraceAgent('selectedAgentOrFallback:pending', agent);
      return agent;
    }
    // active 存在但列表里找不到(非 pending)→ 落到下面 selected / first 兜底。
  }

  // 3) 没有 active / 找不到对应会话 → 才用显式 selected。
  if (selected != null) {
    final agent = _withCatalogCapabilities(selected, catalog, managedAgents);
    _avatarTraceAgent('selectedAgentOrFallback:selected', agent);
    return agent;
  }

  // 4) 最后兜底:conversations.first。
  if (conversations.isEmpty) return null;
  final agent = _withCatalogCapabilities(
      _agentFromConversation(conversations.first), catalog, managedAgents);
  _avatarTraceAgent('selectedAgentOrFallback:firstConversation', agent);
  return agent;
});

final chatConversationTitleProvider = Provider<String>((ref) {
  final activeConversationId =
      ref.watch(chatProvider).asData?.value.activeConversationId;
  final conversations = ref.watch(conversationsProvider).asData?.value;
  return _resolveChatTitle(activeConversationId, conversations);
});

/// 当前会话列表项。数字员工删除等会话级展示/可用性状态必须以服务端
/// conversation DTO 为准，不能从已过滤掉软删项的数字员工目录反推。
final activeConversationItemProvider = Provider<ConversationItem?>((ref) {
  final activeConversationId =
      ref.watch(chatProvider).asData?.value.activeConversationId;
  final conversations = ref.watch(conversationsProvider).asData?.value;
  if (activeConversationId == null || conversations == null) return null;
  for (final item in conversations) {
    if (item.conversationId == activeConversationId) return item;
  }
  return null;
});

String _resolveChatTitle(String? id, List<ConversationItem>? items) {
  if (id == null || items == null) return '对话';
  for (final item in items) {
    if (item.conversationId == id) return item.title;
  }
  return '对话';
}

final conversationsProvider =
    AsyncNotifierProvider<ConversationsNotifier, List<ConversationItem>>(
  ConversationsNotifier.new,
  // 首屏离线失败应结束 loading；联网后由 realtime bridge 刷新。
  retry: (_, __) => null,
);

final conversationsRefreshingProvider = StateProvider<bool>((ref) => false);
final mentionedConversationIdsProvider =
    StateProvider<Set<String>>((ref) => const {});

class ConversationsNotifier extends AsyncNotifier<List<ConversationItem>> {
  int _refreshRequest = 0;
  int _localRevision = 0;
  final Map<String, int> _unreadRevisions = {};
  final Map<String, int> _pendingReads = {};
  int beginRead(String id) {
    clearUnreadLocally(id);
    return _pendingReads[id] = _localRevision;
  }

  void completeRead(String id, int ticket) {
    if (_pendingReads[id] != ticket) return;
    _pendingReads.remove(id);
    _touchUnread(id);
  }

  void _touchUnread(String id) => _unreadRevisions[id] = ++_localRevision;
  // 实时消息去重 (进程内小窗口): 记最近见过的 WuKong messageId/clientMsgNo, 防同一条消息
  // (自发回显 / 重推) 重复加未读或重复置顶。FIFO 淘汰, 上限 _recentRealtimeCap。
  final List<String> _recentRealtimeIds = <String>[];
  final Set<String> _recentRealtimeIdSet = <String>{};
  static const int _recentRealtimeCap = 200;

  bool _seenRealtime(String id) {
    if (id.isEmpty) return false; // 无 id → 不去重 (调用方应尽量给 messageId/clientMsgNo)
    if (_recentRealtimeIdSet.contains(id)) return true;
    _recentRealtimeIdSet.add(id);
    _recentRealtimeIds.add(id);
    if (_recentRealtimeIds.length > _recentRealtimeCap) {
      _recentRealtimeIdSet.remove(_recentRealtimeIds.removeAt(0));
    }
    return false;
  }

  /// 把实时消息时间戳安全转成 ISO 串。WuKong 不同来源单位不一 (SDK WKMsg.timestamp 是秒,
  /// 本地 failed 占位用毫秒), 按量级判定: >1e12 毫秒、>1e9 秒、<=0 回退当前时间。
  static String _resolveOccurredAtIso(int ts) {
    final DateTime dt;
    if (ts > 1000000000000) {
      dt = DateTime.fromMillisecondsSinceEpoch(ts);
    } else if (ts > 1000000000) {
      dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    } else {
      dt = DateTime.now();
    }
    return dt.toIso8601String();
  }

  @override
  Future<List<ConversationItem>> build() async {
    _avatarTraceStart();
    // Cold start: conversations may arrive before `/agents`, so old conversation
    // rows can briefly render placeholder avatars. Listen for richer agent
    // profiles and patch the in-memory list without waiting for polling.
    ref.listen<AsyncValue<List<AgentItem>>>(agentsProvider, (_, next) {
      if (!next.hasValue) return;
      _avatarTraceAgents('agentsProvider', next.requireValue);
      _patchAgentProfileEnrichment();
    });
    final service = ref.read(chatServiceProvider);
    final cached = await service.getCachedConversations();
    if (!ref.mounted) return const [];
    if (cached != null) {
      // 先标记后台权威刷新，再发布本地首屏；否则本地 AsyncData 发布后，
      // refresh 尚未启动会让 loading 横条短暂消失，随后再次闪现。
      ref.read(conversationsRefreshingProvider.notifier).state = true;
      unawaited(Future<void>(() async {
        if (ref.mounted) {
          await refresh();
        }
      }));
      return _dedupeAgentConversations(_enrichAgentConversations(cached));
    }
    final items = await service.listAllConversations();
    _avatarTraceConversations('conversations:listAll', items);
    final enriched =
        _dedupeAgentConversations(_enrichAgentConversations(items));
    _avatarTraceConversations('conversations:initialEnriched', enriched);
    return enriched;
  }

  Future<void> refresh({bool showLoading = true}) async {
    final requestId = ++_refreshRequest;
    // Automatic IM reconciliation must not flash a loading row over ready data.
    // Preserve an already-visible indicator across overlapping requests.
    if (showLoading || (state.value?.isEmpty ?? true)) {
      ref.read(conversationsRefreshingProvider.notifier).state = true;
    }
    try {
      await _refresh(requestId);
    } finally {
      if (ref.mounted && requestId == _refreshRequest) {
        ref.read(conversationsRefreshingProvider.notifier).state = false;
      }
    }
  }

  Future<void> _refresh(int requestId) async {
    final revisionAtStart = _localRevision;
    // doc-13 §A: 保留未 adopt 的 pending 数字员工会话栏 (服务端不返回它们);
    // 若该 agent 已有真实会话 (按 agentId) 则不再保留 pending, 避免重复。
    final currentList = state.asData?.value ?? const <ConversationItem>[];
    final pending = currentList
        .where((c) => isPendingConversation(c.conversationId))
        .toList(growable: false);
    final nextState = await AsyncValue.guard(() async {
      final service = ref.read(chatServiceProvider);
      final server = await service.listAllConversations();
      final activePendingConversationId = _activePendingConversationId();
      List<ConversationItem> merged;
      if (pending.isEmpty) {
        merged = server;
      } else {
        final serverAgentIds = server
            .where(_isAgentConversationForDedupe)
            .map((c) => c.agentId)
            .where((id) => id.isNotEmpty)
            .toSet();
        final keep = pending.where((p) {
          // 首条发送期间服务端可能先返回同 agent 的真实会话, 但
          // ChatNotifier 还没收到 /chat/send 响应并 adopt 真实 uuid。
          // 此时丢掉当前 active pending 会让左侧 selectedConversationId
          // 短暂匹配不到任何列表项, 表现为发送过程中选中态闪掉。
          if (p.conversationId == activePendingConversationId) return true;
          return !serverAgentIds.contains(p.agentId);
        }).toList(growable: false);
        merged = [...keep, ...server];
      }
      return _dedupeAgentConversations(
        _enrichAgentConversations(merged)
      );
    });
    if (!ref.mounted || requestId != _refreshRequest) return;
    // 保留失败发生时的最新数据，不能回滚请求期间的本地阅读/实时消息。
    if (nextState.hasError &&
        isTransientNetworkError(nextState.error) &&
        state.hasValue) {
      return;
    }
    final current = {
      for (final c in state.asData?.value ?? <ConversationItem>[])
        c.conversationId: c
    };
    final protectedState = nextState.whenData((items) => items.map((item) {
          final local = current[item.conversationId];
          if (local != null &&
              ((_unreadRevisions[item.conversationId] ?? 0) > revisionAtStart ||
                  _pendingReads.containsKey(item.conversationId))) {
            return item.copyWith(
                unreadCount: local.unreadCount,
                markedUnread: local.markedUnread);
          }
          return item;
        }).toList());
    state = protectedState;
    final refreshed = protectedState.asData?.value;
    if (refreshed != null) {
      _syncSelectedHumanDirectMetadata(refreshed);
    }
  }

  /// `/chat/conversations` refresh 后同步当前打开的人↔人会话资料。
  /// selection 是打开会话时的快照；若只更新左侧列表，右侧顶栏/名片/RTC 仍会继续用旧昵称。
  void _syncSelectedHumanDirectMetadata(List<ConversationItem> items) {
    final selected = ref.read(selectedHumanDirectProvider);
    if (selected == null) return;

    ConversationItem? conversation;
    for (final item in items) {
      if (item.conversationId == selected.conversationId &&
          item.isHumanDirect) {
        conversation = item;
        break;
      }
    }
    if (conversation == null) return;

    ConversationParticipant? peer;
    for (final participant in conversation.participants) {
      if (participant.kind != 'human') continue;
      if (selected.peerAccountUuid.isNotEmpty) {
        if (participant.accountUuid == selected.peerAccountUuid) {
          peer = participant;
          break;
        }
      } else if (participant.displayName == conversation.title) {
        peer = participant;
        break;
      }
    }

    final next = HumanDirectSelection(
      conversationId: selected.conversationId,
      roomUuid: (conversation.roomUuid ?? '').isNotEmpty
          ? conversation.roomUuid!
          : selected.roomUuid,
      peerAccountUuid: (peer?.accountUuid ?? '').isNotEmpty
          ? peer!.accountUuid
          : selected.peerAccountUuid,
      channelId: (conversation.wukongChannelId ?? '').isNotEmpty
          ? conversation.wukongChannelId!
          : selected.channelId,
      channelType: conversation.wukongChannelType ?? selected.channelType,
      title: conversation.title,
      peerAvatar: conversation.convAvatar,
      peerDepartmentName: peer?.departmentName ?? selected.peerDepartmentName,
      peerEmail: peer?.email ?? selected.peerEmail,
      peerCompanyName: peer?.companyName ?? selected.peerCompanyName,
      clearedAt: conversation.clearedAt,
    );
    if (_sameHumanDirectSelection(selected, next)) return;
    ref.read(selectedHumanDirectProvider.notifier).state = next;
  }

  bool _sameHumanDirectSelection(
    HumanDirectSelection left,
    HumanDirectSelection right,
  ) {
    return left.conversationId == right.conversationId &&
        left.roomUuid == right.roomUuid &&
        left.peerAccountUuid == right.peerAccountUuid &&
        left.channelId == right.channelId &&
        left.channelType == right.channelType &&
        left.title == right.title &&
        left.peerAvatar == right.peerAvatar &&
        left.peerDepartmentName == right.peerDepartmentName &&
        left.peerEmail == right.peerEmail &&
        left.peerCompanyName == right.peerCompanyName &&
        left.clearedAt == right.clearedAt;
  }

  String? _activePendingConversationId() {
    final active = ref.read(activePendingConversationProvider);
    return isPendingConversation(active) ? active : null;
  }

  List<ConversationItem> _enrichAgentConversations(
      List<ConversationItem> items) {
    final agentsById = _currentAgentLookup();
    if (agentsById.isEmpty) return items;
    return [
      for (final item in items)
        if (_isAgentConversationForDedupe(item))
          _enrichAgentConversation(item, agentsById[item.agentId])
        else
          item,
    ];
  }

  void _patchAgentProfileEnrichment() {
    final current = state.asData?.value;
    if (current == null || current.isEmpty) return;
    final enriched = _dedupeAgentConversations(
      _enrichAgentConversations(current),
    );
    if (_sameConversationProfiles(current, enriched)) return;
    _avatarTraceConversationPatch(current, enriched);
    state = AsyncData(enriched);
  }

  bool _sameConversationProfiles(
    List<ConversationItem> a,
    List<ConversationItem> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final left = a[i];
      final right = b[i];
      if (left.conversationId != right.conversationId ||
          left.title != right.title ||
          left.agentName != right.agentName ||
          left.agentAvatarUrl != right.agentAvatarUrl ||
          left.convAvatar != right.convAvatar) {
        return false;
      }
    }
    return true;
  }

  Map<String, AgentItem> _currentAgentLookup() {
    final out = <String, AgentItem>{};
    void put(AgentItem? agent) {
      if (agent == null || agent.agentId.isEmpty) return;
      final previous = out[agent.agentId];
      out[agent.agentId] =
          previous == null ? agent : _preferRicherAgent(agent, previous);
    }

    final agents = ref.exists(agentsProvider)
        ? ref.read(agentsProvider).asData?.value
        : null;
    if (agents != null) {
      for (final agent in agents) {
        put(agent);
      }
    }
    final catalog = ref.exists(digitalEmployeeCatalogProvider)
        ? ref.read(digitalEmployeeCatalogProvider).asData?.value
        : null;
    if (catalog != null) {
      for (final item in catalog.all) {
        put(item.agent);
      }
    }
    put(ref.read(selectedAgentProvider).asData?.value);
    return out;
  }

  /// doc-13 §A: 点击数字员工进入 create-on-first-send 会话时, 在左侧列表插入临时会话栏。
  /// 已有同 conversationId 的 pending、或该 agent 已有真实会话 → 不重复插入。
  void ensurePendingAgent(ConversationItem pending) {
    final current = state.asData?.value ?? const <ConversationItem>[];
    for (final c in current) {
      if (c.conversationId == pending.conversationId) return;
      if (isReusableAgentDirectConversation(c, pending.agentId)) {
        return; // 已有真实会话, 不插 pending
      }
    }
    state = AsyncData(_dedupeAgentConversations(
      [pending, ...current],
      preferConversationId: pending.conversationId),
    );
  }

  /// doc-13 §A 二次返修: 打开某数字员工单聊时, 用**当前 AgentItem** 维护左侧会话项,
  /// 避免直接打开已有真实会话时用的是服务端 placeholder 的机器人旧头像/旧名。
  ///
  ///  - [conversationId] 为 pending → 等价 [ensurePendingAgent]。
  ///  - 为真实 id → 若列表已有同 conversationId 或同 agentId 的真实项, 用当前 [agent] 的
  ///    name/avatar 覆盖 title/agentName/agentAvatarUrl/convAvatar 并移到最前;
  ///    若列表里没有 → 用当前 [agent] 前插一条真实项 (头像/名立即正确, 不等服务端)。
  void upsertAgentConversation({
    required AgentItem agent,
    required String conversationId,
    String? roomUuid,
    String? wukongChannelId,
    int? wukongChannelType,
    String? kind,
  }) {
    // Old call preparation may have left a room row as this employee's sidebar
    // item. A local text recovery must not copy its room/channel into a new ID.
    var current = state.asData?.value ?? const <ConversationItem>[];
    if (agent.executionLocus == 'local') {
      current = current
          .where((c) => !(isReusableAgentDirectConversation(c, agent.agentId) &&
              (c.kind != 'single' || (c.roomUuid ?? '').isNotEmpty)))
          .toList();
    }
    if (isPendingConversation(conversationId)) {
      if (agent.executionLocus == 'local') state = AsyncData(current);
      ensurePendingAgent(pendingConversationItem(
        agentUuid: agent.agentId,
        name: agent.name,
        avatarUrl: agent.avatarUrl,
      ));
      return;
    }
    final display = agent.name.trim().isEmpty ? '数字员工' : agent.name.trim();
    int idx = current.indexWhere((c) => c.conversationId == conversationId);
    if (idx < 0) {
      idx = current.indexWhere(
          (c) => isReusableAgentDirectConversation(c, agent.agentId));
    }
    if (idx >= 0) {
      final avatar = pickAgentAvatarUrl(
        agent.avatarUrl,
        current[idx].convAvatar ?? current[idx].agentAvatarUrl,
      );
      final patched = current[idx].copyWith(
        conversationId: conversationId,
        agentId: agent.agentId,
        title: display,
        agentName: display,
        agentAvatarUrl: avatar,
        convAvatar: avatar,
        kind: kind ?? current[idx].kind,
        roomUuid: roomUuid,
        wukongChannelId: wukongChannelId,
        wukongChannelType: wukongChannelType,
      );
      final rest = [
        for (var i = 0; i < current.length; i++)
          if (i != idx &&
              !(_isAgentConversationForDedupe(current[i]) &&
                  current[i].agentId == agent.agentId))
            current[i],
      ];
      state = AsyncData(_dedupeAgentConversations(
        [patched, ...rest],
        preferConversationId: conversationId),
      );
      return;
    }
    // 列表里还没有该会话 → 用当前 AgentItem 前插一条真实项。
    final avatar = pickAgentAvatarUrl(agent.avatarUrl);
    state = AsyncData(_dedupeAgentConversations(
      [
        ConversationItem(
          conversationId: conversationId,
          title: display,
          agentId: agent.agentId,
          agentName: display,
          agentAvatarUrl: avatar,
          convAvatar: avatar,
          kind: kind ??
              (roomUuid != null && roomUuid.isNotEmpty
                  ? 'agent_direct'
                  : 'single'),
          roomUuid: roomUuid,
          wukongChannelId: wukongChannelId,
          wukongChannelType: wukongChannelType,
        ),
        ...current,
      ],
      preferConversationId: conversationId),
    );
  }

  /// doc-13 §A: 首条发送返回真实 conversation_uuid 后, 把 pending 会话栏升级为真实会话。
  /// 保留 pending 的 title/头像/agentId, 仅换 conversationId; 去重已存在的真实项。不重复。
  void adoptPending(
    String pendingId,
    String realConversationId, {
    String? roomUuid,
    String? wukongChannelId,
    int? wukongChannelType,
    String? kind,
  }) {
    final current = state.asData?.value;
    if (current == null || realConversationId.isEmpty) return;
    final idx = current.indexWhere((c) => c.conversationId == pendingId);
    if (idx < 0) return;
    final real = current[idx].copyWith(
      conversationId: realConversationId,
      kind: kind ??
          (roomUuid != null && roomUuid.isNotEmpty
              ? 'agent_direct'
              : current[idx].kind),
      roomUuid: roomUuid,
      wukongChannelId: wukongChannelId,
      wukongChannelType: wukongChannelType,
    );
    final rest = current
        .where((c) =>
            c.conversationId != pendingId &&
            c.conversationId != realConversationId &&
            !(_isAgentConversationForDedupe(c) &&
                real.agentId.isNotEmpty &&
                c.agentId == real.agentId))
        .toList(growable: false);
    state = AsyncData(_dedupeAgentConversations(
      [real, ...rest],
      preferConversationId: realConversationId),
    );
  }

  void patchConversationRuntime({
    required String conversationId,
    String? roomUuid,
    String? wukongChannelId,
    int? wukongChannelType,
    String? kind,
  }) {
    final current = state.asData?.value;
    if (current == null || conversationId.isEmpty) return;
    var changed = false;
    final next = current.map((c) {
      if (c.conversationId != conversationId) return c;
      changed = true;
      return c.copyWith(
        kind: kind,
        roomUuid: roomUuid,
        wukongChannelId: wukongChannelId,
        wukongChannelType: wukongChannelType,
      );
    }).toList(growable: false);
    if (!changed) return;
    state = AsyncData(_dedupeAgentConversations(
      next,
      preferConversationId: conversationId),
    );
  }

  /// 把指定会话的 `unreadCount` 在本地立即清零，避免红点等到下次 refresh。
  /// UI 在用户点开会话时调用，配合 WuKong `markRead` 使用。下次 refresh 仍以
  /// `/chat/conversations` 返回的 WuKong unread 为准：若真实未读仍存在，红点会回来。
  ///
  /// F09 P2 v2: 同时清 markedUnread (与「标为已读」语义一致)。
  void clearUnreadLocally(String conversationId) {
    _touchUnread(conversationId);
    final mentioned = ref.read(mentionedConversationIdsProvider);
    if (mentioned.contains(conversationId)) {
      ref.read(mentionedConversationIdsProvider.notifier).state = {
        ...mentioned
      }..remove(conversationId);
    }
    final current = state.asData?.value;
    if (current == null) return;
    var changed = false;
    final next = current.map((c) {
      if (c.conversationId == conversationId &&
          (c.unreadCount > 0 || c.markedUnread)) {
        changed = true;
        return c.copyWith(unreadCount: 0, markedUnread: false);
      }
      return c;
    }).toList(growable: false);
    debugPrint('[DEBUG clearUnreadLocally] conversationId=$conversationId '
        'changed=$changed');
    if (!changed) return;
    state = AsyncData(next);
  }

  /// F09 P2 v2: 乐观 patch 单条 conversation 的 per-account 视图态。
  /// 仅本地立即生效, 服务端真值以下一次 `/chat/conversations` refresh 为准。
  void patchPerAccountState(
    String conversationId, {
    bool? pinned,
    bool? muted,
    bool? markedUnread,
  }) {
    if (markedUnread != null) _touchUnread(conversationId);
    final current = state.asData?.value;
    if (current == null) return;
    var changed = false;
    final next = current.map((c) {
      if (c.conversationId == conversationId) {
        changed = true;
        return c.copyWith(
          pinned: pinned,
          muted: muted,
          markedUnread: markedUnread,
        );
      }
      return c;
    }).toList(growable: false);
    if (!changed) return;
    // 置顶变化需要重排; 与契约一致 (docs/contracts/agent-bus-client-contract.md §「会话列表
    // 操作菜单 v2」排序契约): pinned 整体优先, 组内仍按 lastMessageAt 降序 (pinned_at 不参
    // 与组内排序)。lastMessageAt 为空者排最后。
    next.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final ta = DateTime.tryParse(a.lastMessageAt ?? '');
      final tb = DateTime.tryParse(b.lastMessageAt ?? '');
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });
    state = AsyncData(next);
  }

  /// F09 P2 v2: 本地把某会话从列表移除 (用于「不显示该会话」乐观 UI)。
  /// 下一次 refresh 后端聚合默认不再返回 hidden 行, 故列表会与之一致;
  /// 失败回滚时调用方应重新 refresh。
  void removeLocally(String conversationId) {
    final current = state.asData?.value;
    if (current == null) return;
    final next = current
        .where((c) => c.conversationId != conversationId)
        .toList(growable: false);
    if (next.length == current.length) return;
    state = AsyncData(next);
  }

  void prepend(ConversationItem item) {
    final current = state.asData?.value ?? const <ConversationItem>[];
    if (current.any((c) => c.conversationId == item.conversationId)) {
      return;
    }
    state = AsyncData([item, ...current]);
  }

  /// 增量更新某个会话条目（如 SSE 完成后回填 lastMessage / lastMessageAt），
  /// 找不到则忽略。仅替换字段，不会重排顺序。
  void patchConversation(
    String conversationId, {
    String? lastMessage,
    String? lastMessageAt,
    String? updatedAt,
  }) {
    final current = state.asData?.value;
    if (current == null) return;
    var changed = false;
    final next = current.map((c) {
      if (c.conversationId == conversationId) {
        changed = true;
        return c.copyWith(
          lastMessage: lastMessage ?? c.lastMessage,
          lastMessageAt: lastMessageAt ?? c.lastMessageAt,
          updatedAt: updatedAt ?? c.updatedAt,
        );
      }
      return c;
    }).toList(growable: false);
    if (!changed) return;
    state = AsyncData(next);
  }

  void patchConversationTitle(String conversationId, String title) {
    final current = state.asData?.value;
    if (current == null || conversationId.isEmpty) return;
    var changed = false;
    final next = current.map((c) {
      if (c.conversationId == conversationId && c.title != title) {
        changed = true;
        return c.copyWith(title: title);
      }
      return c;
    }).toList(growable: false);
    if (!changed) return;
    state = AsyncData(next);
  }

  /// WuKong human_direct/group 实时消息本地物化 (docs/contracts §P2.1b 客户端会话列表实时更新):
  /// 按 channel 匹配会话 → patch 预览/时间 → 置顶 → 处理未读 → 去重。**会重排** (与 patchConversation 不同)。
  ///   - 当前打开会话 → unread 清 0 (WuKong 红点由右侧 pane markRead 负责, 这里只管左侧本地 badge)。
  ///   - 非当前 + 非自己 → unread +1; 非当前 + 自己(WuKong 自回显) → 更新预览但 unread 不变。
  /// 不命中快照里任何会话 → 返回 false, 调用方 debounce refresh 权威快照; 不在此凭空创建会话。
  bool applyRealtimeMessage({
    required String channelId,
    required int channelType,
    required String previewText,
    required bool fromSelf,
    required Set<String> currentConversationIds,
    int messageTimestamp = 0,
    String dedupId = '',
  }) {
    final current = state.asData?.value;
    if (current == null || channelId.isEmpty) return false;
    final idx = current.indexWhere((c) =>
        c.wukongChannelId == channelId && c.wukongChannelType == channelType);
    if (idx < 0) return false;
    if (_seenRealtime(dedupId)) return true; // 重复消息 → 跳过, 不重复加未读/置顶
    final item = current[idx];
    _touchUnread(item.conversationId);
    final isCurrent = currentConversationIds.contains(item.conversationId);
    final int nextUnread;
    // 用消息发生时间, 不用收到事件的时间 (延迟 / 离线补到时仍显示消息时刻)。
    final occurredIso = _resolveOccurredAtIso(messageTimestamp);
    if (isCurrent) {
      nextUnread = 0;
    } else if (fromSelf) {
      nextUnread = item.unreadCount;
    } else {
      nextUnread = item.unreadCount + 1;
    }
    debugPrint(
        '[DEBUG applyRealtimeMessage] conversationId=${item.conversationId} '
        'isCurrent=$isCurrent fromSelf=$fromSelf '
        'unread ${item.unreadCount}->$nextUnread currentIds=$currentConversationIds');
    final patched = item.copyWith(
      lastMessage: previewText,
      lastMessageAt: occurredIso,
      updatedAt: occurredIso,
      unreadCount: nextUnread,
    );
    final next = <ConversationItem>[patched];
    for (var i = 0; i < current.length; i++) {
      if (i != idx) next.add(current[i]);
    }
    state = AsyncData(next);
    return true;
  }

  /// 数字员工单聊本地预览更新 (用户发送 / Agent 回复完成 / 出错时调): patch 预览 + 置顶, **不加未读**。
  /// 仅动 conversationsProvider, 不触 chatProvider —— 不影响右侧 Agent 执行过程 (SSE) 展示。
  /// 找不到该会话 (尚未 adopt) → no-op。
  void applyAgentConversationPreview(
    String conversationId, {
    required String lastMessage,
  }) {
    final current = state.asData?.value;
    if (current == null || conversationId.isEmpty) return;
    final idx = current.indexWhere((c) => c.conversationId == conversationId);
    if (idx < 0) return;
    final item = current[idx];
    // agent-direct 发送时 WuKong 本端回显会先把左侧预览更新一次，随后
    // ChatNotifier._afterRunStarted 还会带同一段 preview 再进来。若这里继续写
    // DateTime.now()，会让 sidebar 多重建一次，看起来像整列表刷新。相同预览且刚更新过
    // 的 top item 直接跳过；旧的同文案消息仍允许刷新时间。
    if (idx == 0 &&
        (item.lastMessage ?? '').trim() == lastMessage.trim() &&
        _isRecentConversationActivity(item.displayTimeRaw)) {
      return;
    }
    final nowIso = DateTime.now().toIso8601String();
    final patched = item.copyWith(
      lastMessage: lastMessage,
      lastMessageAt: nowIso,
      updatedAt: nowIso,
    );
    final next = <ConversationItem>[patched];
    for (var i = 0; i < current.length; i++) {
      if (i != idx) next.add(current[i]);
    }
    state = AsyncData(next);
  }

  bool _isRecentConversationActivity(String? raw) {
    if (raw == null || raw.trim().isEmpty) return false;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return false;
    final diff = DateTime.now().difference(parsed.toLocal()).abs();
    return diff <= const Duration(seconds: 3);
  }
}

ConversationItem _enrichAgentConversation(
    ConversationItem item, AgentItem? agent) {
  if (agent == null) return item;
  final name = agent.name.trim();
  final avatar = pickAgentAvatarUrl(
      agent.avatarUrl, item.convAvatar ?? item.agentAvatarUrl);
  if (name.isEmpty && avatar == null) return item;
  return item.copyWith(
    title: name.isNotEmpty ? name : item.title,
    agentName: name.isNotEmpty ? name : item.agentName,
    agentAvatarUrl: avatar ?? item.agentAvatarUrl,
    convAvatar: avatar ?? item.convAvatar,
  );
}

AgentItem _preferRicherAgent(AgentItem candidate, AgentItem fallback) {
  String pick(String a, String b) => a.trim().isNotEmpty ? a : b;
  String pickAvatar(String a, String b) => pickAgentAvatarUrl(a, b) ?? '';
  return fallback.copyWith(
    name: pick(candidate.name, fallback.name),
    description: pick(candidate.description, fallback.description),
    avatarUrl: pickAvatar(candidate.avatarUrl, fallback.avatarUrl),
    position: pick(candidate.position, fallback.position),
    positionLabel: pick(candidate.positionLabel, fallback.positionLabel),
    departmentName: pick(candidate.departmentName, fallback.departmentName),
    runtimeEnvironmentUuid: pick(
      candidate.runtimeEnvironmentUuid,
      fallback.runtimeEnvironmentUuid,
    ),
    skills: candidate.skills.isNotEmpty ? candidate.skills : fallback.skills,
    apps: candidate.apps.isNotEmpty ? candidate.apps : fallback.apps,
    supportsSkillBindings: candidate.supportsSkillBindings,
    canManageSkills: candidate.canManageSkills,
  );
}

/// doc-13 §A：数字员工单聊 **create-on-first-send** 的"未建会话"哨兵。
/// 形如 `pending:<agentUuid>`：卡片点击进入"绑定 agent 的空会话"，`activeConversationId`
/// 设为本哨兵；首条 [ChatNotifier.send] 由 agent-bus `POST /chat/send` 建会话并 adopt 真实
/// `conversation_uuid`。带哨兵的会话**不**调 `getHistory`（后端尚无此会话）。
const String pendingConversationPrefix = 'pending:';

bool isPendingConversation(String? id) =>
    id != null && id.startsWith(pendingConversationPrefix);

String pendingConversationFor(String agentUuid) =>
    '$pendingConversationPrefix$agentUuid';

String agentUuidFromPending(String pendingId) =>
    pendingId.substring(pendingConversationPrefix.length);

/// 判断某会话是否可作为"该数字员工的单聊"被复用:必须是 agent 单聊(**非群聊、非人↔人**)、
/// agentId 匹配、且非 pending 哨兵。数字员工 / 通讯录入口查找既有单聊用此判定,避免把"含该
/// agent 的群聊"误当单聊复用(ConversationItem.fromJson 会从群成员写入 agentId)。
bool isReusableAgentDirectConversation(ConversationItem item, String agentId) =>
    item.agentId == agentId &&
    !item.isGroup &&
    !item.isHumanDirect &&
    !isPendingConversation(item.conversationId);

/// doc-13 §A: 构造数字员工的临时会话栏 item (左侧列表渲染 + create-on-first-send)。
ConversationItem pendingConversationItem({
  required String agentUuid,
  required String name,
  String? avatarUrl,
}) {
  return ConversationItem.pendingAgent(
    conversationId: pendingConversationFor(agentUuid),
    agentUuid: agentUuid,
    name: name,
    avatarUrl: avatarUrl,
  );
}

bool _isAgentConversationForDedupe(ConversationItem item) =>
    item.agentId.isNotEmpty && !item.isHumanDirect && !item.isGroup;

/// 同一个数字员工在左侧列表只展示一条会话。
///
/// 服务端可能同时返回历史占位会话和刚由客户端 upsert/adopt 的当前会话
/// (例如同一 agentId 的「你好啊」旧项与「许文博」新项)。客户端不静默删服务端
/// 数据，只按 agentId 合并展示；若传入 [preferConversationId]，优先保留当前打开
/// / 刚 upsert / 刚 adopt 的会话项。
List<ConversationItem> _dedupeAgentConversations(
  List<ConversationItem> items, {
  String? preferConversationId,
}) {
  if (items.length < 2) return items.toList(growable: false);

  final ordered = <ConversationItem>[];
  if (preferConversationId != null && preferConversationId.isNotEmpty) {
    ordered
        .addAll(items.where((c) => c.conversationId == preferConversationId));
  }
  for (final item in items) {
    if (preferConversationId != null &&
        item.conversationId == preferConversationId) {
      continue;
    }
    ordered.add(item);
  }

  final seenConversationIds = <String>{};
  final seenAgentIds = <String>{};
  final result = <ConversationItem>[];
  for (final item in ordered) {
    if (!seenConversationIds.add(item.conversationId)) continue;
    if (_isAgentConversationForDedupe(item) &&
        !seenAgentIds.add(item.agentId)) {
      continue;
    }
    result.add(item);
  }
  return result.toList(growable: false);
}

final chatProvider = AsyncNotifierProvider<ChatNotifier, ChatState>(
  ChatNotifier.new,
);

class ChatNotifier extends AsyncNotifier<ChatState> {
  static const int _historyPageSize = 20;
  static const Duration _agentMetadataRefreshDelay = Duration(seconds: 3);
  static const Duration _billingWalletRefreshDelay = Duration(seconds: 6);

  /// F09 §5.7 / 契约 §3.0f：per-stream runtime 注册表（C5/C10）。
  /// 每条流独立的 stopped 标志、目标消息绑定与取消能力都在 runtime 上，
  /// 不再有任何全局单份流式状态；正文 delta 由 runtime 自己的 frame 队列写入
  /// 目标消息。
  final ChatStreamRuntimeRegistry _runtimes = ChatStreamRuntimeRegistry();

  /// 历史分页兜底页码按会话隔离（before 游标缺失时才用，见 loadMoreHistory）。
  final Map<String, int> _historyPageByConv = {};

  /// send/attach 响应尚未返回时被用户停止的 run（键 = placeholder localId，
  /// 全局唯一）。迟到响应命中时：best-effort 调后端 stop、pending→real 照常
  /// canonicalize，但**绝不**订阅流复活生成（Codex review P1-1）。
  final Set<String> _cancelledPendingRuns = {};

  /// 已由当前客户端主动停止、且已经绑定服务端 agent message uuid 的消息。
  ///
  /// stop 与服务端最终落库存在竞态：本地已经收口后，conversation 轮询可能先拉到
  /// 一份迟到的 final 历史。当前 provider 生命周期内必须继续保留用户的停止投影，
  /// 不能让历史刷新把完整答案重新写回气泡。
  final Set<String> _locallyStoppedMessageIds = {};

  /// `/chat/respond` 已发出但尚未返回 stream 的会话级占用。
  ///
  /// 这段窗口里服务端 run 尚未建立，不能伪装成可 stop 的 [isSending]；但同会话
  /// 的普通 send / 另一条 HITL 必须被 C2 闸口挡住。Dart isolate 内 check + add
  /// 同步完成，因此这是原子 reservation；不同会话仍可并行。
  final Set<String> _respondingConversations = {};

  /// 普通 send 已创建本地 placeholder、但服务端尚未返回 stream 的会话级占用。
  ///
  /// `ChatSessionState.isSending` 只是可被历史缓存保留下来的 UI 投影，不能证明
  /// POST 仍在进行。这里按 canonical conversation key 显式登记本次请求绑定的
  /// placeholder localId，既用于 C2 单会话闸口，也用于切换时判断停止按钮是否
  /// 真有可等待/可停止的 run。
  final Map<String, String> _startingRunByConversation = {};

  /// 订阅时直接失败（HTTP 错误/断网/死流）的 stream id。这类流的服务端 run
  /// 已不可达，不再自动 resume；配合订阅失败时的目标化收口与历史对账，
  /// 防止会话永久卡在「思考中 + 停止按钮」。
  final Set<String> _deadStreams = {};
  final Map<String, int> _accountHistoryRequests = {};

  Timer? _agentMetadataRefreshTimer;
  Timer? _billingWalletRefreshTimer;

  // ---------------- workspace / session 写入原语 ----------------
  // 契约 C1：唯一可写状态源是 ChatWorkspaceState；所有写入经 canonical key
  // 解析（C6 alias），fail closed（C5/R3）：找不到目标就记日志丢弃，绝不回退
  // active 会话或"最后一条 assistant"。

  ChatWorkspaceState get _ws =>
      state.asData?.value ?? const ChatWorkspaceState.initial();

  String _canon(String id) => _ws.canonicalKey(id);

  /// session 里的 `isSending/activeStreamId` 只是 UI 索引，不能单独证明底层流仍
  /// 存活。真实运行只认两类权威登记：POST 尚未返回的 starting-run，或已经注册
  /// 的 per-stream runtime。否则就是需要立即清理并与历史对账的失效运行态。
  bool _hasLiveRun(String conversationKey, ChatSessionState session) {
    final key = _canon(conversationKey);
    if (_runtimes.forConversation(key) != null) return true;
    final startingPlaceholder = _startingRunByConversation[key];
    if (startingPlaceholder != null &&
        session.isSending &&
        session.activeLocalPlaceholderId == startingPlaceholder) {
      return true;
    }
    // agent-direct 的 stop 可能发生在 attach 返回 agent_message_uuid 之前。
    // 这段窗口虽已不再显示 sending，但历史刷新必须继续受保护，否则迟到的
    // final 会先于 attach 回包覆盖本地“已停止”气泡。
    return session.messages.any(
      (message) => _cancelledPendingRuns.contains(message.localId),
    );
  }

  void _setWorkspace(ChatWorkspaceState ws) {
    if (!ref.mounted) return;
    state = AsyncData(ws);
  }

  void _setSession(String canonicalKey, ChatSessionState session) {
    final ws = _ws;
    _setWorkspace(
      ws.copyWith(sessions: {...ws.sessions, canonicalKey: session}),
    );
  }

  void _updateSession(
    String conversationId,
    ChatSessionState Function(ChatSessionState session) update, {
    String tag = '',
  }) {
    final key = _canon(conversationId);
    final existing = _ws.sessions[key];
    if (existing == null) {
      if (kDebugMode) {
        debugPrint('[chat] fail-closed: session $key missing ($tag)');
      }
      return;
    }
    _setSession(key, update(existing));
  }

  /// 测试播种入口：直接构造某会话的 session 分区（替代旧 flat copyWith 写路径）。
  @visibleForTesting
  void debugSeedSession(
    String conversationId, {
    List<ChatMessage>? messages,
    List<ChatFileItem>? pendingFiles,
    bool? isSending,
    ChatComposerDraft? draft,
    bool makeActive = true,
  }) {
    final ws = _ws;
    final key = ws.canonicalKey(conversationId);
    var session = ws.sessions[key] ?? ChatSessionState(conversationId: key);
    session = session.copyWith(
      messages: messages ?? session.messages,
      pendingFiles: pendingFiles ?? session.pendingFiles,
      isSending: isSending ?? session.isSending,
      draft: draft ?? session.draft,
    );
    final sessions = {...ws.sessions, key: session};
    state = AsyncData(makeActive
        ? ws.copyWith(activeConversationId: key, sessions: sessions)
        : ws.copyWith(sessions: sessions));
  }

  @visibleForTesting
  ChatSessionState? debugSession(String conversationId) =>
      _ws.sessionOf(conversationId);

  // ADR-0026 Flutter cutover:本会话此前 prepare 返回 404 disabled → 后续 agent-direct 发送直接走旧
  // /chat/send,不再重复 prepare(避免每次发都打一次 404)。
  bool _agentDirectDualChannelDisabled = false;

  /// 测试注入点:覆盖 agent-direct 双通道编排结果(返回 streamReady/fallback/failed);生产为 null。
  @visibleForTesting
  Future<AgentDirectSendOutcome> Function(
    String agentUuid,
    List<ImMessageBlock> blocks,
    String summary,
  )? debugAgentDirectSendOverride;

  /// 既有 provider 单测不驱动 Flutter 帧，可注入微任务调度器；生产始终为 null，
  /// 使用真实 [SchedulerBinding]。有界帧行为由专门 widget tests 覆盖。
  @visibleForTesting
  int Function(FrameCallback callback)? debugScheduleAnswerFrameCallback;

  @visibleForTesting
  void Function(int callbackId)? debugCancelAnswerFrameCallback;

  @override
  Future<ChatState> build() async {
    final resultsSubscription =
        LocalAgentService.instance.resultsSaved.listen((conversation) {
      if (ref.mounted && _ws.sessions.containsKey(_canon(conversation))) {
        unawaited(_reconcileSessionHistory(_canon(conversation)));
      }
    });
    ref.onDispose(() => unawaited(resultsSubscription.cancel()));
    ref.onDispose(() {
      _agentMetadataRefreshTimer?.cancel();
      _billingWalletRefreshTimer?.cancel();
      // 契约 C12/V14：provider dispose（logout / 切租户走 sessionScopeKey 重建
      // ProviderScope 触发）必须真取消全部流：断底层 SSE 订阅 + 清 Timer + 清注册表。
      _runtimes.cancelAll();
      _cancelledPendingRuns.clear();
      _locallyStoppedMessageIds.clear();
      _respondingConversations.clear();
      _startingRunByConversation.clear();
      _deadStreams.clear();
      _accountHistoryRequests.clear();
    });

    // 监听 conversationsProvider 的刷新（30s 轮询 / cron 推送后红点更新）：
    // 如果当前 active 会话的 lastMessageAt 变新了（典型：cron-done 写库 +
    // 列表轮询拿到新值），主动重拉一次 history 把新消息追加到右侧聊天面板。
    // 不依赖 SSE，纯轮询触发追加；用 ref.listen 不会触发 build 重建，避免
    // 整个面板刷掉运行时累积的 timeline / streaming 状态。
    ref.listen<AsyncValue<List<ConversationItem>>>(conversationsProvider, (
      prev,
      next,
    ) {
      final prevList = prev?.asData?.value;
      final nextList = next.asData?.value;
      if (nextList == null) return;
      unawaited(_maybeAppendIncoming(prevList, nextList));
    });

    // F16 A1 · agent 语音通话结束 → reload 当前会话 canonical 历史，live 转写气泡
    // 被持久消息替换（设计 §3.4 方案 C）。用 addListener 而非 watch：provider 值恒为
    // 同一 controller 实例（watch 永不触发），且通话状态变化不应重建本 notifier。
    final rtcController = ref.read(rtcCallControllerProvider);
    var seenAgentCallEndedTick = rtcController.agentCallEndedTick;
    void onRtcCallChanged() {
      final tick = rtcController.agentCallEndedTick;
      if (tick == seenAgentCallEndedTick) return;
      seenAgentCallEndedTick = tick;
      final ended = rtcController.lastEndedAgentConversationUuid;
      final active = state.asData?.value.activeConversationId;
      if (ended == null || ended != active) return;
      unawaited(reloadActiveMessages());
    }

    rtcController.addListener(onRtcCallChanged);
    ref.onDispose(() => rtcController.removeListener(onRtcCallChanged));

    // 用 read 而不是 watch：conversationsProvider 的后续刷新（红点更新、轮询、
    // SSE patch 等）不应该触发 ChatNotifier 重建，否则会重新拉全量历史导致
    // 右侧聊天面板整体刷新。新增 / 选择 / 删除 会话的场景均通过显式调用
    // selectConversation/createConversation/deleteConversation 同步 active id。
    final previous = state.asData?.value;
    final currentActive = previous?.activeConversationId;

    // doc-13 §A 二次返修: create-on-first-send 哨兵 active —— 服务端尚无此会话, **保留** active
    // 但**绝不** getHistory(否则 404)。首屏空态待输入, 首条 send 由 /chat/send 建会话再 adopt。
    // 必须先于"列表为空 → initial"判断, 否则 server 列表(不含 pending)空时会丢掉刚选中的 pending。
    final base = previous ?? const ChatWorkspaceState.initial();
    if (isPendingConversation(currentActive)) {
      final key = currentActive!;
      final session =
          base.sessions[key] ?? ChatSessionState(conversationId: key);
      final pendingState = base.copyWith(
        activeConversationId: key,
        sessions: {...base.sessions, key: session.copyWith(clearError: true)},
      );
      state = AsyncData(pendingState);
      return pendingState;
    }

    final conversations = await ref.read(conversationsProvider.future);
    if (conversations.isEmpty) {
      // 保留既有 sessions（后台流不因 rebuild 丢失），仅清 active。
      return base.copyWith(clearActiveConversation: true);
    }

    final service = ref.read(chatServiceProvider);
    // P2.1/P2.3a(ADR-0026):human_direct 由 HumanDirectChatPane、group 由 GroupChatPane(均 WuKong)
    // 打开,**绝不**走 legacy `getHistory`(/app/openclaw-agent/.../messages)。自动选中默认只在
    // 非 human_direct、非 group 会话里挑;若没有可走 legacy 的会话,active 置空、不拉历史。
    final legacySelectable = conversations
        .where((item) => !item.isHumanDirect && !item.isGroup)
        .toList();
    // doc-13 §A 二次返修: **保留** currentActive(真实且仍在可走列表里), 不被 first 抢;
    // 都不满足才兜底第一条。currentActive 可能是已被 adopt 的旧 key → 先 canonical 解析。
    final resolvedActive = (currentActive == null || currentActive.isEmpty)
        ? null
        : base.canonicalKey(currentActive);
    final String? active = (resolvedActive != null &&
            resolvedActive.isNotEmpty &&
            legacySelectable
                .any((item) => item.conversationId == resolvedActive))
        ? resolvedActive
        : (legacySelectable.isNotEmpty
            ? legacySelectable.first.conversationId
            : null);
    if (active == null) {
      // 列表里只有 human_direct(或空):右栏交给 HumanDirectChatPane,这里不持 active、不拉 legacy。
      return base.copyWith(clearActiveConversation: true);
    }

    final cached =
        base.sessions[active] ?? ChatSessionState(conversationId: active);
    // 该会话有运行中的流或已有缓存 → 直接展示缓存，绝不重拉覆盖 partial（C3/V4/V11）。
    if (cached.hasActiveRun ||
        _runtimes.forConversation(active) != null ||
        cached.messages.isNotEmpty) {
      final ws = base.copyWith(
        activeConversationId: active,
        sessions: {...base.sessions, active: cached},
      );
      state = AsyncData(ws);
      return ws;
    }

    state = AsyncData(base.copyWith(
      activeConversationId: active,
      sessions: {
        ...base.sessions,
        active: cached.copyWith(
          hasMoreHistory: true,
          isLoadingMessages: true,
          clearError: true,
        ),
      },
    ));

    final diskHistory = await service.getCachedHistory(active,
        clearedAt: _conversationItemById(active)?.clearedAt);
    if (!ref.mounted) return base;
    if (diskHistory.isNotEmpty &&
        !_hasLiveRun(active, _ws.sessions[active] ?? cached)) {
      _updateSession(
          active,
          tag: 'localHistory',
          (s) => s.copyWith(messages: diskHistory, isLoadingMessages: false));
    }
    final List<ChatMessage> history;
    try {
      history = active.startsWith(pendingConversationPrefix)
          ? const <ChatMessage>[]
          : await service.synchronizeHistory(active);
    } catch (e) {
      if (!ref.mounted) return base;
      final denied =
          e is DioException && [401, 403, 404].contains(e.response?.statusCode);
      final current = _ws.sessions[active];
      if (current == null || _hasLiveRun(active, current)) return _ws;
      _updateSession(
          active,
          tag: 'historySyncFailed',
          (s) => s.copyWith(
              messages: denied ? const [] : s.messages,
              isLoadingMessages: false,
              errorMessage: '同步会话失败: $e'));
      return _ws;
    }
    if (!ref.mounted) return base;
    final wsAfter = _ws;
    final latestSession = wsAfter.sessions[active];
    if (latestSession == null || latestSession.hasActiveRun) {
      // 期间会话被删或起了 run → 放弃本次替换（fail closed / V11）。
      return wsAfter;
    }
    // 合并上一份 session 中已累积的流式上下文（timeline / usage / 起止时间），
    // 防止 conversationsProvider 刷新触发的 build() 把 getHistory 返回的
    // 干净 message 覆盖掉运行时构建的执行过程信息。
    final messages = _mergeRuntimeContext(
      history: history,
      previous:
          latestSession.messages.isNotEmpty ? latestSession.messages : null,
    );
    final wsFinal = wsAfter.copyWith(sessions: {
      ...wsAfter.sessions,
      active: latestSession.copyWith(
        messages: messages,
        isSending: false,
        hasMoreHistory: messages.length >= _historyPageSize,
        isLoadingHistory: false,
        isLoadingMessages: false,
        clearError: true,
      ),
    });
    state = AsyncData(wsFinal);
    _resumePendingStream(active, messages);
    return wsFinal;
  }

  Future<void> refreshConversations() async {
    await ref.read(conversationsProvider.notifier).refresh();
  }

  /// doc-13 §A：开启与当前选中数字员工的**新单聊**。agent-bus 无创建会话端点，
  /// 这里只设 create-on-first-send 哨兵（不调网络）；首条 [send] 由 `/chat/send` 建会话。
  Future<void> createConversation() async {
    final current = state.asData?.value;
    if (current == null) return;
    final agent = await ref.read(selectedAgentProvider.future);
    if (agent == null || agent.agentId.isEmpty) return;
    // doc-13 §A: 左侧列表插入临时会话栏 (标题/头像取该数字员工), 让会话立即可见 + 可选中。
    ref.read(conversationsProvider.notifier).ensurePendingAgent(
          pendingConversationItem(
            agentUuid: agent.agentId,
            name: agent.name,
            avatarUrl: agent.avatarUrl,
          ),
        );
    final pendingKey = pendingConversationFor(agent.agentId);
    // 已被 adopt 过的 pending key → 直接打开 canonical 真会话（C6 alias）。
    final canonical = current.canonicalKey(pendingKey);
    if (canonical != pendingKey) {
      await selectConversation(canonical);
      return;
    }
    ref.read(activePendingConversationProvider.notifier).state = pendingKey;
    final ws = _ws;
    final session =
        ws.sessions[pendingKey] ?? ChatSessionState(conversationId: pendingKey);
    // 保留该 pending 会话既有草稿/附件（C7），只清 error。
    _setWorkspace(ws.copyWith(
      activeConversationId: pendingKey,
      sessions: {
        ...ws.sessions,
        pendingKey: session.copyWith(clearError: true)
      },
    ));
  }

  Future<void> deleteConversation(String conversationId) async {
    final current = state.asData?.value;
    if (current == null) return;
    final key = current.canonicalKey(conversationId);

    ref.read(conversationsProvider.notifier).removeLocally(key);
    final service = ref.read(chatServiceProvider);
    try {
      await service.deleteConversation(key);
    } catch (_) {
      await ref.read(conversationsProvider.notifier).refresh();
      rethrow;
    }
    await ref.read(conversationsProvider.notifier).refresh();

    // 契约 C12/V14：真取消该会话全部 runtime；清 session；canonical 删除时
    // alias 一并清（指向它的与它自身的映射都失效）。只影响该会话（V15 反向）。
    _runtimes.cancelForConversation(key);
    _startingRunByConversation.remove(key);
    final ws = _ws;
    final sessions = {...ws.sessions}..remove(key);
    final aliases = {
      for (final e in ws.aliases.entries)
        if (e.value != key && e.key != key) e.key: e.value,
    };
    final wasActive = ws.activeConversationId != null &&
        ws.canonicalKey(ws.activeConversationId!) == key;
    if (wasActive) {
      ref.read(selectedHumanDirectProvider.notifier).state = null;
      ref.read(selectedGroupProvider.notifier).state = null;
      ref.read(selectedAgentProvider.notifier).clear();
      _setWorkspace(ChatWorkspaceState(
        activeConversationId: null,
        sessions: sessions,
        aliases: aliases,
      ));
    } else {
      _setWorkspace(ws.copyWith(sessions: sessions, aliases: aliases));
    }
  }

  /// 「在对话中查看 cron 历史」深度跳转入口：切到目标会话 + 围绕目标消息加载
  /// 上下文窗口（前后各 [windowSize] 条）+ 自动 highlight 目标气泡。
  ///
  /// 为什么不用 [selectConversation]：默认逻辑只拉首页 20 条最新消息，几千条
  /// 之前的目标 cron 消息根本不会进 messages 列表，[ChatMessageList] 找不到
  /// GlobalKey 也就 ensureVisible 不到。这里用 GET .../messages/around 居中
  /// 切窗，保证目标消息一定在 state.messages 里，hasMoreHistory 仍然为 true，
  /// 用户继续上滚还能往更早的方向 [loadMoreHistory]。
  Future<void> selectConversationAtMessage({
    required String conversationId,
    required String messageUuid,
    int windowSize = 20,
  }) async {
    final key = _canon(conversationId);

    // 同步 selectedAgentProvider（参考 selectConversation 的逻辑），让顶部姓名 / 技能正确切换。
    final convs = ref.read(conversationsProvider).asData?.value ??
        const <ConversationItem>[];
    final agents =
        ref.read(agentsProvider).asData?.value ?? const <AgentItem>[];
    ref
        .read(selectedAgentProvider.notifier)
        .selectByConversationId(key, convs, agents);

    final ws = _ws;
    final existing = ws.sessions[key];
    // 该会话正在生成 → around 重切窗会冲掉运行中的 placeholder（V11）。
    // 降级为普通打开 + 首屏内高亮 best-effort。
    if (existing != null &&
        (existing.hasActiveRun || _runtimes.forConversation(key) != null)) {
      await selectConversation(key);
      requestHighlightMessage(messageUuid);
      return;
    }

    final base = existing ?? ChatSessionState(conversationId: key);
    _setWorkspace(ws.copyWith(
      activeConversationId: key,
      sessions: {
        ...ws.sessions,
        key: base.copyWith(
          messages: const [],
          hasMoreHistory: true,
          isLoadingHistory: false,
          isLoadingMessages: true,
          clearError: true,
          clearHighlight: true,
        ),
      },
    ));
    _markCurrentConversationRead(key);
    _historyPageByConv[key] =
        1; // around 窗口替代首页，后续 loadMoreHistory 仍按 oldest.id 上拉

    final service = ref.read(chatServiceProvider);
    try {
      final around = await service.getHistoryAround(
        conversationId: key,
        messageUuid: messageUuid,
        windowSize: windowSize,
      );
      // 目标化写回：即使用户已切走，也只写本会话分区（C8/C9）。
      _updateSession(key, tag: 'around', (s) {
        if (s.hasActiveRun) return s; // 期间起了 run → 放弃覆盖（V11）
        return s.copyWith(
          messages: around.items,
          hasMoreHistory: around.hasMoreUp,
          hasMoreNewer: around.hasMoreDown,
          isLoadingMessages: false,
          // 同时把 highlight 请求一起塞进 state，UI 一次重建就能完成"画消息 + 滚到位 + 闪一下"
          highlightMessageUuid: messageUuid,
          highlightToken: s.highlightToken + 1,
        );
      });
    } catch (e) {
      // around 失败兜底改拉会话首页（agent-bus 暂无 messages/around 端点，
      // 老消息定位为后端迁移项）。P1-4（契约 C8/C9）：兜底**只更新本会话
      // 分区**，绝不 selectConversation 抢回选中——用户等待期间切到 B 时，
      // A 的失败响应不得把界面切回 A；高亮/降级提示也只在 active 仍为 A 时处理。
      try {
        final history = await _withAgentDirectCallEvents(
          conversation: _conversationItemById(key),
          history: await service.getHistory(conversationId: key),
        );
        _updateSession(key, tag: 'aroundFallback', (s) {
          if (s.hasActiveRun) {
            return s.copyWith(isLoadingMessages: false); // V11：不覆盖运行中
          }
          final merged = _mergeRuntimeContext(
            history: history,
            previous: s.messages.isNotEmpty ? s.messages : null,
          );
          return s.copyWith(
            messages: merged,
            hasMoreHistory: merged.length >= _historyPageSize,
            hasMoreNewer: false,
            isLoadingMessages: false,
          );
        });
      } catch (e2) {
        _updateSession(
            key,
            tag: 'aroundFallback',
            (s) => s.copyWith(
                errorMessage: '加载会话失败: $e2', isLoadingMessages: false));
      }
      final act = _ws.activeConversationId;
      if (act != null && _ws.canonicalKey(act) == key) {
        requestHighlightMessage(messageUuid);
        final loaded = _ws.sessions[key];
        final visible =
            loaded != null && loaded.messages.any((m) => m.uuid == messageUuid);
        if (!visible) {
          BotToast.showText(text: '已打开会话；该条记录较早，未能自动定位，可向上翻阅查看');
        }
      }
    }
  }

  /// 请求把某条消息「滚动 + 高亮闪烁」。仅在当前 active 会话里有效；
  /// 通常由「在对话中查看 cron 历史」链路在 selectConversation 之后调用。
  /// token 自增确保同一条消息被点两次也能再次触发动画。
  void requestHighlightMessage(String messageUuid) {
    final activeId = state.asData?.value.activeConversationId;
    if (activeId == null) return;
    _updateSession(activeId, tag: 'highlight', (s) {
      return s.copyWith(
        highlightMessageUuid: messageUuid,
        highlightToken: s.highlightToken + 1,
      );
    });
  }

  /// UI 完成滚动 + 高亮动画后调用，清掉 state 上的 highlight 标记。
  void consumeHighlight() {
    final current = state.asData?.value;
    final activeId = current?.activeConversationId;
    if (current == null ||
        activeId == null ||
        current.highlightMessageUuid == null) {
      return;
    }
    _updateSession(
        activeId,
        tag: 'consumeHighlight',
        (s) => s.copyWith(clearHighlight: true));
  }

  Future<void> selectConversation(String conversationId) async {
    void clearNonAgentPanes() {
      ref.read(selectedHumanDirectProvider.notifier).state = null;
      ref.read(selectedGroupProvider.notifier).state = null;
    }

    // doc-13 §A: create-on-first-send 哨兵会话 —— 后端尚无此会话, **不**调 getHistory;
    // 进入"绑定 agent 的空会话", 首条 send 由 /chat/send 建会话并 adopt 真实 uuid。
    if (isPendingConversation(conversationId)) {
      // 已被 adopt 的 pending key → 打开 canonical 真会话（C6 alias 解析）。
      final canonical = _canon(conversationId);
      if (canonical != conversationId) {
        return selectConversation(canonical);
      }
      clearNonAgentPanes();
      ref.read(activePendingConversationProvider.notifier).state =
          conversationId;
      final ws = _ws;
      final session = ws.sessions[conversationId] ??
          ChatSessionState(conversationId: conversationId);
      // 保留该 pending 会话的草稿/附件/消息缓存（C7），只清 error。
      _setWorkspace(ws.copyWith(
        activeConversationId: conversationId,
        sessions: {
          ...ws.sessions,
          conversationId: session.copyWith(clearError: true),
        },
      ));
      return;
    }

    // P2.1(ADR-0026)防御:human_direct 会话**绝不**走 legacy getHistory。
    // 正常入口由侧栏路由到 selectedHumanDirectProvider;此处兜底:若误传 human_direct,
    // 改设 selectedHumanDirectProvider 并直接返回,不触 legacy message/read API。
    final convsForKind = ref.read(conversationsProvider).asData?.value ??
        const <ConversationItem>[];
    for (final c in convsForKind) {
      if (c.conversationId != conversationId) continue;
      // P2.3a(ADR-0026)防御:误传 group id(如外部入口复用了"含该 agent 的群聊")→ 走群聊选择
      // 状态(GroupChatPane),**绝不**当 agent chat 打开。否则会出现"左侧群聊高亮 + 右侧 agent 内容"
      // 混合态。正常 sidebar 点群聊在 sidebar 层已路由,不经过这里。
      if (c.isGroup && (c.wukongChannelId?.isNotEmpty ?? false)) {
        ref.read(selectedHumanDirectProvider.notifier).state = null;
        ref.read(selectedGroupProvider.notifier).state = GroupSelection(
          conversationId: c.conversationId,
          roomUuid: c.roomUuid ?? '',
          channelId: c.wukongChannelId!,
          channelType: c.wukongChannelType ?? 2,
          title: c.title,
          participants: c.participants,
          clearedAt: c.clearedAt,
          canRenameGroup: c.canRenameGroup,
        );
        _markCurrentConversationRead(c.conversationId);
        return;
      }
      if (c.isHumanDirect && (c.wukongChannelId?.isNotEmpty ?? false)) {
        ref.read(selectedGroupProvider.notifier).state = null;
        // 对端部门:按 displayName == conversation.title 反查 participant (与 sidebar 同口径)。
        String peerDept = '';
        String peerEmail = '';
        String peerCompanyName = '';
        String peerAccountUuid = '';
        for (final p in c.participants) {
          if (p.kind == 'human' && p.displayName == c.title) {
            peerDept = p.departmentName;
            peerEmail = p.email;
            peerCompanyName = p.companyName;
            peerAccountUuid = p.accountUuid;
            break;
          }
        }
        ref.read(selectedHumanDirectProvider.notifier).state =
            HumanDirectSelection(
          conversationId: c.conversationId,
          roomUuid: c.roomUuid ?? '',
          peerAccountUuid: peerAccountUuid,
          channelId: c.wukongChannelId!,
          channelType: c.wukongChannelType ?? 2,
          title: c.title,
          peerAvatar: c.convAvatar,
          peerDepartmentName: peerDept,
          peerEmail: peerEmail,
          peerCompanyName: peerCompanyName,
          clearedAt: c.clearedAt,
        );
        _markCurrentConversationRead(c.conversationId);
        return;
      }
    }
    clearNonAgentPanes();
    ref.read(activePendingConversationProvider.notifier).state = null;

    final key = _canon(conversationId);
    final ws = _ws;
    final isSwitching = ws.activeConversationId == null ||
        ws.canonicalKey(ws.activeConversationId!) != key;

    // 进入会话即校准员工详情，包括移动端返回同一会话。
    // 新员工可能尚未进入本端缓存，不能因会话 ID 未变而跳过能力补拉。
    {
      final convs = ref.read(conversationsProvider).asData?.value ??
          const <ConversationItem>[];
      final agents =
          ref.read(agentsProvider).asData?.value ?? const <AgentItem>[];
      ref
          .read(selectedAgentProvider.notifier)
          .selectByConversationId(key, convs, agents);
    }
    final existing = ws.sessions[key];
    if (!isSwitching &&
        existing != null &&
        !existing.isLoadingMessages &&
        existing.messages.isNotEmpty &&
        (!existing.hasActiveRun || _hasLiveRun(key, existing))) {
      // 同会话再次点击也清未读（可能在他设备上读过又有新消息推过来）
      _markCurrentConversationRead(key);
      return;
    }

    // 契约 C3/V4：只改 activeConversationId；已有缓存（含运行中的 partial）
    // 立即展示，不清 messages / pendingFiles / draft。
    final base = existing ?? ChatSessionState(conversationId: key);
    final hasLiveRun = _hasLiveRun(key, base);
    // 无权威 starting/runtime 登记时，isSending/activeStreamId 只是失效 UI 索引。
    // 切换首帧就清掉，不能等 getHistory 返回后才恢复发送按钮；否则慢请求/失败会
    // 让当前会话错误地长期显示红色停止按钮。
    final visibleBase = hasLiveRun
        ? base
        : base.copyWith(isSending: false, clearActiveStream: true);
    final showCached = visibleBase.messages.isNotEmpty || hasLiveRun;
    _setWorkspace(ws.copyWith(
      activeConversationId: key,
      sessions: {
        ...ws.sessions,
        key: visibleBase.copyWith(
          isLoadingMessages: !showCached,
          hasMoreHistory:
              visibleBase.messages.isEmpty ? true : visibleBase.hasMoreHistory,
          isLoadingHistory: false,
          clearError: true,
        ),
      },
    ));
    if (isSwitching) {
      _markCurrentConversationRead(key);
    }
    _historyPageByConv[key] = 1;
    // 运行中的会话绝不重拉历史覆盖 partial（C3/V11）；切回即续显缓存。
    if (hasLiveRun) return;
    final service = ref.read(chatServiceProvider);
    try {
      final disk = await service.getCachedHistory(key,
          clearedAt: _conversationItemById(key)?.clearedAt);
      if (!ref.mounted) return;
      final beforeSync = _ws.sessions[key];
      if (beforeSync == null || _hasLiveRun(key, beforeSync)) return;
      if (beforeSync.messages.isEmpty && disk.isNotEmpty) {
        _updateSession(
            key,
            tag: 'localHistory',
            (s) => s.copyWith(messages: disk, isLoadingMessages: false));
      }
      final messages = await _withAgentDirectCallEvents(
        conversation: _conversationItemById(key),
        history: await service.synchronizeHistory(key),
      );
      if (!ref.mounted) return;
      final latest = _ws.sessions[key];
      // 期间起了 run / 会话被删 → 放弃这次替换（V11 / fail closed）。
      if (latest == null || _hasLiveRun(key, latest)) {
        return;
      }
      final merged = _mergeRuntimeContext(
        history: messages,
        previous: latest.messages.isNotEmpty ? latest.messages : null,
      );
      _setSession(
        key,
        latest.copyWith(
          messages: merged,
          isSending: false,
          hasMoreHistory: merged.length >= _historyPageSize,
          // 普通入场首屏就是最新消息，向下不需要加载更新内容——清 around 留下的标记。
          hasMoreNewer: false,
          isLoadingMessages: false,
          clearActiveStream: true,
        ),
      );
      _resumePendingStream(key, merged);
    } catch (e) {
      if (!ref.mounted) return;
      final denied =
          e is DioException && [401, 403, 404].contains(e.response?.statusCode);
      _updateSession(
          key,
          tag: 'selectConversation',
          (s) => s.copyWith(
              messages: denied ? const [] : s.messages,
              errorMessage: '加载会话失败: $e',
              isLoadingMessages: false));
    }
  }

  /// 回到会话列表时清空当前详情（扁平列表首屏 / 宿主侧导航）。
  ///
  /// F09 §5.7：只清 active 选中，**保留** sessions 与后台 runtime——
  /// 页面暂时不可见不得取消后台生成（C3）；session 缓存留待切回续显（V4）。
  void clearActiveSession() {
    final current = state.asData?.value;
    if (current == null || current.activeConversationId == null) return;
    ref.read(activePendingConversationProvider.notifier).state = null;
    _setWorkspace(current.copyWith(clearActiveConversation: true));
  }

  /// 检测到 active 会话的 lastMessageAt 比上次轮询更新（cron 写库 / 其他端发消息），
  /// 重拉一次 history 替换 messages，让右侧聊天面板自动追加新消息。
  ///
  /// 跳过条件（保护 streaming 状态不被覆盖）：
  ///   - 没 active 会话
  ///   - 该会话正在 SSE 流中（session.hasActiveRun 或注册表有 runtime）
  ///   - active 会话不在 next 列表里
  ///   - lastMessageAt 没变化
  Future<void> _maybeAppendIncoming(
    List<ConversationItem>? prev,
    List<ConversationItem> next,
  ) async {
    final current = state.asData?.value;
    final activeId = current?.activeConversationId;
    if (current == null || activeId == null || activeId.isEmpty) return;
    // doc-13 §A 二次返修: pending 会话服务端尚不存在, **绝不** getHistory (否则 404)。
    if (isPendingConversation(activeId)) return;
    final key = current.canonicalKey(activeId);
    final session = current.sessions[key];
    if (session == null) return;
    // 契约 C9：守卫按**该会话**的运行态判断，不再用全局标志——别的会话在
    // 后台生成不影响本会话的轮询追加。
    if (_hasLiveRun(key, session)) return;

    ConversationItem? findActive(List<ConversationItem>? list) {
      if (list == null) return null;
      for (final c in list) {
        if (c.conversationId == key) return c;
      }
      return null;
    }

    final nextActive = findActive(next);
    if (nextActive == null) return;
    final prevActive = findActive(prev);
    final prevAt = prevActive?.lastMessageAt ?? '';
    final nextAt = nextActive.lastMessageAt ?? '';
    // 没拿到新时间戳、或时间戳没前进，跳过。空字符串不动也跳过避免空抖动。
    if (nextAt.isEmpty || nextAt == prevAt) return;

    try {
      final service = ref.read(chatServiceProvider);
      final history = await _withAgentDirectCallEvents(
        conversation: nextActive,
        history: await service.getHistory(conversationId: key),
      );
      final latest = _ws.sessions[key];
      // 期间该会话开始 streaming / 被删，丢弃这次结果（V11 / fail closed）。
      if (latest == null || _hasLiveRun(key, latest)) {
        return;
      }
      final merged = _mergeRuntimeContext(
        history: history,
        previous: latest.messages,
      );
      _setSession(
        key,
        latest.copyWith(
          messages: merged,
          isSending: false,
          clearActiveStream: true,
        ),
      );
      _resumePendingStream(key, merged);
      // 只有该会话仍是当前显示会话时才本地清红点（C11）。activeConversationId
      // 只反映"最后选中过谁"，不反映"对话 tab 现在到底可不可见"，必须两者都成立
      // 才算真的在看——否则切到自动任务等其它 tab 后台仍会把旧会话误标已读。
      final act = _ws.activeConversationId;
      final chatVisible = ref.read(isChatRouteActiveProvider);
      if (chatVisible && act != null && _ws.canonicalKey(act) == key) {
        _markCurrentConversationRead(key);
      }
    } catch (_) {
      // 静默：下次轮询再试。
    }
  }

  /// 强制重拉一次当前 active conversation 的 history,用 _mergeRuntimeContext
  /// 把流式 / 本地状态保留下来再替换 messages。
  /// 「聊天历史」面板打开时调用，确保拿到后端最新字段(比如 outputFiles),
  /// 因为 SSE 推送链路里没有这个字段,只有 GetMessages REST 接口才会返回。
  /// 跳过条件跟 [_maybeAppendIncoming] 一致——SSE 流中 / 没 active 时不动。
  Future<void> reloadActiveMessages() async {
    final current = state.asData?.value;
    final activeId = current?.activeConversationId;
    if (current == null || activeId == null || activeId.isEmpty) return;
    // doc-13 §A 二次返修: pending 会话不拉历史 (无此会话, 否则 404)。
    if (isPendingConversation(activeId)) return;
    final key = current.canonicalKey(activeId);
    final session = current.sessions[key];
    if (session == null) return;
    // 契约 C9：按该会话自身运行态守卫（不用全局标志）。
    if (_hasLiveRun(key, session)) return;
    try {
      final service = ref.read(chatServiceProvider);
      final history = await _withAgentDirectCallEvents(
        conversation: _conversationItemById(key),
        history: await service.getHistory(conversationId: key),
      );
      final latest = _ws.sessions[key];
      if (latest == null || _hasLiveRun(key, latest)) {
        return;
      }
      final merged = _mergeRuntimeContext(
        history: history,
        previous: latest.messages,
      );
      _setSession(
        key,
        latest.copyWith(
          messages: merged,
          isSending: false,
          clearActiveStream: true,
        ),
      );
      _resumePendingStream(key, merged);
    } catch (_) {
      // 静默：列表里现有数据够用，下次再拉。
    }
  }

  /// Account events invalidate one loaded conversation, including a live stream
  /// whose terminal event may have been missed. REST must confirm that exact run.
  Future<void> reconcileAccountConversation(String conversationId) async {
    final key = _canon(conversationId);
    if (isPendingConversation(key) || !_ws.sessions.containsKey(key)) return;
    if (_startingRunByConversation.containsKey(key)) return;
    final runtime = _runtimes.forConversation(key);
    final request = (_accountHistoryRequests[key] ?? 0) + 1;
    _accountHistoryRequests[key] = request;
    try {
      final history = await _withAgentDirectCallEvents(
        conversation: _conversationItemById(key),
        history:
            await ref.read(chatServiceProvider).getHistory(conversationId: key),
      );
      if (!ref.mounted || _accountHistoryRequests[key] != request) return;
      final latest = _ws.sessions[key];
      if (latest == null || _startingRunByConversation.containsKey(key)) return;
      final currentRuntime = _runtimes.forConversation(key);
      if (!identical(runtime, currentRuntime)) return;
      if (runtime != null) {
        final terminal = history
            .where((m) =>
                m.messageId == runtime.agentMessageUuid &&
                const {'final', 'failed', 'cancelled', 'awaiting_user'}
                    .contains(m.agentMessageStatus))
            .firstOrNull;
        if (terminal == null) return;
        // Cancel only the matching subscription; do not call the stop API or
        // disturb a newer run. Late frames from this runtime are now ignored.
        _cancelAnswerReveal(runtime);
        runtime.cancel();
        _runtimes.remove(runtime.streamId);
      } else if (_hasLiveRun(key, latest)) {
        return;
      }
      final merged =
          _mergeRuntimeContext(history: history, previous: latest.messages);
      _setSession(
          key,
          latest.copyWith(
              messages: merged, isSending: false, clearActiveStream: true));
      _resumePendingStream(key, merged);
    } catch (_) {
      // Keep current state on network failure. Reconnect/resume reconciles again.
    }
  }

  /// 订阅失败等异常收口后的目标化历史对账：只写 [conversationKey] 会话，
  /// 不 resume（避免死流的 订阅失败→收口→再订阅 循环），不读届时 active。
  Future<void> _reconcileSessionHistory(String conversationKey) async {
    final key = _canon(conversationKey);
    if (isPendingConversation(key)) return;
    final session = _ws.sessions[key];
    if (session == null || _hasLiveRun(key, session)) return;
    try {
      final service = ref.read(chatServiceProvider);
      final history = await _withAgentDirectCallEvents(
        conversation: _conversationItemById(key),
        history: await service.getHistory(conversationId: key),
      );
      final latest = _ws.sessions[key];
      if (latest == null || _hasLiveRun(key, latest)) return;
      final merged = _mergeRuntimeContext(
        history: history,
        previous: latest.messages.isNotEmpty ? latest.messages : null,
      );
      _setSession(
        key,
        latest.copyWith(
          messages: merged,
          isSending: false,
          isLoadingMessages: false,
          clearActiveStream: true,
        ),
      );
    } catch (_) {
      // 静默：对账失败不再级联；用户下次切入会话时 selectConversation 会重试。
    }
  }

  ConversationItem? _conversationItemById(String conversationId) {
    if (conversationId.isEmpty) return null;
    final items = ref.read(conversationsProvider).asData?.value ??
        const <ConversationItem>[];
    for (final item in items) {
      if (item.conversationId == conversationId) return item;
    }
    return null;
  }

  Future<List<ChatMessage>> _withAgentDirectCallEvents({
    required ConversationItem? conversation,
    required List<ChatMessage> history,
  }) async {
    if (conversation == null || conversation.kind != 'agent_direct') {
      return history;
    }
    final channelId = conversation.wukongChannelId ?? '';
    final channelType = conversation.wukongChannelType ?? 2;
    if (channelId.isEmpty) return history;
    try {
      final im = ref.read(wukongImClientProvider);
      final latest = await im.getHistoryMessages(
        channelId,
        channelType,
        limit: _historyPageSize,
      );
      final callMessages = latest
          .where(_isCallEventImMessage)
          .map(_chatMessageFromCallEvent)
          .toList(growable: false);
      if (callMessages.isEmpty) return history;
      final merged = <ChatMessage>[];
      final seen = <String>{};
      void add(ChatMessage m) {
        final key = m.messageId ?? m.uuid ?? '';
        if (key.isNotEmpty && !seen.add(key)) return;
        merged.add(m);
      }

      for (final m in history) {
        add(m);
      }
      for (final m in callMessages) {
        add(m);
      }
      merged.sort((a, b) {
        final at = a.createdAt;
        final bt = b.createdAt;
        if (at == null && bt == null) return 0;
        if (at == null) return -1;
        if (bt == null) return 1;
        return at.compareTo(bt);
      });
      return merged;
    } catch (e, st) {
      debugPrint('[ChatNotifier] sync agent_direct call_event failed: $e\n$st');
      return history;
    }
  }

  bool _isCallEventImMessage(ImMessage message) {
    if (message.blocks.any((b) => b.isCallEvent)) return true;
    final text = message.text.trim();
    return text.startsWith('语音通话') || text.startsWith('视频通话');
  }

  ChatMessage _chatMessageFromCallEvent(ImMessage message) {
    ImMessageBlock? block;
    for (final candidate in message.blocks) {
      if (candidate.isCallEvent) {
        block = candidate;
        break;
      }
    }
    final summary = message.text.trim().isNotEmpty
        ? message.text.trim()
        : _callEventSummary(block);
    final id = message.messageId.isNotEmpty
        ? message.messageId
        : (message.clientMsgNo.isNotEmpty
            ? message.clientMsgNo
            : 'call-event-${message.timestamp}-${summary.hashCode}');
    return ChatMessage(
      uuid: id,
      messageId: id,
      role: ChatRole.question,
      content: summary,
      status: BubbleStatus.success,
      createdAt: _imTimestampToDate(message.timestamp),
      metadata: {
        'kind': 'call_event',
        'media_kind': summary.startsWith('视频通话') ? 'video' : 'audio',
        if ((block?.callEndReason ?? '').isNotEmpty)
          'end_reason': block!.callEndReason,
      },
    );
  }

  String _callEventSummary(ImMessageBlock? block) {
    final text = block?.text.trim() ?? '';
    if (text.isEmpty) return '语音通话';
    return text.startsWith('语音通话') || text.startsWith('视频通话')
        ? text
        : '语音通话 · $text';
  }

  DateTime _imTimestampToDate(int timestamp) {
    if (timestamp > 1000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    }
    if (timestamp > 1000000000) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    }
    return DateTime.now();
  }

  /// 把当前 active conversation 标记为已读。用户场景：
  ///   - 用户已经停在该会话页里（没切走），新 cron 消息推过来导致红点 +1；
  ///   - 用户点了"滚到底部"箭头查看新消息。
  /// 没有 active conversation / id 为空时 no-op。
  void markActiveConversationRead() {
    final id = state.asData?.value.activeConversationId;
    debugPrint('[DEBUG markActiveConversationRead] activeConversationId=$id');
    if (id == null || id.isEmpty) return;
    _markCurrentConversationRead(id);
  }

  /// 用户点开会话即视为已读：先本地清零（红点立刻消失），再异步通知后端。
  /// 后端失败不需要回滚——下次 refresh 会重新拉到真实未读数。
  void _markCurrentConversationRead(String conversationId) {
    if (conversationId.isEmpty) return;
    ref.read(conversationsProvider.notifier).clearUnreadLocally(conversationId);
    final service = ref.read(chatServiceProvider);
    unawaited(
      service.markConversationRead(conversationId).catchError((Object _) {
        // 已读上报失败可忽略：下次拉列表时会拿到真实状态。
      }),
    );
  }

  /// 历史里最后一条是 in-flight 消息（isLoading + streamId）时恢复订阅。
  /// 契约 C10：先查 runtime 注册表去重——切回生成中的会话时 runtime 还活着，
  /// 绝不产生第二条 subscription（双倍消费）。
  void _resumePendingStream(
      String conversationKey, List<ChatMessage> messages) {
    if (messages.isEmpty) return;
    final last = messages.last;
    final streamId = last.streamId?.trim();
    if (!last.isLoading || streamId == null || streamId.isEmpty) return;
    if (_runtimes.contains(streamId)) return; // C10 去重
    // 订阅曾直接失败的死流（服务端 run 早已消亡）不再自动 resume，
    // 否则每次进入会话都会经历 订阅失败→收口 的抖动循环。
    if (_deadStreams.contains(streamId)) return;
    final key = _canon(conversationKey);
    if (_runtimes.forConversation(key) != null) return; // C2 同会话单 run
    final rt = ChatStreamRuntime(
      streamId: streamId,
      conversationId: key,
      localPlaceholderId: last.localId,
      agentMessageUuid: last.messageId,
    );
    // 恢复的流是活跃 run：置 isSending 让停止按钮 / 单 run 闸口生效（C2）。
    _updateSession(key, tag: 'resume', (s) {
      return s.copyWith(
        isSending: true,
        activeStreamId: streamId,
        activeAgentMessageUuid: last.messageId,
        activeLocalPlaceholderId: last.localId,
      );
    });
    unawaited(_startStream(rt));
  }

  Future<void> loadMoreHistory({bool reportErrors = false}) async {
    final ws = state.asData?.value;
    final activeId = ws?.activeConversationId;
    if (ws == null || activeId == null) return;
    final key = ws.canonicalKey(activeId);
    final session = ws.sessions[key];
    if (session == null ||
        session.isLoadingHistory ||
        !session.hasMoreHistory ||
        session.messages.isEmpty) {
      return;
    }
    _updateSession(
        key, tag: 'loadMore', (s) => s.copyWith(isLoadingHistory: true));
    try {
      final oldestId = session.messages.first.messageId;
      // before 本身就是游标，page 必须固定为 1。之前每次 +1 累加：
      //   call N: before=oldest.id AND OFFSET=(N-1)*pageSize
      // 后端 `id < before.id ORDER BY created_at DESC LIMIT pageSize OFFSET ...`
      // 等价于每次跳过 N-1 页的数据，出现窟窿：#440..#459 之后跳到 #380..#399、
      // 再跳到 #300..#319（日志里 `pagination TOP trigger` 清晰可见）。
      final int pageForCall;
      if (oldestId != null) {
        pageForCall = 1;
      } else {
        pageForCall = (_historyPageByConv[key] ?? 1) + 1;
      }
      final service = ref.read(chatServiceProvider);
      final history = await service.getHistory(
        conversationId: key,
        page: pageForCall,
        pageSize: _historyPageSize,
        before: oldestId,
      );
      // 无游标时也只在成功后推进页码，失败重试不能跳过整页。
      if (oldestId == null) _historyPageByConv[key] = pageForCall;
      // 目标化写回：向前 prepend，不触碰尾部运行中的 placeholder（V11）。
      _updateSession(key, tag: 'loadMore', (s) {
        return s.copyWith(
          messages: [...history, ...s.messages],
          hasMoreHistory: history.isNotEmpty,
          isLoadingHistory: false,
        );
      });
    } catch (e) {
      _updateSession(
          key,
          tag: 'loadMore',
          (s) =>
              s.copyWith(isLoadingHistory: false, errorMessage: '加载更多失败: $e'));
      if (reportErrors) rethrow;
    }
  }

  /// 向下分页：从当前消息列表末尾之后拉 N 条更新消息。
  /// 只在 around 场景下（state.hasMoreNewer=true）才会被触发；普通 selectConversation
  /// 的首屏已经是会话最新消息，hasMoreNewer=false，不会调用这里。
  /// 「直接跳到最新消息」：用于 around 中段模式下用户点底部箭头快捷回最新。
  ///
  /// 为什么不走 loadNewerHistory 循环：around 中段离最新消息可能有几千条，
  /// 逐页拉 20 条 * 上百次体验极差。这里直接重置到"首屏最新"（getHistory
  /// page=1），messages 替换成最新 20 条，让用户立刻看到最新对话，向上滚
  /// 还能 loadMoreHistory 继续回溯。
  Future<void> jumpToLatest() async {
    final ws = state.asData?.value;
    final activeId = ws?.activeConversationId;
    if (ws == null || activeId == null || activeId.isEmpty) return;
    final key = ws.canonicalKey(activeId);
    final session = ws.sessions[key];
    // 已经在最新首屏（没有 hasMoreNewer 标记）就别白跑一次网络请求。
    if (session == null || !session.hasMoreNewer) return;

    _historyPageByConv[key] = 1;
    _updateSession(
        key, tag: 'jumpToLatest', (s) => s.copyWith(isLoadingMessages: true));
    try {
      final service = ref.read(chatServiceProvider);
      final messages = await service.getHistory(conversationId: key);
      _updateSession(key, tag: 'jumpToLatest', (s) {
        if (s.hasActiveRun) {
          // 期间起了 run → 不覆盖运行中内容（V11），只收口 loading 标记。
          return s.copyWith(isLoadingMessages: false, clearHighlight: true);
        }
        final merged = _mergeRuntimeContext(
          history: messages,
          previous: s.messages.isNotEmpty ? s.messages : null,
        );
        return s.copyWith(
          messages: merged,
          hasMoreHistory: merged.length >= _historyPageSize,
          hasMoreNewer: false, // 回到最新首屏 → 向下不再可加载
          isLoadingMessages: false,
          clearHighlight: true, // 清 around 时留下的高亮，避免视觉干扰
        );
      });
      final act = _ws.activeConversationId;
      if (act != null && _ws.canonicalKey(act) == key) {
        _markCurrentConversationRead(key);
      }
    } catch (e) {
      _updateSession(
          key,
          tag: 'jumpToLatest',
          (s) =>
              s.copyWith(isLoadingMessages: false, errorMessage: '跳回最新失败: $e'));
    }
  }

  Future<void> loadNewerHistory() async {
    final ws = state.asData?.value;
    final activeId = ws?.activeConversationId;
    if (ws == null || activeId == null) return;
    final key = ws.canonicalKey(activeId);
    final session = ws.sessions[key];
    if (session == null ||
        session.isLoadingNewer ||
        !session.hasMoreNewer ||
        session.messages.isEmpty) {
      return;
    }
    // 往下加载用"当前屏最后一条的 uuid"做 after 游标；uuid 优先取 messageId
    // （ChatMessage 的 messageId 字段里存的是后端 ConversationMessages.UUID，
    // 和 around 端点里的 cm.uuid 一致）。
    String? afterUuid;
    for (var i = session.messages.length - 1; i >= 0; i--) {
      final id = session.messages[i].messageId;
      if (id != null && id.isNotEmpty) {
        afterUuid = id;
        break;
      }
    }
    if (afterUuid == null) return;

    _updateSession(
        key, tag: 'loadNewer', (s) => s.copyWith(isLoadingNewer: true));
    try {
      final service = ref.read(chatServiceProvider);
      final newer = await service.getHistoryNewer(
        conversationId: key,
        afterMessageUuid: afterUuid,
        pageSize: _historyPageSize,
      );
      _updateSession(key, tag: 'loadNewer', (s) {
        return s.copyWith(
          messages: [...s.messages, ...newer],
          // 拉满一页说明后面大概率还有，没拉满就到底了。
          hasMoreNewer: newer.length >= _historyPageSize,
          isLoadingNewer: false,
        );
      });
    } catch (e) {
      _updateSession(
          key,
          tag: 'loadNewer',
          (s) =>
              s.copyWith(isLoadingNewer: false, errorMessage: '加载新消息失败: $e'));
    }
  }

  Future<void> send(
    String text, {
    List<String> skillSlugs = const [],
    List<ImMessageBlock> blocks = const [],
  }) async {
    final current = state.asData?.value;
    if (current == null) return;
    final activeIdAtSend = current.activeConversationId;
    if (activeIdAtSend == null) return;
    // 契约 C4/C8：发起时捕获目标会话 key；本次 send 的全部写入只落这个会话，
    // 不因用户切换会话而改变目标。
    final sourceKey = current.canonicalKey(activeIdAtSend);
    final session = current.sessions[sourceKey] ??
        ChatSessionState(conversationId: sourceKey);
    // 契约 C2：同会话单 active run；不同会话互不影响（V15）。
    if (session.hasActiveRun ||
        _runtimes.forConversation(sourceKey) != null ||
        _respondingConversations.contains(sourceKey) ||
        session.isLoadingMessages) {
      return;
    }

    final pendingFiles = session.pendingFiles;
    final failedPendingFiles =
        pendingFiles.any((f) => !f.uploading && !f.isReadyToSend);
    if (failedPendingFiles) {
      _setSession(sourceKey, session.copyWith(errorMessage: '有文件上传失败，请移除后重试'));
      return;
    }
    final pendingFilesToSend =
        pendingFiles.where((f) => f.isReadyToSend).toList();
    final filesToSend = _mergeFilesForSend([
      ...pendingFilesToSend,
      ..._filesFromMediaBlocks(blocks),
    ]);
    final trimmed = text.trim();
    final messageBlocks = _buildAgentDirectBlocks(
      text: trimmed,
      blocks: blocks,
      files: pendingFilesToSend,
      skillSlugs: skillSlugs,
    );
    final summary = _summaryForAgentBlocks(messageBlocks);
    if (summary.isEmpty) {
      return;
    }

    final bool isNew = isPendingConversation(sourceKey);

    // doc-13 §A: 解析 agent_uuid（agent-bus /chat/send 必填）。
    //   - 哨兵新会话：从哨兵取；
    //   - 既有会话：从会话列表按 id 取 agentId，兜底用当前选中 agent。
    String agentUuid = isNew ? agentUuidFromPending(sourceKey) : '';
    ConversationItem? activeConversation;
    if (agentUuid.isEmpty && !isNew) {
      final convs = ref.read(conversationsProvider).asData?.value ??
          const <ConversationItem>[];
      for (final c in convs) {
        if (c.conversationId == sourceKey) {
          activeConversation = c;
          agentUuid = c.agentId;
          break;
        }
      }
    }
    if (agentUuid.isEmpty) {
      final agent = await ref.read(selectedAgentProvider.future);
      agentUuid = agent?.agentId ?? '';
    }
    if (agentUuid.isEmpty) {
      // 契约 V13 fail closed：placeholder 尚未创建，不得改写既有消息，
      // 只在目标会话上报错。
      _setSession(
        sourceKey,
        (_ws.sessions[sourceKey] ?? session)
            .copyWith(errorMessage: '未找到数字员工，请重新进入对话'),
      );
      return;
    }

    // Resolve against this send's captured conversation. The display provider
    // watches chatProvider and cannot be read back from its notifier.
    final targetAgent = _withCatalogCapabilities(
      _preferSelectedIfSameAgent(
          activeConversation == null
              ? AgentItem.fromJson({'uuid': agentUuid})
              : _agentFromConversation(activeConversation),
          ref.read(selectedAgentProvider).asData?.value),
      ref.read(digitalEmployeeCatalogProvider).asData?.value,
      ref.read(agentsProvider).asData?.value,
    );
    final isLocalAgent = targetAgent.agentId == agentUuid &&
        targetAgent.executionLocus == 'local';
    final selection = ConversationModels.instance.state(agentUuid, sourceKey);
    final desktopModel = (PlatformUtils.isDesktop || isLocalAgent) &&
        targetAgent.hasConversationModels &&
        targetAgent.agentId == agentUuid;
    final modelHint = desktopModel ? selection.selected : null;
    final question = ChatMessage(
      role: ChatRole.question,
      content: trimmed.isNotEmpty ? trimmed : summary,
      status: BubbleStatus.success,
      files: filesToSend,
      empBlocks: messageBlocks.map((block) => block.toJson()).toList(),
    );
    final answer = ChatMessage(
      role: ChatRole.answer,
      content: '',
      status: BubbleStatus.loading,
      metadata: {'local_send_question_id': question.localId},
      streamStartedAt: DateTime.now(),
    );
    final answerLocalId = answer.localId;

    // 只写 sourceKey 会话分区；发送即清本会话草稿与附件池（C7）。
    final latestSession = _ws.sessions[sourceKey] ?? session;
    _setSession(
      sourceKey,
      latestSession.copyWith(
        isSending: true,
        messages: [...latestSession.messages, question, answer],
        pendingFiles: const [],
        draft: ChatComposerDraft.empty,
        clearError: true,
        activeLocalPlaceholderId: answerLocalId,
      ),
    );
    _startingRunByConversation[sourceKey] = answerLocalId;
    _accountHistoryRequests[sourceKey] =
        (_accountHistoryRequests[sourceKey] ?? 0) + 1;
    if (desktopModel && !selection.ready) {
      _failRun(sourceKey, answerLocalId,
          selection.error.isEmpty ? '请选择可用模型后发送。' : selection.error);
      return;
    }

    final service = ref.read(chatServiceProvider);
    try {
      final local = LocalAgentService.instance;
      if (isLocalAgent && PlatformUtils.isDesktop) {
        if (!local.supportsEngine(targetAgent.localEngine)) {
          throw StateError('当前电脑未提供所选引擎，请更新电脑客户端并检查本地引擎状态');
        }
        await local.workspace(agentUuid, sourceKey, targetAgent.displayName);
      }
      final roomBackedAgentDirect = !isNew &&
          activeConversation?.kind == 'agent_direct' &&
          (activeConversation?.roomUuid ?? '').trim().isNotEmpty;
      final hasPendingFileAttachments = filesToSend.isNotEmpty;
      // ADR-0026 Flutter cutover:agent-direct 双通道(纯文本/技能无附件 + WuKong 已连 + 未 disabled)→
      // prepare-wukong → WuKong 直发 → attach → 既有 SSE;否则 fallback 旧 /chat/send(行为不变)。
      // 附件池上传的图片/文件暂不走 WuKong mixed;room-backed agent_direct 走 rooms API
      // 绑定 file_uuids,非 room-backed pending 会话仍 fallback 旧 /chat/send(files)。
      final outcome =
          isLocalAgent || modelHint != null || hasPendingFileAttachments
              ? AgentDirectSendOutcome.fallback()
              : await _tryAgentDirectDualChannel(
                  service: service,
                  agentUuid: agentUuid,
                  blocks: messageBlocks,
                  summary: summary,
                );
      if (outcome.kind == AgentDirectSendKind.streamReady) {
        await _afterRunStarted(
          sourceKey: sourceKey,
          answerLocalId: answerLocalId,
          conversationId: outcome.conversationUuid,
          streamId: outcome.streamId,
          messageId: outcome.agentMessageUuid,
          roomUuid: outcome.roomUuid,
          wukongChannelId: outcome.wukongChannelId,
          wukongChannelType: outcome.wukongChannelType,
          isNew: isNew,
          previewText: summary,
        );
        return;
      }
      if (outcome.kind == AgentDirectSendKind.failed) {
        if (outcome.insufficientCredits) {
          notifyBillingSummaryChanged();
        }
        _failRun(
            sourceKey,
            answerLocalId,
            outcome.errorMessage.isNotEmpty
                ? outcome.errorMessage
                : '发送失败，请稍后重试');
        return;
      }
      if (roomBackedAgentDirect && !isLocalAgent) {
        if (!hasPendingFileAttachments && modelHint == null) {
          _failRun(sourceKey, answerLocalId, '发送失败，请检查实时消息连接后重试');
          return;
        }
        final roomUuid = (activeConversation?.roomUuid ?? '').trim();
        final sent = await service.sendRoomMessage(
          blocks: messageBlocks,
          modelHint: modelHint,
          roomUuid: roomUuid,
          prompt: trimmed.isNotEmpty ? trimmed : summary,
          files: filesToSend,
        );
        if (sent.streamId.isEmpty) {
          _failRun(sourceKey, answerLocalId, '发送失败，请稍后重试');
          return;
        }
        await _afterRunStarted(
          sourceKey: sourceKey,
          answerLocalId: answerLocalId,
          conversationId:
              sent.conversationId.isNotEmpty ? sent.conversationId : sourceKey,
          streamId: sent.streamId,
          messageId: sent.messageId,
          userMessageUuid: sent.userMessageUuid,
          roomUuid: roomUuid,
          isNew: isNew,
          previewText: summary,
        );
        return;
      }
      // fallback → 旧路径 /chat/send（create-on-first-send：新会话 conversationId 传 null）。
      final sent = await service.sendMessage(
        localDeviceId:
            isLocalAgent && PlatformUtils.isDesktop ? local.deviceId : null,
        localContextId: isLocalAgent && PlatformUtils.isDesktop
            ? await local.contextId(sourceKey)
            : null,
        modelHint: modelHint,
        conversationId: isNew ? null : sourceKey,
        agentUuid: agentUuid,
        prompt: trimmed.isNotEmpty ? trimmed : summary,
        files: filesToSend,
        skillSlugs: skillSlugs,
        blocks: messageBlocks,
      );
      if (isLocalAgent && PlatformUtils.isDesktop) {
        await local.adoptConversation(sourceKey, sent.conversationId);
      }
      if (desktopModel) {
        await ConversationModels.instance
            .adopt(agentUuid, sourceKey, sent.conversationId);
      }
      await _afterRunStarted(
        sourceKey: sourceKey,
        answerLocalId: answerLocalId,
        conversationId: sent.conversationId,
        streamId: sent.streamId,
        messageId: sent.messageId,
        userMessageUuid: sent.userMessageUuid,
        isNew: isNew,
        previewText: summary,
      );
    } catch (e) {
      if (isInsufficientCreditsError(e)) {
        notifyBillingSummaryChanged();
      }
      final error = formatChatSendError(e);
      _failRun(sourceKey, answerLocalId,
          error == '当前模型已不可用，请切换模型后重试。' ? selection.unavailableMessage : error);
    }
  }

  /// agent-direct 双通道发送尝试。返回 streamReady / fallback / failed。
  /// 门控:带附件 / 本会话已 disabled / WuKong 未连 → 直接 fallback(走旧 /chat/send)。
  Future<AgentDirectSendOutcome> _tryAgentDirectDualChannel({
    required OpenClawChatService service,
    required String agentUuid,
    required List<ImMessageBlock> blocks,
    required String summary,
  }) async {
    if (_agentDirectDualChannelDisabled) {
      return AgentDirectSendOutcome.fallback();
    }
    if (debugAgentDirectSendOverride != null) {
      final o = await debugAgentDirectSendOverride!(agentUuid, blocks, summary);
      if (o.disabled) _agentDirectDualChannelDisabled = true;
      return o;
    }
    final im = ref.read(wukongImClientProvider);
    final uid = im.connectedUid;
    if (!im.isRealtimeConnected || uid == null || uid.isEmpty) {
      return AgentDirectSendOutcome.fallback(); // WuKong 未连 → 旧路径
    }
    final sender = AgentDirectDualChannelSender(
      service: service,
      wukongSend: (cid, ct, b, s) => sendAgentDirectBlocksAwaitingServerId(
        im,
        cid,
        ct,
        blocks: b,
        summary: s,
      ),
      isWukongConnected: () =>
          im.isRealtimeConnected &&
          im.connectedUid != null &&
          im.connectedUid!.isNotEmpty,
    );
    final o = await sender.send(
      agentUuid: agentUuid,
      blocks: blocks,
      summary: summary,
    );
    if (o.disabled) _agentDirectDualChannelDisabled = true;
    return o;
  }

  List<ImMessageBlock> _buildAgentDirectBlocks({
    required String text,
    required List<ImMessageBlock> blocks,
    required List<ChatFileItem> files,
    required List<String> skillSlugs,
  }) {
    final out = <ImMessageBlock>[];
    out.addAll(_skillBlocksFromSlugs(skillSlugs, blocks));
    if (blocks.isNotEmpty) {
      out.addAll(blocks.where(_isNonEmptyBlock));
    } else if (text.trim().isNotEmpty) {
      out.add(ImMessageBlock(kind: ImMessageBlockKind.text, text: text.trim()));
    }
    for (final file in files) {
      final block = _blockFromChatFile(file);
      if (block != null) out.add(block);
    }
    return out.toList(growable: false);
  }

  List<ImMessageBlock> _skillBlocksFromSlugs(
    List<String> skillSlugs,
    List<ImMessageBlock> existingBlocks,
  ) {
    final seen = <String>{
      for (final b in existingBlocks)
        if (b.isSkill && b.skillSlug.trim().isNotEmpty) b.skillSlug.trim(),
    };
    final out = <ImMessageBlock>[];
    for (final raw in skillSlugs) {
      final slug = raw.trim();
      if (slug.isEmpty || seen.contains(slug)) continue;
      seen.add(slug);
      out.add(ImMessageBlock(kind: ImMessageBlockKind.skill, skillSlug: slug));
    }
    return out;
  }

  bool _isNonEmptyBlock(ImMessageBlock b) {
    if (b.isText || b.isMarkdown) return b.text.trim().isNotEmpty;
    if (b.isSkill) return b.skillSlug.trim().isNotEmpty;
    if (b.isImage) {
      return b.url.trim().isNotEmpty ||
          b.refUuid.trim().isNotEmpty ||
          b.name.trim().isNotEmpty;
    }
    if (b.isFile) {
      return b.url.trim().isNotEmpty ||
          b.fileUuid.trim().isNotEmpty ||
          b.refUuid.trim().isNotEmpty ||
          b.name.trim().isNotEmpty;
    }
    return false;
  }

  ImMessageBlock? _blockFromChatFile(ChatFileItem file) {
    final url = file.fileLink?.trim() ?? '';
    if (url.isEmpty) return null;
    final api = file.toApiJson();
    final kind = file.fileType == ChatFileType.image
        ? ImMessageBlockKind.image
        : ImMessageBlockKind.file;
    return ImMessageBlock(
      kind: kind,
      url: url,
      fileUuid: (file.driveFileUuid ?? file.uuid ?? '').trim(),
      refUuid: (file.uuid ?? '').trim(),
      name: file.fileName.trim(),
      size: file.sizeBytes,
      mime: (api['mimeType'] ?? '').toString(),
    );
  }

  List<ChatFileItem> _filesFromMediaBlocks(List<ImMessageBlock> blocks) {
    if (blocks.isEmpty) return const <ChatFileItem>[];
    final out = <ChatFileItem>[];
    for (final block in blocks) {
      if (!block.isImage && !block.isFile) continue;
      final fileUuid = block.fileUuid.trim();
      if (fileUuid.isEmpty) continue;
      out.add(ChatFileItem(
        fileName: block.name.trim().isNotEmpty
            ? block.name.trim()
            : (block.isImage ? '图片' : '文件'),
        fileType: block.isImage ? ChatFileType.image : ChatFileType.file,
        fileLink: block.url.trim().isNotEmpty ? block.url.trim() : null,
        uuid: block.refUuid.trim().isNotEmpty ? block.refUuid.trim() : fileUuid,
        driveFileUuid: fileUuid,
        sizeBytes: block.size,
      ));
    }
    return out.toList(growable: false);
  }

  List<ChatFileItem> _mergeFilesForSend(List<ChatFileItem> files) {
    if (files.isEmpty) return const <ChatFileItem>[];
    final seen = <String>{};
    final out = <ChatFileItem>[];
    for (final file in files) {
      final key = (file.driveFileUuid ?? file.uuid ?? file.fileLink ?? '')
          .trim()
          .toLowerCase();
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      out.add(file);
    }
    return out.toList(growable: false);
  }

  String _summaryForAgentBlocks(List<ImMessageBlock> blocks) {
    final parts = <String>[];
    for (final b in blocks) {
      if (b.isText || b.isMarkdown) {
        final t = b.text.trim();
        if (t.isNotEmpty) parts.add(t);
      } else if (b.isImage) {
        parts.add('[图片]');
      } else if (b.isFile) {
        parts.add(b.name.trim().isNotEmpty ? b.name.trim() : '[文件]');
      }
    }
    return parts.join(' ').trim();
  }

  /// run 已就绪(双通道或旧路径)后的统一收口:回填 messageId/streamId、adopt 会话、左侧预览、接 SSE。
  ///
  /// 契约 C4/C6/C8：目标 = 发起时捕获的 [sourceKey] + [answerLocalId]，
  /// 绝不读「届时 active」；pending→real 由 [_adoptSession] 原子合并；
  /// **只有** active 仍是该 pending key 时才把 active 改为真实 uuid。
  Future<void> _afterRunStarted({
    required String sourceKey,
    required String answerLocalId,
    required String conversationId,
    required String streamId,
    required String messageId,
    String userMessageUuid = '',
    String roomUuid = '',
    String wukongChannelId = '',
    int wukongChannelType = 0,
    required bool isNew,
    required String previewText,
  }) async {
    var key = _canon(sourceKey);
    if (_startingRunByConversation[key] == answerLocalId) {
      _startingRunByConversation.remove(key);
    }
    // P1-1：响应回来前用户已点停止 → 不得复活生成。
    final wasCancelled = _cancelledPendingRuns.remove(answerLocalId);
    final session = _ws.sessions[key];
    if (session == null) {
      // 会话已被删除：fail closed，不写任何其他会话，也不再订阅流；
      // 服务端 run 已启动 → best-effort 停掉。
      if (kDebugMode) {
        debugPrint('[chat] fail-closed: afterRunStarted session $key gone');
      }
      _bestEffortStop(messageId);
      return;
    }
    // messageId = agent_message_uuid（stop 用）；streamId 用于 /chat/stream。
    final idx =
        session.messages.lastIndexWhere((m) => m.localId == answerLocalId);
    if (idx < 0) {
      // 真 fail closed（Codex review 一并项）：目标 placeholder 已不在——
      // 立即终止后续 adopt/预览/订阅，best-effort 停掉服务端 run。
      if (kDebugMode) {
        debugPrint(
            '[chat] fail-closed: placeholder $answerLocalId missing in $key');
      }
      _bestEffortStop(messageId);
      return;
    }
    final updated = [...session.messages];
    updated[idx] =
        updated[idx].copyWith(messageId: messageId, streamId: streamId);
    if (userMessageUuid.trim().isNotEmpty) {
      final questionIndex = updated.lastIndexWhere((m) =>
          m.role == ChatRole.question &&
          m.localId == updated[idx].metadata?['local_send_question_id']);
      if (questionIndex >= 0) {
        updated[questionIndex] =
            updated[questionIndex].copyWith(messageId: userMessageUuid);
      }
    }
    _setSession(
        key,
        session.copyWith(
            messages: updated,
            activeStreamId: streamId,
            activeAgentMessageUuid: messageId,
            activeLocalPlaceholderId: answerLocalId));

    final adoptedConvId = conversationId.isNotEmpty ? conversationId : key;
    if (isNew && conversationId.isNotEmpty && conversationId != key) {
      // pending→real 原子迁移（C6）：合并/rekey/alias/active 保护/左侧 adopt。
      _adoptSession(
        pendingKey: key,
        realKey: conversationId,
        roomUuid: roomUuid,
        wukongChannelId: wukongChannelId,
        wukongChannelType: wukongChannelType,
      );
      key = conversationId;
    } else if (conversationId.isNotEmpty && roomUuid.isNotEmpty) {
      ref.read(conversationsProvider.notifier).patchConversationRuntime(
            conversationId: conversationId,
            roomUuid: roomUuid,
            wukongChannelId:
                wukongChannelId.isNotEmpty ? wukongChannelId : null,
            wukongChannelType: wukongChannelType > 0 ? wukongChannelType : null,
            kind: 'agent_direct',
          );
    }
    // 左侧会话列表本地预览: 用户消息立即上屏 + 置顶 (不加未读)。
    ref.read(conversationsProvider.notifier).applyAgentConversationPreview(
          adoptedConvId,
          lastMessage: _previewSnippet(previewText),
        );
    if (wasCancelled) {
      final targetKey = _canon(adoptedConvId);
      try {
        await ref.read(chatServiceProvider).stopMessage(messageId: messageId);
        if (!ref.mounted) return;
        _locallyStoppedMessageIds.add(messageId);
        final stopped = ChatStreamRuntime(
            streamId: streamId,
            conversationId: targetKey,
            localPlaceholderId: answerLocalId,
            agentMessageUuid: messageId)
          ..stopped = true;
        _finalizeRunningEntries(stopped, stoppedKey: 'stopped');
        _markRunDone(targetKey, stopped, stopped: true);
        return;
      } catch (_) {
        if (!ref.mounted) return;
        _updateSession(
            targetKey,
            (current) =>
                current.copyWith(errorMessage: '停止请求未确认，任务可能仍在执行，请重试停止'));
        // Observe the known server run again so its actual result remains visible.
      }
    }
    final rt = ChatStreamRuntime(
      streamId: streamId,
      conversationId: _canon(adoptedConvId),
      localPlaceholderId: answerLocalId,
      agentMessageUuid: messageId,
    );
    await _startStream(rt);
  }

  /// 服务端 run 已启动但客户端不再消费（停止竞态 / fail closed）时的兜底停止。
  void _bestEffortStop(String agentMessageUuid) {
    if (agentMessageUuid.isEmpty) return;
    final service = ref.read(chatServiceProvider);
    unawaited(
      service
          .stopMessage(messageId: agentMessageUuid)
          .catchError((Object _) {}),
    );
  }

  /// pending→real 会话迁移（契约 C6 全量实现）。
  void _adoptSession({
    required String pendingKey,
    required String realKey,
    String roomUuid = '',
    String wukongChannelId = '',
    int wukongChannelType = 0,
  }) {
    final ws = _ws;
    final pending = ws.sessions[pendingKey];
    if (pending == null) return;
    final existingReal = ws.sessions[realKey];
    // 尽可能在 real 会话暴露给编辑器前完成 canonicalize：本方法在 send 响应
    // 返回的同一事件循环内同步执行，UI 下一帧看到的已是合并后的 canonical session。
    final merged = existingReal == null
        ? pending.withConversationId(realKey)
        : _mergeSessions(
            pending: pending,
            real: existingReal,
            realKey: realKey,
            pendingKey: pendingKey,
            activeId: ws.activeConversationId,
          );
    final sessions = {...ws.sessions}..remove(pendingKey);
    sessions[realKey] = merged;
    // alias 生命周期：保留到 canonical session 删除或 workspace 整体清理（C6）。
    final aliases = {...ws.aliases, pendingKey: realKey};
    // active 保护：仅当 active 仍是该 pending key 才切到真实 uuid；用户已切走
    // 则 active 保持不变（V7/V13 场景）。
    final active = ws.activeConversationId == pendingKey
        ? realKey
        : ws.activeConversationId;
    _setWorkspace(ChatWorkspaceState(
      activeConversationId: active,
      sessions: sessions,
      aliases: aliases,
    ));
    _runtimes.rekeyConversation(pendingKey, realKey);
    _historyPageByConv.remove(pendingKey);
    if (ref.read(activePendingConversationProvider) == pendingKey) {
      ref.read(activePendingConversationProvider.notifier).state = null;
    }
    // 左侧 pending 会话栏升级为真实会话(去重)。列表预览在本地 patch,
    // 避免每次发送都全量刷新左侧会话列表。
    ref.read(conversationsProvider.notifier).adoptPending(
          pendingKey,
          realKey,
          roomUuid: roomUuid.isNotEmpty ? roomUuid : null,
          wukongChannelId: wukongChannelId.isNotEmpty ? wukongChannelId : null,
          wukongChannelType: wukongChannelType > 0 ? wukongChannelType : null,
          kind: roomUuid.isNotEmpty ? 'agent_direct' : null,
        );
  }

  /// 契约 C6：pending 与已存在 real session 的合并，禁止整体覆盖任意一侧。
  ChatSessionState _mergeSessions({
    required ChatSessionState pending,
    required ChatSessionState real,
    required String realKey,
    required String pendingKey,
    required String? activeId,
  }) {
    // 消息：real 侧服务端顺序在前；pending 侧按 server messageId 第一优先、
    // localId 兜底原位对账（不删除重追加，V19），新增 optimistic 置于历史之后。
    final mergedMessages = [...real.messages];
    final byMsgId = <String, int>{};
    final byLocal = <String, int>{};
    for (var i = 0; i < mergedMessages.length; i++) {
      final m = mergedMessages[i];
      final mid = m.messageId;
      if (mid != null && mid.isNotEmpty) byMsgId[mid] = i;
      byLocal[m.localId] = i;
    }
    for (final m in pending.messages) {
      final mid = m.messageId;
      int? at = (mid != null && mid.isNotEmpty) ? byMsgId[mid] : null;
      at ??= byLocal[m.localId];
      if (at != null) {
        mergedMessages[at] = m; // 原位对账：live 版本（含运行时字段）就地覆盖
      } else {
        byLocal[m.localId] = mergedMessages.length;
        if (mid != null && mid.isNotEmpty) byMsgId[mid] = mergedMessages.length;
        mergedMessages.add(m);
      }
    }

    // composer draft：整体二选一，严格顺序 a–e（F09 §5.7.4）。
    final p = pending.draft;
    final r = real.draft;
    final ChatComposerDraft draft;
    if (p.isEmpty && r.isEmpty) {
      draft = r; // e) 双空 → canonical real
    } else if (p.isEmpty != r.isEmpty) {
      draft = p.isEmpty ? r : p; // a) 非空优先，不考虑 active
    } else if (activeId == pendingKey) {
      draft = p; // b) active 侧优先
    } else if (activeId == realKey) {
      draft = r; // b)
    } else if (p.revision != r.revision) {
      draft = p.revision > r.revision ? p : r; // c) workspace 级 revision
    } else {
      draft = r; // d) revision 相同 → 固定 canonical real，结果确定
    }

    // pendingFiles：全部状态按 localUploadId 去重合并；real 侧顺序在前，
    // pending 侧新增按原序追加；冲突取信息更完整者 ready > uploading > failed。
    int rank(ChatFileItem f) => f.isReadyToSend ? 2 : (f.uploading ? 1 : 0);
    final files = <ChatFileItem>[];
    final fileIdx = <String, int>{};
    for (final f in real.pendingFiles) {
      fileIdx[f.localUploadId] = files.length;
      files.add(f);
    }
    for (final f in pending.pendingFiles) {
      final i = fileIdx[f.localUploadId];
      if (i == null) {
        fileIdx[f.localUploadId] = files.length;
        files.add(f);
      } else if (rank(f) > rank(files[i])) {
        files[i] = f;
      }
    }

    final realLoadedHistory = real.messages.isNotEmpty;
    return ChatSessionState(
      conversationId: realKey,
      messages: mergedMessages,
      draft: draft,
      pendingFiles: files,
      // 保留 pending 侧运行中 runtime 对应的发送态。
      isSending: pending.isSending || real.isSending,
      hasMoreHistory:
          realLoadedHistory ? real.hasMoreHistory : pending.hasMoreHistory,
      isLoadingHistory: real.isLoadingHistory,
      isLoadingMessages: false,
      errorMessage: pending.errorMessage ?? real.errorMessage,
      highlightMessageUuid: real.highlightMessageUuid,
      highlightToken: real.highlightToken,
      hasMoreNewer: real.hasMoreNewer,
      isLoadingNewer: real.isLoadingNewer,
      activeStreamId: pending.activeStreamId ?? real.activeStreamId,
      activeAgentMessageUuid:
          pending.activeAgentMessageUuid ?? real.activeAgentMessageUuid,
      activeLocalPlaceholderId:
          pending.activeLocalPlaceholderId ?? real.activeLocalPlaceholderId,
    );
  }

  /// ADR-0028 §4.6 / Plan 16 §J — HITL `/chat/respond` 客户端入口。
  ///
  /// 业务场景: EmpBlocksView 的 approval/form/action 按钮点击后, widget 通过
  /// [EmpBlocksRespondHandler] 回调到这里; 本方法负责:
  ///   1. **防双击**: 已 `_respondingMessages` 命中 → 返 false (caller 维持 disabled);
  ///   2. POST `/chat/respond`, 拿新 stream_id + 新 agent_message_uuid;
  ///   3. **不**清空旧 awaiting_user 气泡 (它已 final + metadata 含 next_ids,
  ///      运维侧 + 历史回顾仍可看见); 把它的 [agentMessageStatus] 改回 'final'
  ///      让 widget enable 条件 fail-out, 按钮锁死;
  ///   4. **追加** 一条新 assistant placeholder (status=loading, messageId=新 uuid),
  ///      _startStream(新 streamId) 让 SSE 来填充;
  ///   5. 失败 (网络 / 400/404/409/5xx) → BotToast + 返 false, 不动旧气泡, 不创建新气泡。
  ///
  /// 返 `true` 仅在 POST 成功 + 新 stream 订阅链路启动成功; 后续 SSE 终态由
  /// `_handleStreamEvent` 收口 (与 send 同款)。
  ///
  /// **不假成功**: 即便 stream 没产事件, 也不会把 widget 切到"已成功"态 — 因为
  /// 我们仅 disable 按钮, 不显示 "已批准" 字样 (避免欺骗); 真实终态由后端 SSE 决定。
  ///
  /// Returns: `true` 成功 / `false` 失败。
  Future<bool> respondToAgentMessage({
    required String agentMessageUuid,
    required String responseKind,
    required Map<String, dynamic> responsePayload,
  }) async {
    if (agentMessageUuid.isEmpty || responseKind.isEmpty) {
      BotToast.showText(text: '参数缺失, 无法提交');
      return false;
    }
    if (_respondingMessages.contains(agentMessageUuid)) {
      // 防双击: 该 message 已有正在跑的 /chat/respond, 静默拒绝。
      return false;
    }
    // 契约 C8/V12：目标会话从「该消息所在 session」反查（active 优先），
    // 后续所有写入只落该会话——用户提交后切走也不串。
    final ws = state.asData?.value;
    if (ws == null) {
      BotToast.showText(text: '会话状态异常, 请重新进入会话');
      return false;
    }
    bool containsMsg(ChatSessionState s) =>
        s.messages.any((m) => m.messageId == agentMessageUuid);
    String? convKey;
    final activeKey = ws.activeConversationId == null
        ? null
        : ws.canonicalKey(ws.activeConversationId!);
    if (activeKey != null &&
        ws.sessions[activeKey] != null &&
        containsMsg(ws.sessions[activeKey]!)) {
      convKey = activeKey;
    } else {
      for (final entry in ws.sessions.entries) {
        if (containsMsg(entry.value)) {
          convKey = entry.key;
          break;
        }
      }
    }
    if (convKey == null || convKey.isEmpty || isPendingConversation(convKey)) {
      BotToast.showText(text: '会话状态异常, 请重新进入会话');
      return false;
    }
    // 契约 C2：同会话单 active run——上一轮尚未收口时拒绝新一轮。
    final targetSession = ws.sessions[convKey]!;
    final claimKey = ws.canonicalKey(convKey);
    if (targetSession.hasActiveRun ||
        _runtimes.forConversation(claimKey) != null ||
        _respondingConversations.contains(claimKey)) {
      return false;
    }

    _respondingMessages.add(agentMessageUuid);
    // P1-2（契约 C2）：POST 前原子占用会话级 reservation。这里不置
    // session.isSending，因为响应回来前尚无可停止的服务端 run；send/respond
    // 入口都检查本集合，已足以保证同会话互斥。
    _respondingConversations.add(claimKey);

    final service = ref.read(chatServiceProvider);
    try {
      final resp = await service.respondToAgentMessage(
        conversationUuid: convKey,
        agentMessageUuid: agentMessageUuid,
        responseKind: responseKind,
        responsePayload: responsePayload,
      );
      if (resp.streamId.isEmpty || resp.newAgentMessageUuid.isEmpty) {
        BotToast.showText(text: '提交失败, 请稍后重试');
        return false;
      }

      // 1. 把原 awaiting_user 气泡的 agentMessageStatus 改回 'final' (后端已 final),
      //    让 EmpBlocksView 4 条件 enable fail-out, 按钮锁死; empBlocks 不动 (仍可见)。
      // 2. 追加新 assistant placeholder (loading), messageId/streamId 取后端返回值。
      //    全部写入目标会话分区（V12），不读届时 active。
      final placeholder = ChatMessage(
        role: ChatRole.answer,
        content: '',
        status: BubbleStatus.loading,
        streamStartedAt: DateTime.now(),
        messageId: resp.newAgentMessageUuid,
        streamId: resp.streamId,
      );
      final canonical = _canon(convKey);
      final latest = _ws.sessions[canonical];
      if (latest == null) {
        // 会话在等待期间被删除：fail closed——不订阅流，best-effort 停掉新 run。
        _bestEffortStop(resp.newAgentMessageUuid);
        return false;
      }
      final messages = latest.messages.map((m) {
        if (m.messageId == agentMessageUuid &&
            m.agentMessageStatus == 'awaiting_user') {
          return m.copyWith(agentMessageStatus: 'final');
        }
        return m;
      }).toList();
      messages.add(placeholder);
      // 占用转正：闸口从"claim"升级为真实 stream runtime 索引。
      _setSession(
        canonical,
        latest.copyWith(
          messages: messages,
          isSending: true,
          clearError: true,
          activeStreamId: resp.streamId,
          activeAgentMessageUuid: resp.newAgentMessageUuid,
          activeLocalPlaceholderId: placeholder.localId,
        ),
      );

      // 同 send 路径: detached startStream; 不 await 整段终态, 失败/cancel 在 SSE handler 内收口。
      // /chat/respond 返回的新 stream 绑定**原会话**（C8/V12）。
      final rt = ChatStreamRuntime(
        streamId: resp.streamId,
        conversationId: canonical,
        localPlaceholderId: placeholder.localId,
        agentMessageUuid: resp.newAgentMessageUuid,
      );
      unawaited(_startStream(rt));
      return true;
    } catch (e) {
      // raw runtime error 已由后端 sanitize; 此处只显示固定客户端文案。
      BotToast.showText(text: '提交失败, 请稍后重试');
      return false;
    } finally {
      _respondingMessages.remove(agentMessageUuid);
      _respondingConversations.remove(claimKey);
    }
  }

  Future<bool> decideA2AApproval({
    required String approvalRequestId,
    required bool approved,
    String? reason,
    Map<String, dynamic>? formResult,
  }) async {
    final uuid = approvalRequestId.trim();
    if (uuid.isEmpty) {
      BotToast.showText(text: '审批参数缺失, 无法提交');
      return false;
    }
    if (_respondingMessages.contains(uuid)) {
      return false;
    }
    // P1-3（契约 C8/R2）：**发起时**捕获审批块所在的 conversationKey + message
    // localId；完成后只按捕获目标回写，不再读届时 active（审批期间切会话不串）。
    final target = _findA2AApprovalTarget(uuid);
    _respondingMessages.add(uuid);
    try {
      await ref.read(chatServiceProvider).decideA2AApproval(
            approvalRequestId: uuid,
            decision: approved ? 'approved' : 'rejected',
            reason: reason,
            formResult: formResult,
          );
      _markA2AApprovalBlockDecided(
          target, uuid, approved ? 'approved' : 'rejected');
      BotToast.showText(text: approved ? '已同意协作' : '已拒绝协作');
      return true;
    } catch (e) {
      BotToast.showText(
        text:
            formatBackendErrorMessage(e.toString(), fallback: '审批提交失败, 请稍后重试'),
      );
      return false;
    } finally {
      _respondingMessages.remove(uuid);
    }
  }

  /// 防双击: 正在跑 /chat/respond 的 agent_message_uuid 集合 (HITL 提交期间禁用按钮)。
  final Set<String> _respondingMessages = <String>{};

  /// 契约 §3.0f C2/V3：stop 默认只停**当前显示会话**的 active run；
  /// 其他会话的后台流不受影响。
  final Set<String> _stoppingMessages = {};

  Future<void> stop() async {
    final ws = state.asData?.value;
    final activeId = ws?.activeConversationId;
    if (ws == null || activeId == null) return;
    final key = ws.canonicalKey(activeId);
    final session = ws.sessions[key];
    if (session == null || session.messages.isEmpty || !session.isSending) {
      return;
    }
    final rt = _runtimes.forConversation(key);
    final msgId = rt?.agentMessageUuid ?? session.activeAgentMessageUuid;
    // main 68b15f0c:rt 为空时合成 stopTarget 统一收口时间线;reveal buffer
    // 已随打字机修复删除,不再有 _cancelAnswerReveal。
    final stopTarget = rt ??
        ChatStreamRuntime(
          streamId: session.activeStreamId ?? '',
          conversationId: key,
          localPlaceholderId: session.activeLocalPlaceholderId ?? '',
          agentMessageUuid: msgId,
        );
    if (msgId == null || msgId.isEmpty) {
      // Wait for the dispatch ID, then confirm cancellation on that exact run.
      final placeholderId = session.activeLocalPlaceholderId;
      if (placeholderId != null && placeholderId.isNotEmpty) {
        _cancelledPendingRuns.add(placeholderId);
      }
      return;
    }
    if (!_stoppingMessages.add(msgId)) return;
    _setSession(key, session.copyWith(clearError: true));
    try {
      await ref.read(chatServiceProvider).stopMessage(messageId: msgId);
      if (!ref.mounted) return;
      final current = state.asData?.value.sessions[key];
      // Completion or a newer run may win while the stop request is in flight.
      if (current == null ||
          !current.isSending ||
          (current.activeAgentMessageUuid != msgId &&
              _runtimes.forConversation(key)?.agentMessageUuid != msgId)) {
        return;
      }
      stopTarget.stopped = true;
      _finalizeRunningEntries(stopTarget, stoppedKey: 'stopped');
      _locallyStoppedMessageIds.add(msgId);
      if (rt != null) {
        _runtimes.remove(rt.streamId);
        rt.cancel();
      }
      _markRunDone(key, rt, stopped: true);
    } catch (_) {
      if (!ref.mounted) return;
      final current = state.asData?.value.sessions[key];
      if (current != null &&
          current.isSending &&
          (current.activeAgentMessageUuid == msgId ||
              _runtimes.forConversation(key)?.agentMessageUuid == msgId)) {
        _setSession(
            key, current.copyWith(errorMessage: '停止请求未确认，任务可能仍在执行，请重试停止'));
      }
    } finally {
      _stoppingMessages.remove(msgId);
    }
  }

  Future<void> _startStream(ChatStreamRuntime rt) async {
    // 契约 C10：同一 stream 绝不双订阅（切回运行中会话 / resume 竞态）。
    if (_runtimes.contains(rt.streamId)) {
      return;
    }
    _runtimes.register(rt);
    final keyAtStart = _canon(rt.conversationId);
    _accountHistoryRequests[keyAtStart] =
        (_accountHistoryRequests[keyAtStart] ?? 0) + 1;
    final handle = ChatStreamCancelHandle();
    rt.cancelSubscription = handle.cancel;
    final service = ref.read(chatServiceProvider);
    try {
      await service.streamMessage(
        streamId: rt.streamId,
        cancelHandle: handle,
        onEvent: (json) async {
          // per-stream stopped 标志：只吞**本流**的迟到事件，不影响其他会话。
          if (rt.stopped) {
            return;
          }
          await _handleStreamEvent(rt, json);
        },
        onDone: () async {
          if (!rt.stopped) {
            _flushAnswerReveal(rt);
            _markRunDone(rt.conversationId, rt);
          }
          rt.done = true;
        },
      );
    } catch (e) {
      // SSE 订阅本身失败（死流 404/403、断网、网关错误、解析异常）：绝不能让
      // 该会话卡在「isSending + 思考中 + 停止按钮」的失效运行态（pitfall
      // 「activeStreamId 不等于底层流仍存活」）。目标化收口本会话，并把该
      // stream 标记为死流（不再自动 resume），随后与服务端历史对账拿真相。
      if (kDebugMode) {
        debugPrint('[chat] stream ${rt.streamId} subscribe failed: $e');
      }
      _deadStreams.add(rt.streamId);
      if (!rt.stopped && ref.mounted) {
        rt.stopped = true;
        _cancelAnswerReveal(rt);
        _markRunDone(rt.conversationId, rt, stopped: true);
        unawaited(_reconcileSessionHistory(rt.conversationId));
      }
    } finally {
      rt.done = true;
      _cancelAnswerReveal(rt);
      _runtimes.remove(rt.streamId);
      // 兜底：session 的运行索引若仍指向本流且发送态已收口，清掉。
      final key = _canon(rt.conversationId);
      final s = _ws.sessions[key];
      if (s != null && s.activeStreamId == rt.streamId && !s.isSending) {
        _setSession(key, s.copyWith(clearActiveStream: true));
      }
    }
  }

  /// 把 SSE 事件 [json] 应用到 [rt] 绑定的目标 placeholder 上（契约 C4/C5）：
  /// - `phase`        → lifecycle / thinking 步骤；
  /// - `reasoning`    → 累积 `reasoningContent` + reasoning 步骤；
  /// - `message`      → 流式拼 content + generating 步骤；
  /// - `tool_call`    → tool 步骤（参数累积）；
  /// - `tool_result`  → 关联 tool 步骤补充结果；
  /// - `usage`        → usage 摘要 + usage 步骤；
  /// - `done` / `stopped` / `error` → 收口（只收 rt 所属会话）。
  ///
  /// defense-in-depth：事件体身份字段**非空才校验**，不匹配即丢弃并记日志；
  /// 字段缺失继续按 runtime target 处理，绝不回退 active / 最后一条 assistant。
  Future<void> _handleStreamEvent(
    ChatStreamRuntime rt,
    Map<String, dynamic> json,
  ) async {
    if (rt.stopped || rt.done) return;
    final eventType = (json['eventType'] ?? '').toString();
    final evStream = (json['stream_id'] ?? '').toString();
    if (evStream.isNotEmpty && evStream != rt.streamId) {
      if (kDebugMode) {
        debugPrint('[chat] drop event: stream_id $evStream != ${rt.streamId}');
      }
      return;
    }
    final evConv = (json['conversation_uuid'] ?? '').toString();
    if (evConv.isNotEmpty && _canon(evConv) != _canon(rt.conversationId)) {
      if (kDebugMode) {
        debugPrint(
            '[chat] drop event: conversation $evConv != ${rt.conversationId}');
      }
      return;
    }
    final evMsg = (json['message_uuid'] ?? '').toString();
    if (evMsg.isNotEmpty) {
      final bound = rt.agentMessageUuid;
      if (bound == null || bound.isEmpty) {
        rt.agentMessageUuid = evMsg; // 服务端 UUID 首见即绑定（C4）
      } else if (evMsg != bound) {
        if (kDebugMode) {
          debugPrint('[chat] drop event: message_uuid $evMsg != $bound');
        }
        return;
      }
    }

    switch (eventType) {
      case 'local_artifacts':
        // Host snapshot, independent of model text and cloud archival. Identity was checked above.
        final artifacts = <String, Map<String, dynamic>>{};
        for (final block in _parseEmpBlocks(json['blocks'])) {
          final reference = block['local_artifact'];
          if (reference is Map &&
              (block['type'] == 'image' || block['type'] == 'file')) {
            final id = reference['artifact_id'];
            if (id is String && id.isNotEmpty) artifacts[id] = block;
          }
        }
        _updateTargetAnswer(
            rt,
            (m) => m.copyWith(empBlocks: [
                  ...m.empBlocks
                      .where((block) => block['local_artifact'] is! Map),
                  ...artifacts.values,
                ]));
        break;
      case 'phase':
        _applyPhaseEvent(rt, json);
        break;
      case 'reasoning':
        _applyReasoningEvent(rt, json);
        break;
      case 'message':
        await _applyMessageEvent(rt, json);
        break;
      case 'awaiting_user':
        // ADR-0028 §4.2 / Plan 16 §J — HITL pause. 把 raw agentMessageStatus 置
        // 'awaiting_user' + 透 empBlocks, 让 EmpBlocksView 4 条件 enable 富组件提交。
        // 同 message.completed 一样标记 stream 终态收口 (本轮 stream done; 客户端
        // 提交后用 /chat/respond 返回的**新** stream_id 重新订阅承接下一轮)。
        _flushAnswerReveal(rt);
        final blocks = _parseEmpBlocks(json['blocks']);
        _updateTargetAnswer(rt, (m) {
          return m.copyWith(
            empBlocks: blocks.isNotEmpty ? blocks : m.empBlocks,
            agentMessageStatus: 'awaiting_user',
          );
        });
        rt.stopped = true;
        _finalizeRunningEntries(rt, stoppedKey: 'done');
        _markRunDone(rt.conversationId, rt);
        break;
      case 'a2a_approval':
        _applyA2AApprovalEvent(rt, json);
        break;
      case 'stage':
        _applyStageEvent(rt, json);
        break;
      case 'stage_done':
        _finalizeStageEntries(rt);
        break;
      case 'tool_call':
        _applyToolCallEvent(rt, json);
        break;
      case 'tool_result':
        _applyToolResultEvent(rt, json);
        break;
      case 'usage':
        _applyUsageEvent(rt, json);
        break;
      case 'stopped':
        _applyPartialTerminalBlocks(rt, json['blocks']);
        rt.stopped = true;
        _cancelAnswerReveal(rt);
        _finalizeRunningEntries(rt, stoppedKey: 'stopped');
        _markRunDone(rt.conversationId, rt, stopped: true);
        break;
      case 'error':
        _flushAnswerReveal(rt);
        _finalizeRunningEntries(rt, stoppedKey: 'error');
        _applyPartialTerminalBlocks(rt, json['blocks'], includeText: true);
        final errCode = (json['error_code'] ?? '').toString();
        _updateTargetAnswer(
            rt,
            (m) =>
                m.copyWith(failureCode: errCode, agentMessageStatus: 'failed'));
        final errMsg = (json['error_message'] ??
                json['error'] ??
                json['message'] ??
                '生成失败')
            .toString();
        rt.stopped = true;
        if (errCode == 'zap.billing_insufficient_credits' ||
            errCode == 'billing.insufficient_credits') {
          notifyBillingSummaryChanged();
          _failRun(
              rt.conversationId, rt.localPlaceholderId, '积分不足，请先购买积分包或升级套餐');
        } else {
          _failRun(
              rt.conversationId,
              rt.localPlaceholderId,
              formatBackendErrorPayload(
                errorCode: errCode,
                errorMessage: errMsg,
                fallback: '生成失败',
              ));
        }
        break;
      case 'done':
        _flushAnswerReveal(rt);
        rt.stopped = true;
        _finalizeRunningEntries(rt, stoppedKey: 'done');
        _markRunDone(rt.conversationId, rt);
        break;
      case 'raw':
      default:
        break;
    }
  }

  void _applyPhaseEvent(ChatStreamRuntime rt, Map<String, dynamic> json) {
    final phase = (json['phase'] ?? '').toString();
    final model = (json['model'] ?? '').toString();
    if (phase == 'created') {
      _upsertEntry(
        rt,
        key: 'lifecycle',
        kind: ChatTimelineKind.lifecycle,
        title: model.isNotEmpty ? '已连接 OpenClaw · $model' : '已连接 OpenClaw',
        finalStatus: ChatTimelineStatus.done,
      );
    } else if (phase == 'in_progress') {
      _upsertEntry(
        rt,
        key: 'thinking',
        kind: ChatTimelineKind.thinking,
        title: '思考中',
      );
    } else if (phase == 'completed') {
      _stopRunningEntry(rt, 'thinking');
    }
  }

  /// EventType=stage：OpenClaw prep stages 静默期预留行。
  /// 渲染规则（与 Cursor / QClaw 进度条对齐）：**同一时刻只有最新一条在
  /// running（spinner），更早的 stage 行立刻置 done（绿勾）**。这样多条 stage
  /// 同时转圈的视觉噪音消失，用户看到的是逐条亮勾的进度感。
  /// stage_done 信号到达时再 finalize 残留的最后一条。
  void _applyStageEvent(ChatStreamRuntime rt, Map<String, dynamic> json) {
    final id = (json['stageId'] ?? '').toString();
    final text = (json['stageText'] ?? '').toString();
    if (id.isEmpty || text.isEmpty) return;

    final now = DateTime.now();
    final newKey = 'stage:$id';
    _updateTargetAnswer(rt, (last) {
      final entries = last.timelineEntries.map((e) {
        if (e.kind == ChatTimelineKind.stage &&
            e.isRunning &&
            e.key != newKey) {
          return e.copyWith(
            status: ChatTimelineStatus.done,
            endedAt: now
          );
        }
        return e;
      }).toList();
      return last.copyWith(timelineEntries: entries);
    });

    _upsertEntry(
      rt,
      key: newKey,
      kind: ChatTimelineKind.stage,
      title: text
    );
  }

  void _finalizeStageEntries(ChatStreamRuntime rt) {
    final now = DateTime.now();
    _updateTargetAnswer(rt, (last) {
      var changed = false;
      final entries = last.timelineEntries.map((e) {
        if (e.kind == ChatTimelineKind.stage && e.isRunning) {
          changed = true;
          return e.copyWith(
            status: ChatTimelineStatus.done,
            endedAt: now
          );
        }
        return e;
      }).toList();
      return changed ? last.copyWith(timelineEntries: entries) : last;
    });
  }

  void _applyReasoningEvent(ChatStreamRuntime rt, Map<String, dynamic> json) {
    final delta = (json['reasoning'] ?? '').toString();
    final isDone = (json['toolStatus'] ?? '').toString() == 'done';
    final target = _readTargetAnswer(rt);
    if (target == null) return;
    final newReasoning = delta.isNotEmpty
        ? '${target.reasoningContent}$delta'
        : target.reasoningContent;
    _stopRunningEntry(rt, 'thinking');
    _upsertEntry(
      rt,
      key: 'reasoning',
      kind: ChatTimelineKind.reasoning,
      title: '思考过程',
      snippet: _tailSnippet(newReasoning),
      finalStatus: isDone ? ChatTimelineStatus.done : null,
    );
    _updateTargetAnswer(rt, (m) => m.copyWith(reasoningContent: newReasoning));
  }

  Future<void> _applyMessageEvent(
    ChatStreamRuntime rt,
    Map<String, dynamic> json,
  ) async {
    final incoming = (json['content'] ?? '').toString();
    final finished = json['finished'] == true;
    if (finished) {
      // 后端在 finished 帧里塞了 finalText 时（兜底 rewrite 把流式漏掉的
      // /data/... 替换成 S3 URL 后），用它整段覆盖之前 streaming 累积的 content。
      // 否则前端会看到 /data 破图，必须刷新页面才能从 DB 拿到正确版本——这是
      // OpenAI / QClaw 等参考实现里不会出现的体感问题。
      //
      // Batch 1: 终态同时把 raw EMP blocks 写入 last.empBlocks; Batch 2 真渲染消费。
      // 解析失败 / 字段坏 → best-effort 跳过 (与 empBlocksToReadableText 同纪律)。
      if (incoming.isNotEmpty) {
        _cancelAnswerReveal(rt);
      } else {
        // 部分 adapter 的 completed 只带 blocks，不重复 final text。此时此前已到达
        // 的 delta 仍是唯一正文，必须立即 flush，不能因取消 visual queue 而丢字。
        _flushAnswerReveal(rt);
      }
      final rawBlocks = json['blocks'];
      final visibleBlocks = ChatMessage.withoutA2ATimelineBlocks(rawBlocks);
      final empBlocks = _parseEmpBlocks(visibleBlocks);
      final timelineEntries =
          ChatMessage.timelineFromBlocks(rawBlocks, DateTime.now());
      // rawBlocks 是不是 List 决定"这一帧到底有没有明确告诉我们 blocks 是什么"：
      // adapter 没带 blocks 字段(null/非 List) → 保留之前 delta 累积的 m.empBlocks；
      // adapter 明确带了 blocks(哪怕解析出来是空)→ 相信这个空，不能再退回旧值——
      // 否则流式过程中途出现过的临时 empBlocks(比如一度像是要出表单，最终定稿是
      // 纯文本)会永久残留在这条已经 finished 的消息上，纯文本气泡被误判成
      // "带 EMP 富内容"，按 EMP 专用宽度撑满整行(见 ChatAssistantMessageView.
      // hasEmpBlocks 那条 ConstrainedBox 分支)。
      final finishedBlocksExplicit = rawBlocks is List;
      if (incoming.isNotEmpty ||
          empBlocks.isNotEmpty ||
          finishedBlocksExplicit) {
        _updateTargetAnswer(rt, (m) {
          return m.copyWith(
            content: incoming.isNotEmpty ? incoming : m.content,
            empBlocks: empBlocks.isNotEmpty
                ? empBlocks
                : (finishedBlocksExplicit &&
                        m.empBlocks.any((b) => b['local_artifact'] is Map)
                    ? m.empBlocks
                    : (finishedBlocksExplicit ? empBlocks : m.empBlocks)),
            timelineEntries: timelineEntries.isNotEmpty
                ? timelineEntries
                : m.timelineEntries,
          );
        });
      }
      rt.stopped = true;
      _finalizeRunningEntries(rt, stoppedKey: 'done');
      _markRunDone(rt.conversationId, rt);
      return;
    }
    if (incoming.isEmpty) return;

    _stopRunningEntry(rt, 'thinking');
    _queueAnswerDelta(rt, incoming);
  }

  /// `ChatService` 已把 Bus 的累计快照转换为增量；这里进入 per-stream 有界队列。
  /// 同一 UI frame 最多提交一次状态更新，大积压在 16 帧预算内自适应追平。
  void _queueAnswerDelta(ChatStreamRuntime rt, String delta) {
    if (delta.isEmpty) return;
    final target = _readTargetAnswer(rt);
    if (target == null || !target.isAnswer) return;

    rt.answerReveal.add(delta);
    _scheduleAnswerRevealFrame(rt);
  }

  void _scheduleAnswerRevealFrame(ChatStreamRuntime rt) {
    if (rt.stopped ||
        rt.done ||
        rt.answerReveal.isEmpty ||
        rt.answerRevealFrameCallbackId != null) {
      return;
    }

    late final int callbackId;
    callbackId = _scheduleAnswerFrameCallback((_) {
      if (rt.answerRevealFrameCallbackId != callbackId) return;
      rt.answerRevealFrameCallbackId = null;
      if (rt.stopped || rt.done || !ref.mounted) {
        rt.answerReveal.clear();
        return;
      }

      final chunk = rt.answerReveal.takeForFrame();
      if (chunk.isNotEmpty) {
        _appendAnswerChunk(rt, chunk);
      }
      if (!rt.answerReveal.isEmpty) {
        _scheduleAnswerRevealFrame(rt);
      }
    });
    rt.answerRevealFrameCallbackId = callbackId;
    rt.cancelAnswerReveal ??= () => _cancelAnswerReveal(rt);
  }

  void _appendAnswerChunk(ChatStreamRuntime rt, String chunk) {
    final target = _readTargetAnswer(rt);
    if (target == null || !target.isAnswer) {
      _cancelAnswerReveal(rt);
      return;
    }

    final newContent = '${target.content}$chunk';
    final now = DateTime.now();
    _updateTargetAnswer(rt, (message) {
      final entries = [...message.timelineEntries];
      final index = entries.indexWhere((entry) => entry.key == 'generating');
      final title = '输出回答 · ${newContent.length} 字';
      final snippet = _tailSnippet(newContent, max: 80);
      if (index == -1) {
        entries.add(
          ChatTimelineEntry(
            key: 'generating',
            kind: ChatTimelineKind.generating,
            title: title,
            snippet: snippet,
            status: ChatTimelineStatus.running,
            startedAt: now,
          ),
        );
      } else {
        entries[index] = entries[index].copyWith(
          title: title,
          snippet: snippet,
        );
      }
      return message.copyWith(
        content: newContent,
        status: BubbleStatus.loading,
        timelineEntries: entries,
      );
    });
  }

  void _flushAnswerReveal(ChatStreamRuntime rt) {
    final callbackId = rt.answerRevealFrameCallbackId;
    if (callbackId != null) {
      _cancelAnswerFrameCallback(callbackId);
      rt.answerRevealFrameCallbackId = null;
    }
    final pending = rt.answerReveal.flush();
    rt.cancelAnswerReveal = null;
    if (pending.isNotEmpty) {
      _appendAnswerChunk(rt, pending);
    }
  }

  void _applyPartialTerminalBlocks(ChatStreamRuntime rt, dynamic rawBlocks,
      {bool includeText = false}) {
    final visibleBlocks = ChatMessage.withoutA2ATimelineBlocks(rawBlocks);
    final empBlocks = _parseEmpBlocks(visibleBlocks);
    final timelineEntries =
        ChatMessage.timelineFromBlocks(rawBlocks, DateTime.now());
    final text = includeText ? plainBlocksText(visibleBlocks) : '';
    if (rawBlocks is List ||
        empBlocks.isNotEmpty ||
        timelineEntries.isNotEmpty ||
        text.isNotEmpty) {
      _updateTargetAnswer(rt, (m) {
        return m.copyWith(
          content: text.isNotEmpty ? text : m.content,
          empBlocks: rawBlocks is List ? empBlocks : m.empBlocks,
          timelineEntries:
              timelineEntries.isNotEmpty ? timelineEntries : m.timelineEntries,
        );
      });
    }
  }

  void _cancelAnswerReveal(ChatStreamRuntime rt) {
    final callbackId = rt.answerRevealFrameCallbackId;
    if (callbackId != null) {
      _cancelAnswerFrameCallback(callbackId);
      rt.answerRevealFrameCallbackId = null;
    }
    rt.answerReveal.clear();
    rt.cancelAnswerReveal = null;
  }

  int _scheduleAnswerFrameCallback(FrameCallback callback) {
    final schedule = debugScheduleAnswerFrameCallback;
    if (schedule != null) return schedule(callback);
    return SchedulerBinding.instance.scheduleFrameCallback(callback);
  }

  void _cancelAnswerFrameCallback(int callbackId) {
    final cancel = debugCancelAnswerFrameCallback;
    if (cancel != null) {
      cancel(callbackId);
      return;
    }
    SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
  }

  void _applyToolCallEvent(ChatStreamRuntime rt, Map<String, dynamic> json) {
    final toolCallId = (json['toolCallId'] ?? '').toString();
    if (toolCallId.isEmpty) return;
    _stopRunningEntry(rt, 'thinking');

    final toolName = (json['toolName'] ?? '').toString();
    final toolStatus =
        (json['toolStatus'] ?? '').toString().trim().toLowerCase();
    final argsDelta = (json['toolArgsDelta'] ?? '').toString();
    final args = (json['toolArgs'] ?? '').toString();

    final key = 'tool:$toolCallId';
    final entries =
        _readTargetAnswer(rt)?.timelineEntries ?? const <ChatTimelineEntry>[];
    final existing = _findEntry(entries, key);

    final mergedArgs = () {
      final base = existing?.toolArgs ?? '';
      if (args.isNotEmpty) return args;
      if (argsDelta.isEmpty) return base;
      return '$base$argsDelta';
    }();
    final displayName =
        toolName.isNotEmpty ? toolName : (existing?.toolName ?? '工具');
    final failed = toolStatus == 'failed' || toolStatus == 'error';
    final stopped = toolStatus == 'stopped' || toolStatus == 'cancelled';
    final completed =
        const {'completed', 'succeeded', 'done', 'ok'}.contains(toolStatus);
    final statusLabel = switch (toolStatus) {
      'args_delta' => '参数生成中',
      'args_done' => '执行中',
      'failed' || 'error' => '失败',
      'stopped' || 'cancelled' => '已停止',
      'completed' || 'succeeded' || 'done' || 'ok' => '完成',
      _ => '调用中',
    };
    _upsertEntry(
      rt,
      key: key,
      kind: ChatTimelineKind.tool,
      title: '调用工具 $displayName · $statusLabel',
      toolName: displayName,
      toolArgs: mergedArgs.isEmpty ? null : mergedArgs,
      finalStatus: failed
          ? ChatTimelineStatus.error
          : stopped
              ? ChatTimelineStatus.stopped
              : completed
                  ? ChatTimelineStatus.done
                  : null,
    );
  }

  void _applyToolResultEvent(ChatStreamRuntime rt, Map<String, dynamic> json) {
    final toolCallId = (json['toolCallId'] ?? '').toString();
    if (toolCallId.isEmpty) return;
    final key = 'tool:$toolCallId';
    final entries =
        _readTargetAnswer(rt)?.timelineEntries ?? const <ChatTimelineEntry>[];
    final existing = _findEntry(entries, key);
    if (existing == null) return;

    final toolStatus = (json['toolStatus'] ?? '').toString();
    final result = (json['toolResult'] ?? '').toString();
    final resultDelta = (json['toolResultDelta'] ?? '').toString();
    final failed = toolStatus == 'failed';
    final stopped = toolStatus == 'stopped' || toolStatus == 'cancelled';
    final running = toolStatus == 'running';
    final displayName = existing.toolName ?? '工具';
    final mergedResult = result.isNotEmpty
        ? result
        : resultDelta.isNotEmpty
            ? '${existing.toolResult ?? ''}$resultDelta'
            : (existing.toolResult ?? '');
    _upsertEntry(
      rt,
      key: key,
      kind: ChatTimelineKind.tool,
      title: failed
          ? '调用工具 $displayName · 失败'
          : stopped
              ? '调用工具 $displayName · 已停止'
              : running
                  ? '调用工具 $displayName · 输出中'
                  : '调用工具 $displayName · 完成',
      toolName: displayName,
      toolArgs: existing.toolArgs,
      toolResult: mergedResult.isEmpty ? null : mergedResult,
      finalStatus: running
          ? null
          : failed
              ? ChatTimelineStatus.error
              : stopped
                  ? ChatTimelineStatus.stopped
                  : ChatTimelineStatus.done,
    );
  }

  void _applyUsageEvent(ChatStreamRuntime rt, Map<String, dynamic> json) {
    final usage = ChatTokenUsage.tryParse(json);
    if (usage == null) return;
    final parts = <String>[];
    if (usage.inputTokens > 0) parts.add('输入 ${usage.inputTokens}');
    if (usage.outputTokens > 0) parts.add('输出 ${usage.outputTokens}');
    if (usage.totalTokens > 0) parts.add('合计 ${usage.totalTokens}');
    if (usage.model.isNotEmpty) parts.add(usage.model);
    final summary = parts.isEmpty ? null : parts.join(' · ');

    _updateTargetAnswer(rt, (m) {
      return m.copyWith(
        usageSummary: summary ?? m.usageSummary,
        tokenUsage: usage,
      );
    });
    _upsertEntry(
      rt,
      key: 'usage',
      kind: ChatTimelineKind.usage,
      title: '用量 · ${summary ?? '已统计'}',
      finalStatus: ChatTimelineStatus.done,
    );
  }

  // ---------------- 时间线编辑工具 ----------------

  ChatTimelineEntry? _findEntry(List<ChatTimelineEntry> list, String key) {
    for (final e in list) {
      if (e.key == key) return e;
    }
    return null;
  }

  /// 创建或更新时间线条目，[finalStatus] 非空时把状态置为完成态。
  /// 目标 = [rt] 绑定的 placeholder（C4），不再取"最后一条"。
  void _upsertEntry(
    ChatStreamRuntime rt, {
    required String key,
    required ChatTimelineKind kind,
    required String title,
    String? snippet,
    String? toolName,
    String? toolArgs,
    String? toolResult,
    ChatTimelineStatus? finalStatus,
  }) {
    final now = DateTime.now();
    _updateTargetAnswer(rt, (last) {
      final entries = [...last.timelineEntries];
      final idx = entries.indexWhere((e) => e.key == key);
      if (idx == -1) {
        entries.add(
          ChatTimelineEntry(
            key: key,
            kind: kind,
            title: title,
            snippet: snippet,
            status: finalStatus ?? ChatTimelineStatus.running,
            startedAt: now,
            endedAt: finalStatus == null ? null : now,
            toolName: toolName,
            toolArgs: toolArgs,
            toolResult: toolResult,
          ),
        );
      } else {
        final old = entries[idx];
        entries[idx] = old.copyWith(
          kind: kind,
          title: title,
          snippet: snippet ?? old.snippet,
          status: finalStatus ?? old.status,
          endedAt: finalStatus != null ? now : old.endedAt,
          toolName: toolName ?? old.toolName,
          toolArgs: toolArgs ?? old.toolArgs,
          toolResult: toolResult ?? old.toolResult,
        );
      }
      return last.copyWith(timelineEntries: entries);
    });
  }

  /// 把指定 key 的 running 条目置为 done，无需变更标题。
  void _stopRunningEntry(ChatStreamRuntime rt, String key) {
    _updateTargetAnswer(rt, (last) {
      final entries = [...last.timelineEntries];
      final idx = entries.indexWhere((e) => e.key == key);
      if (idx == -1) return last;
      final old = entries[idx];
      if (!old.isRunning) return last;
      entries[idx] = old.copyWith(
        status: ChatTimelineStatus.done,
        endedAt: DateTime.now(),
      );
      return last.copyWith(timelineEntries: entries);
    });
  }

  /// 流结束/出错/停止时统一收口所有未结束的条目，并 append 总结条目（done/error/stopped）。
  void _finalizeRunningEntries(
    ChatStreamRuntime rt, {
    required String stoppedKey,
  }) {
    final now = DateTime.now();
    _updateTargetAnswer(rt, (last) {
      final entries = last.timelineEntries.map((e) {
        if (e.isRunning) {
          final wrapStatus = switch (stoppedKey) {
            'error' => ChatTimelineStatus.error,
            'stopped' => ChatTimelineStatus.stopped,
            _ => ChatTimelineStatus.done,
          };
          return e.copyWith(status: wrapStatus, endedAt: now);
        }
        return e;
      }).toList();

      // 追加结尾的"完成 / 已停止 / 出错"步骤，方便 UI 展示总耗时。
      final wrapKind = switch (stoppedKey) {
        'error' => ChatTimelineKind.error,
        'stopped' => ChatTimelineKind.stopped,
        _ => ChatTimelineKind.done,
      };
      final wrapTitle = switch (stoppedKey) {
        'error' => '出错',
        'stopped' => '已停止',
        _ => '完成',
      };
      final wrapStatus = switch (stoppedKey) {
        'error' => ChatTimelineStatus.error,
        'stopped' => ChatTimelineStatus.stopped,
        _ => ChatTimelineStatus.done,
      };
      if (!entries.any((e) => e.key == stoppedKey)) {
        entries.add(
          ChatTimelineEntry(
            key: stoppedKey,
            kind: wrapKind,
            title: wrapTitle,
            status: wrapStatus,
            startedAt: now,
            endedAt: now,
          ),
        );
      }

      return last.copyWith(
        timelineEntries: entries,
        streamEndedAt: last.streamEndedAt ?? now,
      );
    });
  }

  /// 通用：合并字段到最后一条 assistant 消息。
  /// Batch 1 helper: 把 SSE 终态帧的 `blocks` 字段安全规一化到
  /// `List<Map<String, dynamic>>`。非 List / 元素非 Map → 跳过, 不抛。与
  /// `ChatMessage._readEmpBlocks` 同纪律。
  ///
  /// 只保留真正的 EMP 富内容块；没 type / type=markdown/plain/text 的普通文本块
  /// 不算——跟 ChatMessage._readEmpBlocks、wukong_im_client 的 _readRawEmpBlocks
  /// 口径一致。之前不分类型全塞进 empBlocks，导致 SSE 流式过程中气泡是对的，
  /// 一到 finished 帧解析最终 blocks(普通 markdown 回复也会被误判)就变宽。
  List<Map<String, dynamic>> _parseEmpBlocks(dynamic raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];
    const plainTypes = {'', 'markdown', 'plain', 'text'};
    final out = <Map<String, dynamic>>[];
    for (final b in raw) {
      Map<String, dynamic>? block;
      if (b is Map<String, dynamic>) {
        block = b;
      } else if (b is Map) {
        block = b.map((k, v) => MapEntry(k.toString(), v));
      }
      if (block == null) continue;
      final type = (block['type'] ?? '').toString().trim().toLowerCase();
      if (plainTypes.contains(type)) continue;
      out.add(block);
    }
    return out;
  }

  void _applyA2AApprovalEvent(ChatStreamRuntime rt, Map<String, dynamic> json) {
    final blocks = _parseEmpBlocks(json['blocks']);
    if (blocks.isEmpty) return;
    _updateTargetAnswer(rt, (last) {
      return last.copyWith(
        empBlocks: _mergeA2AApprovalBlocks(last.empBlocks, blocks),
      );
    });
  }

  List<Map<String, dynamic>> _mergeA2AApprovalBlocks(
    List<Map<String, dynamic>> existing,
    List<Map<String, dynamic>> incoming,
  ) {
    final incomingIds = incoming
        .map((b) => (b['approval_request_id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    return [
      for (final block in existing)
        if (!((block['x_source'] ?? '').toString() == 'a2a_approval' &&
            incomingIds
                .contains((block['approval_request_id'] ?? '').toString())))
          block,
      ...incoming,
    ];
  }

  /// 发起 A2A 审批时定位块归属：先当前显示会话，再全部 sessions。
  /// 返回 (conversationKey, message localId)；找不到返回 null（fail closed）。
  ({String conversationKey, String messageLocalId})? _findA2AApprovalTarget(
      String approvalRequestId) {
    final ws = state.asData?.value;
    if (ws == null) return null;
    bool ownsBlock(ChatMessage m) =>
        m.isAnswer &&
        m.empBlocks.any((block) =>
            (block['x_source'] ?? '').toString() == 'a2a_approval' &&
            (block['approval_request_id'] ?? '').toString() ==
                approvalRequestId);
    ({String conversationKey, String messageLocalId})? findIn(
        String key, ChatSessionState session) {
      final idx = session.messages.lastIndexWhere(ownsBlock);
      if (idx < 0) return null;
      return (
        conversationKey: key,
        messageLocalId: session.messages[idx].localId,
      );
    }

    final activeId = ws.activeConversationId;
    if (activeId != null) {
      final key = ws.canonicalKey(activeId);
      final session = ws.sessions[key];
      if (session != null) {
        final hit = findIn(key, session);
        if (hit != null) return hit;
      }
    }
    for (final entry in ws.sessions.entries) {
      final hit = findIn(entry.key, entry.value);
      if (hit != null) return hit;
    }
    return null;
  }

  /// 只按**发起时捕获**的目标回写审批状态（P1-3）；目标缺失 fail closed。
  void _markA2AApprovalBlockDecided(
    ({String conversationKey, String messageLocalId})? target,
    String approvalRequestId,
    String status,
  ) {
    if (target == null) {
      if (kDebugMode) {
        debugPrint(
            '[chat] fail-closed: a2a approval block $approvalRequestId not found');
      }
      return;
    }
    final key = _canon(target.conversationKey);
    final session = _ws.sessions[key];
    if (session == null) {
      if (kDebugMode) {
        debugPrint('[chat] fail-closed: a2a approval session $key gone');
      }
      return;
    }
    final idx = session.messages
        .lastIndexWhere((m) => m.localId == target.messageLocalId);
    if (idx < 0) {
      if (kDebugMode) {
        debugPrint(
            '[chat] fail-closed: a2a approval message ${target.messageLocalId} gone');
      }
      return;
    }
    final msg = session.messages[idx];
    final updated = [
      for (final block in msg.empBlocks)
        if ((block['x_source'] ?? '').toString() == 'a2a_approval' &&
            (block['approval_request_id'] ?? '').toString() ==
                approvalRequestId)
          {
            ...block,
            'a2a_approval_status': status
          }
        else
          block,
    ];
    final messages = [...session.messages];
    messages[idx] = msg.copyWith(empBlocks: updated);
    _setSession(key, session.copyWith(messages: messages));
  }

  /// 契约 C4/C5 的统一写入口：把 [update] 应用到 [rt] 绑定的目标消息上。
  /// 定位顺序：localPlaceholderId → agentMessageUuid；找不到 fail closed
  /// （记日志、丢弃本次写入），**绝不**回退 active 会话或"最后一条 assistant"。
  void _updateTargetAnswer(
    ChatStreamRuntime rt,
    ChatMessage Function(ChatMessage message) update,
  ) {
    if (!ref.mounted) return;
    final key = _canon(rt.conversationId);
    final session = _ws.sessions[key];
    if (session == null) {
      if (kDebugMode) {
        debugPrint(
            '[chat] fail-closed: session $key gone (stream ${rt.streamId})');
      }
      return;
    }
    final idx = _targetAnswerIndex(session, rt);
    if (idx < 0) {
      if (kDebugMode) {
        debugPrint(
            '[chat] fail-closed: placeholder ${rt.localPlaceholderId} missing in $key');
      }
      return;
    }
    final next = update(session.messages[idx]);
    if (identical(next, session.messages[idx])) return;
    final messages = [...session.messages];
    messages[idx] = next;
    _setSession(key, session.copyWith(messages: messages));
  }

  ChatMessage? _readTargetAnswer(ChatStreamRuntime rt) {
    final session = _ws.sessions[_canon(rt.conversationId)];
    if (session == null) return null;
    final idx = _targetAnswerIndex(session, rt);
    return idx < 0 ? null : session.messages[idx];
  }

  int _targetAnswerIndex(ChatSessionState session, ChatStreamRuntime? rt) {
    final localId = rt?.localPlaceholderId ?? session.activeLocalPlaceholderId;
    final msgUuid = rt?.agentMessageUuid ?? session.activeAgentMessageUuid;
    for (var i = session.messages.length - 1; i >= 0; i--) {
      final m = session.messages[i];
      if (localId != null && localId.isNotEmpty && m.localId == localId) {
        return i;
      }
      if (msgUuid != null && msgUuid.isNotEmpty && m.messageId == msgUuid) {
        return i;
      }
    }
    return -1;
  }

  /// 把 [previous] 中按 `messageId` 命中的运行时字段（timeline / usage /
  /// 流起止时间），合并回 [history] 返回的"干净"消息列表，保证流结束后
  /// 由 conversationsProvider 触发的 build 不会把执行过程刷没。
  List<ChatMessage> _mergeRuntimeContext({
    required List<ChatMessage> history,
    required List<ChatMessage>? previous,
  }) {
    if (previous == null || previous.isEmpty) return history;
    final byId = <String, ChatMessage>{};
    for (final m in previous) {
      final id = m.messageId;
      if (id != null && id.isNotEmpty) byId[id] = m;
    }
    final merged = history.map((msg) {
      final id = msg.messageId;
      if (id == null || id.isEmpty) return msg;
      final cached = byId[id];
      if (cached == null) return msg;
      if (_locallyStoppedMessageIds.contains(id)) {
        final results = msg.empBlocks
            .where((block) => block['local_artifact'] is Map)
            .toList();
        final resultIds = results
            .map((block) => (block['local_artifact'] as Map)['artifact_id'])
            .toSet();

        // 用户已明确停止后，历史接口可能仍短暂返回 stop 竞态中抢先落库的
        // final。保留停止瞬间的 partial/空内容与 stopped timeline，禁止完整
        // 答案通过 conversation 轮询“复活”。
        return cached.copyWith(
          empBlocks: [
            for (final block in cached.empBlocks)
              if (block['local_artifact'] is! Map ||
                  !resultIds.contains(
                      (block['local_artifact'] as Map)['artifact_id']))
                block,
            ...results,
          ],
          status: BubbleStatus.success,
          streamEndedAt:
              cached.streamEndedAt ?? msg.streamEndedAt ?? DateTime.now(),
          createdAt: cached.createdAt ?? msg.createdAt,
          agentMessageStatus: 'cancelled',
        );
      }
      // 左侧会话列表预览和这里的气泡状态本是同一次 _markRunDone 一起写的
      // (patch 预览时气泡已经是 success+有正文)；预览只活在 conversationsProvider
      // 里，不受这里的历史合并影响。如果这里不做保护，稍后一次历史刷新读到
      // 后端还没落库完成的滞后快照，会把已经成功的气泡打回 loading/清空正文，
      // 而左侧预览仍留着正确内容——两个数据源就此错开。保持一致：本地已经是
      // 成功终态且有正文时，REST 快照绝不能把它打回非终态。
      final cachedIsAheadTerminal = cached.status == BubbleStatus.success &&
          cached.content.trim().isNotEmpty &&
          msg.isLoading;
      return msg.copyWith(
        content: cachedIsAheadTerminal ? cached.content : msg.content,
        status: cachedIsAheadTerminal ? cached.status : msg.status,
        timelineEntries: msg.timelineEntries.isNotEmpty
            ? msg.timelineEntries
            : cached.timelineEntries,
        usageSummary: msg.usageSummary ?? cached.usageSummary,
        tokenUsage: msg.tokenUsage ?? cached.tokenUsage,
        reasoningContent: msg.reasoningContent.isNotEmpty
            ? msg.reasoningContent
            : cached.reasoningContent,
        streamStartedAt: msg.streamStartedAt ?? cached.streamStartedAt,
        streamEndedAt: cachedIsAheadTerminal
            ? (cached.streamEndedAt ?? msg.streamEndedAt)
            : (msg.streamEndedAt ?? cached.streamEndedAt),
        // Batch 1: empBlocks 同款保留 — history fetch 偶尔比 client live 早一拍
        // 返回空 blocks (server 还在 finalize), 这种情况下保留 client 已收的 blocks。
        // 但只在这条消息还没定稿(非 success/error)时才这样兜底：一旦 msg 已经是
        // 终态, 空 empBlocks 就是权威结果——不判定终态的话, 流式过程中途出现过的
        // 临时 empBlocks(比如模型一度像是要出表单/图表, 最终定稿其实是纯文本)会
        // 通过这个 fallback 永久残留在这条消息上, 表现为纯文本气泡却被当成"带
        // EMP 富内容"处理、按 EMP 专用的 ConstrainedBox(见
        // ChatAssistantMessageView.hasEmpBlocks)撑成近乎整行宽, 而不是按普通气泡
        // 走 IntrinsicWidth 贴合内容宽度。
        empBlocks: msg.empBlocks.isNotEmpty ||
                msg.status == BubbleStatus.success ||
                msg.status == BubbleStatus.error
            ? msg.empBlocks
            : cached.empBlocks,
      );
    }).toList(growable: true);

    // A failed send is a local attempt, not an arbitrary server failure. Keep
    // its question and answer together until there is an exact server identity.
    final failedAnswers = previous.where((m) =>
        m.isAnswer &&
        m.isError &&
        (m.messageId == null || m.messageId!.isEmpty) &&
        m.content.trim().isNotEmpty &&
        !_failedAttemptHasServerQuestion(m, previous, history));
    final serverIds =
        history.map((m) => m.messageId).whereType<String>().toSet();
    final byLocalId = {
      for (final message in previous) message.localId: message
    };
    for (final answer in failedAnswers) {
      final question = byLocalId[answer.metadata?['local_send_question_id']];
      final attempt = [if (question != null) question, answer]
          .where((message) =>
              !serverIds.contains(message.messageId) &&
              !merged.any((m) => m.localId == message.localId))
          .toList();
      if (attempt.isEmpty) continue;

      // A completed local failure must not move below newer server messages on
      // every refresh. Insert the pair together without reordering history.
      final startedAt =
          answer.streamStartedAt ?? question?.createdAt ?? answer.createdAt;
      final next = startedAt == null
          ? -1
          : merged.indexWhere((m) => m.createdAt?.isAfter(startedAt) == true);
      merged.insertAll(next < 0 ? merged.length : next, attempt);
    }
    return List<ChatMessage>.unmodifiable(merged);
  }

  bool _failedAttemptHasServerQuestion(
    ChatMessage answer,
    List<ChatMessage> previous,
    List<ChatMessage> history,
  ) {
    final questionLocalId = answer.metadata?['local_send_question_id'];
    if (questionLocalId is! String || questionLocalId.isEmpty) return false;
    final question = previous
        .where((m) => m.localId == questionLocalId && m.isQuestion)
        .firstOrNull;
    final serverQuestionId = question?.messageId;
    if (serverQuestionId == null || serverQuestionId.isEmpty) return false;
    return history.any((m) => m.isQuestion && m.messageId == serverQuestionId);
  }

  String _tailSnippet(String text, {int max = 160}) {
    if (text.length <= max) return text;
    return text.substring(text.length - max);
  }

  /// run 终态收口（done / stopped / awaiting_user / onDone 兜底）。
  /// 只收 [conversationKey] 会话：目标消息按 rt/session 索引定位（C4）；
  /// 左侧预览只 patch 该会话；**只有该会话当前正被显示才本地清未读**（C11）。
  void _markRunDone(
    String conversationKey,
    ChatStreamRuntime? rt, {
    bool stopped = false,
  }) {
    if (!ref.mounted) return;
    final key = _canon(conversationKey);
    final session = _ws.sessions[key];
    if (session == null) {
      if (kDebugMode) {
        debugPrint('[chat] fail-closed: markRunDone session $key gone');
      }
      return;
    }
    final idx = _targetAnswerIndex(session, rt);
    var messages = session.messages;
    ChatMessage? doneMsg;
    if (idx >= 0) {
      var m = session.messages[idx];
      m = m.copyWith(
        status: BubbleStatus.success,
        streamEndedAt: m.streamEndedAt ?? DateTime.now(),
        agentMessageStatus: stopped ? 'cancelled' : m.agentMessageStatus,
      );
      if (!stopped && m.isAnswer && m.content.isNotEmpty) {
        // 流式期间 markdown 里的图片 URL 可能赶上后端 ingest 落盘的赛跑窗口,
        // 前端拉到 4xx 后 CachedNetworkImage 把这次 error 按 URL 缓住,后续 widget
        // 重建仍命中旧缓存 → 永远破图,只有重启/刷新整个 app 才好。
        // 这里在 done 时给本条消息里所有 markdown 图片 URL 追加一个一次性 query
        // (#__r=<ts>),cacheKey 立刻变,CachedNetworkImage 必然重新发起请求拿到正确图。
        // 后端 endpoint(/files/{uuid}/preview)对 query 参数完全无感,302 行为不变。
        final bumped = _bumpMarkdownImageCacheKeys(m.content);
        if (bumped != m.content) {
          m = m.copyWith(content: bumped);
          if (kDebugMode) {
            debugPrint('[chat] markRunDone bumped image cache keys');
          }
        }
      }
      messages = [...session.messages];
      messages[idx] = m;
      doneMsg = m;
    } else if (kDebugMode) {
      // fail closed：placeholder 已不在（如会话被清）→ 只收口发送态，不碰其他消息。
      debugPrint('[chat] fail-closed: markRunDone target missing in $key');
    }
    _setSession(
      key,
      session.copyWith(
        messages: messages,
        isSending: false,
        clearActiveStream: true,
      ),
    );
    // 左侧会话列表本地预览: Agent 最终回答 → 置顶 (不加未读); 仅动列表, 不影响右侧 SSE 执行态。
    // 纯 EMP 卡片消息(如知识库"来源"卡)content 可能是空串——不能因此跳过预览更新，
    // 否则侧栏会停留在上一条消息的文案上，跟右侧实际展示的最新消息对不上。
    final donePreview = doneMsg == null ? '' : _previewTextForMessage(doneMsg);
    if (doneMsg != null && doneMsg.isAnswer && donePreview.isNotEmpty) {
      ref.read(conversationsProvider.notifier).applyAgentConversationPreview(
            key,
            lastMessage: _previewSnippet(donePreview),
          );
      final act = _ws.activeConversationId;
      if (act != null && _ws.canonicalKey(act) == key) {
        _markCurrentConversationRead(key);
      }
    }
    if (!stopped) {
      _scheduleAgentMetadataRefresh();
      _scheduleBillingWalletRefresh();
    }
  }

  static final RegExp _markdownImageRe =
      RegExp(r'(!\[[^\]]*\]\()([^)\s]+)(\))');

  String _bumpMarkdownImageCacheKeys(String content) {
    if (!content.contains('![')) return content;
    final ts = DateTime.now().millisecondsSinceEpoch;
    return content.replaceAllMapped(_markdownImageRe, (m) {
      final url = m.group(2)!;
      // 已经带过 cache-bust 标记的不重复加(避免每次 done 越加越长)。
      if (url.contains('__r=')) return m.group(0)!;
      final sep = url.contains('?') ? '&' : '?';
      return '${m.group(1)}$url${sep}__r=$ts${m.group(3)}';
    });
  }

  /// run 失败收口（send 阶段异常 / SSE error 事件）。只写目标会话；
  /// placeholder 按 [answerLocalId] 定位，找不到 fail closed——**不得**改写
  /// 上一条已完成消息（契约 V13，修复旧 `_finishWithError` 的越位改写）。
  void _failRun(String conversationKey, String answerLocalId, String message) {
    if (!ref.mounted) return;
    final key = _canon(conversationKey);
    // 用户已经在 send/attach 返回前主动停止时，迟到的 timeout/failed 只是该
    // 已取消请求的收尾，不得把“已停止”气泡改成发送失败。
    final wasCancelled = _cancelledPendingRuns.remove(answerLocalId);
    if (_startingRunByConversation[key] == answerLocalId) {
      _startingRunByConversation.remove(key);
    }
    if (wasCancelled) {
      _markRunDone(
        key,
        ChatStreamRuntime(
          streamId: '',
          conversationId: key,
          localPlaceholderId: answerLocalId,
        ),
        stopped: true,
      );
      return;
    }
    final session = _ws.sessions[key];
    if (session == null) {
      if (kDebugMode) {
        debugPrint('[chat] fail-closed: failRun session $key gone');
      }
      return;
    }
    var messages = session.messages;
    final idx =
        session.messages.lastIndexWhere((m) => m.localId == answerLocalId);
    if (idx >= 0) {
      final last = session.messages[idx];
      messages = [...session.messages];
      messages[idx] = last.copyWith(
        content: last.content.trim().isEmpty ? message : last.content,
        failureMessage: message,
        status: BubbleStatus.error,
        streamEndedAt: last.streamEndedAt ?? DateTime.now(),
      );
    } else if (kDebugMode) {
      debugPrint(
          '[chat] fail-closed: failRun placeholder $answerLocalId missing in $key');
    }
    _setSession(
      key,
      session.copyWith(
        messages: messages,
        isSending: false,
        errorMessage: message,
        clearActiveStream: true,
      ),
    );
    // 左侧会话列表本地预览: Agent 出错 → 错误摘要置顶 (不加未读); 仅动列表, 不影响右侧执行态。
    ref.read(conversationsProvider.notifier).applyAgentConversationPreview(
          key,
          lastMessage: _previewSnippet(
              idx >= 0 ? (messages[idx].deliveryNotice ?? message) : message),
        );
  }

  /// 左侧会话列表预览片段: 单行化 + 截断 (按 rune 切, 不切坏 emoji/CJK)。
  String _previewSnippet(String s) {
    final oneLine = s.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
    final runes = oneLine.runes.toList();
    if (runes.length <= 120) return oneLine;
    return String.fromCharCodes(runes.take(120));
  }

  /// 会话列表预览文案来源：优先用纯文本 [ChatMessage.content]；纯 EMP 卡片消息
  /// (来源引用/工具调用等，content 为空串) 退化成按 block type 给一个简短标签，
  /// 避免侧栏预览停留在上一条消息不刷新。
  String _previewTextForMessage(ChatMessage msg) {
    final content = msg.content.trim();
    if (content.isNotEmpty) return content;
    for (final block in msg.empBlocks) {
      final label = _previewLabelForBlock(block);
      if (label != null) return label;
    }
    return msg.empBlocks.isNotEmpty ? '[卡片消息]' : '';
  }

  String? _previewLabelForBlock(Map<String, dynamic> block) {
    final type = (block['type'] ?? '').toString();
    switch (type) {
      case 'source':
        return '[来源引用]';
      case 'tool_call':
      case 'tool_result':
        return '[工具调用]';
      case 'chart':
        return '[图表]';
      default:
        return null;
    }
  }

  void _scheduleAgentMetadataRefresh() {
    _agentMetadataRefreshTimer?.cancel();
    _agentMetadataRefreshTimer = Timer(
      _agentMetadataRefreshDelay,
      () => unawaited(_refreshCurrentAgentMetadata()),
    );
  }

  void _scheduleBillingWalletRefresh() {
    _billingWalletRefreshTimer?.cancel();
    _billingWalletRefreshTimer = Timer(_billingWalletRefreshDelay, () {
      _billingWalletRefreshTimer = null;
      if (!ref.mounted) return;
      notifyBillingSummaryChanged();
    });
  }

  Future<void> _refreshCurrentAgentMetadata() async {
    if (!ref.mounted) return;
    // 流结束后顺手刷一次 agent 列表 —— agent 这一轮可能落了新的自定义技能
    // 到 workspace（典型：`aigc-skill-creator` 写完 SKILL.md），输入框上方的
    // 「快速技能」标签和「自定义技能」分组都依赖 agentsProvider 里 agent.skills，
    // 不主动 invalidate 用户得手动切 agent 才能看到新加的技能。
    if (!ref.mounted) return;
    await ref.read(agentsProvider.notifier).refresh();
  }

  Future<void> pickFiles() async {
    final selected = await pickChatFiles();
    if (selected.isEmpty) return;
    await addFiles(selected);
  }

  Future<void> pickImages() async {
    final selected = await pickImageFiles();
    if (selected.isEmpty) return;
    await addFiles(selected);
  }

  Future<void> addFiles(List<XFile> selected) async {
    final current = state.asData?.value;
    final activeId = current?.activeConversationId;
    if (current == null || activeId == null || selected.isEmpty) return;
    // 契约 C7/C8：发起时捕获目标会话；上传完成的迟到回调只回写该会话。
    final sourceKey = current.canonicalKey(activeId);
    final session = current.sessions[sourceKey] ??
        ChatSessionState(conversationId: sourceKey);
    final converted = selected.take(5).map((file) {
      final ext = file.name.split('.').last.toLowerCase();
      final isImage = const {
        'jpg',
        'png',
        'jpeg',
        'gif',
        'bmp',
        'webp',
      }.contains(ext);
      final isVideo = const {
        'mp4',
        'mov',
        'm4v',
        'webm',
        'avi',
        'mkv',
      }.contains(ext);
      return ChatFileItem(
        fileName: file.name,
        filePath: file.path,
        fileType: isImage
            ? ChatFileType.image
            : (isVideo ? ChatFileType.video : ChatFileType.file),
        uploading: true,
      );
    }).toList();
    final nextPending = [
      ...session.pendingFiles,
      ...converted,
    ].take(5).toList();
    _setSession(sourceKey,
        session.copyWith(pendingFiles: nextPending, clearError: true));
    await _uploadPendingFiles(sourceKey);
  }

  /// 把云盘已有文件作为附件挂到当前输入框待发送项里(不重新上传)。
  ///
  /// 复用 ChatFileItem 通道:
  ///   - fileLink     = 后端签发的短 TTL preview URL(后端 ChatRunner 自己也能从
  ///                    driveFileUuid 反查,这里仅为了让前端附件气泡 / 复用渲染
  ///                    路径能直接出图;预览过期不影响发送)
  ///   - driveFileUuid = drive_files.uuid(SendMessage 用它写 cmf.drive_file_uuid)
  ///   - uuid         = 同 driveFileUuid(占老 fileId 兼容字段位)
  ///   - uploading    = false(已就绪,直接可发)
  ///
  /// 与本地上传(addFiles → _uploadPendingFiles)合用同一池子,所以一并参与
  /// 5 个附件的上限。previewUrl 单个失败不影响其余成功项。
  Future<void> addDriveFiles(List<DriveFile> files) async {
    final current = state.asData?.value;
    final activeId = current?.activeConversationId;
    if (current == null || activeId == null || files.isEmpty) return;
    final sourceKey = current.canonicalKey(activeId);
    final session = current.sessions[sourceKey] ??
        ChatSessionState(conversationId: sourceKey);
    final remaining = 5 - session.pendingFiles.length;
    if (remaining <= 0) return;
    final picked = files.take(remaining).toList();

    final driveSvc = ref.read(driveServiceProvider);
    final newItems = <ChatFileItem>[];
    for (final f in picked) {
      try {
        final preview = await driveSvc.previewUrl(fileUuid: f.uuid);
        newItems.add(
          ChatFileItem(
            fileName: f.name,
            fileType: _chatFileTypeFromMime(f.mimeType, f.name),
            fileLink: preview.url,
            uuid: f.uuid,
            driveFileUuid: f.uuid,
            uploading: false,
          ),
        );
      } catch (_) {
        // 单个预览签名失败就跳过,不阻塞其他文件入栈。
      }
    }
    if (newItems.isEmpty) return;
    // 迟到写回按 canonical key 解析（期间可能已 rekey，C8）。
    _updateSession(sourceKey, tag: 'addDriveFiles', (s) {
      return s.copyWith(
        pendingFiles: [...s.pendingFiles, ...newItems].take(5).toList(),
        clearError: true,
      );
    });
  }

  Future<void> _uploadPendingFiles(String sourceKey) async {
    final session = _ws.sessions[_canon(sourceKey)];
    if (session == null || session.pendingFiles.isEmpty) return;
    final service = ref.read(chatServiceProvider);
    final toUpload =
        session.pendingFiles.where((f) => f.uploading).toList(growable: false);
    for (final item in toUpload) {
      try {
        final uploaded = await service.uploadFile(item);
        _patchPendingFileById(sourceKey, item.localUploadId, (f) {
          return f.copyWith(
            fileLink: uploaded.url,
            uuid: uploaded.uuid,
            driveFileUuid: uploaded.driveFileUuid,
            uploading: false,
          );
        });
      } catch (_) {
        _patchPendingFileById(
            sourceKey, item.localUploadId, (f) => f.copyWith(uploading: false));
      }
    }
  }

  /// 契约 C7/C8/V6/V18：上传完成/失败的迟到回调按 localUploadId 单项回写
  /// **发起会话**（经 alias 解析 canonical key），即使用户已切走。
  /// 不整表快照覆盖；目标附件已被移除时 fail closed。
  void _patchPendingFileById(
    String conversationKey,
    String localUploadId,
    ChatFileItem Function(ChatFileItem file) update,
  ) {
    if (!ref.mounted) return;
    final key = _canon(conversationKey);
    final session = _ws.sessions[key];
    if (session == null) {
      if (kDebugMode) {
        debugPrint('[chat] fail-closed: upload callback, session $key gone');
      }
      return;
    }
    final idx = session.pendingFiles
        .indexWhere((f) => f.localUploadId == localUploadId);
    if (idx < 0) {
      if (kDebugMode) {
        debugPrint(
            '[chat] fail-closed: upload callback, file $localUploadId removed');
      }
      return;
    }
    final files = [...session.pendingFiles];
    files[idx] = update(files[idx]);
    _setSession(key, session.copyWith(pendingFiles: files));
  }

  void removePendingFile(ChatFileItem item) {
    final current = state.asData?.value;
    final activeId = current?.activeConversationId;
    if (current == null || activeId == null) return;
    _updateSession(activeId, tag: 'removePendingFile', (s) {
      return s.copyWith(
        pendingFiles: s.pendingFiles
            .where((f) => f.localUploadId != item.localUploadId)
            .toList(growable: false),
      );
    });
  }

  Future<void> feedback({
    required ChatMessage message,
    required FeedbackType feedback,
  }) async {
    if (!message.isAnswer || message.messageId == null) return;
    final ws = state.asData?.value;
    if (ws == null) return;
    // 按 messageId 定位消息所在会话（active 优先），不假设在当前会话。
    bool containsMsg(ChatSessionState s) =>
        s.messages.any((m) => m.messageId == message.messageId);
    String? key;
    final activeKey = ws.activeConversationId == null
        ? null
        : ws.canonicalKey(ws.activeConversationId!);
    if (activeKey != null &&
        ws.sessions[activeKey] != null &&
        containsMsg(ws.sessions[activeKey]!)) {
      key = activeKey;
    } else {
      for (final entry in ws.sessions.entries) {
        if (containsMsg(entry.value)) {
          key = entry.key;
          break;
        }
      }
    }
    if (key == null) return;
    _updateSession(key, tag: 'feedback', (s) {
      final updated = s.messages.map((m) {
        if (m.messageId == message.messageId) {
          return m.copyWith(feedback: feedback);
        }
        return m;
      }).toList();
      return s.copyWith(messages: updated);
    });
  }

  // ---------------- composer 草稿（契约 C7） ----------------

  /// widget 层在会话切换/失活时保存该会话的 composer 草稿快照。
  /// key 经 alias 解析（rekey 后旧 key 的迟到保存也落 canonical session）。
  void saveComposerDraft(String conversationId, ChatComposerDraft draft) {
    if (!ref.mounted || conversationId.isEmpty) return;
    final ws = _ws;
    final key = ws.canonicalKey(conversationId);
    final session = ws.sessions[key] ?? ChatSessionState(conversationId: key);
    _setWorkspace(
      ws.copyWith(
          sessions: {...ws.sessions, key: session.copyWith(draft: draft)}),
    );
  }

  /// widget 层恢复草稿用；无 session 或无草稿时返回 empty。
  ChatComposerDraft composerDraftFor(String conversationId) =>
      _ws.sessionOf(conversationId)?.draft ?? ChatComposerDraft.empty;
}

ChatFileType _chatFileTypeFromMime(String mime, String name) {
  final m = mime.toLowerCase();
  if (m.startsWith('image/')) return ChatFileType.image;
  if (m.startsWith('video/')) return ChatFileType.video;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  if (const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}.contains(ext)) {
    return ChatFileType.image;
  }
  if (const {'mp4', 'mov', 'm4v', 'webm', 'avi', 'mkv'}.contains(ext)) {
    return ChatFileType.video;
  }
  return ChatFileType.file;
}

AgentItem _agentFromConversation(ConversationItem conversation) {
  // 头像优先 convAvatar (会话级头像, upsert/refresh 写当前 AgentItem 头像处) → agentAvatarUrl;
  // 名字空时回退 title, 避免顶栏/空态出现空名。
  final avatar = pickAgentAvatarUrl(
          conversation.convAvatar, conversation.agentAvatarUrl) ??
      '';
  final name = conversation.agentName.trim().isNotEmpty
      ? conversation.agentName
      : conversation.title;
  return AgentItem(
    agentId: conversation.agentId,
    name: name,
    description: '',
    avatarUrl: avatar,
    positionLabel: conversation.agentPositionLabel,
    departmentName: conversation.agentDepartmentName,
    status: 'active',
    isDefault: false,
    syncStatus: 'synced',
    lastSyncedAt: null,
  );
}
