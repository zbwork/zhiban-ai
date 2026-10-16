import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';

import 'package:zhiban_client/emp/blocks/emp_blocks_view.dart'
    show EmpBlocksRespondHandler;
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'agent_capability_chip_row.dart';
import 'chat_conversation_layout.dart';
import 'chat_empty_state.dart';
import 'chat_theme.dart';
import 'messages/chat_message_list.dart';
import 'messages/chat_messages_shimmer.dart';
import 'package:zhiban_client/widgets/ui/chat_platform_widgets.dart';
import 'prompt_input/prompt_input.dart';
import 'prompt_input/rich_prompt_controller.dart';

typedef AgentAppLaunchHandler = FutureOr<void> Function(
  AgentAppItem app,
  VoidCallback onPresented
);

class ChatSessionView extends StatefulWidget {
  const ChatSessionView({
    super.key,
    required this.state,
    this.controller,
    this.focusNode,
    this.onPickAttachment,
    this.onPickFiles,
    this.onPickImages,
    this.onRemoveFile,
    required this.onPickFromDrive,
    required this.onSend,
    this.onSendBlocks,
    this.sendGuard,
    required this.onStop,
    required this.onLoadMoreHistory,
    this.onLoadNewerHistory,
    this.onJumpToLatest,
    this.onScrolledToBottom,
    this.onOpenAttachment,
    this.onNotify,
    this.onPasteImage,
    this.userAvatarUrl,
    this.agentAvatarUrl,
    this.agentSkills = const [],
    this.agentApps = const [],
    this.supportsSkillBindings = true,
    this.onAddSkill,
    this.onLaunchApp,
    this.onHighlightConsumed,
    this.onVoiceCall,
    this.voiceCallEnabled = false,
    this.voiceCallActive = false,
    this.onVideoCall,
    this.videoCallEnabled = false,
    this.videoCallActive = false,
    this.respondHandler,
    this.extraTrailingMessages = const [],
    this.onDraftChanged,
    this.emptyStateMessage,
    this.composerEnabled = true,
    this.runtimeControls,
    this.runtimeApprovals,
    this.sendReady = true,
  });

  final ChatState state;
  final RichPromptController? controller;
  final FocusNode? focusNode;
  final ValueChanged<ChatAttachmentPickKind>? onPickAttachment;

  /// 兼容会话隔离测试与旧调用点；新代码统一使用 [onPickAttachment]。
  final VoidCallback? onPickFiles;
  final VoidCallback? onPickImages;
  final ValueChanged<ChatFileItem>? onRemoveFile;
  final Future<bool> Function()? onPasteImage;
  // 弹出云盘文件选择器,把选中的云盘文件挂到输入框附件区。
  final VoidCallback onPickFromDrive;

  /// 发送消息的回调：携带文本与已选中的技能 slug 列表。
  /// 技能 slug 不会拼到文本里——后端在调 OpenClaw 时单独处理。
  final void Function(String text, List<String> skillSlugs) onSend;

  /// 新结构化 composer 回调：携带 mixed blocks。未提供时回退旧 [onSend]。
  final void Function(
    String text,
    List<String> skillSlugs,
    List<ImMessageBlock> blocks,
  )? onSendBlocks;

  /// 发送前守卫：返回 false 表示当前不可发送（如运行环境仍在预热），
  /// 本次发送整体取消，**输入框内容与附件原样保留**；提示由守卫实现方负责。
  final bool Function()? sendGuard;
  final VoidCallback onStop;
  final FutureOr<void> Function() onLoadMoreHistory;

  /// 向下加载更新消息（around 中段入场后向下滚时触发）。
  final VoidCallback? onLoadNewerHistory;

  /// 「一键跳到最新」：hasMoreNewer 场景下点底部箭头直接重置到首屏最新。
  final VoidCallback? onJumpToLatest;

  /// 用户点底部箭头主动滚到底时调用——上层用来给 active 会话清红点。
  final VoidCallback? onScrolledToBottom;

  final ValueChanged<ChatFileItem>? onOpenAttachment;
  final ValueChanged<String>? onNotify;

  /// 当前登录用户头像 URL（右侧气泡使用）。
  final String? userAvatarUrl;

  /// 当前对话所属智能体头像 URL（左侧气泡使用）。
  final String? agentAvatarUrl;

  /// 当前数字员工已绑定的技能 / 应用。这里展示的是 agent 维度摘要，不打
  /// conversation-bound 应用接口，避免空会话 / 旧会话进入页触发 404。
  final List<AgentSkillItem> agentSkills;
  final List<AgentAppItem> agentApps;
  final bool supportsSkillBindings;
  final VoidCallback? onAddSkill;
  final AgentAppLaunchHandler? onLaunchApp;

  /// 展示层追加在消息流尾部的临时消息（F16 RTC live 转写）。
  /// 纯渲染投影，不写回任何 session。
  final List<ChatMessage> extraTrailingMessages;

  /// 当前会话富输入草稿发生切换时，按会话保存到 workspace。
  final void Function(String conversationId, ChatComposerDraft draft)?
      onDraftChanged;

  /// 数字员工单聊的欢迎语；null 时沿用人类单聊/群聊的通用空态文案。
  final String? emptyStateMessage;

  /// false 时不构建输入、附件、快捷能力、通话及发送控件，改为只读说明条。
  final bool composerEnabled;
  final Widget? runtimeControls;
  final Widget? runtimeApprovals;
  final bool sendReady;

  /// 滚动 + 高亮 cron 消息动画完成后回调（清掉 ChatNotifier 上的标记）。
  final VoidCallback? onHighlightConsumed;
  final VoidCallback? onVoiceCall;
  final bool voiceCallEnabled;
  final bool voiceCallActive;
  final VoidCallback? onVideoCall;
  final bool videoCallEnabled;
  final bool videoCallActive;

  /// ADR-0028 §4.9 — HITL 富组件提交回调集; null 时 EmpBlocksView 保持只读。
  /// 由 chat_conversation_content 包装 ref.read(chatProvider.notifier).respondToAgentMessage(...)。
  final EmpBlocksRespondHandler? respondHandler;

  @override
  State<ChatSessionView> createState() => _ChatSessionViewState();
}

class _ChatSessionViewState extends State<ChatSessionView> {
  late final RichPromptController _fallbackController;
  late final FocusNode _fallbackFocusNode;
  RichPromptController get _controller =>
      widget.controller ?? _fallbackController;
  FocusNode get _inputFocusNode => widget.focusNode ?? _fallbackFocusNode;
  final GlobalKey<ChatMessageListState> _messageListKey =
      GlobalKey<ChatMessageListState>();
  final GlobalKey<PromptInputState> _promptInputKey =
      GlobalKey<PromptInputState>();
  final _mobilePromptInputKey = GlobalKey();

  SkillDraftInput? get _mobileSkillDraft =>
      _mobilePromptInputKey.currentState as SkillDraftInput?;
  final GlobalKey _promptKey = GlobalKey();
  double _promptInset = 120;
  String? _launchingAppId;
  String? _activeAppId;

  // The capability row is rendered in the same bottom overlay as the
  // composer. Keep a small visual gap so the last message never sits beneath
  // its rounded chips while the row is being measured or resized.
  double get _messageBottomInset =>
      _promptInset + (PlatformUtils.isMobile ? 12 : 16);

  @override
  void initState() {
    super.initState();
    _fallbackController = RichPromptController();
    _fallbackFocusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurePrompt();
      _restoreDraftFor(widget.state.activeConversationId);
    });
  }

  @override
  void dispose() {
    _fallbackController.dispose();
    _fallbackFocusNode.dispose();
    super.dispose();
  }

  void _pickAttachment(ChatAttachmentPickKind kind) {
    final unified = widget.onPickAttachment;
    if (unified != null) {
      unified(kind);
      return;
    }
    switch (kind) {
      case ChatAttachmentPickKind.images:
        (widget.onPickImages ?? widget.onPickFiles)?.call();
        return;
      case ChatAttachmentPickKind.files:
      case ChatAttachmentPickKind.camera:
        widget.onPickFiles?.call();
        return;
    }
  }

  @override
  void didUpdateWidget(covariant ChatSessionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.state.activeConversationId;
    final newId = widget.state.activeConversationId;
    if (oldWidget.composerEnabled && !widget.composerEnabled) {
      _inputFocusNode.unfocus();
    }
    if (oldId != newId) {
      final isRekey = oldId != null &&
          newId != null &&
          widget.state.canonicalKey(oldId) == widget.state.canonicalKey(newId);
      if (!isRekey) {
        if (oldId != null) _saveDraftFor(oldId);
        final targetId = newId;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || widget.state.activeConversationId != targetId) return;
          _restoreDraftFor(targetId);
        });
      }
    }
    if (oldWidget.state.isSending != widget.state.isSending ||
        oldWidget.state.isLoadingMessages != widget.state.isLoadingMessages ||
        oldId != newId ||
        oldWidget.agentSkills.length != widget.agentSkills.length ||
        oldWidget.agentApps.length != widget.agentApps.length) {
      _measurePrompt();
    }
  }

  @override
  void deactivate() {
    final id = widget.state.activeConversationId;
    if (id != null) _saveDraftFor(id);
    super.deactivate();
  }

  List<({String slug, String name})> _currentSelectedSkills() {
    return _promptInputKey.currentState?.selectedSkills ??
        _mobileSkillDraft?.selectedSkills ??
        const <({String slug, String name})>[];
  }

  void _saveDraftFor(String conversationId) {
    final onDraftChanged = widget.onDraftChanged;
    if (onDraftChanged == null) return;
    final payload = _controller.snapshotDraft();
    final skills = _currentSelectedSkills();
    final draft = (!payload.hasContent && skills.isEmpty)
        ? ChatComposerDraft.empty
        : ChatComposerDraft(
            revision: ChatDraftRevisions.next(),
            text: _controller.textWithoutAttachmentTokens,
            hasContent: payload.hasContent,
            selectedSkills: skills,
            composer: payload,
          );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        onDraftChanged(conversationId, draft);
      } catch (_) {
        // 页面已销毁时不再写 provider。
      }
    });
  }

  void _restoreDraftFor(String? conversationId) {
    if (!mounted) return;
    final draft = conversationId == null
        ? ChatComposerDraft.empty
        : widget.state.sessionOf(conversationId)?.draft ??
            ChatComposerDraft.empty;
    final payload = draft.composer;
    _controller.restoreDraft(
      payload is RichComposerDraftPayload ? payload : null,
    );
    _promptInputKey.currentState?.restoreSelectedSkills(draft.selectedSkills);
    _mobileSkillDraft?.restoreSelectedSkills(draft.selectedSkills);
  }

  void _measurePrompt() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _promptKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final h = box.size.height;
      if ((h - _promptInset).abs() > 0.5) {
        final wasAtBottom = _messageListKey.currentState?.isNearBottom ?? false;
        _messageListKey.currentState?.resetLastMessageMinHeight();
        setState(() => _promptInset = h);
        if (wasAtBottom) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _messageListKey.currentState?.scrollToBottom();
          });
        }
      }
    });
  }

  void _sendPrompt(String text, {List<String> skillSlugs = const []}) {
    if (!widget.composerEnabled) return;
    final blocks = _withSkillBlocks(_controller.toMixedBlocks(), skillSlugs);
    final summary = RichPromptController.summaryOfBlocks(blocks);
    final plain = _controller.textWithoutAttachmentTokens;
    final hasReadyPending = _controller.attachments.any((a) => !a.isUploading);
    if (summary.isEmpty && !hasReadyPending) return;
    // 守卫拦截（如运行环境预热中）：直接取消本次发送，不清输入框不发请求。
    if (widget.sendGuard?.call() == false) return;
    _inputFocusNode.unfocus();
    _messageListKey.currentState?.resetLastMessageMinHeight();
    final sendText = plain.isNotEmpty ? plain : summary;
    final onSendBlocks = widget.onSendBlocks;
    if (onSendBlocks != null) {
      onSendBlocks(sendText, skillSlugs, blocks);
    } else {
      widget.onSend(sendText, skillSlugs);
    }
    _controller.clearRich();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _messageListKey.currentState?.scrollToBottom(animated: true);
    });
  }

  List<ImMessageBlock> _withSkillBlocks(
    List<ImMessageBlock> blocks,
    List<String> skillSlugs,
  ) {
    if (skillSlugs.isEmpty) return blocks;
    final seen = <String>{
      for (final b in blocks)
        if (b.isSkill && b.skillSlug.trim().isNotEmpty) b.skillSlug.trim(),
    };
    final skillBySlug = {
      for (final s in widget.agentSkills)
        if (s.slug.trim().isNotEmpty) s.slug.trim(): s,
    };
    final skillBlocks = <ImMessageBlock>[];
    for (final raw in skillSlugs) {
      final slug = raw.trim();
      if (slug.isEmpty || seen.contains(slug)) continue;
      seen.add(slug);
      final item = skillBySlug[slug];
      final name = item == null
          ? ''
          : (item.skillName.trim().isEmpty
              ? item.slug.trim()
              : item.skillName.trim());
      skillBlocks.add(ImMessageBlock(
        kind: ImMessageBlockKind.skill,
        skillSlug: slug,
        name: name,
      ));
    }
    if (skillBlocks.isEmpty) return blocks;
    return [...skillBlocks, ...blocks];
  }

  void _selectSkill(AgentSkillItem skill) {
    final label = skill.skillName.trim().isEmpty
        ? skill.slug.trim()
        : skill.skillName.trim();
    _promptInputKey.currentState?.addSelectedSkill(
      slug: skill.slug,
      name: label,
    );
    _mobileSkillDraft?.addSelectedSkill(
      slug: skill.slug,
      name: label
    );
  }

  void _selectApp(AgentAppItem app) {
    unawaited(_launchSelectedApp(app));
  }

  Future<void> _launchSelectedApp(AgentAppItem app) async {
    if (_launchingAppId != null || _activeAppId != null) return;
    final launcher = widget.onLaunchApp;
    if (launcher == null) {
      widget.onNotify?.call('当前应用暂不可用');
      return;
    }
    setState(() => _launchingAppId = app.id);
    var presented = false;
    void onPresented() {
      if (presented || !mounted || _launchingAppId != app.id) return;
      presented = true;
      setState(() {
        _launchingAppId = null;
        _activeAppId = app.id;
      });
    }

    try {
      await launcher(app, onPresented);
    } catch (error) {
      widget.onNotify?.call('应用启动失败: $error');
    } finally {
      if (mounted) {
        setState(() {
          _launchingAppId = null;
          _activeAppId = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayMessages = [
      ...widget.state.messages,
      ...widget.extraTrailingMessages,
    ];
    final skillIconUrls = <String, String>{
      for (final skill in widget.agentSkills)
        if (skill.slug.trim().isNotEmpty)
          skill.slug.trim(): skill.iconUrl.trim(),
    };
    final disabledComposer =
        widget.composerEnabled ? null : const _DeletedAgentReadOnlyComposer();
    return ColoredBox(
      color: ChatTheme.pageBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 气泡最大宽度按扣除列表留白后的消息区域计算(移动端再乘 90% 比例,
                // 避免长消息把气泡撑满整行宽度)。
                final w = constraints.maxWidth;
                final maxBubbleWidth =
                    ChatConversationLayout.maxBubbleWidthForContainer(w);
                return Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.bottomCenter,
                  children: [
                    Positioned.fill(
                      child: widget.state.isLoadingMessages &&
                              displayMessages.isEmpty
                          ? DeferredChatMessagesShimmer(
                              bottomContentInset: _messageBottomInset,
                            )
                          : displayMessages.isEmpty
                              ? ChatEmptyState(
                                  bottomInset: _messageBottomInset,
                                  message: widget.emptyStateMessage ??
                                      '暂无消息，开始新的对话吧',
                                )
                              : ChatMessageList(
                                  key: _messageListKey,
                                  activeConversationId:
                                      widget.state.activeConversationId,
                                  messages: displayMessages,
                                  hasMoreHistory: widget.state.hasMoreHistory,
                                  isLoadingHistory:
                                      widget.state.isLoadingHistory,
                                  isSending: widget.state.isSending,
                                  maxBubbleWidth: maxBubbleWidth,
                                  bottomContentInset: _messageBottomInset,
                                  onLoadMoreHistory: widget.onLoadMoreHistory,
                                  onLoadNewerHistory: widget.onLoadNewerHistory,
                                  hasMoreNewer: widget.state.hasMoreNewer,
                                  isLoadingNewer: widget.state.isLoadingNewer,
                                  onScrolledToBottom: widget.onScrolledToBottom,
                                  onJumpToLatest: widget.onJumpToLatest,
                                  onOpenAttachment: widget.onOpenAttachment,
                                  onStop: widget.onStop,
                                  userAvatarUrl: widget.userAvatarUrl,
                                  agentAvatarUrl: widget.agentAvatarUrl,
                                  skillIconUrls: skillIconUrls,
                                  highlightMessageUuid:
                                      widget.state.highlightMessageUuid,
                                  highlightToken: widget.state.highlightToken,
                                  onHighlightConsumed:
                                      widget.onHighlightConsumed,
                                  respondHandler: widget.composerEnabled
                                      ? widget.respondHandler
                                      : null,
                                ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child:
                          NotificationListener<SizeChangedLayoutNotification>(
                        onNotification: (n) {
                          _measurePrompt();
                          return true;
                        },
                        child: SizeChangedLayoutNotifier(
                          child: KeyedSubtree(
                            key: _promptKey,
                            child: disabledComposer ??
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (widget.runtimeApprovals != null)
                                      widget.runtimeApprovals!,
                                    AgentCapabilityChipRow(
                                      leading: PlatformUtils.isMobile
                                          ? widget.runtimeControls
                                          : null,
                                      skills: widget.agentSkills,
                                      apps: widget.agentApps,
                                      supportsSkillBindings:
                                          widget.supportsSkillBindings,
                                      onAddSkill: widget.onAddSkill,
                                      onSelectSkill: _selectSkill,
                                      onSelectApp: _selectApp,
                                      launchingAppId: _launchingAppId,
                                      appLaunchLocked:
                                          _launchingAppId != null ||
                                              _activeAppId != null,
                                    ),
                                    if (PlatformUtils.isMobile)
                                      ChatPlatformWidgets.of(context)
                                          .promptInput(
                                        sendReady: widget.sendReady,
                                        key: _mobilePromptInputKey,
                                        enabled: widget.composerEnabled,
                                        focusNode: _inputFocusNode,
                                        controller: _controller,
                                        showSkillButton:
                                            widget.supportsSkillBindings,
                                        conversationUuid:
                                            widget.state.activeConversationId ??
                                                '',
                                        onPickAttachment: _pickAttachment,
                                        onPickFromDrive: widget.onPickFromDrive,
                                        isSending: widget.state.isSending,
                                        onSend: (skillSlugs) {
                                          _sendPrompt(
                                            _controller.text,
                                            skillSlugs: skillSlugs,
                                          );
                                        },
                                        onStop: widget.onStop,
                                        onNotify: widget.onNotify,
                                        onVoiceCall: widget.onVoiceCall,
                                        voiceCallEnabled:
                                            widget.voiceCallEnabled,
                                        voiceCallActive: widget.voiceCallActive,
                                        onVideoCall: widget.onVideoCall,
                                        videoCallEnabled:
                                            widget.videoCallEnabled,
                                        videoCallActive: widget.videoCallActive,
                                        allowAttachmentOnlySend: true,
                                        skillIconUrls: skillIconUrls,
                                      )
                                    else
                                      PromptInput(
                                        runtimeControls: widget.runtimeControls,
                                        sendReady: widget.sendReady,
                                        key: _promptInputKey,
                                        enabled: widget.composerEnabled,
                                        focusNode: _inputFocusNode,
                                        controller: _controller,
                                        conversationUuid:
                                            widget.state.activeConversationId ??
                                                '',
                                        onPickAttachment: _pickAttachment,
                                        onPasteImage: widget.onPasteImage,
                                        onPickFromDrive: widget.onPickFromDrive,
                                        isSending: widget.state.isSending,
                                        onSend: (skillSlugs) {
                                          _sendPrompt(
                                            _controller.text,
                                            skillSlugs: skillSlugs,
                                          );
                                        },
                                        onStop: widget.onStop,
                                        onNotify: widget.onNotify,
                                        onVoiceCall: widget.onVoiceCall,
                                        voiceCallEnabled:
                                            widget.voiceCallEnabled,
                                        voiceCallActive: widget.voiceCallActive,
                                        onVideoCall: widget.onVideoCall,
                                        videoCallEnabled:
                                            widget.videoCallEnabled,
                                        videoCallActive: widget.videoCallActive,
                                        allowAttachmentOnlySend: true,
                                        skillIconUrls: skillIconUrls,
                                      ),
                                  ],
                                ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DeletedAgentReadOnlyComposer extends StatelessWidget {
  const _DeletedAgentReadOnlyComposer();

  static const message = '该数字员工已删除，无法继续发送消息';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = colors.onSurfaceVariant.withValues(alpha: 0.62);
    final safeBottom =
        PlatformUtils.isMobile ? MediaQuery.viewPaddingOf(context).bottom : 0.0;
    return Semantics(
      readOnly: true,
      label: message,
      child: Container(
        height: (PlatformUtils.isMobile ? 56 : 72) + safeBottom,
        padding: EdgeInsets.fromLTRB(16, 0, 16, safeBottom),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(
            top: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.65),
              width: 0.8,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(CupertinoIcons.info_circle, size: 16, color: muted),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: muted,
                  fontSize: PlatformUtils.isMobile ? 13 : 14,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
