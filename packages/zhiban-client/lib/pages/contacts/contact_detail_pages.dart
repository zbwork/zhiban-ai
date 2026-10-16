import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/config/color_config.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/chat/services/agent_conversation_launcher.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/pages/contacts/contact_service.dart';
import 'package:zhiban_client/pages/contacts/contacts_constants.dart';
import 'package:zhiban_client/pages/contacts/contacts_panes.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/rtc/rtc_call_controller.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_client/services/rooms_api.dart';
import 'package:zhiban_core/utils/error_utils.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_page_bar.dart';

/// 成员名片页（人员详情）。
/// 路由：/contacts/person-detail，由 rootNavigatorKey push，无 Tab Bar。
/// 支持两种打开方式：已持有完整 [person]（通讯录列表点入）直接渲染；
/// 只有 [accountUuid]（如聊天里点头像）时页面内部自行拉取详情，调用方无需先请求。
class ContactsPersonDetailPage extends ConsumerStatefulWidget {
  const ContactsPersonDetailPage({super.key, required this.person})
      : accountUuid = null;

  const ContactsPersonDetailPage.byId({super.key, required this.accountUuid})
      : person = null;

  final ContactPerson? person;
  final String? accountUuid;

  @override
  ConsumerState<ContactsPersonDetailPage> createState() =>
      _ContactsPersonDetailPageState();
}

class _ContactsPersonDetailPageState
    extends ConsumerState<ContactsPersonDetailPage> {
  String? _openingHumanChatPeerId;
  late final Future<ContactPerson>? _fetch = widget.person == null
      ? const ContactsService().member(widget.accountUuid!)
      : null;

  Future<void> _openHumanChat(ContactPerson person,
      {bool startVoiceCall = false}) async {
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
        BotToast.showText(text: '打开对话失败:后端未返回 wukong channel');
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
        await ref
            .read(chatServiceProvider)
            .markConversationRead(room.conversationUuid);
      } catch (_) {}
      try {
        await ref
            .read(chatServiceProvider)
            .showConversation(room.conversationUuid);
      } catch (_) {}
      // ignore: discarded_futures
      ref.read(conversationsProvider.notifier).refresh();
      final rtc = startVoiceCall ? ref.read(rtcCallControllerProvider) : null;
      if (mounted) {
        GoRouter.of(context).go(RoutePaths.chat);
        if (PlatformUtils.isMobile) context.push(RoutePaths.chatConversation);
      }
      if (rtc != null) {
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
      if (PlatformUtils.isMobile) context.push(RoutePaths.chatConversation);
    }
  }

  Widget _buildBody(ContactPerson person) {
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 40),
      child: PersonDetailCard(
        person: person,
        onMessage: () {
          if (person.isAgent) {
            _openAgentChat(person);
          } else {
            _openHumanChat(person);
          }
        },
        onVoiceCall: person.isHuman && person.canChat
            ? () => _openHumanChat(person, startVoiceCall: true)
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final person = widget.person;
    if (person != null) {
      return Scaffold(
        appBar: UiPageBar(title: person.displayName),
        backgroundColor: ColorConfig.pageBackground,
        body: _buildBody(person),
      );
    }
    return Scaffold(
      appBar: const UiPageBar(title: '联系人详情'),
      backgroundColor: ColorConfig.pageBackground,
      body: FutureBuilder<ContactPerson>(
        future: _fetch,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CupertinoActivityIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return const EmptyState(text: '获取联系人信息失败');
          }
          return _buildBody(snapshot.data!);
        },
      ),
    );
  }
}

/// 支持两种打开方式：已持有完整 [agent]（数字员工列表点入）直接渲染；
/// 只有 [agentUuid]（如群聊里点数字员工头像）时页面内部自行拉取详情。
class ContactsAgentDetailPage extends ConsumerStatefulWidget {
  const ContactsAgentDetailPage({super.key, required this.agent})
      : agentUuid = null;

  const ContactsAgentDetailPage.byId({super.key, required this.agentUuid})
      : agent = null;

  final ContactAgent? agent;
  final String? agentUuid;

  @override
  ConsumerState<ContactsAgentDetailPage> createState() =>
      _ContactsAgentDetailPageState();
}

class _ContactsAgentDetailPageState
    extends ConsumerState<ContactsAgentDetailPage> {
  late final Future<ContactAgent>? _fetch = widget.agent == null
      ? const ContactsService().agent(widget.agentUuid!)
      : null;

  Future<void> _openChat(ContactAgent agent) async {
    await openAgentDirectConversation(ref, agent: agent.toAgentItem());
    if (mounted) {
      GoRouter.of(context).go(RoutePaths.chat);
      if (PlatformUtils.isMobile) context.push(RoutePaths.chatConversation);
    }
  }

  Widget _buildBody(ContactAgent agent) {
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 40),
      child: AgentDetailCard(
        agent: agent,
        onMessage: () => _openChat(agent)
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    if (agent != null) {
      return Scaffold(
        backgroundColor: ColorConfig.pageBackground,
        appBar: UiPageBar(title: agent.displayName),
        body: _buildBody(agent),
      );
    }
    return Scaffold(
      backgroundColor: ColorConfig.pageBackground,
      appBar: const UiPageBar(title: '数字员工详情'),
      body: FutureBuilder<ContactAgent>(
        future: _fetch,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CupertinoActivityIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return const EmptyState(text: '获取数字员工信息失败');
          }
          return _buildBody(snapshot.data!);
        },
      ),
    );
  }
}
