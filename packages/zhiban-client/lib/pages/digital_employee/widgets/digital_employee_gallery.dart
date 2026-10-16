import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_client/utils/url_utils.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_pull_to_refresh.dart';

import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_client/pages/chat/widgets/agent_capability_bindings.dart';
import 'package:zhiban_client/pages/digital_employee/providers/digital_employee_providers.dart';
import 'package:zhiban_client/pages/digital_employee/services/digital_employee_service.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/agent_card.dart';
import 'package:zhiban_client/pages/digital_employee/widgets/agent_detail_content.dart';
import 'package:zhiban_client/pages/runtime_prewarm/providers/prewarm_providers.dart';

/// 知办AI 数字员工画廊。
///
/// 卡片保持轻量白底，只展示后端真实返回的字段，避免空字段预留把卡片撑高。
class OpenClawDigitalEmployeeGallery extends ConsumerStatefulWidget {
  const OpenClawDigitalEmployeeGallery({
    super.key,
    required this.requestCreateAgentDraft,
    required this.requestEditAgentDraft,
    required this.showToast,
    required this.onOpenConversation,
    this.mobile = false,
    this.mobileFilterEnabled = true,
    this.filterTrailing,
  });

  final Future<CreateAgentDraft?> Function(BuildContext context)
      requestCreateAgentDraft;
  final Future<CreateAgentDraft?> Function(
    BuildContext context,
    AgentItem agent,
  ) requestEditAgentDraft;
  final void Function(String message) showToast;
  final Future<void> Function(String conversationId, AgentItem agent)
      onOpenConversation;
  final bool mobile;

  /// 关闭时移动端不显示分类 Tab，并始终展示当前目录响应的全部来源。
  final bool mobileFilterEnabled;

  /// 桌面端过滤 tab 行右侧的操作区（搜索框 + 新建按钮），与 tab 同一行。
  final Widget? filterTrailing;

  @override
  OpenClawDigitalEmployeeGalleryState createState() =>
      OpenClawDigitalEmployeeGalleryState();
}

class OpenClawDigitalEmployeeGalleryState
    extends ConsumerState<OpenClawDigitalEmployeeGallery> {
  static const int _mobilePageSize = 20;
  final RefreshController _refreshController = RefreshController();
  int _mobileVisibleCount = _mobilePageSize;

  @override
  void dispose() {
    _refreshController.dispose();
    super.dispose();
  }

  Future<void> createAgent() => _createAgent();

  int _resolveMobileVisibleCount(int total) {
    if (_mobileVisibleCount < 0) return 0;
    return _mobileVisibleCount > total ? total : _mobileVisibleCount;
  }

  Future<void> _createAgent() async {
    final draft = await widget.requestCreateAgentDraft(context);
    if (draft == null) return;
    if (!mounted) return;
    final closeLoading = BotToast.showLoading();
    try {
      final created = await ref.read(chatServiceProvider).createAgent(
            name: draft.name,
            description: draft.description,
            internalDescription: draft.internalDescription,
            welcomeMsg: draft.welcomeMsg,
            systemPrompt: draft.systemPrompt,
            tags: draft.tags,
            modelPrimary: draft.modelPrimary,
            modelSource: draft.modelSource,
            modelServiceEndpointType: draft.modelServiceEndpointType,
            modelServiceBaseUrl: draft.modelServiceBaseUrl,
            modelServiceModelId: draft.modelServiceModelId,
            modelServiceApiKey: draft.modelServiceApiKey,
            visibility: draft.visibility,
            status: draft.status,
            runtimeEnvironmentUuid: draft.runtimeEnvironmentUuid,
            executionLocus: draft.executionLocus,
            localEngine: draft.localEngine,
            agentKey: draft.agentKey,
            allowInternetAccess: draft.allowInternetAccess,
            contactEnabled: draft.contactEnabled,
            allowInviteToGroup: draft.allowInviteToGroup,
            avatarUrl: draft.avatarUrl,
            position: draft.position,
            positionLabel: draft.positionLabel,
            appUuids: draft.appUuids,
            appLabels: draft.appLabels,
            knowledgeBaseUuids: draft.knowledgeBaseUuids,
            knowledgeBaseLabels: draft.knowledgeBaseLabels,
          );
      final skillError = await _replaceCapabilityBindings(
        agentId: created.agentId,
        draft: draft,
      );
      final visibleAgent = await _loadAgentDetailForDisplay(
        created.agentId,
        fallback: created,
        draft: draft,
      );
      final catalogAgent = await _waitForCatalogAgent(
        created.agentId,
        fallback: visibleAgent,
        draft: draft,
      );
      final displayAgent = catalogAgent ?? visibleAgent;
      if (!mounted) return;
      ref.read(digitalEmployeeFilterProvider.notifier).state =
          DigitalEmployeeCatalogFilter.all;
      ref.read(agentsProvider.notifier).upsertAgent(displayAgent);
      ref
          .read(digitalEmployeeCatalogProvider.notifier)
          .upsertPersonalAgent(displayAgent);
      unawaited(
        ref.read(digitalEmployeeCatalogProvider.notifier).refresh(
              preservePersonalAgent: displayAgent,
              keepPreviousOnError: true,
            ),
      );
      final shouldSyncCloudRuntime = _shouldSyncCloudRuntime(displayAgent);
      if (shouldSyncCloudRuntime) {
        await _ensureRuntimeNow();
      }
      if (skillError == null) {
        widget.showToast(
          displayAgent.executionLocus == 'local'
              ? '已创建 ${displayAgent.displayName}，可在这台电脑使用'
              : shouldSyncCloudRuntime
                  ? '已创建 ${displayAgent.displayName}，正在准备运行环境'
                  : '已创建 ${displayAgent.displayName}',
        );
      } else {
        widget.showToast('已创建 ${displayAgent.displayName}，但能力装配失败：$skillError');
      }
    } catch (error) {
      widget.showToast('创建智能体失败：$error');
    } finally {
      closeLoading();
    }
  }

  Future<void> _ensureRuntimeNow() async {
    try {
      await ref.read(prewarmControllerProvider.notifier).ensureNow();
    } catch (_) {}
  }

  bool _shouldSyncCloudRuntime(AgentItem agent) {
    return agent.executionLocus != 'local' &&
        ref.read(cloudRuntimePrewarmEnabledProvider);
  }

  /// 一次性把技能 / 应用 / 知识库三类能力真绑定到后端。实现与通讯录入口
  /// 共用 [replaceAgentCapabilityBindings]，保证两个编辑入口行为一致。
  Future<Object?> _replaceCapabilityBindings({
    required String agentId,
    required CreateAgentDraft draft,
  }) {
    return replaceAgentCapabilityBindings(ref, agentId: agentId, draft: draft);
  }

  Future<void> _editAgent(AgentItem agent) async {
    // 打开编辑框前要回读 GET /agents/{uuid}（契约要求），期间给 loading 反馈。
    final closeDetailLoading = BotToast.showLoading();
    final AgentItem editableAgent;
    try {
      editableAgent = await _loadAgentDetailForDisplay(
        agent.agentId,
        fallback: agent,
      );
    } finally {
      closeDetailLoading();
    }
    if (!mounted) return;
    final draft = await widget.requestEditAgentDraft(context, editableAgent);
    if (draft == null) return;
    if (draft.deleteRequested) {
      await _deleteAgent(agent);
      return;
    }
    if (!mounted) return;
    // 保存期间全程 loading（与创建流程一致）：更新 + 能力绑定 + 详情回读
    // 是多个串行请求，没有反馈会让用户以为没点上。
    final closeLoading = BotToast.showLoading();
    try {
      final updated = await ref.read(chatServiceProvider).updateAgent(
            agentId: agent.agentId,
            name: draft.name,
            description: draft.description,
            internalDescription: draft.internalDescription,
            welcomeMsg: draft.welcomeMsg,
            systemPrompt: draft.systemPrompt,
            tags: draft.tags,
            visibility: draft.visibility,
            status: draft.status,
            runtimeEnvironmentUuid: draft.runtimeEnvironmentUuid,
            executionLocus: draft.executionLocus,
            localEngine: draft.localEngine,
            agentKey: draft.agentKey,
            allowInternetAccess: draft.allowInternetAccess,
            contactEnabled: draft.contactEnabled,
            allowInviteToGroup: draft.allowInviteToGroup,
            avatarUrl: draft.avatarUrl,
            position: draft.position,
            positionLabel: draft.positionLabel,
            appUuids: draft.appUuids,
            appLabels: draft.appLabels,
            knowledgeBaseUuids: draft.knowledgeBaseUuids,
            knowledgeBaseLabels: draft.knowledgeBaseLabels,
          );
      final skillError = await _replaceCapabilityBindings(
        agentId: agent.agentId,
        draft: draft,
      );
      final visibleAgent = await _loadAgentDetailForDisplay(
        updated.agentId,
        fallback: updated,
        draft: draft,
      );

      // 头像换图时，cached_network_image 是按 URL 做 key 缓存的；
      // 如果旧 URL 还在缓存里，下一次重新渲染同一个 AgentAvatar 时会
      // 命中缓存继续画"老头像"。这里把新旧两个 URL 都从内存 / 磁盘
      // 缓存里清掉，强制 CachedNetworkImage 走一次新的网络请求。
      final oldUrl = agent.avatarUrl.trim();
      final newUrl = visibleAgent.avatarUrl.trim();
      if (oldUrl.isNotEmpty && oldUrl != newUrl) {
        await CachedNetworkImage.evictFromCache(oldUrl);
        await CachedNetworkImage.evictFromCache(_avatarCacheKey(oldUrl));
      }
      if (newUrl.isNotEmpty) {
        await CachedNetworkImage.evictFromCache(newUrl);
        await CachedNetworkImage.evictFromCache(_avatarCacheKey(newUrl));
      }

      // 直接把 updateAgent 返回的 agent 合并进列表里（不依赖
      // 后端 listAgents 的"最终一致性"），保证画廊立刻显示新头像 / 新名称。
      ref.read(agentsProvider.notifier).upsertAgent(visibleAgent);
      ref
          .read(digitalEmployeeCatalogProvider.notifier)
          .upsertPersonalAgent(visibleAgent);
      // 仍然 invalidate 一下，让后台跑一次 listAgents 做兜底校对。
      ref.invalidate(agentsProvider);
      unawaited(
        ref.read(digitalEmployeeCatalogProvider.notifier).refresh(
              preservePersonalAgent: visibleAgent,
              keepPreviousOnError: true,
            ),
      );
      final currentSelected = ref.read(selectedAgentProvider).asData?.value;
      if (currentSelected?.agentId == visibleAgent.agentId) {
        ref.read(selectedAgentProvider.notifier).refreshCurrent(visibleAgent);
      }
      // 左侧会话列表里每条 row 的头像 / 名字字段（agentAvatarUrl /
      // agentName）是 ai-office `ListConversations` 里 SQL JOIN 出来的
      // 快照，不会跟着 agentsProvider 自动联动。改完档案要主动 refresh
      // 一次会话列表，否则左边那条小哈一直是老头像（截图里指出的现象）。
      try {
        await ref.read(conversationsProvider.notifier).refresh();
      } catch (_) {}
      final shouldSyncCloudRuntime = _shouldSyncCloudRuntime(visibleAgent);
      if (shouldSyncCloudRuntime) await _ensureRuntimeNow();
      if (skillError == null) {
        widget.showToast(shouldSyncCloudRuntime
            ? '已更新 ${visibleAgent.displayName}，正在同步运行环境'
            : '已更新 ${visibleAgent.displayName}');
      } else {
        widget.showToast('已更新 ${visibleAgent.displayName}，但能力装配失败：$skillError');
      }
    } catch (error) {
      widget.showToast('更新智能体失败：$error');
    } finally {
      closeLoading();
    }
  }

  Future<AgentItem> _loadAgentDetailForDisplay(
    String agentId, {
    required AgentItem fallback,
    CreateAgentDraft? draft,
  }) async {
    try {
      final detailed = await ref.read(chatServiceProvider).getAgent(agentId);
      return _mergeAgentDisplayData(detailed, fallback: fallback, draft: draft);
    } catch (_) {
      return _mergeAgentDisplayData(fallback, fallback: fallback, draft: draft);
    }
  }

  Future<AgentItem?> _waitForCatalogAgent(
    String agentId, {
    required AgentItem fallback,
    CreateAgentDraft? draft,
  }) async {
    const timeout = Duration(seconds: 5);
    const interval = Duration(milliseconds: 350);
    final deadline = DateTime.now().add(timeout);
    while (mounted && DateTime.now().isBefore(deadline)) {
      try {
        final keyword = ref.read(digitalEmployeeSearchProvider);
        final catalog = await ref
            .read(digitalEmployeeServiceProvider)
            .listCatalog(keyword: keyword);
        final found = _findCatalogAgent(catalog, agentId);
        if (found != null) {
          // Contacts carries display data only; the management detail is authoritative.
          final merged = _mergeAgentDisplayData(
            fallback,
            fallback: found,
            draft: draft,
          );
          ref
              .read(digitalEmployeeCatalogProvider.notifier)
              .upsertPersonalAgent(merged);
          return merged;
        }
      } catch (_) {}
      await Future<void>.delayed(interval);
    }
    return null;
  }

  AgentItem? _findCatalogAgent(DigitalEmployeeCatalog catalog, String agentId) {
    for (final item in catalog.all) {
      if (item.agent.agentId == agentId) {
        return item.agent;
      }
    }
    return null;
  }

  String _avatarCacheKey(String url) {
    final value = url.trim();
    if (value.startsWith('/message-files/')) {
      return apiImageResolveUrl(value);
    }
    return resolveAgentAvatarUrl(value);
  }

  AgentItem _mergeAgentDisplayData(
    AgentItem agent, {
    required AgentItem fallback,
    CreateAgentDraft? draft,
  }) {
    final draftSkills = _skillsFromDraft(draft?.skillLabels);
    final draftApps = _appsFromDraft(draft?.appLabels);
    return agent.copyWith(
      agentId: agent.agentId.isNotEmpty ? agent.agentId : fallback.agentId,
      name: agent.name.isNotEmpty ? agent.name : fallback.name,
      description: agent.description.isNotEmpty
          ? agent.description
          : (draft?.description.trim().isNotEmpty == true
              ? draft!.description.trim()
              : fallback.description),
      avatarUrl: selectAgentAvatarForDisplay(
        draftDisplayUrl: draft?.avatarDisplayUrl ?? '',
        draftAvatarUrl: draft?.avatarUrl ?? '',
        agentAvatarUrl: agent.avatarUrl,
        fallbackAvatarUrl: fallback.avatarUrl,
      ),
      internalDescription: agent.internalDescription.isNotEmpty
          ? agent.internalDescription
          : (draft?.internalDescription.trim().isNotEmpty == true
              ? draft!.internalDescription.trim()
              : fallback.internalDescription),
      welcomeMsg: agent.welcomeMsg.isNotEmpty
          ? agent.welcomeMsg
          : (draft?.welcomeMsg.trim().isNotEmpty == true
              ? draft!.welcomeMsg.trim()
              : fallback.welcomeMsg),
      tags: agent.tags.isNotEmpty
          ? agent.tags
          : (draft?.tags.isNotEmpty == true ? draft!.tags : fallback.tags),
      runtimeEnvironmentUuid: agent.executionLocus == 'local'
          ? ''
          : agent.runtimeEnvironmentUuid.isNotEmpty
              ? agent.runtimeEnvironmentUuid
              : (draft?.runtimeEnvironmentUuid.trim().isNotEmpty == true
                  ? draft!.runtimeEnvironmentUuid.trim()
                  : fallback.runtimeEnvironmentUuid),
      agentKey: agent.agentKey.isNotEmpty
          ? agent.agentKey
          : (draft?.agentKey.trim().isNotEmpty == true
              ? draft!.agentKey.trim()
              : fallback.agentKey),
      skills: agent.skills.isNotEmpty
          ? agent.skills
          : (draftSkills.isNotEmpty ? draftSkills : fallback.skills),
      apps: agent.apps.isNotEmpty
          ? agent.apps
          : (draftApps.isNotEmpty ? draftApps : fallback.apps),
      configuredAppLabels: agent.configuredAppLabels.isNotEmpty
          ? agent.configuredAppLabels
          : (draft?.appLabels.isNotEmpty == true
              ? draft!.appLabels
              : fallback.configuredAppLabels),
      configuredKnowledgeBaseLabels:
          agent.configuredKnowledgeBaseLabels.isNotEmpty
              ? agent.configuredKnowledgeBaseLabels
              : (draft?.knowledgeBaseLabels.isNotEmpty == true
                  ? draft!.knowledgeBaseLabels
                  : fallback.configuredKnowledgeBaseLabels),
    );
  }

  List<AgentSkillItem> _skillsFromDraft(Map<String, String>? labels) {
    if (labels == null || labels.isEmpty) return const <AgentSkillItem>[];
    return labels.entries
        .where((entry) => entry.key.trim().isNotEmpty)
        .map((entry) => AgentSkillItem(
              slug: entry.key.trim(),
              skillName: entry.value.trim().isNotEmpty
                  ? entry.value.trim()
                  : entry.key.trim(),
              status: 'active',
              isInstalled: true,
            ))
        .toList(growable: false);
  }

  List<AgentAppItem> _appsFromDraft(Map<String, String>? labels) {
    if (labels == null || labels.isEmpty) return const <AgentAppItem>[];
    return labels.entries
        .where((entry) => entry.key.trim().isNotEmpty)
        .map((entry) => AgentAppItem(
              id: entry.key.trim(),
              name: entry.value.trim().isNotEmpty
                  ? entry.value.trim()
                  : entry.key.trim(),
            ))
        .toList(growable: false);
  }

  Future<void> _deleteAgent(AgentItem agent) async {
    final confirm = await showUiConfirmDialog(
      context,
      title: '删除数字员工',
      description: '确定要删除 ${agent.displayName} 吗？此操作无法恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!confirm) return;
    if (!mounted) return;
    final name = agent.displayName;
    try {
      await ref.read(chatServiceProvider).deleteAgent(agent.agentId);
    } catch (error) {
      if (!mounted) return;
      widget.showToast('删除智能体失败：$error');
      return;
    }
    if (!mounted) return;
    ref.invalidate(agentsProvider);
    ref.invalidate(digitalEmployeeCatalogProvider);
    final currentSelected = ref.read(selectedAgentProvider).asData?.value;
    if (currentSelected?.agentId == agent.agentId) {
      ref.read(selectedAgentProvider.notifier).clear();
    }
    try {
      await ref.read(conversationsProvider.notifier).refresh();
    } catch (_) {}
    final shouldSyncCloudRuntime = _shouldSyncCloudRuntime(agent);
    if (shouldSyncCloudRuntime) await _ensureRuntimeNow();
    widget
        .showToast(shouldSyncCloudRuntime ? '已删除 $name，正在清理运行环境' : '已删除 $name');
  }

  Future<void> _openAgentConversation(AgentItem agent) async {
    ref.read(selectedHumanDirectProvider.notifier).state = null;
    ref.read(selectedGroupProvider.notifier).state = null;
    ref.read(selectedAgentProvider.notifier).select(agent);
    var list = ref.read(conversationsProvider).asData?.value ??
        const <ConversationItem>[];
    if (list.isEmpty) {
      list = await ref.read(conversationsProvider.future);
      if (!mounted) return;
    }
    // 只复用"该 agent 的单聊会话":排除群聊 / 人↔人会话。否则"含该 agent 的群聊"会因
    // ConversationItem.fromJson 把 agent 参与者写进 agentId 而被误当成单聊复用,导致
    // 左侧高亮群聊、右侧却是该 agent 单聊内容的混合态。
    var existing = list.cast<ConversationItem?>().firstWhere(
          (item) => isReusableAgentDirectConversation(item!, agent.agentId),
          orElse: () => null,
        );
    if (existing == null) {
      final service = ref.read(chatServiceProvider);
      final allConversations =
          await service.listAllConversations(includeHidden: true);
      if (!mounted) return;
      existing = allConversations.cast<ConversationItem?>().firstWhere(
            (item) => isReusableAgentDirectConversation(item!, agent.agentId),
            orElse: () => null,
          );
      if (existing != null) {
        await service.showConversation(existing.conversationId);
        if (!mounted) return;
        await ref.read(conversationsProvider.notifier).refresh();
        if (!mounted) return;
        ref.read(conversationsProvider.notifier).upsertAgentConversation(
              agent: agent,
              conversationId: existing.conversationId,
            );
      }
    }
    // doc-13 §A: 既有真实会话直接打开；否则进入 create-on-first-send 哨兵会话（不调网络，
    // agent-bus 无创建会话端点），首条消息由 /chat/send 建会话。
    final conversationId =
        existing?.conversationId ?? pendingConversationFor(agent.agentId);
    // 二次返修: 用当前 AgentItem 维护左侧会话项 —— 既有会话也用真人头像/名覆盖服务端
    // placeholder（机器人旧头像），不再仅在 pending 分支插入。
    ref.read(conversationsProvider.notifier).upsertAgentConversation(
          agent: agent,
          conversationId: conversationId
        );
    if (!mounted) return;
    await widget.onOpenConversation(conversationId, agent);
  }

  Future<void> _openAgentDetail(
    BuildContext context,
    AgentItem agent,
    String sourceLabel,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => UiDialogShell(
        size: UiDialogSize.standard,
        maxHeight: 640,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UiSheetHeader(
                title: '数字员工详情',
                onClose: () => Navigator.of(dialogContext).pop(),
              ),
              const SizedBox(height: 16),
              AgentDetailContent(
                agent: agent,
                sourceLabel: sourceLabel,
                onChat: () {
                  Navigator.of(dialogContext).pop();
                  _openAgentConversation(agent);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(digitalEmployeeSearchProvider, (_, __) {
      // 搜索词变化时重置本地分页，避免上一次"没有更多"状态影响新结果。
      if (!mounted) return;
      setState(() => _mobileVisibleCount = _mobilePageSize);
      _refreshController.resetNoData();
    });
    if (widget.mobile && widget.mobileFilterEnabled) {
      ref.listen<DigitalEmployeeCatalogFilter>(
        digitalEmployeeFilterProvider,
        (_, __) {
          // 切换分类后重置当前分类的本地分页窗口；服务端目录快照和刷新入口不变。
          if (!mounted) return;
          setState(() => _mobileVisibleCount = _mobilePageSize);
          _refreshController.resetNoData();
        }
      );
    }

    final catalogAsync = ref.watch(digitalEmployeeCatalogProvider);
    // 搜索/刷新触发的重载是「携带旧值的 Loading 态」：必须用 .value 拿旧
    // 数据继续渲染（asData 在 Loading 态恒为 null，会把整页替换成转圈、连带
    // 卸载过滤行里的搜索框导致输入文字丢失）。只有首载（无旧值）才显示 spinner。
    final catalog = catalogAsync.value;

    if (widget.mobile) {
      final filtered = widget.mobileFilterEnabled
          ? ref.watch(filteredDigitalEmployeesProvider)
          : catalog?.all ?? const <DigitalEmployeeCatalogItem>[];
      return Column(
        children: [
          if (widget.mobileFilterEnabled)
            const _DigitalEmployeeMobileFilterBar(),
          Expanded(
            child: ColoredBox(
              key: const ValueKey('digital-employee-mobile-list-background'),
              color: Colors.white,
              child: catalog == null
                  ? const DigitalEmployeeGallerySkeleton(mobile: true)
                  : _buildMobileList(context, filtered),
            ),
          ),
        ],
      );
    }

    if (catalog == null) {
      return const DigitalEmployeeGallerySkeleton(mobile: false);
    }

    final filtered = ref.watch(filteredDigitalEmployeesProvider);
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth =
                debugResolveDesktopAgentCardWidth(constraints.maxWidth);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: _DigitalEmployeeFilterBar(catalog: catalog),
                    ),
                    if (widget.filterTrailing != null) widget.filterTrailing!,
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: _desktopAgentGridGap,
                  runSpacing: _desktopAgentGridGap,
                  children: [
                    for (final entry in filtered)
                      SizedBox(
                        width: cardWidth,
                        child: AgentCard(
                          agent: entry.agent,
                          sourceLabel: entry.sourceLabel,
                          canEdit: entry.canEdit,
                          onTap: () => _openAgentDetail(
                              context, entry.agent, entry.sourceLabel),
                          onEdit: () => _editAgent(entry.agent),
                          onDelete: () => _deleteAgent(entry.agent),
                        ),
                      ),
                    SizedBox(
                      width: cardWidth,
                      child: _AddMoreCard(onTap: _createAgent),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildMobileList(
    BuildContext context,
    List<DigitalEmployeeCatalogItem> filtered,
  ) {
    final visibleCount = _resolveMobileVisibleCount(filtered.length);
    final visible = filtered.take(visibleCount).toList(growable: false);
    final canLoadMore = visibleCount < filtered.length;
    final totalItems = visible.length;
    final listContent = totalItems == 0
        ? ListView(
            padding: EdgeInsets.only(
              top: 12,
              bottom: MediaQuery.of(context).padding.bottom + 10,
            ),
            children: const [
              SizedBox(height: 96),
              Center(
                child: Text(
                  '暂无数字员工',
                  style: TextStyle(color: Color(0xFF86909C), fontSize: 14),
                ),
              ),
            ],
          )
        : ListView.separated(
            padding: EdgeInsets.fromLTRB(
              15,
              15,
              15,
              MediaQuery.of(context).padding.bottom + 20,
            ),
            itemCount: totalItems,
            itemBuilder: (context, index) {
              final entry = visible[index];
              return AgentCard(
                agent: entry.agent,
                sourceLabel: entry.sourceLabel,
                canEdit: entry.canEdit,
                mobile: true,
                menuAlwaysVisible: true,
                onTap: () =>
                    _openAgentDetail(context, entry.agent, entry.sourceLabel),
                onEdit: () => _editAgent(entry.agent),
                onDelete: () => _deleteAgent(entry.agent),
              );
            },
            separatorBuilder: (_, __) => const SizedBox(height: 15),
          );

    return UiPullToRefresh(
      controller: _refreshController,
      enablePullUp: true,
      onRefresh: () async {
        // 移动端刷新直接重拉数字员工列表，并重置本地分页窗口。
        await ref.read(digitalEmployeeCatalogProvider.notifier).refresh();
        if (!mounted) return;
        setState(() => _mobileVisibleCount = _mobilePageSize);
        _refreshController
          ..refreshCompleted()
          ..resetNoData();
      },
      onLoading: () async {
        if (!canLoadMore) {
          _refreshController.loadNoData();
          return;
        }
        setState(() {
          final next = _mobileVisibleCount + _mobilePageSize;
          _mobileVisibleCount = next > filtered.length ? filtered.length : next;
        });
        _refreshController.loadComplete();
      },
      child: listContent,
    );
  }
}

class DigitalEmployeeGallerySkeleton extends StatelessWidget {
  const DigitalEmployeeGallerySkeleton({
    super.key,
    required this.mobile
  });

  final bool mobile;

  @override
  Widget build(BuildContext context) {
    if (mobile) {
      return ListView.separated(
        padding: EdgeInsets.fromLTRB(
          15,
          15,
          15,
          MediaQuery.of(context).padding.bottom + 20,
        ),
        itemCount: 6,
        separatorBuilder: (_, __) => const SizedBox(height: 15),
        itemBuilder: (_, __) => const AgentCardSkeleton(mobile: true),
      );
    }

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth =
                debugResolveDesktopAgentCardWidth(constraints.maxWidth);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Expanded(child: _AgentFilterSkeleton()),
                    SizedBox(width: 12),
                    UiSkeletonBlock(width: 340, height: 40, radius: 12),
                    SizedBox(width: 12),
                    UiSkeletonBlock(width: 132, height: 42, radius: 10),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: _desktopAgentGridGap,
                  runSpacing: _desktopAgentGridGap,
                  children: List.generate(
                    8,
                    // 高度不写死——AgentCardSkeleton 自身内容比 150 高（实测溢出
                    // ~44px，"BOTTOM OVERFLOWED"），交给它按自己的 Column 自然
                    // 撑开，不用跟着骨架屏内部间距变化反复对一个魔数。
                    (_) => SizedBox(
                      width: cardWidth,
                      child: const AgentCardSkeleton(),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AgentFilterSkeleton extends StatelessWidget {
  const _AgentFilterSkeleton();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F2F5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          children: [
            UiSkeletonBlock(width: 64, height: 28, radius: 7),
            SizedBox(width: 4),
            UiSkeletonBlock(width: 88, height: 28, radius: 7),
          ],
        ),
      ),
    );
  }
}

// ============================ 过滤器 ============================

class _DigitalEmployeeMobileFilterBar extends ConsumerWidget {
  const _DigitalEmployeeMobileFilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(digitalEmployeeFilterProvider);
    return UiSlantedTabs<DigitalEmployeeCatalogFilter>(
      current: selected,
      onChanged: (filter) =>
          ref.read(digitalEmployeeFilterProvider.notifier).state = filter,
      selectionColor: Colors.white,
      activeColor: const Color(0xFF111111),
      inactiveColor: const Color(0xFF111111),
      tabs: [
        for (final filter in DigitalEmployeeCatalogFilter.values)
          UiSlantedTab(value: filter, label: filter.label),
      ],
    );
  }
}

class _DigitalEmployeeFilterBar extends ConsumerWidget {
  const _DigitalEmployeeFilterBar({required this.catalog});

  final DigitalEmployeeCatalog? catalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(digitalEmployeeFilterProvider);
    final primary = Theme.of(context).colorScheme.primary;
    return UiSegmentedTabs<DigitalEmployeeCatalogFilter>(
      current: selected,
      onChanged: (filter) =>
          ref.read(digitalEmployeeFilterProvider.notifier).state = filter,
      activeColor: primary,
      segmentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      trackRadius: 10,
      tabs: [
        for (final filter in DigitalEmployeeCatalogFilter.values)
          UiSegmentedTab(value: filter, label: filter.label),
      ],
    );
  }
}

// ============================ 网格布局 ============================

const double _desktopAgentCardMinWidth = 292;
const double _desktopAgentGridGap = 12;

@visibleForTesting
int debugResolveDesktopAgentColumnCount(double availableWidth) {
  if (!availableWidth.isFinite || availableWidth <= 0) return 1;
  final count = ((availableWidth + _desktopAgentGridGap) /
          (_desktopAgentCardMinWidth + _desktopAgentGridGap))
      .floor();
  return count < 1 ? 1 : count;
}

@visibleForTesting
double debugResolveDesktopAgentCardWidth(double availableWidth) {
  if (!availableWidth.isFinite || availableWidth <= 0) {
    return _desktopAgentCardMinWidth;
  }
  final columns = debugResolveDesktopAgentColumnCount(availableWidth);
  final totalGap = _desktopAgentGridGap * (columns - 1);
  return (availableWidth - totalGap) / columns;
}

// ============================ "添加更多" 卡片 ============================

class _AddMoreCard extends StatefulWidget {
  const _AddMoreCard({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_AddMoreCard> createState() => _AddMoreCardState();
}

class _AddMoreCardState extends State<_AddMoreCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: agentCardHeight(context)),
          decoration: BoxDecoration(
            color: _hover ? const Color(0xFFF1F2F4) : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: _hover ? const Color(0xFFCBD5E1) : const Color(0xFFE5E7EB),
            ),
          ),
          padding: const EdgeInsets.all(16),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                  color: Color(0xFFF0F6FF),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.add,
                  size: 24,
                  color: Color(0xFF165DFF),
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                '添加更多',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF165DFF),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
