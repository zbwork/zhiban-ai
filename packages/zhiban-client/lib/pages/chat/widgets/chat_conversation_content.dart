import 'package:zhiban_client/services/local_runtime_api.dart';
import 'dart:async';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:zhiban_client/services/conversation_models.dart';
import 'local_approval_card.dart';
import 'local_agent_controls.dart';

import 'package:bot_toast/bot_toast.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhiban_client/emp/blocks/emp_blocks_view.dart'
    show EmpBlocksRespondHandler;
import 'package:zhiban_core/im/im_client.dart';
import 'package:zhiban_client/pages/apps/providers/apps_providers.dart';
import 'package:zhiban_client/pages/apps/services/apps_service.dart';
import 'package:zhiban_client/pages/apps/widgets/app_webview_container.dart';
import 'package:zhiban_client/pages/case_fee_payment/case_fee_payment.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/services/clipboard_image_paste.dart';
import 'package:zhiban_client/pages/chat/services/agent_conversation_launcher.dart';
import 'package:zhiban_client/pages/chat/services/open_employee_action.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_empty_state.dart';
import 'package:zhiban_client/pages/chat/widgets/chat_session_view.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/agent_skills_sheet.dart';
import 'package:zhiban_client/pages/chat/widgets/prompt_input/rich_prompt_controller.dart';
import 'package:zhiban_core/drive/drive_models.dart';
import 'package:zhiban_client/pages/drive/providers/drive_providers.dart';
import 'package:zhiban_client/pages/drive/widgets/drive_file_picker.dart';
import 'package:zhiban_client/pages/runtime_prewarm/models/prewarm_send_guard.dart';
import 'package:zhiban_client/pages/runtime_prewarm/providers/prewarm_providers.dart';
import 'package:zhiban_client/rtc/rtc_call_controller.dart';
import 'package:zhiban_client/rtc/rtc_client.dart';
import 'package:zhiban_client/utils/file_picker_utils.dart';

const int _kMaxAttachments = 5;

class ChatConversationContent extends ConsumerStatefulWidget {
  const ChatConversationContent({
    super.key,
    this.onOpenAttachment,
    this.onNotify,
    this.userAvatarUrl,
  });

  final ValueChanged<ChatFileItem>? onOpenAttachment;
  final ValueChanged<String>? onNotify;

  /// 当前登录用户头像 URL。空字符串/null 时显示默认头像。
  /// 由 host app（zhiban-app）从 [AccountInfoService] 拿到后注入。
  final String? userAvatarUrl;

  @override
  ConsumerState<ChatConversationContent> createState() =>
      ChatConversationContentState();
}

class ChatConversationContentState
    extends ConsumerState<ChatConversationContent> {
  final RichPromptController _controller = RichPromptController();
  final FocusNode _inputFocusNode = FocusNode();
  bool _recoveringLocalConversation = false;

  @override
  void dispose() {
    _controller.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  ChatFileType _localFileType(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const images = {'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'};
    const videos = {'mp4', 'mov', 'm4v', 'webm', 'avi', 'mkv'};
    if (images.contains(ext)) return ChatFileType.image;
    if (videos.contains(ext)) return ChatFileType.video;
    return ChatFileType.file;
  }

  int get _remainingAttachmentSlots =>
      (_kMaxAttachments - _controller.attachments.length)
          .clamp(0, _kMaxAttachments);

  void insertDroppedFiles(List<XFile> files) {
    if (ref.read(activeConversationItemProvider)?.agentDeleted == true) return;
    for (final f in files.take(_remainingAttachmentSlots)) {
      _insertLocalAttachment(f, _localFileType(f.name));
    }
  }

  void _insertLocalAttachment(XFile file, ChatFileType fileType) {
    final id = 'att-${DateTime.now().microsecondsSinceEpoch}';
    _controller.activateTrailingTextBlock();
    _controller.insertAttachment(RichPromptAttachment(
      id: id,
      fileName: file.name,
      fileType: fileType,
      localPath: file.path,
    ));
    unawaited(_uploadLocalAttachment(id, file, fileType));
  }

  Future<void> _uploadLocalAttachment(
    String id,
    XFile file,
    ChatFileType fileType,
  ) async {
    try {
      final size = await file.length();
      final item = ChatFileItem(
        fileName: file.name,
        fileType: fileType,
        filePath: file.path,
        sizeBytes: size,
      );
      final uploaded = await ref.read(chatServiceProvider).uploadFile(item);
      final fileUuid = (uploaded.driveFileUuid ?? uploaded.uuid ?? '').trim();
      _controller.updateAttachment(
        id,
        (old) => old.copyWith(
          status: RichAttachmentStatus.ready,
          progress: 100,
          block: ImMessageBlock(
            kind: fileType == ChatFileType.image
                ? ImMessageBlockKind.image
                : ImMessageBlockKind.file,
            url: uploaded.url,
            fileUuid: fileUuid,
            name: file.name,
            size: size,
          ),
        ),
      );
      refocusPromptInput(_inputFocusNode);
    } catch (e) {
      _controller.updateAttachment(
        id,
        (old) => old.copyWith(
          status: RichAttachmentStatus.failed,
          error: e.toString(),
        ),
      );
    }
  }

  void _insertDriveAttachment(DriveFile file) {
    final id = 'att-${DateTime.now().microsecondsSinceEpoch}';
    final type = file.mimeType.startsWith('image/')
        ? ChatFileType.image
        : _localFileType(file.name);
    _controller.activateTrailingTextBlock();
    _controller.insertAttachment(RichPromptAttachment(
      id: id,
      fileName: file.name,
      fileType: type),
    );
    unawaited(_uploadDriveAttachment(id, file, type));
  }

  Future<void> _uploadDriveAttachment(
    String id,
    DriveFile file,
    ChatFileType type,
  ) async {
    try {
      final preview =
          await ref.read(driveServiceProvider).previewUrl(fileUuid: file.uuid);
      _controller.updateAttachment(
        id,
        (old) => old.copyWith(
          status: RichAttachmentStatus.ready,
          progress: 100,
          block: ImMessageBlock(
            kind: type == ChatFileType.image
                ? ImMessageBlockKind.image
                : ImMessageBlockKind.file,
            url: preview.url,
            fileUuid: file.uuid,
            name: file.name,
            size: file.sizeBytes,
          ),
        ),
      );
      refocusPromptInput(_inputFocusNode);
    } catch (e) {
      _controller.updateAttachment(
        id,
        (old) => old.copyWith(
          status: RichAttachmentStatus.failed,
          error: e.toString(),
        ),
      );
    }
  }

  Future<void> _onPickAttachment(ChatAttachmentPickKind kind) async {
    List<XFile> files;
    switch (kind) {
      case ChatAttachmentPickKind.files:
        files = await pickChatFiles();
      case ChatAttachmentPickKind.images:
        files = await pickImageFiles();
      case ChatAttachmentPickKind.camera:
        final photo = await takePhotoFile();
        files = photo == null ? const [] : [photo];
    }
    if (files.isEmpty) return;
    for (final f in files.take(_remainingAttachmentSlots)) {
      _insertLocalAttachment(f, _localFileType(f.name));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatProvider, (previous, next) {
      final error = next.asData?.value.errorMessage;
      if (error != null &&
          error.startsWith('停止请求未确认') &&
          error != previous?.asData?.value.errorMessage) {
        BotToast.showText(text: error);
      }
    });
    final onOpenAttachment = widget.onOpenAttachment;
    final onNotify = widget.onNotify;
    final userAvatarUrl = widget.userAvatarUrl;
    final chatAsync = ref.watch(chatProvider);
    final agent = ref.watch(selectedAgentOrFallbackProvider);
    final activeConversation = ref.watch(activeConversationItemProvider);
    final incompatibleLocalRoom = agent?.executionLocus == 'local' &&
        activeConversation != null &&
        !activeConversation.isGroup &&
        !activeConversation.isHumanDirect &&
        (activeConversation.roomUuid ?? '').isNotEmpty;
    final composerEnabled = !(activeConversation?.agentDeleted ?? false);
    final remoteOnline = ref.watch(localDesktopOnlineProvider);
    final agentAvatarUrl = agent?.avatarUrl;

    return chatAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (error, _) => Center(child: Text('加载会话失败: $error')),
      data: (state) {
        final rtcController = ref.watch(rtcCallControllerProvider);
        final callTarget = _resolveAgentCallTarget(ref, state, agent);
        return ListenableBuilder(
          listenable: Listenable.merge([
            rtcController,
            LocalAgentService.instance,
            ConversationModels.instance
          ]),
          builder: (context, _) {
            final callEnabled = callTarget != null && !rtcController.busy;
            // F16 A1 · 通话中把 live 转写气泡拼到当前会话消息流尾部（按轮次排序，
            // partial 原地流式更新）；通话结束 controller 清空 live + ChatNotifier
            // reload canonical 历史，此处自然回落为纯持久消息（设计 §3.4 方案 C）。
            final liveMessages = _liveTranscriptMessages(rtcController, state);
            return ChatSessionView(
              runtimeControls: incompatibleLocalRoom
                  ? Row(children: [
                      const Flexible(child: Text('此会话暂不支持本地运行')),
                      TextButton(
                        onPressed: _recoveringLocalConversation
                            ? null
                            : () => _returnToLocalTextConversation(
                                agent!, state.activeConversationId!),
                        child: Text(
                            _recoveringLocalConversation ? '正在恢复…' : '返回文字对话'),
                      ),
                    ])
                  : agent != null &&
                          agent.hasConversationModels &&
                          (PlatformUtils.isDesktop ||
                              agent.executionLocus == 'local')
                      ? LocalAgentControls(
                          key: ValueKey(
                              'local:${state.activeConversationId}:${agent.agentId}'),
                          agent: agent,
                          conversation: state.activeConversationId ?? '')
                      : null,
              runtimeApprovals: agent?.executionLocus == 'local' &&
                      !incompatibleLocalRoom
                  ? LocalApprovalPanel(
                      showRequests: false,
                      showStatus: !PlatformUtils.isMobile,
                      key: ValueKey('approval:${state.activeConversationId}'),
                      conversation: state.activeConversationId ?? '')
                  : null,
              sendReady: incompatibleLocalRoom
                  ? false
                  : agent?.executionLocus == 'local'
                      ? (PlatformUtils.isDesktop
                              ? LocalAgentService.instance.online
                              : remoteOnline) &&
                          ConversationModels.instance
                              .state(agent!.agentId,
                                  state.activeConversationId ?? '')
                              .canAttemptSend
                      : !PlatformUtils.isDesktop ||
                          agent?.hasConversationModels != true ||
                          agent == null ||
                          ConversationModels.instance
                              .state(agent.agentId,
                                  state.activeConversationId ?? '')
                              .canAttemptSend,
              state: state,
              composerEnabled: composerEnabled,
              controller: _controller,
              focusNode: _inputFocusNode,
              extraTrailingMessages: liveMessages,
              emptyStateMessage:
                  agent == null ? null : digitalEmployeeWelcomeMessage(agent),
              onDraftChanged: (conversationId, draft) => ref
                  .read(chatProvider.notifier)
                  .saveComposerDraft(conversationId, draft),
              onPickAttachment: _onPickAttachment,
              onPasteImage: () async {
                final files = await readClipboardAttachmentsAsXFiles();
                if (files.isEmpty) return false;
                final slots = _remainingAttachmentSlots;
                if (slots <= 0) return false;
                for (final f in files.take(slots)) {
                  _insertLocalAttachment(f, _localFileType(f.name));
                }
                return true;
              },
              onPickFromDrive: () async {
                final picked = await showDriveFilePicker(context, ref);
                if (picked == null || picked.isEmpty) return;
                for (final f in picked.take(_remainingAttachmentSlots)) {
                  _insertDriveAttachment(f);
                }
              },
              onSend: (text, skillSlugs) => ref
                  .read(chatProvider.notifier)
                  .send(text, skillSlugs: skillSlugs),
              onSendBlocks: (text, skillSlugs, blocks) => ref
                  .read(chatProvider.notifier)
                  .send(text, skillSlugs: skillSlugs, blocks: blocks),
              sendGuard: () =>
                  !incompatibleLocalRoom &&
                  _guardRuntimeReadyForSend(ref, agent),
              onStop: () => ref.read(chatProvider.notifier).stop(),
              // ADR-0028 §4.9 — HITL 富组件 (approval / form / action) 提交回调集。
              // EmpBlocksView 4 条件 enable 通过后会调下面三条之一; 失败 toast 由
              // notifier 内部负责, 这里不重复弹。
              respondHandler: EmpBlocksRespondHandler(
                // type='approval' / 'approval_request' →
                //   response_kind='approval' + payload={decision, reason?}
                onApproval: ({
                  required String agentMessageUuid,
                  required String decision,
                  String? reason,
                }) =>
                    ref.read(chatProvider.notifier).respondToAgentMessage(
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
                // type='confirm' → response_kind='confirm' + payload={confirmed: bool}
                // (与 approval 完全不同的 payload 形态; 不能合并 — 后端 confirm 分支
                // 只读 `confirmed`, 不读 `decision`)。
                onConfirm: ({
                  required String agentMessageUuid,
                  required bool confirmed,
                }) =>
                    ref.read(chatProvider.notifier).respondToAgentMessage(
                  agentMessageUuid: agentMessageUuid,
                  responseKind: 'confirm',
                  responsePayload: {'confirmed': confirmed},
                ),
                onForm: ({
                  required String agentMessageUuid,
                  required Map<String, dynamic> fields,
                }) =>
                    ref.read(chatProvider.notifier).respondToAgentMessage(
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
                  required String fieldLabel,
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
                  final uploaded =
                      await ref.read(chatServiceProvider).uploadFile(item);
                  final fileUuid =
                      (uploaded.driveFileUuid ?? uploaded.uuid ?? '').trim();
                  if (fileUuid.isEmpty) {
                    throw StateError('文件上传成功但未返回 file_id');
                  }
                  return <String, dynamic>{
                    // 契约 §3.0a 规范键是 file_uuid; file_id 为历史键, 双写
                    // 过渡 (消费端已全部双收, 2026-07-21)。
                    'file_uuid': fileUuid,
                    'file_id': fileUuid,
                    'name': picked.name,
                    'size': size,
                    if ((picked.mimeType ?? '').trim().isNotEmpty)
                      'mime_type': picked.mimeType!.trim(),
                    if (uploaded.url.trim().isNotEmpty) 'url': uploaded.url,
                    if (fieldName.trim().isNotEmpty)
                      'field_name': fieldName.trim(),
                    if (fieldLabel.trim().isNotEmpty)
                      'field_label': fieldLabel.trim(),
                  };
                },
                onAction: ({
                  required String agentMessageUuid,
                  required String actionId,
                  Map<String, dynamic>? params,
                }) =>
                    ref.read(chatProvider.notifier).respondToAgentMessage(
                  agentMessageUuid: agentMessageUuid,
                  responseKind: 'action',
                  responsePayload: {
                    'action_id': actionId,
                    if (params != null) 'params': params,
                  },
                ),
                // suggestion chip（「猜你想问」追问引导）: 点击 = 发一条普通用户
                // 消息（气泡上屏 + 正常流式），不走 respond 回灌（2026-07-15
                // 交互修订——旧 action 形态点完按钮转圈干等整轮，体验差）。
                onSendText: (text) =>
                    ref.read(chatProvider.notifier).send(text),
                // 工单服务费「去支付」（F24 收款线上化，代账/注册）：本地打开支付页/弹窗。
                onOpenPayment: (actionId) =>
                    openCaseFeePayment(context, actionId),
                // 「找财税助手」等助手间衔接按钮（F26）：本地切到该数字员工聊天框。
                onOpenEmployee: (actionId) =>
                    openEmployeeConversationFromAction(context, ref, actionId),
              ),
              onLoadMoreHistory: () => ref
                  .read(chatProvider.notifier)
                  .loadMoreHistory(reportErrors: true),
              onLoadNewerHistory: () =>
                  ref.read(chatProvider.notifier).loadNewerHistory(),
              onJumpToLatest: () =>
                  ref.read(chatProvider.notifier).jumpToLatest(),
              onScrolledToBottom: () =>
                  ref.read(chatProvider.notifier).markActiveConversationRead(),
              onHighlightConsumed: () =>
                  ref.read(chatProvider.notifier).consumeHighlight(),
              onOpenAttachment: onOpenAttachment,
              onNotify: onNotify,
              userAvatarUrl: userAvatarUrl,
              agentAvatarUrl: agentAvatarUrl,
              agentSkills: agent?.skills ?? const <AgentSkillItem>[],
              agentApps: agent?.apps ?? const <AgentAppItem>[],
              supportsSkillBindings: agent?.supportsSkillBindings ?? false,
              onAddSkill: agent?.canManageSkills == true
                  ? () => unawaited(showAgentSkillPickerAndInstall(
                        context,
                        ref,
                        agent: agent!,
                      ))
                  : null,
              onLaunchApp: (app, onPresented) => _launchAgentApp(
                context: context,
                ref: ref,
                state: state,
                app: app,
                onPresented: onPresented,
              ),
              onVoiceCall: callTarget == null
                  ? null
                  : () => unawaited(_startAgentCall(
                        context: context,
                        ref: ref,
                        controller: rtcController,
                        target: callTarget,
                        agent: agent,
                        mediaKind: RtcMediaKind.audio,
                      )),
              voiceCallEnabled: callEnabled,
              voiceCallActive:
                  rtcController.hasActiveCall && !rtcController.isVideo,
              onVideoCall: callTarget == null
                  ? null
                  : () => unawaited(_startAgentCall(
                        context: context,
                        ref: ref,
                        controller: rtcController,
                        target: callTarget,
                        agent: agent,
                        mediaKind: RtcMediaKind.video,
                      )),
              videoCallEnabled: callEnabled,
              videoCallActive:
                  rtcController.hasActiveCall && rtcController.isVideo,
            );
          },
        );
      },
    );
  }

  Future<void> _returnToLocalTextConversation(
      AgentItem agent, String conversationId) async {
    setState(() => _recoveringLocalConversation = true);
    try {
      await openAgentDirectConversation(
        ref,
        agent: agent,
        expectedActiveConversationId: conversationId,
      );
    } catch (_) {
      if (mounted &&
          ref.read(chatProvider).asData?.value.activeConversationId ==
              conversationId) {
        _notify(context, '文字会话恢复失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _recoveringLocalConversation = false);
    }
  }

  _AgentCallTarget? _resolveAgentCallTarget(
    WidgetRef ref,
    ChatState state,
    AgentItem? agent,
  ) {
    if (ref.watch(selectedGroupProvider) != null ||
        ref.watch(selectedHumanDirectProvider) != null) {
      return null;
    }
    final conversationUuid = (state.activeConversationId ?? '').trim();
    if (conversationUuid.isEmpty) {
      return null;
    }
    final pendingAgentUuid = isPendingConversation(conversationUuid)
        ? agentUuidFromPending(conversationUuid).trim()
        : '';
    if (pendingAgentUuid.isNotEmpty) {
      final displayName =
          agent?.name.trim().isNotEmpty == true ? agent!.name.trim() : '数字员工';
      return _AgentCallTarget(
        roomUuid: '',
        agentUuid: pendingAgentUuid,
        conversationUuid: conversationUuid,
        displayName: displayName,
        avatarUrl: agent?.avatarUrl.trim() ?? '',
      );
    }
    if (conversationUuid.startsWith('pending:')) {
      return null;
    }
    final conversations = ref.watch(conversationsProvider).asData?.value ??
        const <ConversationItem>[];
    ConversationItem? active;
    for (final c in conversations) {
      if (c.conversationId == conversationUuid) {
        active = c;
        break;
      }
    }
    if (active == null || active.isHumanDirect || active.isGroup) {
      return null;
    }
    final roomUuid = (active.roomUuid ?? '').trim();
    final agentUuid = (active.agentId.trim().isNotEmpty
            ? active.agentId
            : agent?.agentId ?? '')
        .trim();
    if (agentUuid.isEmpty) {
      return null;
    }
    final displayName = active.title.trim().isNotEmpty
        ? active.title.trim()
        : (agent?.name.trim().isNotEmpty == true ? agent!.name.trim() : '数字员工');
    final avatarUrl = (active.agentAvatarUrl?.trim().isNotEmpty ?? false)
        ? active.agentAvatarUrl!.trim()
        : (agent?.avatarUrl.trim() ?? '');
    return _AgentCallTarget(
      roomUuid: roomUuid,
      agentUuid: agentUuid,
      conversationUuid: conversationUuid,
      displayName: displayName,
      avatarUrl: avatarUrl,
    );
  }

  Future<void> _startAgentCall({
    required BuildContext context,
    required WidgetRef ref,
    required RtcCallController controller,
    required _AgentCallTarget target,
    required AgentItem? agent,
    required RtcMediaKind mediaKind,
  }) async {
    if (agent?.executionLocus == 'local') {
      _notify(context, localAgentCallUnavailableMessage);
      return;
    }
    var roomUuid = target.roomUuid.trim();
    var conversationUuid = target.conversationUuid.trim();
    if (roomUuid.isEmpty) {
      try {
        final prepared = await ref
            .read(chatServiceProvider)
            .prepareAgentDirectWuKong(target.agentUuid);
        roomUuid = prepared.roomUuid.trim();
        conversationUuid = prepared.conversationUuid.trim().isNotEmpty
            ? prepared.conversationUuid.trim()
            : conversationUuid;
        if (roomUuid.isEmpty || conversationUuid.isEmpty) {
          if (!context.mounted) return;
          _notify(context, '通话准备失败，请稍后重试');
          return;
        }
        if (agent != null) {
          ref.read(conversationsProvider.notifier).upsertAgentConversation(
                agent: agent,
                conversationId: conversationUuid,
                roomUuid: roomUuid,
                wukongChannelId: prepared.wukongChannelId.trim().isNotEmpty
                    ? prepared.wukongChannelId.trim()
                    : null,
                wukongChannelType: prepared.wukongChannelType > 0
                    ? prepared.wukongChannelType
                    : null,
                kind: 'agent_direct',
              );
        } else {
          ref.read(conversationsProvider.notifier).patchConversationRuntime(
                conversationId: conversationUuid,
                roomUuid: roomUuid,
                wukongChannelId: prepared.wukongChannelId.trim().isNotEmpty
                    ? prepared.wukongChannelId.trim()
                    : null,
                wukongChannelType: prepared.wukongChannelType > 0
                    ? prepared.wukongChannelType
                    : null,
                kind: 'agent_direct',
              );
        }
        if (conversationUuid != target.conversationUuid) {
          await ref.read(chatProvider.notifier).selectConversation(
                conversationUuid
              );
        }
      } catch (_) {
        if (!context.mounted) return;
        _notify(context, '通话准备失败，请稍后重试');
        return;
      }
    }
    await controller.startOutgoing(
      roomUuid: roomUuid,
      agentUuid: target.agentUuid,
      conversationUuid: conversationUuid,
      peerName: target.displayName,
      peerAvatarUrl: target.avatarUrl,
      mediaKind: mediaKind,
    );
  }

  Future<void> _launchAgentApp({
    required BuildContext context,
    required WidgetRef ref,
    required ChatState state,
    required AgentAppItem app,
    required VoidCallback onPresented,
  }) async {
    final appUuid = app.id.trim();
    if (appUuid.isEmpty) {
      _notify(context, '应用暂不可用');
      return;
    }
    final conversationUuid = (state.activeConversationId ?? '').trim();
    if (conversationUuid.isEmpty || conversationUuid.startsWith('pending:')) {
      _notify(context, '请先进入有效会话后再打开应用');
      return;
    }
    final title = app.name.trim().isEmpty ? app.slug.trim() : app.name.trim();
    final svc = ref.read(appsBusServiceProvider);
    try {
      final result = await svc.launch(
        appUuid: appUuid,
        conversationUuid: conversationUuid,
        state: generateCsrfState(),
        nonce: generateNonce(),
      );
      if (!context.mounted) return;
      await openAppWebView(
        context,
        launchUrl: result.launchUrl,
        displayMode: result.displayMode,
        title: title.isEmpty ? '应用' : title,
        onPresented: onPresented,
      );
    } catch (e) {
      if (!context.mounted) return;
      _notify(context, '应用启动失败: $e');
    }
  }

  void _notify(BuildContext context, String message) {
    final handler = widget.onNotify;
    if (handler != null) {
      handler(message);
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message))
    );
  }
}

class _AgentCallTarget {
  const _AgentCallTarget({
    required this.roomUuid,
    required this.agentUuid,
    required this.conversationUuid,
    required this.displayName,
    this.avatarUrl = '',
  });

  final String roomUuid;
  final String agentUuid;
  final String conversationUuid;
  final String displayName;
  final String avatarUrl;
}

/// F16 A1 · 把通话中的 live 转写合成临时 [ChatMessage]，供拼接到消息流尾部。
///
/// - 仅当 live 归属会话 == 当前 active 会话时返回非空（别的会话不串显）。
/// - user 转写 → question 气泡；agent 回答 → answer 气泡（partial 用 loading 态：
///   正文流式增长 + 状态条，操作条隐藏；end 定稿转 success）。
/// - **与 canonical 精确去重**：服务端持久消息在通话中也会经 IM 刷新到达，定稿 live
///   泡的文本若已出现在已落库消息里则让位（避免双显）。文本不一致的极端 case 最迟
///   在通话结束 reload 时被替换（设计 §3.4 方案 C 接受此轻微 reflow）。
List<ChatMessage> _liveTranscriptMessages(
  RtcCallController controller,
  ChatState state,
) {
  final live = controller.liveTranscripts;
  if (live.isEmpty) return const <ChatMessage>[];
  final convUuid = controller.activeAgentConversationUuid?.trim();
  final activeConvUuid = state.activeConversationId?.trim();
  if (convUuid == null || convUuid.isEmpty || convUuid != activeConvUuid) {
    debugPrint(
        '[F16 RTC] hide live transcription conv=$convUuid active=$activeConvUuid count=${live.length}');
    return const <ChatMessage>[];
  }
  final canonicalTexts = <String>{};
  final msgs = state.messages;
  // 只比对尾部窗口：canonical 重复只可能出现在本通电话期间新落库的消息里。
  final from = msgs.length > 40 ? msgs.length - 40 : 0;
  for (var i = from; i < msgs.length; i++) {
    final t = msgs[i].content.trim();
    if (t.isNotEmpty) canonicalTexts.add(t);
  }
  final out = <ChatMessage>[];
  for (final t in live) {
    final liveText = t.text.trim();
    if (t.end && canonicalTexts.contains(liveText)) continue;
    // 2026-06-12 实测修复: agent 侧 RTM partial 可能半路丢失, live 气泡冻结成半句
    // (如 live="可以听到！请问" vs 落库="可以听到！请问有什么我可以帮助你的吗？"),
    // 上面的精确匹配永远不命中 → 半句气泡与正式消息同屏重复。落库文本是 live 文本
    // 的前缀延展时 (同一轮回答, canonical 只会更完整), 无条件让位 canonical。
    // 长度阈值 ≥4 防止开头一两个字误匹配到窗口内更早的旧消息。
    if (!t.interrupted &&
        !t.isUser &&
        liveText.length >= 4 &&
        canonicalTexts.any((c) => c.startsWith(liveText))) {
      continue;
    }
    out.add(ChatMessage(
      uuid: 'rtc-live-${t.roundId}-${t.isUser ? 'u' : 'a'}',
      role: t.isUser ? ChatRole.question : ChatRole.answer,
      content: t.text,
      reasoningContent: t.reasoning,
      status: t.isUser
          ? BubbleStatus.idle
          : (t.end || t.interrupted
              ? BubbleStatus.success
              : BubbleStatus.loading),
      streamStartedAt: t.isUser ? null : t.firstSeenAt,
      createdAt: t.firstSeenAt,
      metadata: {
        'rtc_live': true,
        if (t.interrupted) 'rtc_interrupted': true,
      },
    ));
  }
  return out;
}

/// 发送前预热守卫：仅当前数字员工 / 其运行环境仍在准备中时拦截发送。
///
/// 返回 false 时 [ChatSessionView] 取消本次发送，输入框内容与附件原样保留；
/// 这里负责 toast 提示并重新展示右下角预热进度浮层，让用户能看到还差什么。
/// 右下角是账号级全局任务列表；其他数字员工 / 运行环境任务不得误伤当前会话。
/// 任务失败、列表为空、或 ensure 尚未返回任务归属时不拦，交给后端正常返回。
bool _guardRuntimeReadyForSend(WidgetRef ref, AgentItem? agent) {
  if (agent == null) return true;
  if ((PlatformUtils.isDesktop || agent.executionLocus == 'local') &&
      agent.hasConversationModels) {
    final conversation =
        ref.read(chatProvider).asData?.value.activeConversationId ?? '';
    final model =
        ConversationModels.instance.state(agent.agentId, conversation);
    if (!model.canAttemptSend) {
      BotToast.showText(
          text: model.error.isEmpty ? '请等待模型列表加载并选择可用模型' : model.error);
      return false;
    }
  }
  if (agent.executionLocus == 'local') {
    if (!PlatformUtils.isDesktop) {
      if (ref.read(localDesktopOnlineProvider)) return true;
      BotToast.showText(text: ref.read(localDesktopStatusMessageProvider));
      return false;
    }
    final local = LocalAgentService.instance;
    if (local.online) return true;
    BotToast.showText(
        text: local.errorMessage.isEmpty
            ? '请等待这台电脑的运行组件连接后发送'
            : local.errorMessage);
    return false;
  }
  final prewarm = ref.read(prewarmControllerProvider);
  final reason = prewarmSendBlockReason(
    tasks: prewarm.tasks,
    digitalEmployeeUuid: agent.agentId,
    runtimeEnvironmentUuid: agent.runtimeEnvironmentUuid,
  );
  if (reason == null) return true;

  final String tip;
  if (reason == PrewarmSendBlockReason.runtimeEnvironment) {
    tip = '运行环境正在准备中，就绪后即可发送消息，请稍候';
  } else {
    tip = '数字员工「${agent.displayName}」正在加载中，就绪后即可发送消息，请稍候';
  }
  BotToast.showText(text: tip);
  ref.read(prewarmControllerProvider.notifier).reveal();
  return false;
}
