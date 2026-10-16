import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart';
import 'package:zhiban_client/pages/chat/widgets/create_group_dialog.dart';
import 'package:zhiban_client/pages/chat/widgets/group_title_edit.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_client/services/rooms_api.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';

/// 建群 + 建成后把右侧内容区切到新群(不导航,由 provider 状态驱动)。
/// [preselectedUuids] 供单聊顶栏"加人"入口预选中当前对方。取消或后端未返回
/// WuKong 频道时返回 null。
Future<GroupRoom?> createGroupAndSwitchTo(
  BuildContext context,
  WidgetRef ref, {
  Set<String> preselectedUuids = const {},
}) async {
  final room = await showDialog<GroupRoom>(
    context: context,
    builder: (_) => CreateGroupDialog(preselectedUuids: preselectedUuids),
  );
  if (room == null || !context.mounted) return null;
  final ch = room.wukongChannelId;
  if (ch == null || ch.isEmpty) {
    BotToast.showText(text: '群聊已创建，但后端未返回 WuKong 频道');
    return null;
  }
  ref.read(selectedHumanDirectProvider.notifier).state = null;
  ref.read(selectedGroupProvider.notifier).state = GroupSelection(
    conversationId: room.conversationUuid,
    roomUuid: room.roomUuid,
    channelId: ch,
    channelType: room.wukongChannelType ?? 2,
    title: room.title,
    clearedAt: null,
    canRenameGroup: true,
    participants: room.participants
        .map((p) => ConversationParticipant(
              kind: p.kind,
              accountUuid: p.kind == 'human' ? p.id : '',
              agentUuid: p.kind == 'agent' ? p.id : '',
              displayName: p.displayName,
              avatar: '',
            ))
        .toList(),
  );
  unawaited(ref.read(conversationsProvider.notifier).refresh());
  return room;
}

String? resolveSidebarSelectedConversationId({
  required bool highlightActive,
  required GroupSelection? selectedGroup,
  required HumanDirectSelection? selectedHumanDirect,
  required String? activeConversationId,
}) {
  if (!highlightActive) return null;
  return selectedHumanDirect?.conversationId ??
      selectedGroup?.conversationId ??
      activeConversationId;
}

mixin ChatConversationActionsMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  String? openingHumanChatPeerId;

  ValueChanged<String>? get onConversationTapped;

  void onBeforeSelection() {}

  void selectConversation(ConversationItem conversation) {
    final ch = conversation.wukongChannelId;
    onBeforeSelection();

    if (conversation.isGroup && ch != null && ch.isNotEmpty) {
      ref.read(activePendingConversationProvider.notifier).state = null;
      ref.read(selectedHumanDirectProvider.notifier).state = null;
      ref.read(selectedGroupProvider.notifier).state = GroupSelection(
        conversationId: conversation.conversationId,
        roomUuid: conversation.roomUuid ?? '',
        channelId: ch,
        channelType: conversation.wukongChannelType ?? 2,
        title: conversation.title,
        participants: conversation.participants,
        clearedAt: conversation.clearedAt,
        canRenameGroup: conversation.canRenameGroup,
      );
      markConversationReadLocallyAndRemote(
        conversation.conversationId,
        channelId: ch,
        channelType: conversation.wukongChannelType ?? 2,
      );
      onConversationTapped?.call(conversation.conversationId);
      return;
    }

    if (conversation.isHumanDirect && ch != null && ch.isNotEmpty) {
      ref.read(activePendingConversationProvider.notifier).state = null;
      ref.read(selectedGroupProvider.notifier).state = null;
      String peerDept = '';
      String peerEmail = '';
      String peerCompanyName = '';
      String peerAccountUuid = '';
      for (final p in conversation.participants) {
        if (p.kind == 'human' && p.displayName == conversation.title) {
          peerDept = p.departmentName;
          peerEmail = p.email;
          peerCompanyName = p.companyName;
          peerAccountUuid = p.accountUuid;
          break;
        }
      }
      ref.read(selectedHumanDirectProvider.notifier).state =
          HumanDirectSelection(
        conversationId: conversation.conversationId,
        roomUuid: conversation.roomUuid ?? '',
        peerAccountUuid: peerAccountUuid,
        channelId: ch,
        channelType: conversation.wukongChannelType ?? 2,
        title: conversation.title,
        peerAvatar: conversation.convAvatar,
        peerDepartmentName: peerDept,
        peerEmail: peerEmail,
        peerCompanyName: peerCompanyName,
        clearedAt: conversation.clearedAt,
      );
      markConversationReadLocallyAndRemote(
        conversation.conversationId,
        channelId: ch,
        channelType: conversation.wukongChannelType ?? 2,
      );
      onConversationTapped?.call(conversation.conversationId);
      return;
    }
    ref.read(activePendingConversationProvider.notifier).state = null;
    ref.read(selectedHumanDirectProvider.notifier).state = null;
    ref.read(selectedGroupProvider.notifier).state = null;
    ref
        .read(chatProvider.notifier)
        .selectConversation(conversation.conversationId);
    onConversationTapped?.call(conversation.conversationId);
  }

  void markConversationReadLocallyAndRemote(
    String conversationId, {
    required String channelId,
    required int channelType,
  }) {
    if (conversationId.isEmpty) return;
    ref.read(conversationsProvider.notifier).clearUnreadLocally(conversationId);
    if (channelId.isNotEmpty) {
      unawaited(
        ref
            .read(wukongImClientProvider)
            .markRead(channelId, channelType)
            .catchError((Object _) {}),
      );
    }
    unawaited(
      ref
          .read(chatServiceProvider)
          .markConversationRead(conversationId)
          .catchError((Object _) {}),
    );
  }

  void markConversationRead(ConversationItem c) {
    markConversationReadLocallyAndRemote(
      c.conversationId,
      channelId: c.wukongChannelId ?? '',
      channelType: c.wukongChannelType ?? 2,
    );
  }

  void togglePin(ConversationItem c) {
    final next = !c.pinned;
    ref
        .read(conversationsProvider.notifier)
        .patchPerAccountState(c.conversationId, pinned: next);
    unawaited(
      ref
          .read(chatServiceProvider)
          .setConversationPinned(c.conversationId, next)
          .catchError((Object e) {
        BotToast.showText(text: next ? '置顶失败' : '取消置顶失败');
        unawaited(ref.read(conversationsProvider.notifier).refresh());
      }),
    );
  }

  void toggleMute(ConversationItem c) {
    final next = !c.muted;
    ref
        .read(conversationsProvider.notifier)
        .patchPerAccountState(c.conversationId, muted: next);
    unawaited(
      ref
          .read(chatServiceProvider)
          .setConversationMuted(c.conversationId, next)
          .catchError((Object e) {
        BotToast.showText(text: next ? '免打扰失败' : '取消免打扰失败');
        unawaited(ref.read(conversationsProvider.notifier).refresh());
      }),
    );
  }

  void markUnread(ConversationItem c) {
    ref
        .read(conversationsProvider.notifier)
        .patchPerAccountState(c.conversationId, markedUnread: true);
    unawaited(
      ref
          .read(chatServiceProvider)
          .markConversationUnread(c.conversationId)
          .catchError((Object e) {
        BotToast.showText(text: '标为未读失败');
        unawaited(ref.read(conversationsProvider.notifier).refresh());
      }),
    );
  }

  Future<void> hideConversation(ConversationItem c) async {
    final confirmed = await showUiConfirmDialog(
      context,
      title: '删除会话',
      description: '仅从你的会话列表中移除，不会删除双方或群内可见的历史消息。',
      confirmLabel: '删除',
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    unawaited(
      ref
          .read(chatProvider.notifier)
          .deleteConversation(c.conversationId)
          .catchError((Object e) {
        BotToast.showText(text: '删除会话失败');
        unawaited(ref.read(conversationsProvider.notifier).refresh());
      }),
    );
  }

  Future<void> renameGroup(ConversationItem c) async {
    final roomUuid = c.roomUuid;
    if (roomUuid == null || roomUuid.isEmpty) {
      BotToast.showText(text: '该会话没有可改名的群');
      return;
    }
    final newTitle = await showUiInputDialog(
      context,
      title: '修改群名',
      initialValue: c.title,
      hintText: '请输入新的群名',
      maxLength: 64,
      validator: (value) {
        return groupTitleValidationError(value);
      },
    );
    if (newTitle == null || !mounted) return;
    final trimmed = normalizeGroupTitleInput(newTitle);
    if (trimmed.isEmpty || trimmed == c.title) return;
    try {
      await ref.read(chatServiceProvider).renameGroupRoom(roomUuid, trimmed);
      ref
          .read(conversationsProvider.notifier)
          .patchConversationTitle(c.conversationId, trimmed);
      final selected = ref.read(selectedGroupProvider);
      if (selected?.conversationId == c.conversationId) {
        ref.read(selectedGroupProvider.notifier).state =
            selected!.copyWith(title: trimmed);
      }
      unawaited(ref.read(conversationsProvider.notifier).refresh());
      BotToast.showText(text: '群名已更新');
    } catch (e) {
      BotToast.showText(text: groupRenameFailureMessage(e));
    }
  }

  Future<void> createGroup() async {
    final room = await createGroupAndSwitchTo(context, ref);
    if (room != null) onConversationTapped?.call(room.conversationUuid);
  }

  Future<void> openHumanContact(ContactPerson person) async {
    if (!person.isHuman || person.id.isEmpty) return;
    if (!person.canChat) {
      BotToast.showText(text: '不能给自己发消息');
      return;
    }
    if (openingHumanChatPeerId == person.id) return;
    onBeforeSelection();
    setState(() => openingHumanChatPeerId = person.id);
    final dismiss = BotToast.showLoading();
    try {
      final room = await RoomsService().createDirectRoom(
        peerAccountUuid: person.id,
        title: person.displayName,
      );
      if (!mounted) return;
      final ch = room.wukongChannelId;
      if (ch == null || ch.isEmpty) {
        BotToast.showText(text: '对话已创建，但后端未返回频道');
        return;
      }
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
        peerEmail: contactEmail(person),
        peerCompanyName:
            ref.read(accountInfoProvider).value?.tenantName.trim() ?? '',
        clearedAt: room.clearedAt,
      );
      markConversationReadLocallyAndRemote(
        room.conversationUuid,
        channelId: ch,
        channelType: room.wukongChannelType ?? 2,
      );
      try {
        await ref.read(chatServiceProvider).showConversation(
              room.conversationUuid
            );
      } catch (_) {}
      unawaited(ref.read(conversationsProvider.notifier).refresh());
      onConversationTapped?.call(room.conversationUuid);
    } catch (_) {
      BotToast.showText(text: '打开对话失败');
    } finally {
      dismiss();
      if (mounted && openingHumanChatPeerId == person.id) {
        setState(() => openingHumanChatPeerId = null);
      }
    }
  }

  String contactEmail(ContactPerson person) {
    final subtitle = person.subtitle.trim();
    return subtitle.contains('@') ? subtitle : '';
  }
}
