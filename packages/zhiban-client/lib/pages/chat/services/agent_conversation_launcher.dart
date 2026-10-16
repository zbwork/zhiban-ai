import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';

const zhibanSupportAgentKey = 'zhiban-support';
const zhibanSupportAgentName = '知办客服';
const localAgentCallUnavailableMessage = '本地数字员工暂不支持语音和视频通话，请使用文字对话';

typedef ZhibanSupportCatalogLoader = Future<List<ContactAgent>> Function();

/// 单测可替换目录加载器；生产只查当前租户可见的数字员工通讯录。
final zhibanSupportCatalogLoaderProvider =
    Provider<ZhibanSupportCatalogLoader>((ref) {
  return () async {
    final snapshot =
        await const ContactsService().agents(keyword: zhibanSupportAgentName);
    return snapshot.all;
  };
});

/// [openAgentDirectConversation] 的返回值:调用方(如 RTC 通话)需要的
/// 会话/room/WuKong channel 锚点。room 相关字段仅 `prepareWuKong=true` 时非空。
class AgentConversationLaunchResult {
  const AgentConversationLaunchResult({
    required this.agent,
    required this.conversationId,
    this.roomUuid = '',
    this.wukongChannelId = '',
    this.wukongChannelType = 0,
  });

  final AgentItem agent;
  final String conversationId;
  final String roomUuid;
  final String wukongChannelId;
  final int wukongChannelType;
}

/// 打开(或复用)与某数字员工的 agent-direct 单聊会话,并把聊天页选中态切过去。
///
/// 通讯录(桌面 + 移动)与群聊成员资料卡共用此入口。数字员工**不**走 human
/// `/direct-rooms`(那是人↔人 C2C);无既有会话时进入 create-on-first-send
/// pending 哨兵会话(首条消息建会话)。
///
/// [prepareWuKong]=true 时先调 `POST /chat/agent-direct/prepare-wukong` 确保
/// agent-direct room/conversation/WuKong channel 已初始化(RTC 通话前置),再改
/// 选中态——prepare 失败直接向上抛且**不**动现有选中态,由调用方提示;成功则用
/// 返回的 room/channel 信息 patch 会话列表。
///
/// 导航(go/push 聊天页)留给调用方 —— 发消息需要跳转,通话则原地拉起 RTC。
Future<AgentConversationLaunchResult> openAgentDirectConversation(
  WidgetRef ref, {
  required AgentItem agent,
  bool prepareWuKong = false,
  String? expectedActiveConversationId,
}) async {
  if (prepareWuKong && agent.executionLocus == 'local') {
    throw StateError(localAgentCallUnavailableMessage);
  }
  var preparedConversationUuid = '';
  var roomUuid = '';
  var wukongChannelId = '';
  var wukongChannelType = 0;
  if (prepareWuKong) {
    final prepared = await ref
        .read(chatServiceProvider)
        .prepareAgentDirectWuKong(agent.agentId);
    preparedConversationUuid = prepared.conversationUuid.trim();
    roomUuid = prepared.roomUuid.trim();
    wukongChannelId = prepared.wukongChannelId.trim();
    wukongChannelType = prepared.wukongChannelType;
  }

  var convId = preparedConversationUuid.isNotEmpty
      ? preparedConversationUuid
      : pendingConversationFor(agent.agentId);
  if (preparedConversationUuid.isEmpty) {
    var convs = ref.read(conversationsProvider).asData?.value ??
        const <ConversationItem>[];
    bool reusable(ConversationItem c) =>
        isReusableAgentDirectConversation(c, agent.agentId) &&
        (agent.executionLocus != 'local' ||
            (c.kind == 'single' && (c.roomUuid ?? '').isEmpty));
    // The sidebar deduplicates by employee, so an old RTC room may have hidden
    // the original text conversation. Look up the unmerged list before falling
    // back to create-on-first-send. Never delete or move its history.
    if (agent.executionLocus == 'local' && !convs.any(reusable)) {
      final service = ref.read(chatServiceProvider);
      const pageSize = 200;
      for (var page = 1;; page++) {
        convs =
            await service.listAllConversations(page: page, pageSize: pageSize);
        if (!ref.context.mounted) throw StateError('会话已关闭');
        if (convs.any(reusable) || convs.length < pageSize) break;
      }
    }
    for (final c in convs) {
      // 只复用该 agent 的单聊会话:排除群聊 / 人↔人(群里含该 agent 不算单聊)。
      if (reusable(c)) {
        convId = c.conversationId;
        break;
      }
    }
  }

  if (!ref.context.mounted ||
      (expectedActiveConversationId != null &&
          (ref.read(chatProvider).asData?.value.activeConversationId !=
                  expectedActiveConversationId ||
              ref.read(selectedGroupProvider) != null ||
              ref.read(selectedHumanDirectProvider) != null))) {
    throw StateError('会话已切换');
  }
  ref.read(selectedHumanDirectProvider.notifier).state = null;
  ref.read(selectedGroupProvider.notifier).state = null;
  ref.read(selectedAgentProvider.notifier).select(agent);

  ref.read(conversationsProvider.notifier).upsertAgentConversation(
        agent: agent,
        conversationId: convId,
        roomUuid: roomUuid.isNotEmpty ? roomUuid : null,
        wukongChannelId: wukongChannelId.isNotEmpty ? wukongChannelId : null,
        wukongChannelType: wukongChannelType > 0 ? wukongChannelType : null,
        kind: roomUuid.isNotEmpty ? 'agent_direct' : null,
      );
  await ref.read(chatProvider.notifier).selectConversation(convId);
  if (!isPendingConversation(convId)) {
    ref.read(conversationsProvider.notifier).clearUnreadLocally(convId);
    try {
      await ref.read(chatServiceProvider).markConversationRead(convId);
    } catch (_) {
      // 数字员工入口不因已读上报失败阻塞跳转/通话。
    }
  }
  return AgentConversationLaunchResult(
    agent: agent,
    conversationId: convId,
    roomUuid: roomUuid,
    wukongChannelId: wukongChannelId,
    wukongChannelType: wukongChannelType,
  );
}

/// 找到当前租户的「知办客服」并复用标准数字员工单聊链路。
///
/// 已有会话优先，避免为了打开已经存在的客服会话再发目录请求；没有会话时从
/// `/contacts/agents` 查租户可见副本。名称是 F10 固定产品名，且优先排除用户
/// 自建的同名数字员工。
Future<AgentConversationLaunchResult> openZhibanSupportConversation(
  WidgetRef ref,
) async {
  var conversations = ref.read(conversationsProvider).asData?.value;
  if (conversations == null) {
    try {
      conversations = await ref.read(conversationsProvider.future);
    } catch (_) {
      // 会话列表不可用时仍可通过通讯录目录定位客服。
    }
  }

  final existing = findZhibanSupportAgentFromConversations(
    conversations ?? const <ConversationItem>[],
  );
  if (existing != null) {
    return openAgentDirectConversation(ref, agent: existing);
  }

  final contacts = await ref.read(zhibanSupportCatalogLoaderProvider)();
  final support = findZhibanSupportAgentFromContacts(contacts);
  if (support == null) {
    throw StateError('当前企业暂未配置知办客服');
  }
  return openAgentDirectConversation(ref, agent: support);
}

/// 按数字员工**显示名**打开(或复用)其单聊会话（F26 助手间衔接, 2026-07-24,
/// 消息 action 块 `open_employee:{名称}` 的容器层实现, 如「找财税助手」）。
///
/// 已有会话优先；没有会话时从 `/contacts/agents` 查租户可见副本。找不到
/// 同名员工抛 [StateError]（文案可直接 toast），调用方兜底提示不回灌会话。
Future<AgentConversationLaunchResult> openAgentConversationByName(
  WidgetRef ref,
  String employeeName,
) async {
  final name = employeeName.trim();
  if (name.isEmpty) throw StateError('未指定数字员工');
  var conversations = ref.read(conversationsProvider).asData?.value;
  if (conversations == null) {
    try {
      conversations = await ref.read(conversationsProvider.future);
    } catch (_) {
      // 会话列表不可用时仍可通过通讯录目录定位。
    }
  }

  final existing = findAgentByNameFromConversations(
    conversations ?? const <ConversationItem>[],
    name,
  );
  if (existing != null) {
    return openAgentDirectConversation(ref, agent: existing);
  }

  final snapshot = await const ContactsService().agents(keyword: name);
  final match = findAgentByNameFromContacts(snapshot.all, name);
  if (match == null) {
    throw StateError('当前企业暂未配置「$name」');
  }
  return openAgentDirectConversation(ref, agent: match);
}

@visibleForTesting
AgentItem? findZhibanSupportAgentFromConversations(
  Iterable<ConversationItem> conversations,
) {
  return findAgentByNameFromConversations(
    conversations,
    zhibanSupportAgentName,
  )?.copyWith(agentKey: zhibanSupportAgentKey);
}

@visibleForTesting
AgentItem? findZhibanSupportAgentFromContacts(
  Iterable<ContactAgent> contacts
) {
  return findAgentByNameFromContacts(contacts, zhibanSupportAgentName)
      ?.copyWith(agentKey: zhibanSupportAgentKey);
}

@visibleForTesting
AgentItem? findAgentByNameFromConversations(
  Iterable<ConversationItem> conversations,
  String name,
) {
  for (final conversation in conversations) {
    if (conversation.agentDeleted || conversation.agentId.trim().isEmpty) {
      continue;
    }
    if (!isReusableAgentDirectConversation(
      conversation,
      conversation.agentId,
    )) {
      continue;
    }
    final names = <String>{
      conversation.agentName.trim(),
      conversation.title.trim(),
    };
    if (!names.contains(name)) continue;
    return AgentItem(
      agentId: conversation.agentId,
      name: name,
      description: '',
      avatarUrl: conversation.agentAvatarUrl ?? conversation.convAvatar ?? '',
      positionLabel: conversation.agentPositionLabel,
      departmentName: conversation.agentDepartmentName,
      agentKey: '',
      status: 'published',
      isDefault: false,
      syncStatus: '',
      lastSyncedAt: null,
    );
  }
  return null;
}

@visibleForTesting
AgentItem? findAgentByNameFromContacts(
  Iterable<ContactAgent> contacts,
  String name,
) {
  for (final contact in contacts) {
    if (!contact.canChat ||
        contact.source == 'personal' ||
        contact.displayName.trim() != name) {
      continue;
    }
    return contact.toAgentItem();
  }
  return null;
}
