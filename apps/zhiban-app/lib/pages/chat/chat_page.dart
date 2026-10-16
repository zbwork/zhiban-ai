import 'package:zhiban_client/pages/chat/widgets/conversation_connection_banner.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/utils/open_chat_attachment.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_conversation_content.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_detail_header.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_history_panel.dart';
import 'package:nexwork/pages/chat/widgets/desktop_drop.dart';
import 'package:zhiban_client/pages/chat/widgets/group_chat_pane.dart';
import 'package:zhiban_client/pages/chat/widgets/human_direct_chat_pane.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/chat_conversation_action_menu.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/chat_conversation_actions.dart';
import 'package:zhiban_client/pages/chat/widgets/sidebar/components/conversation_list_panel.dart';
import 'package:zhiban_core/contacts/contact_models.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/services/account_info_api.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/window/window_controller.dart';
import 'package:nexwork/pages/chat/widgets/file_preview/attachment_preview_host.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({
    super.key,
    this.triggerCreateSkill = false,
    this.targetAgentId,
    this.directKind,
    this.peerAccountUuid,
    this.directTitle,
  });

  /// ADR-0026: `?direct=human&peer_account_uuid=&title=` 进入时,主对话区渲染
  /// 普通员工 WuKong direct IM(复用三栏 shell,不再跳独立页)。`direct=human` 时生效。
  final String? directKind;
  final String? peerAccountUuid;
  final String? directTitle;

  /// 通过 `?create_skill=true` 进入时为 true，会自动触发「创建自定义技能」流程：
  /// 直接给数字员工发一条「我要创建个新技能」，由 agent 按 prompt 路由到
  /// builtin 的 `aigc-skill-creator`（位于 OpenClaw 容器 `/opt/openclaw-builtin/
  /// skills/aigc-skill-creator/`，不走 SkillHub 安装、不写 git、不打 zip）。
  ///
  /// 历史版本曾在这里调 `installAgentSkill('skill-creator')` + 把 skill 标签
  /// 绑到消息上 —— 那是为了对齐老 H5 行为，但 `skill-creator` 是 OpenClaw
  /// runtime bundled 的 skill，已被 ai-office 拉黑（`isBundledSystemSkill`），
  /// 任何安装请求都会以「skill is bundled by openclaw runtime」400 拒绝。
  /// 现在的语义是：「+ 添加自定义技能」= 进对话 + 发一条引导语，仅此而已。
  final bool triggerCreateSkill;

  /// `?agentId=` 透传过来的目标数字员工 id，配合上面 flag 使用。
  /// 如果当前 selectedAgentProvider 已经是该 agent，则直接走；不一致时这里
  /// 不强切（已经在跳转入口侧统一处理 select 逻辑）。
  final String? targetAgentId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  static const String _skillCreatorPrompt = '我要创建个新技能';
  final _contentKey = GlobalKey<ChatConversationContentState>();

  bool _autoTriggered = false;
  bool _panelOpen = false;

  @override
  void initState() {
    super.initState();
    _panelOpen = ref.read(chatHistoryPanelOpenProvider);
    if (widget.triggerCreateSkill) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeAutoCreateSkill();
      });
    }
  }

  @override
  void dispose() {
    // 离开 chat 页时,如果面板还开着、窗口已经撑宽过,先把窗口收回去,
    // 否则用户切到「我的」「文档」等页时会看到窗口右侧一大块空白。
    if (_panelOpen) {
      WindowController.instance.setOverlayWidth(0);
    }
    super.dispose();
  }

  // 进对话页后，自动给当前数字员工发一条「我要创建个新技能」引导语。
  //
  // 不再走「安装 skill-creator」流程：`aigc-skill-creator` 已经作为 builtin
  // skill 内嵌在 OpenClaw 容器（`/opt/openclaw-builtin/skills/...`），
  // BOOTSTRAP prompt 里也明确告诉了 agent 收到这种诉求要直接落 SKILL.md。
  // 这里的职责仅限：等会话就绪 → 把引导语发出去。
  Future<void> _maybeAutoCreateSkill() async {
    if (_autoTriggered) return;
    _autoTriggered = true;
    final agentId = widget.targetAgentId?.trim() ?? '';
    if (agentId.isEmpty) return;
    try {
      final agent = await ref.read(selectedAgentProvider.future);
      if (agent == null || agent.agentId != agentId) {
        BotToast.showText(text: '正在切换数字员工，请稍候重试');
        return;
      }
      final chatNotifier = ref.read(chatProvider.notifier);
      var chatState = await ref.read(chatProvider.future);
      if (chatState.activeConversationId == null) {
        try {
          await chatNotifier.createConversation();
          chatState = await ref.read(chatProvider.future);
        } catch (_) {}
      }
      if (chatState.activeConversationId == null) {
        BotToast.showText(text: '未找到可用会话，请稍后再试');
        return;
      }
      await chatNotifier.send(_skillCreatorPrompt);
    } catch (e) {
      BotToast.showText(text: '触发创建技能失败：$e');
    }
  }

  /// 「聊天历史」面板当前实际宽度,用于在状态变化时驱动 WindowController
  /// 把窗口往右扩(打开)或收回(关闭)。280..300 之间,与 chat_page 内
  /// LayoutBuilder 选出来的 panelW 同源。0 = 关闭/无法展开。
  static const double _historyPanelDesiredWidth = 300;

  /// 单聊(人↔人 / 人↔数字员工)顶栏"发起群聊"入口:拉起建群弹窗并预选中对方。
  Widget _buildAddToGroupButton(String preselectedUuid) {
    return UiIconButton(
      icon: CupertinoIcons.person_add,
      tooltip: '发起群聊',
      size: 36,
      iconSize: 20,
      color: const Color(0xFF344054),
      onTap: () => createGroupAndSwitchTo(
        context,
        ref,
        preselectedUuids: {preselectedUuid},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformUtils.isDesktop) return _buildContent(context);
    final active = ref.watch(activeConversationItemProvider);
    final human = ref.watch(selectedHumanDirectProvider);
    final group = ref.watch(selectedGroupProvider);
    return AttachmentPreviewHost(
      onVisibilityChanged: (open) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          WindowController.instance
              .setOverlayWidth(open ? 380 : 0, owner: 'preview');
        });
      },
      sessionKey:
          '${human?.conversationId ?? group?.conversationId ?? active?.conversationId ?? ''}:${widget.peerAccountUuid ?? ''}',
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    // 监听面板开关 → 调用 WindowController.setOverlayWidth 让窗口宽度跟随变化。
    // 用 post-frame callback 避免在 build 里同步触发 setSize 引起重入。
    ref.listen<bool>(chatHistoryPanelOpenProvider, (prev, next) {
      _panelOpen = next;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WindowController.instance
            .setOverlayWidth(next ? _historyPanelDesiredWidth : 0);
      });
    });
    // P2.1(ADR-0026):会话列表/通讯录选中的人↔人 WuKong direct → 三栏内渲染 WuKong 对话区。
    // 优先走「已选中会话」(按 channel 打开,不重调 /direct-rooms,P2.1 点 10)。
    final selfAvatar = ref.watch(accountInfoProvider).asData?.value?.avatar;
    final humanDirect = ref.watch(selectedHumanDirectProvider);
    if (humanDirect != null) {
      return _buildShell(
        rightPane: HumanDirectChatPane(
          key: ValueKey('hd-${humanDirect.conversationId}'),
          peerAccountUuid: humanDirect.peerAccountUuid,
          roomUuid: humanDirect.roomUuid,
          channelId: humanDirect.channelId,
          channelType: humanDirect.channelType,
          title: humanDirect.title,
          peerAvatarUrl: humanDirect.peerAvatar,
          peerDepartmentName: humanDirect.peerDepartmentName,
          peerEmail: humanDirect.peerEmail,
          peerCompanyName: humanDirect.peerCompanyName,
          selfAvatarUrl: selfAvatar,
          conversationUuid: humanDirect.conversationId,
          clearedAt: humanDirect.clearedAt,
          headerTrailing: humanDirect.peerAccountUuid.isEmpty
              ? null
              : _buildAddToGroupButton(humanDirect.peerAccountUuid),
        ),
        imPane: true,
      );
    }
    // P2.3a(ADR-0026):选中的 WuKong 群聊(kind=group)→ 三栏内渲染群 pane(按 channel type=2 打开)。
    final group = ref.watch(selectedGroupProvider);
    if (group != null) {
      return _buildShell(
        rightPane: GroupChatPane(
          key: ValueKey('grp-${group.conversationId}'),
          roomUuid: group.roomUuid,
          channelId: group.channelId,
          channelType: group.channelType,
          title: group.title,
          conversationUuid: group.conversationId,
          participants: group.participants,
          selfAvatarUrl: selfAvatar,
          clearedAt: group.clearedAt,
          canRenameGroup: group.canRenameGroup,
        ),
        imPane: true,
      );
    }
    // 兼容旧路由入口 ?direct=human&peer_account_uuid=(走 peer → /direct-rooms)。
    final peer = widget.peerAccountUuid?.trim() ?? '';
    if (widget.directKind == 'human' && peer.isNotEmpty) {
      return _buildShell(
        rightPane: HumanDirectChatPane(
          key: ValueKey('human-$peer'),
          peerAccountUuid: peer,
          title: widget.directTitle,
          selfAvatarUrl: selfAvatar,
          headerTrailing: _buildAddToGroupButton(peer),
        ),
        imPane: true,
      );
    }

    // 会话列表确定为空时，右侧展示预留引导，避免 PC 初次进入时主区域空白。
    final conversationsAsync = ref.watch(conversationsProvider);
    final conversations = conversationsAsync.asData?.value;
    if (conversations != null && conversations.isEmpty) {
      return _buildEmptyConversationsShell();
    }

    final title = ref.watch(chatConversationTitleProvider);
    final activeConversation = ref.watch(activeConversationItemProvider);
    final selectedAgent = ref.watch(selectedAgentOrFallbackProvider);
    final userAvatar = ref.watch(accountInfoProvider).asData?.value?.avatar;
    final content = ChatConversationContent(
      key: _contentKey,
      onOpenAttachment: (file) => previewChatAttachment(
          _contentKey.currentContext ?? context, file,
          ref: ref),
      onNotify: (message) => BotToast.showText(
        text: message,
        align: Alignment.center,
      ),
      userAvatarUrl: userAvatar,
    );

    return _buildShell(
      rightPane: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChatDetailHeader(
            title: title,
            agentDeleted: activeConversation?.agentDeleted ?? false,
            trailing: (selectedAgent?.agentId ?? '').isEmpty
                ? null
                : _buildAddToGroupButton(selectedAgent!.agentId),
          ),
          Expanded(
            child: DesktopDrop(
              onDropFiles: (files) =>
                  _contentKey.currentState?.insertDroppedFiles(files),
              child: content,
            ),
          ),
        ],
      ),
    );
  }

  /// 桌面三栏外壳：左侧"对话"侧栏 + 右侧主内容 + 可选「聊天历史」面板。
  /// rightPane 决定中间主区渲染什么（普通对话内容 / 特殊数字员工 H5）。
  Widget _buildShell({required Widget rightPane, bool imPane = false}) {
    return LayoutBuilder(builder: (context, constraints) {
      final totalW = constraints.maxWidth;
      final historyOpen = ref.watch(chatHistoryPanelOpenProvider);
      // 「聊天历史」外接面板宽度自适应:
      //   - 默认 300;
      //   - 窗口紧的时候压到 280,保证主对话区有 480px 内宽不至于不可用;
      //   - 算下来若给不出 280 给面板就关掉,避免布局崩成负宽。
      // 240 是左侧会话侧栏固定宽,minMain=480 是主对话区最低可用宽度。
      final double sidebarW = totalW >= 660 ? 240 : 0;
      const double minMainW = 480;
      double panelW = 0;
      if (historyOpen) {
        final avail = totalW - sidebarW - minMainW;
        if (avail >= 300) {
          panelW = 300;
        } else if (avail >= 280) {
          panelW = 280;
        } else {
          panelW = 0; // 太窄,这一帧不渲染,避免溢出;header 按钮仍是激活态。
        }
      }

      return Row(
        children: [
          if (sidebarW > 0)
            Container(
              width: sidebarW,
              decoration: const BoxDecoration(
                border: Border(
                  right: BorderSide(color: Color(0xFFE8EDF4), width: 0.8),
                ),
              ),
              child: const _DesktopConversationSidebar(),
            ),
          Expanded(child: rightPane),
          // IM pane(人↔人 / 群聊)自己渲染 ChatImHistoryPanel(数据来自 controller),
          // 这里不再叠 agent 的 ChatHistoryPanel(否则错数据 + 双面板)。
          if (panelW > 0 && !imPane) ChatHistoryPanel(width: panelW),
        ],
      );
    });
  }

  Widget _buildEmptyConversationsShell() {
    return Row(
      children: [
        Container(
          width: 240,
          decoration: const BoxDecoration(
            border: Border(
              right: BorderSide(color: Color(0xFFE8EDF4), width: 0.8),
            ),
          ),
          child: const _DesktopConversationSidebar(),
        ),
        const Expanded(child: _EmptyConversationsPlaceholder()),
      ],
    );
  }
}

/// PC 端「对话」列表为空时，替代正常右侧主区的预留。
/// 点击 CTA 跳数字员工页，让用户去挑一个 agent 开始第一次对话。
class _EmptyConversationsPlaceholder extends StatelessWidget {
  const _EmptyConversationsPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF7F8FA),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: const BoxDecoration(
              color: Color(0xFFEFF3FF),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(
              CupertinoIcons.chat_bubble_2,
              size: 40,
              color: Color(0xFF2563EB),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            '暂无对话',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1D2129),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '去数字员工页挑一位助手，开启一个新对话',
            style: TextStyle(fontSize: 13, color: Color(0xFF86909C)),
          ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () => context.go(RoutePaths.digitalEmployee),
            child: const Text('去数字员工'),
          ),
        ],
      ),
    );
  }
}

class _DesktopConversationSidebar extends ConsumerStatefulWidget {
  const _DesktopConversationSidebar();

  @override
  ConsumerState<_DesktopConversationSidebar> createState() =>
      _DesktopConversationSidebarState();
}

class _DesktopConversationSidebarState
    extends ConsumerState<_DesktopConversationSidebar>
    with ChatConversationActionsMixin<_DesktopConversationSidebar> {
  bool _didInitialSelect = false;
  final TextEditingController _searchController = TextEditingController();
  String _keyword = '';

  @override
  ValueChanged<String>? get onConversationTapped => null;

  @override
  void onBeforeSelection() => _clearSearch();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _clearSearch() {
    if (_keyword.isEmpty && _searchController.text.isEmpty) return;
    _searchController.clear();
    setState(() => _keyword = '');
  }

  @override
  Widget build(BuildContext context) {
    final chatAsync = ref.watch(chatProvider);
    final conversationsAsync = ref.watch(conversationsProvider);
    final conversations =
        conversationsAsync.asData?.value ?? const <ConversationItem>[];
    final selectedHumanDirect = ref.watch(selectedHumanDirectProvider);
    final selectedGroup = ref.watch(selectedGroupProvider);

    if (!_didInitialSelect &&
        !chatAsync.isLoading &&
        chatAsync.hasValue &&
        chatAsync.asData?.value.activeConversationId == null &&
        selectedHumanDirect == null &&
        selectedGroup == null &&
        conversations.isNotEmpty) {
      _didInitialSelect = true;
      final preferred = conversations.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        selectConversation(preferred);
      });
    }

    final selectedConversationId = resolveSidebarSelectedConversationId(
      highlightActive: true,
      selectedGroup: selectedGroup,
      selectedHumanDirect: selectedHumanDirect,
      activeConversationId: chatAsync.asData?.value.activeConversationId,
    );

    final listPanel = ConversationListPanel(
      padding: const EdgeInsets.all(4.0),
      selectedConversationId: selectedConversationId,
      conversations: conversations,
      showLoadingIndicator: false,
      loadingConversations: conversationsAsync.isLoading ||
          ref.watch(conversationsRefreshingProvider),
      emptyLabel: conversationsAsync.hasError ? '会话加载失败' : '暂无会话',
      onConversationSelected: selectConversation,
      menuCallbacks: ConversationMenuCallbacks(
        onTogglePin: togglePin,
        onToggleMute: toggleMute,
        onMarkRead: markConversationRead,
        onMarkUnread: markUnread,
        onHide: hideConversation,
        onRenameGroup: renameGroup,
      ),
    );

    final keyword = _keyword.trim();
    final searching = keyword.isNotEmpty;
    final digitalEmployeeMatches = searching
        ? conversations
            .where((item) =>
                digitalEmployeeConversationMatchesKeyword(item, keyword))
            .toList(growable: false)
        : const <ConversationItem>[];
    final groupMatches = searching
        ? conversations
            .where((item) =>
                item.isGroup && conversationMatchesKeyword(item, keyword))
            .toList(growable: false)
        : const <ConversationItem>[];
    final contactResults = searching
        ? ref.watch(chatSidebarContactSearchProvider(keyword))
        : const AsyncValue<List<ContactPerson>>.data(<ContactPerson>[]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConversationListHeader(
          controller: _searchController,
          onCreateGroup: createGroup,
          onSearchChanged: (value) => setState(() => _keyword = value),
          onClearSearch: _clearSearch,
        ),
        ConversationConnectionBanner(
            initialLoading: ref.watch(conversationsProvider).isLoading),
        Expanded(
          child: searching
              ? ConversationSearchResults(
                  contacts: contactResults,
                  digitalEmployees: digitalEmployeeMatches,
                  groups: groupMatches,
                  onContactSelected: openHumanContact,
                  onConversationSelected: selectConversation,
                )
              : LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(minHeight: constraints.maxHeight),
                      child: listPanel,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
