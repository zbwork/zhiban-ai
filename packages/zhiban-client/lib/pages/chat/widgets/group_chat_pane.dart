import 'messages/chat_messages_shimmer.dart';
import 'dart:async';
import 'package:zhiban_ui/widgets/ui_ai_generated_label.dart';
import 'chat_ai_generated.dart';

import 'package:bot_toast/bot_toast.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateController;
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_ui/widgets/ui_dialog.dart';
import 'package:zhiban_client/emp/blocks/emp_blocks_view.dart';
import 'package:zhiban_client/im/chat_media_api.dart';
import 'package:zhiban_client/im/human_direct_im_controller.dart';
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/im/human_chat_draft_guard.dart';
import 'package:zhiban_client/pages/case_fee_payment/case_fee_payment.dart';

import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/providers/chat_read_receipt_events.dart';
import 'package:zhiban_client/pages/chat/providers/chat_receipts_controller.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_read_receipt.dart';
import 'package:zhiban_client/pages/chat/providers/conversation_realtime_bridge.dart'
    show wukongImClientProvider;
import 'package:zhiban_client/pages/chat/services/agent_conversation_launcher.dart';
import 'package:zhiban_client/pages/chat/services/chat_service.dart';
import 'package:zhiban_client/pages/chat/services/open_employee_action.dart';
import 'package:zhiban_client/pages/chat/services/clipboard_image_paste.dart';
import 'package:zhiban_client/pages/chat/widgets/add_group_members_dialog.dart';
import 'package:zhiban_client/pages/chat/widgets/agent_mention.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_connection_notice.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_empty_state.dart';
import 'package:zhiban_client/pages/chat/providers/chat_media_download_controller.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_forward_executor.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_forward_picker.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_media_kind.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_media_preview.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_im_history.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_im_history_panel.dart';
import 'package:zhiban_core/chat/chat_reply_reference.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_action_menu.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_selection.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_reply_locate.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_scroll.dart';
import 'package:zhiban_client/pages/chat/widgets/group_title_edit.dart';
import 'package:zhiban_client/pages/chat/widgets/group_agent_final_content.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_message_time_divider.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_mixed_message_bubble.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_multi_select.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_reply_widgets.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_theme.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_upload_progress_indicator.dart';
import 'package:zhiban_client/pages/chat/widgets/contact_profile_card.dart';
import 'package:zhiban_client/pages/chat/widgets/messages/components/chat_avatar.dart';
import 'package:zhiban_client/widgets/ui/chat_platform_widgets.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/prompt_input.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/rich_prompt_controller.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_client/pages/chat/widgets/send_status_indicator.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_file_picker.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/rtc/rtc_call_controller.dart';
import 'package:zhiban_client/rtc/rtc_client.dart' show RtcMediaKind;
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_client/services/logout_flow.dart';
import 'package:zhiban_client/services/rooms_api.dart';
import 'package:zhiban_client/utils/file_picker_utils.dart';
import 'package:zhiban_client/widgets/human_direct_media.dart';

/// 群成员展示用 view-model(统一 _detail / participants 两个来源)。
class _MemberVM {
  const _MemberVM({
    required this.kind,
    required this.accountUuid,
    required this.name,
    required this.avatar,
    this.departmentName = '',
    this.email = '',
    this.companyName = '',
    this.canDirectChat = false,
    this.skillNames = const <String>[],
    required this.isOwner,
  });
  final String kind;
  final String accountUuid;
  final String name;
  final String avatar;
  final String departmentName;
  final String email;
  final String companyName;
  final bool canDirectChat;
  final List<String> skillNames;
  final bool isOwner;
}

/// P2.3a WuKong 群聊主区(ADR-0026)。
///
/// 复用人↔人的 [HumanDirectImController](按 channel 打开,**不走 /direct-rooms**),
/// 以 group channel(type=2)打开。顶栏不显示头像 icon(参照企业微信),右侧显示群成员面板
/// (含群主标记 + 添加群成员)。群消息发送者按 `from_uid` 反查成员取名/头像。
class GroupChatPane extends ConsumerStatefulWidget {
  const GroupChatPane({
    super.key,
    required this.roomUuid,
    required this.channelId,
    required this.channelType,
    required this.title,
    required this.conversationUuid,
    this.participants = const [],
    this.selfAvatarUrl,
    this.clearedAt,
    this.canRenameGroup = false,
    this.showHeader = true,
  });

  final String roomUuid;
  final String channelId;
  final int channelType; // 恒 2(group)
  final String title;
  final String conversationUuid;
  final List<ConversationParticipant> participants;
  final String? selfAvatarUrl;
  final String? clearedAt;
  final bool canRenameGroup;

  /// 桌面三栏内渲染显示顶栏 + 右侧成员面板;移动端全屏页传 false(UiPageBar 承担标题/添加)。
  final bool showHeader;

  @override
  ConsumerState<GroupChatPane> createState() => _GroupChatPaneState();
}

class _GroupChatPaneState extends ConsumerState<GroupChatPane> {
  static const double _mentionPopupMaxWidth = 400;
  static const double _mentionPopupMinWidth = 320;
  static const double _autoScrollBottomThreshold = 32;

  late final HumanDirectImController controller;
  StateController<HumanDirectImController?>? _activeImControllerNotifier;
  // F09 P1 已读回执 v1: per-pane cache + debounce; open 后 conversationUuid 就绪时 lazy 初始化.
  ChatReceiptsController? _receipts;
  bool _initialReceiptsReady = false;
  bool _receiptPreparationStarted = false;
  StreamSubscription<ImConnectionStatus>? _receiptConnectionSub;
  StreamSubscription<ChatReadReceiptChangedEvent>? _receiptEventSub;
  final RichPromptController _input = RichPromptController();
  final FocusNode _inputFocus = FocusNode();
  final ChatBottomScrollController _scroll = ChatBottomScrollController();
  bool _sending = false;
  bool _cacheClearGuard() =>
      _input.hasRichContent || _sending || controller.hasPendingUploads;

  // P2 历史定位:主 ListView 每条 message 按 identity 复用 GlobalKey;
  // 点击历史结果 → 关抽屉 + ensureVisible + 高亮 _highlightedKey(~1s 后清除)。
  final Map<String, GlobalKey> _messageKeys = {};
  String? _highlightedKey;
  Timer? _highlightTimer;

  GroupRoomDetail? _detail;

  // from_uid 反查:human 用 account_uuid,agent 用 agent_uuid。
  final Map<String, _MemberVM> _byAccount = {};
  final Map<String, _MemberVM> _byAgent = {};

  // @ 候选 (输入 @ 时按群内成员过滤;含 @所有人 + 员工 + 数字员工)。
  List<MentionCandidate> _mentionCandidates = const [];
  MentionCandidateTab _mentionTab = MentionCandidateTab.all;
  int _mentionSelectedIndex = 0;
  String _lastMentionQuery = '';

  // 用户经候选面板选中的 mention 实体(保留真实 type+id,发送时优先于名字兜底,解决同名歧义)。
  final List<PickedMention> _picked = <PickedMention>[];
  // 上一帧输入文本,用于在编辑时维护 picked occurrence 区间(前移/失效)。
  String _lastInputText = '';
  bool _expandingMentionDeletion = false;

  // F09 引用回复 v1: 当前待引用消息. null = 普通输入态.
  ChatReplyReference? _replyRef;

  // F09 多选 v1: 进入多选模式后渲染顶部批量条 + 气泡 checkbox.
  bool _selectionMode = false;
  final Set<String> _selectedKeys = <String>{};
  final Set<String> _submittedHitlMessages = <String>{};
  // F09 多选 v1 (2026-06 P2 防重入): 批量转发执行中 → 转发/删除/取消按钮全 disabled,
  // 重复点击 「转发」直接 return; 避免同一批消息被发两遍。
  bool _batchForwarding = false;

  @override
  void initState() {
    super.initState();
    HumanChatDraftGuard.register(_cacheClearGuard);
    _rebuildLookup();
    controller = HumanDirectImController(
      client: ref.read(wukongImClientProvider),
      presetChannelId: widget.channelId,
      presetChannelType: widget.channelType,
      presetConversationUuid: widget.conversationUuid,
      presetClearedAt: widget.clearedAt,
    );
    _activeImControllerNotifier = ref.read(activeImControllerProvider.notifier);
    final notifier = _activeImControllerNotifier;
    final createdController = controller;
    Future(() {
      if (mounted) notifier?.state = createdController;
    });
    controller.addListener(_onChange);
    _scroll.addListener(_onScroll);
    _inputFocus.onKeyEvent = _handleMentionKey;
    _input.addListener(_onInputChanged);
    // ignore: discarded_futures
    controller.open(title: widget.title);
    // ignore: discarded_futures
    _loadDetail();
  }

  /// 群内可 @ 实体:@所有人(置顶)+ 员工 + 数字员工(飞书式排序)。
  List<MentionCandidate> get _mentionables {
    final out = <MentionCandidate>[kMentionAll];
    for (final m in _members) {
      if (m.name.trim().isEmpty || m.accountUuid.isEmpty) continue;
      out.add(MentionCandidate(
        type: m.kind == 'agent' ? MentionType.agent : MentionType.human,
        id: m.accountUuid, // human=account_uuid, agent=agent_uuid
        displayName: m.name,
        avatar: m.avatar,
      ));
    }
    return sortMentionCandidates(out);
  }

  /// 高亮渲染用的可 @ 名字集合(成员名 + 所有人)。
  Set<String> get _mentionNames {
    final s = <String>{'所有人'};
    for (final m in _members) {
      if (m.name.trim().isNotEmpty) s.add(m.name);
    }
    return s;
  }

  Map<String, String> get _activeHumanNamesById => {
        for (final m in _members)
          if (m.kind == 'human' &&
              m.accountUuid.isNotEmpty &&
              m.name.trim().isNotEmpty)
            m.accountUuid: m.name.trim(),
      };

  List<MentionCandidate> get _visibleMentionCandidates =>
      visibleMentionCandidates(_mentionCandidates, _mentionTab);

  void _setMentionTab(MentionCandidateTab tab) {
    setState(() {
      _mentionTab = tab;
      _mentionSelectedIndex = 0;
    });
  }

  void _cycleMentionTab({required bool reverse}) {
    _setMentionTab(nextMentionCandidateTab(_mentionTab, reverse: reverse));
  }

  /// 输入变化:维护 picked occurrence 区间(编辑在 token 前→平移、相交→失效),再弹/收候选。
  void _onInputChanged() {
    final newText = _input.text;
    if (!_expandingMentionDeletion && _picked.isNotEmpty) {
      final expansion =
          expandPartialMentionDeletion(_picked, _lastInputText, newText);
      if (expansion != null) {
        _expandingMentionDeletion = true;
        _input.value = TextEditingValue(
          text: expansion.text,
          selection: TextSelection.collapsed(offset: expansion.caret),
        );
        _expandingMentionDeletion = false;
        return;
      }
    }
    if (_picked.isNotEmpty && newText != _lastInputText) {
      final reconciled =
          reconcilePickedMentions(_picked, _lastInputText, newText);
      _picked
        ..clear()
        ..addAll(reconciled);
    }
    _lastInputText = newText;

    final all = _mentionables;
    final sel = _input.selection;
    final caret = sel.isValid ? sel.baseOffset : newText.length;
    final q = detectMention(newText, caret);
    final query = q?.query ?? '';
    final next = (q == null)
        ? const <MentionCandidate>[]
        : filterCandidates(all, q.query);
    if (!mounted) return;
    setState(() {
      _mentionCandidates = next;
      if (next.isEmpty) {
        _mentionSelectedIndex = 0;
        _mentionTab = MentionCandidateTab.all;
      } else if (query != _lastMentionQuery) {
        _mentionSelectedIndex = 0;
        _mentionTab = MentionCandidateTab.all;
      } else if (_mentionSelectedIndex >= next.length) {
        _mentionSelectedIndex = next.length - 1;
      }
      _lastMentionQuery = query;
    });
  }

  KeyEventResult _handleMentionKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _mentionCandidates.isEmpty) {
      return KeyEventResult.ignored;
    }
    final visible = _visibleMentionCandidates;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      _cycleMentionTab(reverse: HardwareKeyboard.instance.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (visible.isEmpty) {
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _mentionSelectedIndex = (_mentionSelectedIndex + 1) % visible.length;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _mentionSelectedIndex =
            (_mentionSelectedIndex - 1 + visible.length) % visible.length;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _onPickMention(visible[_mentionSelectedIndex]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _mentionCandidates = const [];
        _mentionTab = MentionCandidateTab.all;
        _mentionSelectedIndex = 0;
        _lastMentionQuery = '';
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onPickMention(MentionCandidate c) {
    final sel = _input.selection;
    final caret = sel.isValid ? sel.baseOffset : _input.text.length;
    final q = detectMention(_input.text, caret);
    if (q == null) return;
    final token = '@${c.displayName}';
    final r = applyMention(_input.text, caret, q, c.displayName);
    // 赋值会同步触发 _onInputChanged:reconcile 既有 picked(随插入平移)+ 同步 _lastInputText。
    _input.value = TextEditingValue(
      text: r.text,
      selection: TextSelection.collapsed(offset: r.caret),
    );
    // 再追加本次选中的 picked —— 其 occurrence 区间在新文本里 = [q.start, q.start+token.length]。
    // 记录真实实体身份(发送时优先于名字兜底,解决同名歧义;区间相交编辑后会失效不复活)。
    _picked.add(PickedMention(
      candidate: c,
      token: token,
      start: q.start,
      end: q.start + token.length,
    ));
    setState(() {
      _mentionCandidates = const [];
      _mentionTab = MentionCandidateTab.all;
      _mentionSelectedIndex = 0;
      _lastMentionQuery = '';
    });
    _inputFocus.requestFocus();
  }

  /// 从 _detail(优先)或 widget.participants 重建 from_uid 反查表。
  void _rebuildLookup() {
    _byAccount.clear();
    _byAgent.clear();
    for (final m in _members) {
      if (m.kind == 'human' && m.accountUuid.isNotEmpty) {
        _byAccount[m.accountUuid] = m;
      } else if (m.kind == 'agent' && m.accountUuid.isNotEmpty) {
        _byAgent[m.accountUuid] = m;
      }
    }
  }

  /// 群成员 view-model:有权威 detail 用 detail(含群主 + 头像),否则用初始 participants。
  List<_MemberVM> get _members {
    final d = _detail;
    if (d != null) {
      return d.members.map((m) {
        final p = _participantByMemberId(m.kind, m.id);
        return _MemberVM(
          kind: m.kind,
          accountUuid: m.id,
          name: m.displayName.trim().isNotEmpty
              ? m.displayName
              : (p?.displayName ?? ''),
          avatar: m.avatar.trim().isNotEmpty ? m.avatar : (p?.avatar ?? ''),
          departmentName: m.departmentName.isNotEmpty
              ? m.departmentName
              : (p?.departmentName ?? ''),
          email: m.email.isNotEmpty ? m.email : (p?.email ?? ''),
          companyName:
              m.companyName.isNotEmpty ? m.companyName : (p?.companyName ?? ''),
          canDirectChat: m.canDirectChat,
          skillNames: m.skills
              .map((skill) => skill.name.trim())
              .where((name) => name.isNotEmpty)
              .toList(growable: false),
          isOwner: d.isOwner(m),
        );
      }).toList();
    }
    return widget.participants
        .map((p) => _MemberVM(
              kind: p.kind,
              accountUuid: p.kind == 'human' ? p.accountUuid : p.agentUuid,
              name: p.displayName,
              avatar: p.avatar,
              departmentName: p.departmentName,
              email: p.email,
              companyName: p.companyName,
              canDirectChat: false,
              isOwner: false,
            ))
        .toList();
  }

  ConversationParticipant? _participantByMemberId(String kind, String id) {
    for (final p in widget.participants) {
      final pid = p.kind == 'human' ? p.accountUuid : p.agentUuid;
      if (p.kind == kind && pid == id) return p;
    }
    return null;
  }

  String get _selfAccountUuid {
    final fromUid = _accountUuidFromWukongUid(controller.myUid ?? '');
    if (fromUid.isNotEmpty) return fromUid;
    return ref.read(accountInfoProvider).asData?.value?.accountNo.trim() ?? '';
  }

  String _accountUuidFromWukongUid(String uid) {
    const marker = '_u_';
    final idx = uid.indexOf(marker);
    if (idx < 0) return '';
    return uid.substring(idx + marker.length).trim();
  }

  ChatContactProfile _profileForMember(_MemberVM m) {
    final self = _selfAccountUuid;
    return ChatContactProfile(
      kind: m.kind,
      accountUuid: m.accountUuid,
      displayName: m.name.isNotEmpty ? m.name : '未命名',
      avatarUrl: m.avatar,
      departmentName: m.departmentName,
      email: m.email,
      companyName: m.companyName,
      capabilityNames: m.skillNames,
      isSelf: self.isNotEmpty && self == m.accountUuid,
    );
  }

  bool _canActOnHuman(_MemberVM m) {
    return m.kind == 'human' &&
        m.accountUuid.isNotEmpty &&
        !_profileForMember(m).isSelf;
  }

  // 数字员工成员:accountUuid 字段承载 agent_uuid(见 _MemberVM 构造),非空即可操作。
  bool _canActOnAgent(_MemberVM m) =>
      m.kind == 'agent' && m.accountUuid.isNotEmpty && m.canDirectChat;

  void _showMemberProfile(_MemberVM m, Offset anchor) {
    final profile = _profileForMember(m);
    if (PlatformUtils.isMobile) {
      _openMemberContactDetail(m, profile);
      return;
    }
    // 数字员工:发消息/语音/视频都走 agent-direct 链路(openAgentDirectConversation),
    // **不**走 human /direct-rooms;通话前先 prepare room/conversation/WuKong channel。
    if (m.kind == 'agent') {
      final canAct = _canActOnAgent(m);
      showChatContactProfileCard(
        context,
        anchor: anchor,
        profile: profile,
        onMessage: canAct ? () => _openAgentChatForMember(m) : null,
        onVoiceCall: canAct
            ? () => _startAgentCallForMember(m, RtcMediaKind.audio)
            : null,
        onVideoCall: canAct
            ? () => _startAgentCallForMember(m, RtcMediaKind.video)
            : null,
      );
      return;
    }
    final canAct = _canActOnHuman(m);
    showChatContactProfileCard(
      context,
      anchor: anchor,
      profile: profile,
      onMessage: canAct ? () => _openDirectChatForMember(m) : null,
      onVoiceCall: canAct
          ? () => _startDirectCallForMember(m, RtcMediaKind.audio)
          : null,
      onVideoCall: canAct
          ? () => _startDirectCallForMember(m, RtcMediaKind.video)
          : null,
    );
  }

  void _openMemberContactDetail(_MemberVM m, ChatContactProfile profile) {
    if (profile.isSelf) {
      context.push(RoutePaths.profileDetails);
      return;
    }
    if (profile.accountUuid.isEmpty) return;
    context.push(
      m.kind == 'agent'
          ? RoutePaths.contactsAgentDetail
          : RoutePaths.contactsPersonDetail,
      extra: m.accountUuid,
    );
  }

  Future<DirectRoom?> _ensureDirectRoomForMember(_MemberVM m) async {
    if (!_canActOnHuman(m)) {
      // 数字员工不走人-人 /direct-rooms(见 _openAgentChatForMember / _startAgentCallForMember)。
      BotToast.showText(
          text: m.kind == 'human' ? '不能给自己发消息' : '暂不支持给数字员工发起人对人操作');
      return null;
    }
    return RoomsService().createDirectRoom(
      peerAccountUuid: m.accountUuid,
      title: m.name,
    );
  }

  AgentItem _agentItemForMember(_MemberVM m) {
    return AgentItem(
      agentId: m.accountUuid, // agent 成员的 accountUuid 字段承载 agent_uuid
      name: m.name,
      description: '',
      avatarUrl: m.avatar,
      status: '',
      isDefault: false,
      syncStatus: '',
      lastSyncedAt: null,
    );
  }

  /// 群成员资料卡「发消息」(数字员工):打开/创建 agent-direct 单聊并跳转聊天页。
  Future<void> _openAgentChatForMember(_MemberVM m) async {
    final closeLoading = BotToast.showLoading();
    try {
      await openAgentDirectConversation(ref, agent: _agentItemForMember(m));
      if (!mounted) return;
      GoRouter.of(context).go(RoutePaths.chat);
      if (PlatformUtils.isMobile) context.push(RoutePaths.chatConversation);
    } catch (_) {
      BotToast.showText(text: '打开数字员工对话失败，请稍后重试');
    } finally {
      closeLoading();
    }
  }

  /// 群成员资料卡「语音/视频」(数字员工):先确保 agent-direct room/conversation/
  /// WuKong channel 已初始化(prepare-wukong),再发起 RTC;prepare 失败不拉起通话。
  Future<void> _startAgentCallForMember(_MemberVM m, RtcMediaKind kind) async {
    final closeLoading = BotToast.showLoading();
    try {
      final result = await openAgentDirectConversation(
        ref,
        agent: _agentItemForMember(m),
        prepareWuKong: true,
      );
      if (result.roomUuid.isEmpty ||
          result.conversationId.isEmpty ||
          isPendingConversation(result.conversationId)) {
        BotToast.showText(text: '通话准备失败，请稍后重试');
        return;
      }
      if (!mounted) return;
      await ref.read(rtcCallControllerProvider).startOutgoing(
            roomUuid: result.roomUuid,
            agentUuid: m.accountUuid,
            conversationUuid: result.conversationId,
            peerName: m.name.isNotEmpty ? m.name : '数字员工',
            peerAvatarUrl: m.avatar,
            mediaKind: kind,
          );
    } catch (_) {
      BotToast.showText(text: '通话准备失败，请稍后重试');
    } finally {
      closeLoading();
    }
  }

  Future<void> _openDirectChatForMember(_MemberVM m) async {
    final closeLoading = BotToast.showLoading();
    try {
      final room = await _ensureDirectRoomForMember(m);
      if (room == null) return;
      final ch = room.wukongChannelId;
      if (ch == null || ch.isEmpty) {
        BotToast.showText(text: '打开对话失败:后端未返回 wukong channel');
        return;
      }
      if (!mounted) return;
      ref.read(selectedGroupProvider.notifier).state = null;
      ref.read(selectedAgentProvider.notifier).clear();
      ref.read(selectedHumanDirectProvider.notifier).state =
          HumanDirectSelection(
        conversationId: room.conversationUuid,
        roomUuid: room.roomUuid,
        peerAccountUuid: m.accountUuid,
        channelId: ch,
        channelType: room.wukongChannelType ?? 2,
        title: m.name.isNotEmpty ? m.name : '同事对话',
        peerAvatar: m.avatar,
        peerDepartmentName: m.departmentName,
        peerEmail: m.email,
        peerCompanyName: m.companyName,
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
      unawaited(ref
          .read(chatServiceProvider)
          .showConversation(room.conversationUuid)
          .catchError((Object _) {}));
      unawaited(ref.read(conversationsProvider.notifier).refresh());
      if (mounted) GoRouter.of(context).go(RoutePaths.chat);
    } catch (e) {
      final detail = e.toString();
      final selfError = detail.contains('directroom.cannot_chat_with_self') ||
          detail.contains('cannot chat with self');
      BotToast.showText(text: selfError ? '不能给自己发消息' : '打开对话失败:$e');
    } finally {
      closeLoading();
    }
  }

  Future<void> _startDirectCallForMember(_MemberVM m, RtcMediaKind kind) async {
    final closeLoading = BotToast.showLoading();
    try {
      final room = await _ensureDirectRoomForMember(m);
      if (room == null) return;
      unawaited(ref.read(rtcCallControllerProvider).startOutgoing(
            roomUuid: room.roomUuid,
            calleeAccountUuid: m.accountUuid,
            peerName: m.name,
            mediaKind: kind,
          ));
    } catch (e) {
      final action = kind == RtcMediaKind.video ? '视频' : '语音';
      BotToast.showText(text: '发起$action通话失败:$e');
    } finally {
      closeLoading();
    }
  }

  void _startGroupCall(RtcMediaKind kind) {
    if (widget.roomUuid.isEmpty) {
      BotToast.showText(text: '缺少群聊 room 信息，无法发起通话');
      return;
    }
    final action = kind == RtcMediaKind.video ? '视频' : '语音';
    unawaited(ref
        .read(rtcCallControllerProvider)
        .startOutgoing(
          roomUuid: widget.roomUuid,
          peerName: widget.title.isNotEmpty ? widget.title : '群通话',
          mediaKind: kind,
        )
        .catchError((Object e) {
      BotToast.showText(text: '发起群$action通话失败:$e');
    }));
  }

  void _onGroupVoiceCallPressed() => _startGroupCall(RtcMediaKind.audio);

  void _onGroupVideoCallPressed() => _startGroupCall(RtcMediaKind.video);

  EmpBlocksRespondHandler get _groupEmpRespondHandler =>
      EmpBlocksRespondHandler(
        onApproval: ({
          required String agentMessageUuid,
          required String decision,
          String? reason,
        }) =>
            _respondToGroupAgentMessage(
          agentMessageUuid: agentMessageUuid,
          responseKind: 'approval',
          responsePayload: {
            'decision': decision,
            if (reason != null && reason.isNotEmpty) 'reason': reason,
          },
        ),
        onA2AApproval: ({
          required String approvalRequestId,
          required String decision,
          String? reason,
        }) =>
            ref.read(chatProvider.notifier).decideA2AApproval(
                  approvalRequestId: approvalRequestId,
                  approved: decision == 'approve',
                  reason: reason,
                ),
        onConfirm: ({
          required String agentMessageUuid,
          required bool confirmed
        }) =>
            _respondToGroupAgentMessage(
          agentMessageUuid: agentMessageUuid,
          responseKind: 'confirm',
          responsePayload: {'confirmed': confirmed},
        ),
        onForm: ({
          required String agentMessageUuid,
          required Map<String, dynamic> fields,
        }) =>
            _respondToGroupAgentMessage(
          agentMessageUuid: agentMessageUuid,
          responseKind: 'form',
          responsePayload: {'fields': fields},
        ),
        onA2AForm: ({
          required String approvalRequestId,
          required Map<String, dynamic> fields,
        }) =>
            ref.read(chatProvider.notifier).decideA2AApproval(
                  approvalRequestId: approvalRequestId,
                  approved: true,
                  formResult: fields,
                ),
        onFile: ({
          required String fieldName,
          required String fieldLabel
        }) async {
          final picked = await pickAnyFile();
          if (picked == null) return null;
          final path = picked.path.trim();
          if (path.isEmpty) {
            throw StateError('文件路径为空');
          }
          final size = await picked.length();
          final item = ChatFileItem(
            fileName: picked.name,
            fileType: ChatFileType.file,
            filePath: path,
            sizeBytes: size,
          );
          final uploaded = await ref.read(chatServiceProvider).uploadFile(item);
          final fileUuid =
              (uploaded.driveFileUuid ?? uploaded.uuid ?? '').trim();
          if (fileUuid.isEmpty) {
            throw StateError('文件上传成功但未返回 file_id');
          }
          return <String, dynamic>{
            // 契约 §3.0a 规范键是 file_uuid; file_id 为历史键, 双写过渡
            // (消费端已全部双收, 2026-07-21)。
            'file_uuid': fileUuid,
            'file_id': fileUuid,
            'name': picked.name,
            'size': size,
            if ((picked.mimeType ?? '').trim().isNotEmpty)
              'mime_type': picked.mimeType!.trim(),
            if (uploaded.url.trim().isNotEmpty) 'url': uploaded.url,
            if (fieldName.trim().isNotEmpty) 'field_name': fieldName.trim(),
            if (fieldLabel.trim().isNotEmpty) 'field_label': fieldLabel.trim(),
          };
        },
        onAction: ({
          required String agentMessageUuid,
          required String actionId,
          Map<String, dynamic>? params,
        }) =>
            _respondToGroupAgentMessage(
          agentMessageUuid: agentMessageUuid,
          responseKind: 'action',
          responsePayload: {
            'action_id': actionId,
            if (params != null) 'params': params,
          },
        ),
        // 工单服务费「去支付」（F24 收款线上化，代账/注册）：本地打开支付页/弹窗。
        onOpenPayment: (actionId) => openCaseFeePayment(context, actionId),
        // 「找财税助手」等助手间衔接按钮（F26）：本地切到该数字员工聊天框。
        onOpenEmployee: (actionId) =>
            openEmployeeConversationFromAction(context, ref, actionId),
      );

  Future<bool> _respondToGroupAgentMessage({
    required String agentMessageUuid,
    required String responseKind,
    required Map<String, dynamic> responsePayload,
  }) async {
    if (widget.conversationUuid.isEmpty || agentMessageUuid.isEmpty) {
      BotToast.showText(text: '会话状态异常, 暂不能提交');
      return false;
    }
    if (_submittedHitlMessages.contains(agentMessageUuid)) {
      return false;
    }
    try {
      final resp = await ref.read(chatServiceProvider).respondToAgentMessage(
            conversationUuid: widget.conversationUuid,
            agentMessageUuid: agentMessageUuid,
            responseKind: responseKind,
            responsePayload: responsePayload,
          );
      if (resp.streamId.isEmpty || resp.newAgentMessageUuid.isEmpty) {
        BotToast.showText(text: '提交失败, 请稍后重试');
        return false;
      }
      if (mounted) {
        setState(() => _submittedHitlMessages.add(agentMessageUuid));
      }
      BotToast.showText(text: '已提交');
      return true;
    } catch (_) {
      BotToast.showText(text: '提交失败, 请稍后重试');
      return false;
    }
  }

  Future<void> _loadDetail() async {
    if (widget.roomUuid.isEmpty) return;
    try {
      final d = await RoomsService().getGroupRoom(widget.roomUuid);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _rebuildLookup();
      });
    } catch (_) {
      // 拿不到详情不阻塞聊天:回退用初始 participants 展示成员。
    }
  }

  Future<void> _onAddMembers() async {
    // 已在群内成员 id:human=account_uuid, 数字员工=agent_uuid(_MemberVM.accountUuid 已按 kind 取)。
    final existing = {
      for (final m in _members)
        if (m.accountUuid.isNotEmpty) m.accountUuid,
    };
    final added = await addGroupMembersFlow(
      context,
      ref,
      roomUuid: widget.roomUuid,
      existingMemberIds: existing,
    );
    if (added) await _loadDetail();
  }

  // 加载更早历史期间抑制自动跳底，固定消息中心保持原阅读位置。
  bool _loadingOlder = false;
  bool _initialScrollPending = true;

  void _onChange() {
    if (!mounted) return;
    final shouldStickToBottom = _isNearBottom();
    // F09 P1 已读回执 v1: open 完成后 conversationUuid 就绪, 懒创建 receipts controller。
    final convUuid = controller.conversationUuid;
    if (_receipts == null && convUuid != null && convUuid.isNotEmpty) {
      _receipts = ChatReceiptsController(
        conversationUuid: convUuid,
        service: ref.read(chatServiceProvider),
      );
      _receipts!.addListener(_onReceiptState);
      _receiptEventSub ??= ref
          .read(chatReadReceiptEventBusProvider)
          .stream
          .listen(_onReadReceiptChanged);
    }
    final receipts = _receipts;
    if (receipts != null && !controller.isConnectionKicked) {
      var maxSeq = 0;
      final selfSeqs = <int>[];
      final myUid = controller.myUid ?? '';
      for (final m in controller.messages) {
        if (m.messageSeq > maxSeq) maxSeq = m.messageSeq;
        if (myUid.isNotEmpty &&
            m.fromUid == myUid &&
            m.messageSeq > 0 &&
            !m.isRevoked &&
            !m.isPending &&
            !m.isFailed) {
          selfSeqs.add(m.messageSeq);
        }
      }
      if (!_receiptPreparationStarted &&
          (!controller.loading || controller.messages.isNotEmpty)) {
        _initialReceiptsReady = receipts.hasSnapshots(selfSeqs);
        debugPrint('[chat-first-frame] messages=${controller.messages.length} '
            'receiptsReady=$_initialReceiptsReady loading=${controller.loading}');
        _receiptPreparationStarted = true;
        unawaited(receipts
            .prepareInitial(selfSeqs, readThrough: maxSeq)
            .whenComplete(() {
          if (!mounted) return;
          _initialReceiptsReady = true;
          _onChange();
        }));
        final im = ref.read(wukongImClientProvider);
        _receiptConnectionSub = im.listenConnectionStatus().listen((_) {
          if (im.isRealtimeConnected) receipts.onReconnect();
        });
      }
      if (_receiptPreparationStarted && !_initialReceiptsReady) {
        unawaited(receipts.prepareInitial(selfSeqs, readThrough: maxSeq));
      }
      if (_initialReceiptsReady) {
        receipts.recordSentSeqs(selfSeqs);
        if (maxSeq > 0) {
          receipts.reportReadWatermark(maxSeq, selfSeqs: selfSeqs);
        }
      }
    }
    setState(() {});
    if (_initialReceiptsReady &&
        _initialScrollPending &&
        controller.messages.isNotEmpty) {
      _initialScrollPending = false;
      _scroll.scrollToLatest();
    }
    if (_loadingOlder || !_initialReceiptsReady) return; // 上拉加载更早历史时不自动跳到底
    if (shouldStickToBottom) {
      _scroll.scrollToLatest();
    }
  }

  bool get _hideHistory =>
      controller.isConnectionKicked ||
      controller.historyAccessDenied ||
      (_receipts?.accessDenied ?? false);

  void _onReceiptState() {
    if (_receipts?.accessDenied ?? false) controller.discardWarmHistory();
    if (mounted) setState(() {});
  }

  void _onReadReceiptChanged(ChatReadReceiptChangedEvent event) {
    final receipts = _receipts;
    if (receipts == null) return;
    if (event.conversationUuid != receipts.conversationUuid) return;
    receipts.refreshReadThrough(event.lastReadMessageSeq);
  }

  /// 滚到顶部附近 → 加载更早历史(P1)。加载后保持视口锚点,不自动跳到底、不重画聊天页。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.userScrollDirection != ScrollDirection.idle) {
      _scroll.cancelScrollToLatest();
    }
    // 移动端由下拉刷新控件在释放手势后触发，桌面用顶部滚轮/触控板。
    if (usesChatPullToRefresh(context) || _loadingOlder) return;
    if (_scroll.position.userScrollDirection != ScrollDirection.reverse) return;
    if (_scroll.position.extentAfter > 80) return;
    unawaited(_loadOlder());
  }

  Future<void> _loadOlder() async {
    if (!_scroll.hasClients ||
        _loadingOlder ||
        controller.loadingMore ||
        !controller.hasMoreHistory) {
      return;
    }
    _loadingOlder = true;
    _scroll.cancelScrollToLatest();
    try {
      await controller.loadMoreHistory(reportErrors: true);
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {
      if (!mounted) return;
      if (usesChatPullToRefresh(context)) rethrow;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('加载更早消息失败，请重试'))
      );
    } finally {
      _loadingOlder = false;
    }
  }

  // 左侧会话列表的实时预览/置顶/未读由 app 级 ConversationRealtimeBridge 统一处理:
  // 自己发出的 pending 经 WuKong SDK msgInserted 回显流到 bridge(fromSelf 不加未读),
  // 这里不再单独回调 patch 左侧。

  bool _isNearBottom() {
    if (!_scroll.hasClients) return true;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return true;
    return (chatLatestScrollOffset(position) - position.pixels).abs() <=
        _autoScrollBottomThreshold;
  }

  /// 自己 failed 消息重发(P1):文本走 retryTextMessage、媒体走 retryMediaMessage;
  /// 复用 _runSend 的 catch + snackbar,避免未处理异常。
  void _onRetry(ImMessage m) {
    final action = m.mediaKind == ImMediaKind.none
        ? () => controller.retryTextMessage(m)
        : () => controller.retryMediaMessage(m);
    // ignore: discarded_futures
    _runSend(action, '重发失败');
  }

  /// P2/P3: 取消正在上传的本地媒体(自己侧 uploading 预留态)。
  void _onCancelUpload(ImMessage m) => controller.cancelMediaUpload(m);

  /// F09 C: 群聊菜单「保存文件」(P2 2026-06 CR 接入 download controller).
  /// 与 human_direct 同口径: 走 `ChatMediaDownloadController.start`,
  /// 同 url 在下载中 → controller 自吐 toast「该文件已在下载中」, 不并发。
  void _onSaveFile(ImMessage m) {
    if (!m.isMedia || m.mediaUrl.trim().isEmpty) return;
    final name = m.mediaName.trim().isNotEmpty
        ? m.mediaName
        : (m.text.trim().isNotEmpty ? m.text : '文件');
    // ignore: discarded_futures
    ref.read(chatMediaDownloadControllerProvider).start(
          url: m.mediaUrl,
          name: name,
          reveal: true,
          isImage: looksLikeSavableImage(m),
        );
  }

  /// F09 P1 群聊撤回自己消息: 同 human_direct, 走 /chat/messages/revoke;
  /// 失败 BotToast + revertRevoke 回滚 (controller 共用 HumanDirectImController)。
  Future<void> _onRevoke(ImMessage m) async {
    final convUuid = controller.conversationUuid;
    if (convUuid == null || convUuid.isEmpty) {
      BotToast.showText(text: '撤回失败:会话未就绪');
      return;
    }
    if (!_isServerMessageId(m.messageId)) {
      BotToast.showText(text: '撤回失败:消息尚未送达');
      return;
    }
    final snapshot = controller.markLocallyRevoked(
      messageId: m.messageId,
      clientMsgNo: m.clientMsgNo,
    );
    if (snapshot == null) return;
    try {
      await ref.read(chatServiceProvider).revokeMessage(
            conversationUuid: convUuid,
            messageId: m.messageId,
            messageSeq: m.messageSeq,
            clientMsgNo: m.clientMsgNo,
          );
    } catch (e) {
      controller.revertRevoke(snapshot);
      if (mounted) BotToast.showText(text: chatRevokeFailureMessage(e));
    }
  }

  static bool _isServerMessageId(String id) =>
      id.isNotEmpty && id != '0' && !id.startsWith('local-');

  /// P2 历史定位:点击历史结果 → 关抽屉 + 滚到主聊天区对应消息 + 短暂高亮(~1s)。
  /// 仅定位**当前已加载**(最新 `controller.messages`)的消息;已删除 / 不在窗口 → 仅关闭,不 crash。
  void _onSelectHistoryMessage(ImMessage m) {
    ref.read(chatHistoryPanelOpenProvider.notifier).state = false;
    final index = findImMessageIndex(controller.messages, m);
    if (index < 0) return;
    final idKey = imMessageIdentity(m);
    // 高亮(单一 key,1s 清除);目标暂未上屏时滚动到位 build 后即可见。
    setState(() => _highlightedKey = idKey);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _highlightedKey = null);
    });
    // 关抽屉后下一帧开始定位(离屏先 ± 扩张近似滚动让 item build,再 ensureVisible,最多 kLocateMaxAttempts 次)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureMessageVisibleWithRetry(idKey, index, attempt: 0);
    });
  }

  /// 消息按时间正序索引；按实际视口方向换算历史定位偏移。
  /// 第 [attempt] 次围绕估算点
  /// 做 ± 扩张搜索(每次跳**不同**偏移,避免重复跳同一点),`jumpTo` 让目标 item 当帧 build。
  void _scrollToMessageByIndex(int index, int attempt) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final estimated = estimateHistoryScrollOffset(
      index: index,
      itemCount: controller.messages.length,
      maxScrollExtent: pos.maxScrollExtent - pos.minScrollExtent,
    );
    _scroll.cancelScrollToLatest();
    final probe = expandingProbeOffset(
      estimated: estimated,
      attempt: attempt,
      viewport: pos.viewportDimension,
      maxScrollExtent: pos.maxScrollExtent - pos.minScrollExtent,
    );
    _scroll.jumpTo(pos.axisDirection == AxisDirection.up
        ? pos.maxScrollExtent - probe
        : pos.minScrollExtent + probe);
  }

  /// 离屏定位 + retry(最多 [kLocateMaxAttempts]):context 在屏 → `ensureVisible`;
  /// 离屏 → ± 扩张近似滚动后下一帧再试;用尽仍无 → 仅高亮(已设),不滚动、不 crash(best-effort)。
  void _ensureMessageVisibleWithRetry(String idKey, int index,
      {int attempt = 0}) {
    if (!mounted) return;
    _scroll.cancelScrollToLatest();
    final resolved = runLocateAttempt(
      attempt: attempt,
      probeContext: () => _messageKeys[idKey]?.currentContext != null,
      onVisible: () {
        final ctx = _messageKeys[idKey]!.currentContext;
        if (!isRenderObjectAttached(ctx)) return;
        unawaited(Scrollable.ensureVisible(ctx!,
                duration: const Duration(milliseconds: 200), alignment: 0.65)
            .catchError((_) {}));
      },
      onApproxScroll: () => _scrollToMessageByIndex(index, attempt),
    );
    if (resolved || attempt >= kLocateMaxAttempts) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureMessageVisibleWithRetry(idKey, index, attempt: attempt + 1);
    });
  }

  /// F09 多选 v1: 进入选择模式; 同时清掉 reply preview.
  /// F09 P2 媒体体验 (2026-06): 点击图片缩略图 → 大图预览 (含当前窗口所有图片)。
  void _onPreviewImage(ImMessage m, {Object? heroTag, String? imageUrl}) {
    final images = collectPreviewableImages(
      controller.messages,
      resolveSenderName: (x) => x.fromUid == (controller.myUid ?? '')
          ? '我'
          : (_resolveSender(x.fromUid)?.name ?? '群成员'),
    );
    if (images.isEmpty) return;
    final messageKey = imMessageIdentity(m);
    final selectedIndex = imageUrl == null
        ? -1
        : images.indexWhere(
            (image) => image.messageKey == messageKey && image.url == imageUrl);
    final idx = selectedIndex >= 0
        ? selectedIndex
        : findImagePreviewIndex(images, messageKey);
    // ignore: discarded_futures
    showChatImagePreview(
      context: context,
      images: images,
      initialIndex: idx,
      heroTag: heroTag,
    );
  }

  /// F09 P2 媒体体验 (2026-06): 点击视频文件 → 下载 + 系统打开 (无内嵌播放器)。
  void _onOpenVideo(ImMessage m) {
    final url = m.mediaUrl.trim();
    if (url.isEmpty) return;
    final name = m.mediaName.trim().isNotEmpty
        ? m.mediaName
        : (m.text.trim().isNotEmpty ? m.text : '视频');
    _openVideoMedia(url: url, name: name);
  }

  void _onOpenVideoBlock(ImMessage parent, ImMessageBlock block) {
    final url = block.url.trim();
    if (url.isEmpty) return;
    final name = block.name.trim().isNotEmpty ? block.name.trim() : '视频';
    _openVideoMedia(url: url, name: name);
  }

  void _openVideoMedia({required String url, required String name}) {
    // ignore: discarded_futures
    ref.read(chatMediaDownloadControllerProvider).start(
        url: url, name: name.trim().isNotEmpty ? name : '视频', reveal: true);
  }

  void _onEnterSelection(ImMessage m) {
    if (!canSelectMessage(m)) return;
    setState(() {
      _selectionMode = true;
      _replyRef = null;
      _selectedKeys
        ..clear()
        ..add(messageSelectionKey(m));
    });
  }

  void _exitSelection() {
    if (!_selectionMode && _selectedKeys.isEmpty) return;
    setState(() {
      _selectionMode = false;
      _selectedKeys.clear();
    });
  }

  void _toggleSelection(ImMessage m) {
    if (!canSelectMessage(m)) return;
    final key = messageSelectionKey(m);
    setState(() {
      if (_selectedKeys.contains(key)) {
        _selectedKeys.remove(key);
      } else {
        if (_selectedKeys.length >= kChatMultiSelectMax) {
          BotToast.showText(text: '一次最多选 $kChatMultiSelectMax 条');
          return;
        }
        _selectedKeys.add(key);
      }
    });
  }

  List<ImMessage> _collectSelected() {
    if (_selectedKeys.isEmpty) return const <ImMessage>[];
    final out = <ImMessage>[];
    for (final m in controller.messages) {
      if (_selectedKeys.contains(messageSelectionKey(m))) out.add(m);
    }
    return out;
  }

  Future<void> _batchDeleteSelected() async {
    final items = _collectSelected();
    if (items.isEmpty) return;
    final ok = await showUiConfirmDialog(
      context,
      title: '删除 ${items.length} 条消息',
      description: '仅在你本地视图中移除, 不影响群内其他人。',
      confirmLabel: '删除',
      danger: true,
    );
    if (ok != true) return;
    for (final m in items) {
      controller.removeLocalMessage(m);
    }
    if (mounted) _exitSelection();
  }

  /// 批量转发 (CR-2026-06-P2 防重入): `_batchForwarding=true` 期间重复触发直接 return;
  /// `forwardMessagesToTargets` 包在 try/finally; 转发期间批量条三按钮全 disable。
  Future<void> _batchForwardSelected(ChatForwardMode mode) async {
    if (_batchForwarding) return; // 防重入
    final items = _collectSelected();
    if (items.isEmpty) return;
    final forwardable =
        items.where(canBatchForwardMessage).toList(growable: false);
    final skipped = items.length - forwardable.length;
    if (forwardable.isEmpty) {
      BotToast.showText(text: '所选消息无可转发内容');
      return;
    }
    final picked = await showChatForwardPickerDialog(
      context,
      title: mode == ChatForwardMode.merged
          ? '合并转发到… (${forwardable.length} 条)'
          : '逐条转发到… (${forwardable.length} 条)',
      subtitle: skipped > 0 ? '另有 $skipped 条不可转发, 将自动跳过' : null,
      multi: true,
    );
    // 用户取消 picker → 不进入 forwarding 状态。
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() => _batchForwarding = true);
    final client = ref.read(wukongImClientProvider);
    try {
      final result = await forwardRichMessagesToTargets(
        messages: forwardable,
        targets: picked,
        mode: mode,
        senderNameOf: _forwardSenderName,
        mergeTitle:
            '${widget.title.trim().isNotEmpty ? widget.title.trim() : '群聊'}的聊天记录',
        cloneMediaBlock: _cloneForwardMediaBlock,
        send: (ch, ct, payload) => _sendForwardPayload(client, ch, ct, payload),
      );
      if (!mounted) return;
      BotToast.showText(
        text: chatForwardResultToast(result: result, isBatch: true),
      );
      _exitSelection();
    } finally {
      if (mounted) setState(() => _batchForwarding = false);
    }
  }

  /// F09 转发 v1 (2026-06 多目标增量): 单条文本转发到 1..N 个目标.
  /// **不**携带原消息 mentions metadata (避免 @数字员工 在目标群被误触发).
  Future<void> _onForward(ImMessage m) async {
    if (!canForwardRichMessage(m)) return;
    final picked = await showChatForwardPickerDialog(
      context,
      title: '转发到…',
      subtitle: chatForwardSubtitleOf(m),
      multi: true,
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final client = ref.read(wukongImClientProvider);
    final result = await forwardRichMessagesToTargets(
      messages: <ImMessage>[m],
      targets: picked,
      mode: ChatForwardMode.separate,
      cloneMediaBlock: _cloneForwardMediaBlock,
      send: (ch, ct, payload) => _sendForwardPayload(client, ch, ct, payload),
    );
    if (!mounted) return;
    BotToast.showText(
      text: chatForwardResultToast(
        result: result,
        isBatch: false,
        singleTargetName: picked.length == 1 ? picked.first.title : null,
      ),
    );
  }

  Future<void> _sendForwardPayload(ImClient client, String channelId,
      int channelType, ChatForwardPayload payload) {
    if (payload.isPlainText) {
      return client.sendTextMessage(channelId, channelType, payload.plainText);
    }
    return client.sendMixedMessage(
      channelId,
      channelType,
      blocks: payload.blocks,
      summary: payload.summary,
    );
  }

  Future<ImMessageBlock?> _cloneForwardMediaBlock(
      String targetConversationUuid, ImMessageBlock block) async {
    final fileUuid = block.fileUuid.trim();
    if (fileUuid.isEmpty) return null;
    final media = await ChatMediaApi().createRef(
      conversationUuid: targetConversationUuid,
      driveFileUuid: fileUuid,
    );
    final isImage = block.isImage || media.isImage;
    return ImMessageBlock(
      kind: isImage ? ImMessageBlockKind.image : ImMessageBlockKind.file,
      url: _chatMediaPath(media.refUuid, isImage ? 'preview' : 'download'),
      fileUuid: media.driveFileUuid,
      refUuid: media.refUuid,
      name: media.fileName.trim().isNotEmpty ? media.fileName : block.name,
      size: media.sizeBytes > 0 ? media.sizeBytes : block.size,
      mime: media.mimeType.trim().isNotEmpty ? media.mimeType : block.mime,
      width: block.width,
      height: block.height,
    );
  }

  static String _chatMediaPath(String refUuid, String action) =>
      '/chat/media/$refUuid/$action';

  String _forwardSenderName(ImMessage message) {
    if (message.fromUid == (controller.myUid ?? '')) return '我';
    return _resolveSender(message.fromUid)?.name ?? '群成员';
  }

  /// F09 引用回复 v1: 群内菜单「引用」入口. 发送人名按 from_uid 反查 (没查到回退「群成员」)。
  void _onReply(ImMessage m) {
    if (!canReplyMessage(m)) return;
    final isPeer = m.fromUid != (controller.myUid ?? '');
    final senderName =
        isPeer ? (_resolveSender(m.fromUid)?.name ?? '群成员') : '我';
    setState(() {
      _replyRef = buildReplyRefFromMessage(source: m, senderName: senderName);
    });
    _inputFocus.requestFocus();
  }

  /// F09 引用回复 v1 (2026-06 best-effort 跨页定位): 群内同 human_direct 逻辑.
  Future<void> _onLocateReply(ChatReplyReference refMsg) async {
    int idx = _findMessageByReplyRef(refMsg);
    if (idx < 0) {
      idx = await loadOlderUntilFoundForReplyRef(
        controller: controller,
        ref: refMsg,
        findIndex: () => _findMessageByReplyRef(refMsg),
      );
    }
    if (!mounted) return;
    if (idx < 0) {
      BotToast.showText(text: '原消息不在当前会话窗口');
      return;
    }
    final msg = controller.messages[idx];
    final idKey = imMessageIdentity(msg);
    setState(() => _highlightedKey = idKey);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _highlightedKey = null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureMessageVisibleWithRetry(idKey, idx, attempt: 0);
    });
  }

  /// 在 controller.messages 中按 reply 元数据找原消息 (复用共享 helper)。
  int _findMessageByReplyRef(ChatReplyReference refMsg) =>
      findMessageIndexByReplyRef(controller.messages, refMsg);

  /// reply 引用的原消息在当前窗口已撤回 → unavailable. 不在窗口不算 unavailable.
  bool _replyTargetUnavailable(ChatReplyReference refMsg) {
    final idx = _findMessageByReplyRef(refMsg);
    if (idx < 0) return false;
    return controller.messages[idx].isRevoked;
  }

  /// P3: kicked 恢复入口 —— 复用现有 logout 流程(清 token + resetSessionScope)+ 跳登录,
  /// **不**新造认证架构、不自动 logout。
  Future<void> _onReLogin() async {
    await performLogoutToLogin(context);
  }

  @override
  void dispose() {
    HumanChatDraftGuard.unregister(_cacheClearGuard);
    final notifier = _activeImControllerNotifier;
    final disposedController = controller;
    Future(() {
      // notifier 背后的 provider 可能在这个延迟任务触发前就被整体 dispose 了
      // (比如 resetSessionScope 重建 ProviderScope)；此时 .state 会抛
      // "used after dispose"，此处只是尽力清理，抛了就说明不用清理了。
      try {
        if (notifier?.state == disposedController) {
          notifier?.state = null;
        }
      } catch (_) {}
    });
    _highlightTimer?.cancel();
    controller.removeListener(_onChange);
    _scroll.removeListener(_onScroll);
    _input.removeListener(_onInputChanged);
    _receiptEventSub?.cancel();
    _receiptEventSub = null;
    _receiptConnectionSub?.cancel();
    _receipts?.dispose();
    controller.dispose();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  _MemberVM? _resolveSender(String fromUid) {
    final uIdx = fromUid.indexOf('_u_');
    if (uIdx >= 0) {
      return _byAccount[fromUid.substring(uIdx + 3)];
    }
    final aIdx = fromUid.indexOf('_a_');
    if (aIdx >= 0) {
      return _byAgent[fromUid.substring(aIdx + 3)];
    }
    return null;
  }

  Future<void> _send() async {
    if (!_input.hasRichContent || _sending) return;
    if (_input.hasUploading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('文件上传中，请稍候'))
      );
      return;
    }
    if (_input.hasFailed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('有文件上传失败，请移除后重试'))
      );
      return;
    }
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    final sentDraft = _input.snapshotDraft();
    final sentReply = _replyRef;
    final replyJson = sentReply?.toJson();
    try {
      // 结构化 mentions:picked 优先(保留真实实体身份)+ 文本兜底;后端 metadata 优先触发。
      final rawText = _input.text;
      final mentions = mentionsForSend(rawText, _picked, _mentionables)
          .map((c) => c.toPayload())
          .toList();
      final blocks = _input.toMixedBlocks();
      if (blocks.isEmpty) return;
      if (blocks.length == 1 && blocks.single.isText) {
        await controller.sendText(blocks.single.text,
            mentions: mentions.isEmpty ? null : mentions, replyRef: replyJson);
      } else {
        await controller.sendMixedMessage(
          blocks,
          summary: RichPromptController.summaryOfBlocks(blocks),
          mentions: mentions.isEmpty ? null : mentions,
          replyRef: replyJson,
        );
      }
      if (!mounted) return;
      final cleared = _input.clearIfUnchanged(sentDraft);
      setState(() {
        if (cleared) {
          _picked.clear();
          _mentionCandidates = const [];
        }
        if (_replyRef == sentReply) _replyRef = null;
      });
      _scroll.scrollToLatest(animated: true);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('发送失败: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  bool _isImageFileName(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'}
        .contains(ext);
  }

  void _addPendingImages(List<XFile> files) {
    if (files.isEmpty) return;
    final slots = (9 - _input.attachments.length).clamp(0, 9);
    if (slots <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多一次发送 9 个附件'))
      );
      return;
    }
    for (final f in files.take(slots)) {
      final name = f.name.trim().isEmpty ? '图片.png' : f.name.trim();
      _insertLocalAttachment(f.path, name, ChatFileType.image);
    }
    _inputFocus.requestFocus();
    if (files.length > slots) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多一次发送 9 个附件'))
      );
    }
  }

  void _addPendingLocalAttachments(List<XFile> files) {
    if (files.isEmpty) return;
    final slots = (9 - _input.attachments.length).clamp(0, 9);
    if (slots <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多一次发送 9 个附件'))
      );
      return;
    }
    for (final f in files.take(slots)) {
      final type = _chatFileTypeForName(f.name);
      final fallback = type == ChatFileType.image ? '图片.png' : '文件';
      final name = f.name.trim().isEmpty ? fallback : f.name.trim();
      _insertLocalAttachment(f.path, name, type);
    }
    _inputFocus.requestFocus();
    if (files.length > slots) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多一次发送 9 个附件'))
      );
    }
  }

  void _insertLocalAttachment(
    String path,
    String name,
    ChatFileType fileType
  ) {
    final id = 'att-${DateTime.now().microsecondsSinceEpoch}';
    final cancel = CancelToken();
    final mediaKind =
        fileType == ChatFileType.image ? ImMediaKind.image : ImMediaKind.file;
    _input.activateTrailingTextBlock();
    _input.insertAttachment(RichPromptAttachment(
      id: id,
      fileName: name,
      fileType: fileType,
      localPath: path,
      onCancel: () {
        if (!cancel.isCancelled) cancel.cancel('removed from composer');
      },
    ));
    unawaited(controller
        .prepareLocalMediaBlock(
      path,
      name,
      mediaKind,
      cancelToken: cancel,
      onProgress: (p) => _input.updateAttachment(
        id,
        (old) => old.copyWith(progress: p.clamp(0, 100)),
      ),
    )
        .then((block) {
      _input.updateAttachment(
        id,
        (old) => old.copyWith(
          status: RichAttachmentStatus.ready,
          progress: 100,
          block: block,
        ),
      );
      refocusPromptInput(_inputFocus);
    }).catchError((Object e) {
      if (cancel.isCancelled) return null;
      _input.updateAttachment(
        id,
        (old) => old.copyWith(
          status: RichAttachmentStatus.failed,
          error: e.toString(),
        ),
      );
      return null;
    }));
  }

  ChatFileType _chatFileTypeForName(String name) =>
      _isImageFileName(name) ? ChatFileType.image : ChatFileType.file;

  Future<void> _runSend(Future<void> Function() action, String failHint) async {
    if (_sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$failHint: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _onPickAttachment(ChatAttachmentPickKind kind) {
    switch (kind) {
      case ChatAttachmentPickKind.files:
        _pickAndSendFiles();
      case ChatAttachmentPickKind.images:
        _pickAndSendImages();
      case ChatAttachmentPickKind.camera:
        _takeAndSendPhoto();
    }
  }

  Future<void> _pickAndSendImages() async {
    final files = await pickImageFiles();
    if (!mounted) return;
    if (files.isEmpty) return;
    _addPendingImages(files);
  }

  Future<void> _takeAndSendPhoto() async {
    final file = await takePhotoFile();
    if (!mounted) return;
    if (file == null) return;
    _addPendingImages([file]);
  }

  Future<bool> _pasteAndSendImage() async {
    final files = await readClipboardAttachmentsAsXFiles();
    if (files.isEmpty) return false;
    _addPendingLocalAttachments(files);
    return true;
  }

  Future<void> _pickAndSendFiles() async {
    final files = await pickChatFiles();
    if (!mounted) return;
    if (files.isEmpty) return;
    final slots = (9 - _input.attachments.length).clamp(0, 9);
    if (slots <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最多一次发送 9 个附件'))
      );
      return;
    }
    for (final f in files.take(slots)) {
      _insertLocalAttachment(f.path, f.name, _chatFileTypeForName(f.name));
    }
  }

  Future<void> _pickAndSendFromDrive() async {
    final picked = await showDriveFilePicker(context, ref);
    if (!mounted) return;
    if (picked == null || picked.isEmpty) return;
    final slots = (9 - _input.attachments.length).clamp(0, 9);
    for (final f in picked.take(slots)) {
      _insertDriveAttachment(f);
    }
  }

  void _insertDriveAttachment(DriveFile f) {
    final id = 'att-${DateTime.now().microsecondsSinceEpoch}';
    final type = f.mimeType.startsWith('image/')
        ? ChatFileType.image
        : _chatFileTypeForName(f.name);
    _input.activateTrailingTextBlock();
    _input.insertAttachment(RichPromptAttachment(
      id: id,
      fileName: f.name,
      fileType: type),
    );
    unawaited(controller.prepareDriveMediaBlock(f).then((block) {
      _input.updateAttachment(
        id,
        (old) => old.copyWith(
          status: RichAttachmentStatus.ready,
          progress: 100,
          block: block,
        ),
      );
      refocusPromptInput(_inputFocus);
    }).catchError((Object e) {
      _input.updateAttachment(
        id,
        (old) => old.copyWith(
          status: RichAttachmentStatus.failed,
          error: e.toString(),
        ),
      );
      return null;
    }));
  }

  Widget _buildMentionOverlay(
    BuildContext context,
    PromptInputOverlayMetrics metrics,
  ) {
    if (_mentionCandidates.isEmpty) return const SizedBox.shrink();
    final selection = _input.selection;
    final caret = selection.isValid ? selection.baseOffset : _input.text.length;
    final mentionQuery = detectMention(_input.text, caret);
    if (mentionQuery == null) return const SizedBox.shrink();

    final popupWidth = (metrics.containerSize.width - 28)
        .clamp(_mentionPopupMinWidth, _mentionPopupMaxWidth)
        .toDouble();
    final actualRect = metrics.textOffsetRect(mentionQuery.start);
    final fallbackOffset = actualRect == null
        ? measureMentionTokenOffset(
            text: _input.text,
            textOffset: mentionQuery.start,
            maxWidth: metrics.textFieldWidth,
          )
        : Offset.zero;
    final anchorLeftInInput =
        actualRect?.left ?? metrics.textFieldOrigin.dx + fallbackOffset.dx;
    final anchorTopInInput =
        actualRect?.top ?? metrics.textFieldOrigin.dy + fallbackOffset.dy;
    final desiredLeft = metrics.overlayOrigin.dx + anchorLeftInInput;
    final left = resolveMentionPopupLeft(
      desiredLeft: desiredLeft,
      popupWidth: popupWidth,
      boundaryLeft: metrics.overlayOrigin.dx,
      boundaryRight: metrics.overlayOrigin.dx + metrics.containerSize.width,
    );
    // 企业微信式:弹层底边永远贴在当前 @ 所在行的上方,不遮挡 @ 和光标。
    final popupBottomInOverlay =
        metrics.overlayOrigin.dy + anchorTopInInput - 8;
    final bottom = (metrics.overlaySize.height - popupBottomInOverlay)
        .clamp(8.0, metrics.overlaySize.height);
    final selectedMention = _mentionCandidates.isEmpty
        ? null
        : _visibleMentionCandidates.isEmpty
            ? null
            : _visibleMentionCandidates[_mentionSelectedIndex.clamp(
                0, _visibleMentionCandidates.length - 1)];

    return Positioned(
      left: left,
      bottom: bottom.toDouble(),
      child: SizedBox(
        width: popupWidth,
        child: MentionBar(
          candidates: _mentionCandidates,
          activeTab: _mentionTab,
          selected: selectedMention,
          onTabChange: _setMentionTab,
          onHoverCandidate: (candidate) {
            final i = _visibleMentionCandidates.indexWhere(
              (c) => c.type == candidate.type && c.id == candidate.id,
            );
            if (i >= 0 && i != _mentionSelectedIndex) {
              setState(() => _mentionSelectedIndex = i);
            }
          },
          onPick: _onPickMention,
        ),
      ),
    );
  }

  Future<bool> _submitGroupTitle(String title) async {
    final trimmed = normalizeGroupTitleInput(title);
    if (trimmed.isEmpty || trimmed == widget.title.trim()) return true;
    try {
      await ref
          .read(chatServiceProvider)
          .renameGroupRoom(widget.roomUuid, trimmed);
      ref
          .read(conversationsProvider.notifier)
          .patchConversationTitle(widget.conversationUuid, trimmed);
      final selected = ref.read(selectedGroupProvider);
      if (selected?.conversationId == widget.conversationUuid) {
        ref.read(selectedGroupProvider.notifier).state =
            selected!.copyWith(title: trimmed);
      }
      unawaited(ref.read(conversationsProvider.notifier).refresh());
      return true;
    } catch (e) {
      BotToast.showText(text: groupRenameFailureMessage(e));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = _members;
    final chatColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeader)
          _GroupHeader(
            title: widget.title,
            canRenameGroup: widget.canRenameGroup,
            onTitleSubmitted: _submitGroupTitle,
          ),
        // P3: kicked/连接断开 → 明确提示 + 重新登录入口(优先于通用加载错误)。
        if (controller.isConnectionKicked)
          ChatConnectionNotice(onReLogin: _onReLogin),
        if (!controller.isConnectionKicked && controller.error != null)
          Container(
            width: double.infinity,
            color: const Color(0xFFFDECEC),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '加载失败: ${controller.error}',
              style: const TextStyle(color: Color(0xFFD92D20), fontSize: 12),
            ),
          ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  color: ChatTheme.pageBg,
                  child: _hideHistory ||
                          (controller.loading && controller.messages.isEmpty) ||
                          (!_initialReceiptsReady &&
                              controller.messages.isNotEmpty)
                      ? _hideHistory
                          ? const Center(child: Text('当前会话不可访问，请重新登录或检查权限'))
                          : const DeferredChatMessagesShimmer(
                              bottomContentInset: 0)
                      : controller.messages.isEmpty
                          ? const ChatEmptyState()
                          : ChatMessageScrollbar(
                              controller: _scroll,
                              child: ChatHistoryList(
                                scrollController: _scroll,
                                hasMore: controller.hasMoreHistory,
                                onLoadOlder: _loadOlder,
                                itemIds: controller.messages
                                    .map(imMessageIdentity)
                                    .toList(),
                                padding: EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  _selectionMode ? 110 : 12,
                                ),
                                itemBuilder: (context, i) {
                                  final msgs = controller.messages;
                                  final msg = msgs[i];
                                  final sender = _resolveSender(msg.fromUid);
                                  // F09 引用回复 v1: 解码 reply ref + 在窗口内查 unavailable 状态.
                                  final replyRefJson = msg.replyRefJson;
                                  ChatReplyReference? replyRef;
                                  if (replyRefJson != null &&
                                      replyRefJson.isNotEmpty) {
                                    final base = ChatReplyReference.fromJson(
                                        replyRefJson);
                                    replyRef = base.copyWith(
                                      isUnavailable:
                                          _replyTargetUnavailable(base),
                                    );
                                  }
                                  final bubble = _GroupBubble(
                                    msg: msg,
                                    myUid: controller.myUid ?? '',
                                    senderName: sender?.name ?? '群成员',
                                    senderKind: sender?.kind,
                                    senderAvatarUrl: sender?.avatar,
                                    selfAvatarUrl: widget.selfAvatarUrl,
                                    mentionNames: _mentionNames,
                                    activeHumanNamesById: _activeHumanNamesById,
                                    onSenderProfileTap: (_selectionMode ||
                                            sender == null)
                                        ? null
                                        : (anchor) =>
                                            _showMemberProfile(sender, anchor),
                                    onRetry: _selectionMode ? null : _onRetry,
                                    onCancelUpload:
                                        _selectionMode ? null : _onCancelUpload,
                                    onDelete: _selectionMode
                                        ? null
                                        : controller.removeLocalMessage,
                                    onRevoke: _selectionMode ? null : _onRevoke,
                                    onSaveFile:
                                        _selectionMode ? null : _onSaveFile,
                                    onReply: _selectionMode ? null : _onReply,
                                    onForward:
                                        _selectionMode ? null : _onForward,
                                    onMultiSelect: _selectionMode
                                        ? null
                                        : _onEnterSelection,
                                    replyRef: replyRef,
                                    onLocateReply:
                                        _selectionMode ? null : _onLocateReply,
                                    onPreviewImage:
                                        _selectionMode ? null : _onPreviewImage,
                                    onOpenVideo:
                                        _selectionMode ? null : _onOpenVideo,
                                    onOpenVideoBlock: _selectionMode
                                        ? null
                                        : _onOpenVideoBlock,
                                    hitlConversationUuid:
                                        controller.conversationUuid ??
                                            widget.conversationUuid,
                                    submittedHitlMessages:
                                        _submittedHitlMessages,
                                    empRespondHandler: _selectionMode
                                        ? null
                                        : _groupEmpRespondHandler,
                                    // F09 P1 已读回执 v1: 自己 sent 渲染 indicator (controller 内部判定).
                                    receipts: _selectionMode ? null : _receipts,
                                  );
                                  // F09 多选 v1: selection mode 下气泡左/右出 checkbox + 整行 toggle.
                                  final selectionKey = messageSelectionKey(msg);
                                  final selectable = canSelectMessage(msg);
                                  final bubbleForList = _selectionMode
                                      ? ChatSelectableBubble(
                                          checked: _selectedKeys
                                              .contains(selectionKey),
                                          enabled: selectable,
                                          isPeer: msg.fromUid !=
                                              (controller.myUid ?? ''),
                                          onToggle: () => _toggleSelection(msg),
                                          child: bubble,
                                        )
                                      : bubble;
                                  // P2 历史定位:按 identity 复用 GlobalKey + 高亮包装(无高亮时透明)。
                                  final idKey = imMessageIdentity(msg);
                                  final gk = _messageKeys.putIfAbsent(
                                      idKey, () => GlobalKey());
                                  final located = KeyedSubtree(
                                    key: gk,
                                    child: ChatLocateHighlight(
                                      active: _highlightedKey == idKey,
                                      child: bubbleForList,
                                    ),
                                  );
                                  // P2: 相邻消息时间差 ≥ 5min(或第一条)→ 在该条上方插入时间分隔。
                                  if (!shouldShowTimeDivider(
                                    prevTimestampMs:
                                        i > 0 ? msgs[i - 1].timestamp : null,
                                    timestampMs: msg.timestamp,
                                  )) {
                                    return located;
                                  }
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ChatMessageTimeDivider(
                                          timestampMs: msg.timestamp),
                                      located,
                                    ],
                                  );
                                },
                              ),
                            ),
                ),
              ),
              if (_selectionMode)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 18,
                  child: Center(
                    child: ChatBatchActionBar(
                      selectedCount: _selectedKeys.length,
                      forwarding: _batchForwarding,
                      onCancel: _batchForwarding ? null : _exitSelection,
                      onForwardSeparate: _batchForwarding
                          ? null
                          : () =>
                              _batchForwardSelected(ChatForwardMode.separate),
                      onForwardMerged: _batchForwarding
                          ? null
                          : () => _batchForwardSelected(ChatForwardMode.merged),
                      onDelete: _batchForwarding ? null : _batchDeleteSelected,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_replyRef != null)
          ChatReplyPreviewBar(
            reference: _replyRef!,
            onCancel: () {
              setState(() => _replyRef = null);
              _inputFocus.requestFocus();
            },
          ),
        if (PlatformUtils.isMobile && _mentionCandidates.isNotEmpty)
          TextFieldTapRegion(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: MentionBar(
                candidates: _mentionCandidates,
                activeTab: _mentionTab,
                selected: _visibleMentionCandidates.isEmpty
                    ? null
                    : _visibleMentionCandidates[_mentionSelectedIndex.clamp(
                        0, _visibleMentionCandidates.length - 1)],
                onTabChange: _setMentionTab,
                onPick: _onPickMention,
              ),
            ),
          ),
        ListenableBuilder(
          listenable: ref.watch(rtcCallControllerProvider),
          builder: (context, _) {
            final rtc = ref.read(rtcCallControllerProvider);
            if (PlatformUtils.isMobile) {
              return ChatPlatformWidgets.of(context).promptInput(
                focusNode: _inputFocus,
                controller: _input,
                conversationUuid: widget.conversationUuid,
                showSkillButton: false,
                onPickAttachment: _onPickAttachment,
                onPickFromDrive: _pickAndSendFromDrive,
                onVoiceCall: _onGroupVoiceCallPressed,
                voiceCallEnabled: !rtc.busy,
                voiceCallActive: rtc.hasActiveCall && !rtc.isVideo,
                onVideoCall: _onGroupVideoCallPressed,
                videoCallEnabled: !rtc.busy,
                videoCallActive: rtc.hasActiveCall && rtc.isVideo,
                allowAttachmentOnlySend: true,
                isSending: _sending,
                onSend: (_) => _send(),
              );
            }
            return PromptInput(
              focusNode: _inputFocus,
              controller: _input,
              conversationUuid: widget.conversationUuid,
              showSkillChips: false,
              showSkillButton: false,
              showAiDisclaimer: false,
              onPickAttachment: _onPickAttachment,
              onPasteImage: _pasteAndSendImage,
              onPickFromDrive: _pickAndSendFromDrive,
              onVoiceCall: _onGroupVoiceCallPressed,
              voiceCallEnabled: !rtc.busy,
              voiceCallActive: rtc.hasActiveCall && !rtc.isVideo,
              onVideoCall: _onGroupVideoCallPressed,
              videoCallEnabled: !rtc.busy,
              videoCallActive: rtc.hasActiveCall && rtc.isVideo,
              allowAttachmentOnlySend: true,
              isSending: _sending,
              onSend: (_) => _send(),
              onStop: () {},
              overlayBuilder: _buildMentionOverlay,
            );
          },
        ),
      ],
    );

    // 桌面三栏(showHeader)右侧挂群成员面板;移动端(showHeader=false)只渲染聊天列(成员在 app bar)。
    final body = !widget.showHeader
        ? chatColumn
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: chatColumn),
              _GroupMemberPanel(
                members: members,
                onAddMembers: widget.roomUuid.isNotEmpty ? _onAddMembers : null,
                onMemberTap: _showMemberProfile,
              ),
            ],
          );
    // P2: 聊天历史抽屉(复用 chatHistoryPanelOpenProvider 入口;群成员名回退「群成员」)。
    return ChatImHistoryHost(
      controller: controller,
      resolveSenderName: (m) => _resolveSender(m.fromUid)?.name ?? '群成员',
      onSelectMessage: _onSelectHistoryMessage,
      onPreviewImage: _onPreviewImage,
      onOpenVideo: _onOpenVideo,
      child: body,
    );
  }
}

/// 顶栏:白底 64px,标题 + 人数(**无头像 icon**,右侧动作放进群成员栏顶部)。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.canRenameGroup,
    required this.onTitleSubmitted,
  });
  final String title;
  final bool canRenameGroup;
  final Future<bool> Function(String title) onTitleSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFE8EDF4), width: 0.8),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GroupTitleEdit(
                  title: title,
                  editable: canRenameGroup,
                  onSubmit: onTitleSubmitted,
                  onInvalid: (message) => BotToast.showText(text: message),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 右侧群成员面板:群成员 · N + 成员列表(群主标记)。
class _GroupMemberPanel extends StatelessWidget {
  const _GroupMemberPanel({
    required this.members,
    required this.onAddMembers,
    required this.onMemberTap,
  });
  static const double _panelWidth = 190;

  final List<_MemberVM> members;
  final VoidCallback? onAddMembers;
  final void Function(_MemberVM member, Offset anchor) onMemberTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 给头像、5 个汉字名称和角色标签留足空间,避免成员名过早截断。
      width: _panelWidth,
      decoration: const BoxDecoration(
        color: Colors.white
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 64,
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFFE8EDF4), width: 0.8),
              ),
            ),
            padding: const EdgeInsets.only(left: 10, right: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                InkWell(
                  onTap: onAddMembers,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      CupertinoIcons.person_add,
                      size: 18,
                      color: onAddMembers == null
                          ? const Color(0xFFC9CDD4)
                          : const Color(0xFF4E5969),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: Color(0xFFDDE5EF), width: 1),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '群成员 · ${members.length}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF4E5969),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: members.length,
                      itemBuilder: (context, i) {
                        final m = members[i];
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (details) =>
                              onMemberTap(m, details.globalPosition),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 6),
                            child: Row(
                              children: [
                                ChatAvatar(
                                  url: m.avatar.isEmpty ? null : m.avatar,
                                  fallbackText: m.name,
                                  kind: m.kind == 'agent'
                                      ? ChatAvatarKind.agent
                                      : ChatAvatarKind.user,
                                  size: 22,
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    m.name.isEmpty ? '未命名' : m.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF1D2129),
                                    ),
                                  ),
                                ),
                                // 数字员工标识: 仿群主标签, 换成蓝色 (品牌色)。
                                if (m.kind == 'agent') ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEAF2FF),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      '数字员工',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF2563EB),
                                        height: 1.0,
                                      ),
                                    ),
                                  ),
                                ],
                                if (m.isOwner) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFFF3E8),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      '群主',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFFD46B08),
                                        height: 1.0,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 群消息气泡:别人左侧白底(头像 + 发送者名 + 气泡),自己右侧浅蓝。
class _GroupBubble extends StatelessWidget {
  const _GroupBubble({
    required this.msg,
    required this.myUid,
    required this.senderName,
    this.senderKind,
    this.senderAvatarUrl,
    this.selfAvatarUrl,
    this.mentionNames = const {},
    this.activeHumanNamesById = const {},
    this.onSenderProfileTap,
    this.onRetry,
    this.onCancelUpload,
    this.onDelete,
    this.onRevoke,
    this.onSaveFile,
    this.onReply,
    this.onForward,
    this.onMultiSelect,
    this.replyRef,
    this.onLocateReply,
    this.onPreviewImage,
    this.onOpenVideo,
    this.onOpenVideoBlock,
    this.hitlConversationUuid = '',
    this.submittedHitlMessages = const {},
    this.empRespondHandler,
    this.receipts,
  });
  final ImMessage msg;
  final String myUid;
  final String senderName;
  final String? senderKind; // 'human' | 'agent'
  final String? senderAvatarUrl;
  final String? selfAvatarUrl;
  final Set<String> mentionNames;
  final Map<String, String> activeHumanNamesById;
  final void Function(Offset anchor)? onSenderProfileTap;

  /// 自己 failed 文本消息的重发回调(P1)。
  final void Function(ImMessage msg)? onRetry;

  /// 自己 uploading 媒体预留态的取消回调(P2/P3)。
  final void Function(ImMessage msg)? onCancelUpload;

  /// 本地删除回调(P2,仅客户端);右键 / 长按菜单用。
  final void Function(ImMessage msg)? onDelete;

  /// F09 P1: 撤回自己消息(仅自己 sent 显示)。
  final void Function(ImMessage msg)? onRevoke;

  /// F09 C: 保存文件到下载目录(并 best-effort reveal). 媒体消息可见。
  final void Function(ImMessage msg)? onSaveFile;

  /// F09 引用回复 v1: 菜单「引用」入口. null = 不显示该菜单项。
  final void Function(ImMessage msg)? onReply;

  /// F09 转发 v1: 菜单「转发」入口 (媒体 fail-closed; null = 不显示该项)。
  final void Function(ImMessage msg)? onForward;

  /// F09 多选 v1: 菜单「多选」入口, 进入选择模式。null = 不显示。
  final void Function(ImMessage msg)? onMultiSelect;

  /// F09 引用回复 v1: 本消息引用的原消息快照. null = 普通消息.
  final ChatReplyReference? replyRef;

  /// F09 引用回复 v1: 点击引用块定位回原消息.
  final void Function(ChatReplyReference ref)? onLocateReply;

  /// F09 P2 媒体体验 (2026-06): 点击图片缩略图 → 大图预览。
  final void Function(ImMessage msg, {Object? heroTag, String? imageUrl})?
      onPreviewImage;

  /// F09 P2 媒体体验 (2026-06): 点击视频文件 → 下载 + 系统打开。
  final void Function(ImMessage msg)? onOpenVideo;

  /// F09 P2 媒体体验 (2026-06): mixed 内 file block 视频用 block URL 打开。
  final void Function(ImMessage parent, ImMessageBlock block)? onOpenVideoBlock;

  final String hitlConversationUuid;
  final Set<String> submittedHitlMessages;
  final EmpBlocksRespondHandler? empRespondHandler;

  /// F09 P1 已读回执 v1: per-pane controller。null = 未就绪, 入口不渲染。
  final ChatReceiptsController? receipts;

  @override
  Widget build(BuildContext context) {
    final isPeer = msg.fromUid != myUid;
    final bg = isPeer
        ? ChatTheme.enterprisePeerBubble
        : ChatTheme.enterpriseSelfBubble;

    final replyMentionNames = groupReplyHumanMentionNames(
      msg.mentions,
      activeHumanNamesById,
    );
    final replyMentionPrefix = groupReplyMentionPrefix(replyMentionNames);
    final showReplyMention = isPeer &&
        senderKind == 'agent' &&
        replyMentionPrefix.isNotEmpty &&
        !msg.text.trimLeft().startsWith(replyMentionPrefix);
    final replyMentionSpans = mentionHighlightSpans(
      replyMentionPrefix,
      {...mentionNames, ...replyMentionNames}
    );
    final shareReplyMentionFirstLine =
        showReplyMention && groupReplyMentionCanShareFirstLine(msg.empBlocks);

    final Widget bubble;
    // 只有纯文本气泡(撤回提示 / 普通文本)整条包一层 ChatSelectableSurface;
    // 图片/文件/mixed/EMP/通话卡片这些**没有直接文字**或者**自己内部已经按块
    // 单独包了**(mixed)的分支不能再在这里整体包一层——ChatSelectableSurface
    // 永久 IgnorePointer,包住图片/文件/EMP 按钮会直接挡掉它们的点击。
    var wrapSelectable = false;
    if (msg.isRevoked) {
      wrapSelectable = true;
      final tombstoneText = isPeer ? '对方撤回了一条消息' : '你撤回了一条消息';
      bubble = Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          tombstoneText,
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xFF8A94A6),
            fontStyle: FontStyle.italic,
            height: 1.4,
          ),
        ),
      );
    } else if (isCallEventLikeMessage(msg)) {
      bubble = ChatCallEventCard(
        label: callEventMessageLabel(msg),
        endReason: callEventMessageEndReason(msg),
      );
    } else if (msg.empBlocks.isNotEmpty) {
      final agentFinalTextBlocks = groupAgentFinalTextBlocks(msg.blocks);
      final hasAgentFinalText = agentFinalTextBlocks.isNotEmpty;
      final empBlocksView = EmpBlocksView(
        blocks: msg.empBlocks,
        agentMessageStatus: submittedHitlMessages.contains(msg.agentMessageUuid)
            ? 'final'
            : msg.agentMessageStatus,
        agentMessageUuid: msg.agentMessageUuid,
        conversationUuid: hitlConversationUuid,
        respondHandler: empRespondHandler,
      );
      bubble = Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: isPeer ? 8 : 6
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isPeer
                ? ChatTheme.enterprisePeerBubbleBorder
                : ChatTheme.enterpriseSelfBubbleBorder,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasAgentFinalText) ...[
              if (showReplyMention)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text.rich(
                    TextSpan(children: replyMentionSpans)
                  ),
                ),
              GroupAgentFinalTextBlocksView(
                blocks: agentFinalTextBlocks,
                mentionNames: mentionNames,
              ),
              const SizedBox(height: 8),
              empBlocksView,
            ] else if (shareReplyMentionFirstLine)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(children: replyMentionSpans)
                  ),
                  const SizedBox(width: 6),
                  Flexible(child: empBlocksView),
                ],
              )
            else if (showReplyMention)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text.rich(
                  TextSpan(children: replyMentionSpans)
                ),
              ),
            if (!hasAgentFinalText && !shareReplyMentionFirstLine)
              empBlocksView,
          ],
        ),
      );
    } else if (msg.mediaKind == ImMediaKind.image && msg.mediaUrl.isNotEmpty) {
      // P2: 点击图片 → 大图预览 overlay (含上一张/下一张)。
      bubble = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: HumanDirectMediaImage(
          url: msg.mediaUrl,
          onPreviewWithHero: onPreviewImage == null
              ? null
              : (tag) => onPreviewImage!(msg, heroTag: tag),
        ),
      );
    } else if (msg.mediaKind == ImMediaKind.file && msg.mediaUrl.isNotEmpty) {
      // P2 (2026-06): 视频以「视频卡片」呈现; 点击 → 下载 + 系统打开 (无内嵌播放器)。
      final isVideo = isVideoMessage(msg);
      bubble = HumanDirectFileCard(
        url: msg.mediaUrl,
        name: msg.mediaName.isNotEmpty ? msg.mediaName : msg.text,
        size: msg.mediaSize,
        mime: msg.mediaMime,
        isVideoOverride: isVideo,
        onOpen: isVideo && onOpenVideo != null ? () => onOpenVideo!(msg) : null,
      );
    } else if (msg.isMixed) {
      // P2 (2026-06 CR): mixed image/video block 与顶层一致, 透传 parentMessage + 回调。
      bubble = ChatMixedMessageBubble(
        blocks: msg.blocks,
        backgroundColor: bg,
        isPeer: isPeer,
        mentionNames: mentionNames,
        replyMentionPrefix: showReplyMention ? replyMentionPrefix : '',
        parentMessage: msg,
        onPreviewImage: onPreviewImage,
        onOpenVideo: onOpenVideoBlock,
      );
    } else {
      wrapSelectable = true;
      final rawText = msg.text.isNotEmpty ? msg.text : '[非文本消息]';
      final text = showReplyMention ? '$replyMentionPrefix $rawText' : rawText;
      // 文本内的 @名字(命中群成员 / 所有人)高亮成蓝色 span(P3-3),其余普通。
      final spans = mentionHighlightSpans(text, mentionNames);
      bubble = Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: isPeer ? 8 : 6
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isPeer
                ? ChatTheme.enterprisePeerBubbleBorder
                : ChatTheme.enterpriseSelfBubbleBorder,
          ),
        ),
        child: Text.rich(TextSpan(children: spans)),
      );
    }

    // F09 引用回复 v1: 气泡内引用块. tombstone 时不画.
    // 气泡正文(不含上面的引用预览块 / 下面的发送者名字行)——只有纯文本才包
    // ChatSelectableSurface,图片/文件/mixed/EMP/通话卡片不包(没有可选文字,
    // 包了反而挡住点击;mixed 已经按块单独包了)。
    Widget bubbleWithReply =
        wrapSelectable ? ChatSelectableSurface(child: bubble) : bubble;
    if (replyRef != null && !msg.isRevoked) {
      bubbleWithReply = Column(
        crossAxisAlignment:
            isPeer ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          ChatBubbleReplyBlock(
            reference: replyRef!,
            onTap:
                onLocateReply == null ? null : () => onLocateReply!(replyRef!),
          ),
          wrapSelectable ? ChatSelectableSurface(child: bubble) : bubble,
        ],
      );
    }

    if (isAiGeneratedImContent(msg, senderKind: senderKind)) {
      bubbleWithReply = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [bubbleWithReply, const UiAiGeneratedLabel()],
      );
    }

    final bubbleWithName = isPeer
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 3),
                child: MouseRegion(
                  cursor: onSenderProfileTap == null
                      ? SystemMouseCursors.basic
                      : SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: onSenderProfileTap == null
                        ? null
                        : (details) =>
                            onSenderProfileTap!(details.globalPosition),
                    child: Text(
                      senderName,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF86909C),
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
              bubbleWithReply,
            ],
          )
        : bubbleWithReply;

    // P2 + F09 P1/C/v2: 右键 / 长按 → 复制 / 引用 / 转发 / 多选 / 重发 / 撤回 / 保存文件 / 本地删除 / 取消上传。
    final actionBubble = ChatMessageActionRegion(
      msg: msg,
      isMine: !isPeer,
      onReply: onReply == null ? null : () => onReply!(msg),
      onForward: onForward == null ? null : () => onForward!(msg),
      onMultiSelect: onMultiSelect == null ? null : () => onMultiSelect!(msg),
      onResend: onRetry == null ? null : () => onRetry!(msg),
      onRevoke: onRevoke == null ? null : () => onRevoke!(msg),
      onSaveFile: onSaveFile == null ? null : () => onSaveFile!(msg),
      onDelete: onDelete == null ? null : () => onDelete!(msg),
      onCancelUpload:
          onCancelUpload == null ? null : () => onCancelUpload!(msg),
      child: bubbleWithName,
    );

    // F09 P1 已读回执 v1: 同 human_direct, 自己 sent (非 revoked/pending/failed/uploading)
    // 左侧始终保留状态位;snapshot / controller 没就绪时由 ChatReceiptStatusSlot 显示弱灰占位。
    final bool showSelfReceiptSlot = shouldShowSelfReceiptStatusSlot(
      msg: msg,
      isPeer: isPeer,
    );

    final children = isPeer
        ? <Widget>[
            Flexible(fit: FlexFit.loose, child: actionBubble)
          ]
        : <Widget>[
            Flexible(
              fit: FlexFit.loose,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // uploading(本地媒体上传中)→ 进度+取消;否则 pending 转圈 / failed 红色感叹号(可点重发)。
                  if (msg.isUploading)
                    ChatUploadProgressIndicator(
                      progress: msg.uploadProgress,
                      onCancel: () => onCancelUpload?.call(msg),
                    )
                  else
                    ChatSendStatusIndicator(
                      isPeer: isPeer,
                      status: msg.sendStatus,
                      errorMessage: msg.errorMessage,
                      onRetry: (msg.isFailed &&
                              onRetry != null &&
                              (msg.mediaKind != ImMediaKind.none ||
                                  msg.text.isNotEmpty))
                          ? () => onRetry!(msg)
                          : null,
                    ),
                  // F09 P1 已读回执状态位 (群聊):贴气泡左下角, snapshot 没回来也不消失。
                  if (showSelfReceiptSlot)
                    Padding(
                      padding: const EdgeInsets.only(right: 4, bottom: 3),
                      child: ChatReceiptStatusSlot(
                        controller: receipts,
                        messageSeq: msg.messageSeq,
                        isGroup: true,
                      ),
                    ),
                  Flexible(fit: FlexFit.loose, child: actionBubble),
                ],
              ),
            ),
          ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment:
            isPeer ? MainAxisAlignment.start : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}
