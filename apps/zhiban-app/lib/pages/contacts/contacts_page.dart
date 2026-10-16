import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/chat/services/agent_conversation_launcher.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_providers.dart';
import 'package:zhiban_client/pages/contacts/contacts_constants.dart';
import 'package:zhiban_client/pages/contacts/contacts_panes.dart';
import 'package:zhiban_client/pages/contacts/contacts_sidebar.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/rtc/rtc_call_controller.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_client/services/rooms_api.dart';
import 'package:zhiban_core/utils/error_utils.dart';

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  ContactsMode _mode = ContactsMode.agents;
  ContactPerson? _selectedPerson;
  ContactAgent? _selectedAgent;
  AgentListFilter _selectedAgentFilter = AgentListFilter.all;
  String? _openingHumanChatPeerId;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(contactsCacheRefreshProvider).refreshStale();
    });
  }

  void _selectAgentFilter(AgentListFilter filter) {
    setState(() {
      _mode = ContactsMode.agents;
      _selectedPerson = null;
      _selectedAgent = null;
      _selectedAgentFilter = filter;
    });
  }

  void _selectAgent(ContactAgent agent) {
    setState(() {
      _mode = ContactsMode.agents;
      _selectedPerson = null;
      _selectedAgent = agent;
    });
  }

  void _selectDepartment(ContactDepartment dept) {
    setState(() {
      _mode = ContactsMode.org;
      _selectedPerson = null;
      _selectedAgent = null;
      _selectedAgentFilter = AgentListFilter.all;
    });
    ref.read(selectedContactDepartmentProvider.notifier).state = dept;
  }

  void _selectPerson(ContactPerson person) {
    setState(() {
      _mode = ContactsMode.org;
      _selectedPerson = person;
      _selectedAgent = null;
    });
  }

  // P2.1(ADR-0026 点 11):点普通员工 → 调 /direct-rooms 建/取房(写 rooms+participants+
  // conversation+wukong link)→ 选中该会话 → 进主「对话」页(三栏),右侧 WuKong direct IM。
  // 不再进独立 direct_chat 页;按 channel 打开,后续列表点选也不重调 /direct-rooms。
  /// 打开与同事的 1:1 对话；[startVoiceCall] 为 true 时进入对话后立即发起语音通话
  /// （通讯录名片「语音通话」入口, 与聊天工具栏电话按钮同一条 RTC 链路）。
  Future<void> _openHumanChat(
    ContactPerson person, {
    bool startVoiceCall = false,
  }) async {
    if (!person.isHuman || person.id.isEmpty) return;
    if (!person.canChat) {
      BotToast.showText(text: startVoiceCall ? '不能呼叫自己' : '不能给自己发消息');
      return;
    }
    if (_openingHumanChatPeerId == person.id) return;
    _openingHumanChatPeerId = person.id;
    final messenger = BotToast.showLoading();
    try {
      final room = await RoomsService().createDirectRoom(
        peerAccountUuid: person.id,
        title: person.displayName,
      );
      final ch = room.wukongChannelId;
      if (ch == null || ch.isEmpty) {
        BotToast.showText(text: '打开对话失败:后端未返回 wukong channel(wukong 未启用?)');
        return;
      }
      final peerEmail = emailValue(person);
      ref.read(selectedGroupProvider.notifier).state = null;
      ref.read(selectedAgentProvider.notifier).clear();
      ref.read(selectedHumanDirectProvider.notifier).state =
          HumanDirectSelection(
        conversationId: room.conversationUuid,
        roomUuid: room.roomUuid,
        peerAccountUuid: person.id,
        channelId: ch,
        channelType: room.wukongChannelType ?? 2,
        title: person.displayName.isNotEmpty ? person.displayName : '同事对话',
        peerAvatar: person.avatarUrl,
        peerDepartmentName: person.departmentName,
        peerEmail: peerEmail == '未设置' ? '' : peerEmail,
        peerCompanyName:
            ref.read(accountInfoProvider).value?.tenantName.trim() ?? '',
        clearedAt: room.clearedAt,
      );
      ref
          .read(conversationsProvider.notifier)
          .clearUnreadLocally(room.conversationUuid);
      unawaited(
        ref
            .read(wukongImClientProvider)
            .markRead(ch, room.wukongChannelType ?? 2)
            .catchError((Object _) {}),
      );
      try {
        await ref.read(chatServiceProvider).markConversationRead(
              room.conversationUuid,
            );
      } catch (_) {
        // 进入会话优先;已读上报失败时下次权威 refresh 会把真实 unread 带回。
      }
      try {
        await ref.read(chatServiceProvider).showConversation(
              room.conversationUuid,
            );
      } catch (_) {
        // 恢复左侧可见失败不阻塞进入会话;refresh 会保留服务端真实 hidden 状态。
      }
      // 让新会话出现在左侧列表(fire-and-forget;失败不阻塞进入对话)。
      // ignore: discarded_futures
      ref.read(conversationsProvider.notifier).refresh();
      // RTC 控制器在路由切换前取出: 跳转后本页可能已 dispose, 不能再碰 ref。
      final rtc = startVoiceCall ? ref.read(rtcCallControllerProvider) : null;
      if (mounted) {
        GoRouter.of(context).go(RoutePaths.chat);
      }
      if (rtc != null) {
        // 全局协调器 + overlay 接管呼叫/通话态; 先落到聊天页再起呼, 与聊天内电话按钮一致。
        unawaited(rtc.startOutgoing(
          roomUuid: room.roomUuid,
          conversationUuid: room.conversationUuid,
          calleeAccountUuid: person.id,
          peerName: person.displayName,
        ));
      }
    } catch (e) {
      final detail = formatError(e, fallback: '打开对话失败');
      final text = detail.contains('directroom.cannot_chat_with_self') ||
              detail.contains('cannot chat with self')
          ? '不能给自己发消息'
          : detail == '打开对话失败'
              ? detail
              : '打开对话失败:$detail';
      BotToast.showText(text: text);
    } finally {
      messenger();
      if (_openingHumanChatPeerId == person.id) {
        _openingHumanChatPeerId = null;
      }
    }
  }

  // doc-13 §C: 点部门内「数字员工」→ 复用 A 的数字员工单聊入口（agent-bus /chat/*）。
  // 既有单聊会话则打开，否则进入 create-on-first-send 哨兵会话（首条消息建会话）。
  // 数字员工**不**走人-人 /direct-rooms（那是 human C2C）。共享流程见
  // openAgentDirectConversation(agent_conversation_launcher.dart)。
  Future<void> _openAgentChat(ContactPerson person) async {
    if (!person.isAgent || person.id.isEmpty) return;
    final agent = AgentItem(
      agentId: person.id,
      name: person.displayName,
      description: person.subtitle,
      avatarUrl: person.avatarUrl,
      positionLabel: person.positionLabel,
      skills: person.skills,
      apps: person.apps,
      status: '',
      isDefault: false,
      syncStatus: '',
      lastSyncedAt: null,
    );
    await openAgentDirectConversation(ref, agent: agent);
    if (mounted) {
      GoRouter.of(context).go(RoutePaths.chat);
    }
  }

  Future<void> _openContactAgentChat(ContactAgent agent) async {
    await openAgentDirectConversation(ref, agent: agent.toAgentItem());
    if (mounted) {
      GoRouter.of(context).go(RoutePaths.chat);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      body: Row(
        children: [
          ContactsSidebar(
            selectedPersonId: _selectedPerson?.id,
            selectedAgentId: _selectedAgent?.id,
            selectedAgentFilter: _selectedAgentFilter,
            onAgentFilterSelected: _selectAgentFilter,
            onAgentSelected: _selectAgent,
            onDepartmentSelected: _selectDepartment,
            onHumanSelected: _selectPerson,
          ),
          Expanded(
            child: _mode == ContactsMode.agents
                ? AgentsPane(
                    selectedAgent: _selectedAgent,
                    selectedFilter: _selectedAgentFilter,
                    onSelect: _selectAgent,
                    onMessage: _openContactAgentChat,
                  )
                : OrgMembersPane(
                    selectedPerson: _selectedPerson,
                    onHumanSelected: _selectPerson,
                    onMessage: _openHumanChat,
                    onAgentMessage: _openAgentChat,
                    onVoiceCall: (p) => _openHumanChat(p, startVoiceCall: true),
                    onDepartmentSelected: _selectDepartment,
                  ),
          ),
        ],
      ),
    );
  }
}
