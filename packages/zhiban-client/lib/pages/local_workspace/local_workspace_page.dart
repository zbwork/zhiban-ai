import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:zhiban_core/im/im_client.dart';
import '../chat/widgets/prompt_input/rich_prompt_controller.dart';
import '../chat/widgets/file_preview/attachment_preview_host.dart';
import '../chat/utils/open_chat_attachment.dart';
import 'services/local_attachment.dart';
import 'package:path_provider/path_provider.dart';
import '../chat/widgets/create_agent_dialog.dart';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_ui/zhiban_ui.dart';

import '../../config/color_config.dart';
import '../../routes/route_paths.dart';
import '../../window/window_controller.dart';
import '../chat/widgets/chat_empty_state.dart';
import '../chat/widgets/chat_detail_header.dart';
import '../chat/widgets/chat_history_panel.dart';
import '../chat/providers/chat_providers.dart'
    show chatHistoryPanelOpenProvider;
import '../settings/settings_page.dart';
import '../task/models/task_models.dart';
import '../task/providers/task_provider.dart';
import 'services/community_runtime.dart';
import '../drive/widgets/drive_content_view.dart';
import '../contacts/contacts_panes.dart' as contacts;
import '../chat/widgets/chat_session_view.dart';
import '../chat/widgets/desktop_drop.dart';
import '../chat/widgets/sidebar/components/conversation_list_panel.dart';
import '../digital_employee/services/digital_employee_service.dart';
import '../digital_employee/widgets/digital_employee_search_field.dart';
import '../skills/widgets/skill_detail_dialog.dart';
import '../skills/widgets/skill_install_agent_dialog.dart';
import '../digital_employee/widgets/digital_employee_gallery.dart';
import '../skills/models/skill_models.dart';
import '../skills/widgets/skills_content.dart';
import '../skills/widgets/skills_filters_bar.dart';
import '../skills/widgets/skills_tab_switcher.dart';
import '../skills/widgets/my_skills_view.dart';
import '../skills/models/skill_source.dart';
import '../skills/providers/skills_providers.dart';
import '../../widgets/page_header.dart';
import 'local_chat_model_control.dart';
import 'local_workspace_controller.dart';
import 'services/local_model_client.dart';
import 'services/local_workspace_store.dart';

typedef LocalTaskPageBuilder = Widget Function(List<AgentItem> agents,
    Future<void> Function(CronRunEntry entry) openRun, Stream<void> changes);

final localAttachmentPickerProvider =
    Provider<Future<List<String>> Function()>((ref) => () async {
          final files = await openFiles();
          return files.map((f) => f.path).toList();
        });

/// Local data adapter for the existing desktop presentation components.
/// The host App supplies its original MainLayout; this widget owns no navigation.
class LocalWorkspacePage extends ConsumerStatefulWidget {
  const LocalWorkspacePage(
      {super.key, required this.section, this.child, this.localTaskBuilder});
  final String section;
  final Widget? child;
  final LocalTaskPageBuilder? localTaskBuilder;
  @override
  ConsumerState<LocalWorkspacePage> createState() => _LocalWorkspacePageState();
}

class _LocalWorkspacePageState extends ConsumerState<LocalWorkspacePage> {
  String? _selected;
  LocalWorkspaceController? _controller;
  late final CommunityApproval _taskApproval = _approveTask;
  Future<bool> _approveTask(Map<String, dynamic> approval) async {
    if (!mounted) return false;
    final intent = approval['intent'] as Map;
    return await showUiConfirmDialog(context,
            title: '允许本机操作？',
            description:
                '工具：${intent['tool']}\n操作：${intent['operation']}\n${jsonEncode(intent['args'])}',
            confirmLabel: '允许本次',
            danger: ['shell', 'delete', 'overwrite']
                .contains(intent['operation'])) ==
        true;
  }

  final _messageLoads =
      <String, ({int revision, Future<List<LocalRow>> future})>{};
  final _messageViews = <String, List<ChatMessage>>{};
  Future<List<LocalRow>> _messages(LocalWorkspaceController c, String id) {
    final load = _messageLoads[id];
    if (load != null && load.revision == c.dataRevision) return load.future;
    final future = c.store.messages(id);
    _messageLoads[id] = (revision: c.dataRevision, future: future);
    return future;
  }

  final _composers = <String, RichPromptController>{};
  final _attachments = <String, LocalAttachment>{};
  final _reading = <String>{};
  RichPromptController _composer(String id) =>
      _composers.putIfAbsent(id, RichPromptController.new);

  Future<void> _pickLocalFiles(String id, ChatAttachmentPickKind kind,
      {List<String>? droppedPaths}) async {
    if (_reading.contains(id)) return;
    _pruneAttachments();
    await _action(() async {
      final files =
          droppedPaths ?? await ref.read(localAttachmentPickerProvider)();
      if (!mounted || files.isEmpty || _reading.contains(id)) return;
      final composer = _composer(id);
      if (composer.attachments.length + files.length > 5) {
        throw StateError('每次最多添加 5 个附件');
      }
      setState(() => _reading.add(id));
      try {
        final parsed = <LocalAttachment>[];
        for (final file in files) {
          parsed.add(await LocalAttachmentService().read(file));
        }
        if (!mounted ||
            !identical(_composers[id], composer) ||
            !(ref
                    .read(localWorkspaceProvider)
                    .value
                    ?.employees
                    .any((e) => e['id'] == id) ??
                false)) {
          return;
        }
        final total = [
          ...parsed,
          for (final item in composer.attachments)
            if (_attachments[item.id] != null) _attachments[item.id]!
        ].fold<int>(0, (n, f) => n + f.text.length);
        if (total > 120000) throw StateError('附件总文字超过 120,000 字符，请分次发送');
        for (final file in parsed) {
          final key = LocalWorkspaceStore.uuid.v4();
          _attachments[key] = file;
          composer.insertAttachment(RichPromptAttachment(
              id: key,
              fileName: file.name,
              fileType: ChatFileType.file,
              localPath: file.path,
              status: RichAttachmentStatus.ready,
              progress: 100,
              block: ImMessageBlock(
                  kind: ImMessageBlockKind.file,
                  url: Uri.file(file.path).toString(),
                  name: file.name,
                  size: file.size)));
        }
      } finally {
        _reading.remove(id);
        if (mounted) setState(() {});
      }
    });
  }

  void _pruneAttachments() {
    final used =
        _composers.values.expand((c) => c.attachments).map((a) => a.id).toSet();
    _attachments.removeWhere((key, _) => !used.contains(key));
  }

  bool _sendLocal(LocalWorkspaceController c, LocalRow e) {
    _pruneAttachments();
    final id = e['id'] as String;
    final composer = _composer(id);
    if (c.busy(id) || _reading.contains(id)) return false;
    final selected = composer.attachments
        .map((a) => _attachments[a.id])
        .whereType<LocalAttachment>()
        .toList();
    final keys = composer.attachments.map((a) => a.id).toList();
    final text = composer.textWithoutAttachmentTokens;
    _action(
        () => c.send(e, text, attachments: selected, approve: (approval) async {
              if (!mounted || !c.busy(id)) return false;
              final intent = approval['intent'] as Map;
              return await showUiConfirmDialog(context,
                      title: '允许本机操作？',
                      description:
                          '工具：${intent['tool']}\n操作：${intent['operation']}\n${jsonEncode(intent['args'])}',
                      confirmLabel: '允许本次',
                      danger: ['shell', 'delete', 'overwrite']
                          .contains(intent['operation'])) ==
                  true;
            }, onAccepted: () {
              if (!mounted) return;
              composer.clearRich();
              for (final key in keys) {
                _attachments.remove(key);
              }
              setState(() {});
            }));
    // The original composer clears only after durable local acceptance.
    return false;
  }

  final _search = TextEditingController();
  String _keyword = '';
  bool _mine = false;
  int? _skillCategory;
  SortOption _sort = SortOption.defaultSort;
  final _skillsScroll = ScrollController();
  String? _highlight;
  int _highlightToken = 0;

  @override
  void dispose() {
    if (identical(_controller?.taskApproval, _taskApproval)) {
      _controller?.taskApproval = null;
    }
    WindowController.instance.setOverlayWidth(0);
    _search.dispose();
    _skillsScroll.dispose();
    for (final composer in _composers.values) {
      composer.dispose();
    }
    super.dispose();
  }

  Future<void> _action(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      BotToast.showText(
          text: e is LocalModelException
              ? e.message
              : e is StateError
                  ? e.message.toString()
                  : '操作失败，请检查本地存储或系统凭据库权限后重试');
    }
  }

  @override
  void didUpdateWidget(covariant LocalWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) {
      WindowController.instance.setOverlayWidth(0);
      _search.clear();
      _keyword = '';
      _mine = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(chatHistoryPanelOpenProvider, (previous, next) {
      if (widget.section == RoutePaths.chat) {
        WindowController.instance.setOverlayWidth(next ? 280 : 0);
      }
    });
    final workspace = ref.watch(localWorkspaceProvider);
    final ready = workspace.value;
    if (ready != null) {
      _controller = ready;
      ready.taskApproval = _taskApproval;
    }
    if (widget.child != null) return widget.child!;
    if ([RoutePaths.drive, RoutePaths.contacts].contains(widget.section)) {
      final title = widget.section == RoutePaths.task
          ? '自动任务'
          : widget.section == RoutePaths.drive
              ? '云盘'
              : '通讯录';
      return ColoredBox(
          color: ColorConfig.pageBackground,
          child: Column(children: [
            _header(title, '$title需要登录后使用'),
            Expanded(
                child: widget.section == RoutePaths.drive
                    ? const DriveContentView(
                        showUnavailableState: true,
                        unavailableMessage: '云盘需要登录后使用')
                    : const contacts.EmptyState(text: '通讯录需要登录后使用')),
          ]));
    }
    if (widget.section == RoutePaths.settings) return _settings();
    return ColoredBox(
        color: ColorConfig.pageBackground,
        child: workspace.when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, stack) => Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('本地工作区打开失败，请检查磁盘和应用目录权限'),
            TextButton(
                onPressed: () => ref.invalidate(localWorkspaceProvider),
                child: const Text('重试')),
          ])),
          data: (c) => ListenableBuilder(
              listenable: c,
              builder: (context, _) {
                if (widget.section == RoutePaths.task) {
                  final builder = widget.localTaskBuilder;
                  if (builder == null) {
                    return const Center(child: Text('当前入口未配置任务页面'));
                  }
                  return ProviderScope(
                      overrides: [
                        taskServiceProvider.overrideWithValue(c.tasks)
                      ],
                      child:
                          builder([for (final e in c.employees) _agent(c, e)],
                              (entry) async {
                        if (!c.employees
                            .any((e) => e['id'] == entry.conversationUuid)) {
                          BotToast.showText(text: '数字员工已删除，执行记录仍保留');
                          return;
                        }
                        setState(() => _selected = entry.conversationUuid);
                        context.go(RoutePaths.chat);
                      }, c.tasks.changes));
                }
                if (widget.section == RoutePaths.digitalEmployee) {
                  return _employees(c);
                }
                if (widget.section == RoutePaths.inspire) return _skills(c);
                return _chat(c);
              }),
        ));
  }

  Widget _header(String title, String subtitle, {Widget? trailing}) =>
      PageHeader(title: title, subtitle: subtitle, trailing: trailing);

  Widget _settings() => const SettingsPage(localWorkspace: true);

  List<AgentSkillItem> _boundSkills(LocalWorkspaceController c, LocalRow e) {
    final bound =
        (jsonDecode(e['skills'] as String) as List).cast<String>().toSet();
    return [
      for (final s in c.skills)
        if (bound.contains(s['id']))
          AgentSkillItem(
            slug: s['id'] as String,
            skillName: s['name'] as String,
            status: 'installed',
            isInstalled: true,
          )
    ];
  }

  AgentItem _agent(LocalWorkspaceController c, LocalRow e) => AgentItem(
        agentId: e['id'] as String,
        name: e['name'] as String,
        description:
            _metadata(e)['description'] as String? ?? e['prompt'] as String,
        avatarUrl: _metadata(e)['avatar_url'] as String? ?? '',
        executionLocus: 'local',
        visibility: 'personal',
        modelPrimary: e['model_id'] as String,
        welcomeMsg: _metadata(e)['welcome_msg'] as String? ?? '',
        tags: (_metadata(e)['tags'] as List? ?? []).cast<String>(),
        skills: _boundSkills(c, e),
        status: 'active',
        isDefault: false,
        canManageSkills: true,
        syncStatus: 'synced',
        lastSyncedAt: null,
      );

  Widget _employees(LocalWorkspaceController c) {
    final employees = c.employees.where((e) => [e['name'], e['prompt']]
        .join(' ')
        .toLowerCase()
        .contains(_keyword.toLowerCase()));
    LocalRow row(AgentItem agent) =>
        c.employees.firstWhere((e) => e['id'] == agent.agentId);
    return Column(children: [
      _header('数字员工', '集中搜索、管理并打开数字员工会话。'),
      Expanded(
          child: SizedBox(
        width: double.infinity,
        child: OpenClawDigitalEmployeeGallery(
          localCatalog: DigitalEmployeeCatalog(
            personal: [
              for (final e in employees)
                DigitalEmployeeCatalogItem.personal(_agent(c, e))
            ],
            enterprise: const [],
          ),
          requestCreateAgentDraft: (_) async => null,
          requestEditAgentDraft: (_, agent) async => null,
          showToast: (message) => BotToast.showText(text: message),
          onOpenConversation: (_, agent) async {},
          onLocalCreate: () => _edit(c),
          onLocalEdit: (agent) => _edit(c, row(agent)),
          onLocalDelete: (agent) => _delete(c, row(agent)),
          onLocalOpen: (agent) async {
            _selected = agent.agentId;
            context.go(RoutePaths.chat);
          },
          filterTrailing: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
                width: 340,
                child: DigitalEmployeeSearchField(
                  controller: _search,
                  onLocalChanged: (value) =>
                      setState(() => _keyword = value.trim()),
                )),
            const SizedBox(width: 12),
            SizedBox(
                height: 40,
                child: FilledButton.icon(
                  onPressed: () => _edit(c),
                  icon: const Icon(CupertinoIcons.add, size: 18),
                  label: const Text('新建数字员工'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1D63F2),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    textStyle: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                )),
          ]),
        ),
      )),
    ]);
  }

  Skill _skill(LocalRow s, Set<String> bound) => Skill(
      uuid: s['id'] as String,
      slug: s['id'] as String,
      displayName: s['name'] as String,
      description: s['description'] as String,
      source: s['source'] as String? ?? 'builtin',
      iconUrl: s['icon_url'] as String? ?? '',
      status: 'active',
      categoryId: (s['category_id'] as int? ?? 1) == 0
          ? null
          : s['category_id'] as int? ?? 1,
      version: s['version'] as String?,
      installStatus: bound.contains(s['id']) ? 'installed' : '',
      isInstalled: bound.contains(s['id']),
      downloadCount: s['download_count'] as int? ?? 0,
      versionCount: 1,
      usageExample: s['usage_example'] as String? ?? '将需要处理的内容粘贴到聊天中');

  Widget _skills(LocalWorkspaceController c) {
    if (!c.catalogAttempted) {
      c.catalogAttempted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(c.syncSkillCatalog());
      });
    }
    final bound = {
      for (final e in c.employees)
        ...(jsonDecode(e['skills'] as String) as List).cast<String>()
    };
    final skills = c.skills
        .where((s) => c.marketSkillIds.contains(s['id']))
        .where((s) =>
            _skillCategory == null || (s['category_id'] ?? 1) == _skillCategory)
        .where((s) => "${s['id']} ${s['name']} ${s['description']}"
            .toLowerCase()
            .contains(_keyword.toLowerCase()))
        .toList();
    skills.sort((a, b) {
      final count = (b['download_count'] as int? ?? 0)
          .compareTo(a['download_count'] as int? ?? 0);
      if (count != 0) return count;
      return (a['sort_order'] as int? ?? 0)
          .compareTo(b['sort_order'] as int? ?? 0);
    });
    final tabs = SkillsTabSwitcher(
        tab: _mine ? SkillsTab.mine : SkillsTab.market,
        compact: false,
        onChanged: (tab) => setState(() => _mine = tab == SkillsTab.mine));
    if (_mine) {
      return Column(children: [
        _header('我的技能', '管理你创建的数字员工已添加的技能。', trailing: tabs),
        Expanded(
            child: MySkillsView(
          localAgents: [for (final e in c.employees) _agent(c, e)],
          localMarketSkills: [for (final s in c.skills) _skill(s, bound)],
          onGoMarket: () => setState(() => _mine = false),
          onLocalUse: (agent) async {
            _selected = agent.agentId;
            context.go(RoutePaths.chat);
          },
          onLocalRemove: (agent, slug) async {
            final e = c.employees.firstWhere((e) => e['id'] == agent.agentId);
            final bindings = (jsonDecode(e['skills'] as String) as List)
                .cast<String>()
              ..remove(slug);
            await c.saveEmployee({...e, 'skills': jsonEncode(bindings)});
          },
        )),
      ]);
    }
    return Column(children: [
      SkillsFiltersBar(
          mobile: false,
          subtitle: c.catalogError ??
              (c.catalogFromServer ? '浏览技能，为数字员工添加所需能力。' : '正在获取技能目录。'),
          searchBar: UiSearchField(
              controller: _search,
              hintText: '搜索技能',
              fillColor: Colors.white,
              onChanged: (v) => setState(() => _keyword = v.trim()),
              onClear: () => setState(() {
                    _search.clear();
                    _keyword = '';
                  })),
          sortOptions: const [SortOption.defaultSort, SortOption.downloadCount],
          source: SkillSource.all,
          sort: _sort,
          categories: c.skillCategories,
          selectedCategoryId: _skillCategory,
          tabSwitcher: tabs,
          onSourceChanged: (_) {},
          onSortChanged: (v) => setState(() => _sort = v),
          onCategoryChanged: (v) => setState(() => _skillCategory = v),
          onRefresh: () => c.syncSkillCatalog(),
          isRefreshing: c.catalogRefreshing),
      Expanded(
          child: SkillsContent(
              addLabel: (_) => '添加',
              state: SkillsListState(
                  categories: c.skillCategories,
                  skills: [for (final s in skills) _skill(s, bound)],
                  hasReachedMax: true,
                  isLoading: c.catalogRefreshing,
                  isRefreshing: c.catalogRefreshing,
                  error: c.catalogError),
              scrollController: _skillsScroll,
              onSkillTap: (s) => _skillDetail(
                  c.skills.firstWhere((row) => row['id'] == s.slug)),
              onSkillAdd: (s) => _installSkill(
                  c, c.skills.firstWhere((row) => row['id'] == s.slug)),
              onLoadMore: () {})),
    ]);
  }

  Future<void> _skillDetail(LocalRow s) => showDialog<void>(
        context: context,
        builder: (_) => SkillDetailDialog(
          skill: _skill(s, {}),
          enableInstall: true,
          availabilityMessage: s['executable'] == 0
              ? '添加时下载技能包并保存在本地，安装后可离线使用。'
              : '技能已保存在本地，聊天时自动加载；工具操作沿用本地权限设置。',
          onInstall: () {
            final c = ref.read(localWorkspaceProvider).value;
            if (c != null) _installSkill(c, s);
          },
        ),
      );

  Future<void> _installSkill(LocalWorkspaceController c, LocalRow s) async {
    final healthy = await c.skillPackageHealthy(s['id'] as String);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => SkillInstallAgentDialog(
        skill: _skill(s, {}),
        localPackageHealthy: healthy,
        localAgents: [for (final e in c.employees) _agent(c, e)],
        onLocalAdd: (agent) async {
          await c.installSkill(s['id'] as String);
          final e = c.employees.firstWhere((e) => e['id'] == agent.agentId);
          final bound = (jsonDecode(e['skills'] as String) as List)
              .cast<String>()
              .toSet()
            ..add(s['id'] as String);
          await c.saveEmployee({...e, 'skills': jsonEncode(bound.toList())});
        },
        onLocalUse: (agent) async {
          if (!mounted) return;
          _selected = agent.agentId;
          context.go(RoutePaths.chat);
        },
      ),
    );
  }

  Widget _chat(LocalWorkspaceController c) {
    final e = c.employees.where((e) => e['id'] == _selected).firstOrNull ??
        c.employees.firstOrNull;
    final id = e?['id'] as String?;
    final matches =
        c.employees.where((e) => (e['name'] as String).contains(_keyword));
    return AttachmentPreviewHost(
        sessionKey: id ?? 'empty',
        child: Builder(
            builder: (context) => Row(children: [
                  SizedBox(
                      width: 240,
                      child: Column(children: [
                        ConversationListHeader(
                            controller: _search,
                            onCreateGroup: null,
                            onSearchChanged: (v) =>
                                setState(() => _keyword = v),
                            onClearSearch: () => setState(() {
                                  _search.clear();
                                  _keyword = '';
                                })),
                        Expanded(
                            child: LayoutBuilder(
                                builder: (context, constraints) =>
                                    SingleChildScrollView(
                                        child: ConstrainedBox(
                                            constraints: BoxConstraints(
                                                minHeight:
                                                    constraints.maxHeight),
                                            child: ConversationListPanel(
                                              padding: const EdgeInsets.all(4),
                                              selectedConversationId: id,
                                              loadingConversations: false,
                                              conversations: [
                                                for (final employee in matches)
                                                  ConversationItem(
                                                    conversationId:
                                                        employee['id']
                                                            as String,
                                                    title: employee['name']
                                                        as String,
                                                    agentId: employee['id']
                                                        as String,
                                                    agentName: employee['name']
                                                        as String,
                                                    lastMessage:
                                                        employee['last_content']
                                                            as String?,
                                                    isDoing: c.busy(
                                                        employee['id']
                                                            as String),
                                                  )
                                              ],
                                              onConversationSelected: (item) =>
                                                  setState(() => _selected =
                                                      item.conversationId),
                                            ))))),
                      ])),
                  const VerticalDivider(width: 0.8),
                  Expanded(
                      child: e == null
                          ? Column(children: [
                              const Expanded(
                                  child: ChatEmptyState(
                                      message: '创建数字员工，开始第一次对话')),
                              FilledButton(
                                  onPressed: () => _edit(c),
                                  child: const Text('新建数字员工')),
                              TextButton(
                                  onPressed: () =>
                                      context.go(RoutePaths.modelService),
                                  child: const Text('配置模型 API Key')),
                              const SizedBox(height: 48),
                            ])
                          : Column(children: [
                              ChatDetailHeader(
                                  title: e['name'] as String,
                                  localAgent: _agent(c, e),
                                  localExecutionOnDemand: true,
                                  trailing: IconButton(
                                      tooltip: '编辑数字员工',
                                      onPressed: c.busy(id!)
                                          ? null
                                          : () => _edit(c, e),
                                      icon:
                                          const Icon(CupertinoIcons.ellipsis))),
                              Expanded(
                                  child: FutureBuilder<List<LocalRow>>(
                                      key: ValueKey(id),
                                      future: _messages(c, id),
                                      builder: (context, snapshot) {
                                        if (snapshot.hasError) {
                                          return const Center(
                                              child: Text('消息读取失败，请重试'));
                                        }
                                        final rows = snapshot.data ?? [];
                                        // A replacement Future retains old DB rows while the
                                        // runtime may already have cleared its live overlay.
                                        // Keep the complete rendered snapshot until DB catches up.
                                        final messages = snapshot
                                                        .connectionState !=
                                                    ConnectionState.done &&
                                                _messageViews.containsKey(id)
                                            ? _messageViews[id]!
                                            : <ChatMessage>[
                                                for (final row in rows)
                                                  ChatMessage(
                                                    localId:
                                                        row['id'] as String,
                                                    messageId:
                                                        row['id'] as String,
                                                    role: row['role'] == 'user'
                                                        ? ChatRole.question
                                                        : ChatRole.answer,
                                                    content:
                                                        c.liveText[row['id']] ??
                                                            row['content']
                                                                as String,
                                                    timelineEntries: List<
                                                        ChatTimelineEntry>.unmodifiable(c
                                                                .timelines[
                                                            row['id']] ??
                                                        LocalWorkspaceController
                                                            .decodeTimeline(row[
                                                                'timeline'])),
                                                    files: LocalAttachment
                                                            .decode(row[
                                                                'attachments'])
                                                        .map((f) => f.file)
                                                        .toList(),
                                                    streamStartedAt: row[
                                                                'status'] ==
                                                            'pending'
                                                        ? DateTime
                                                            .fromMillisecondsSinceEpoch(
                                                                row['created']
                                                                    as int)
                                                        : null,
                                                    status: row['status'] ==
                                                            'pending'
                                                        ? BubbleStatus.loading
                                                        : row['status'] ==
                                                                'complete'
                                                            ? BubbleStatus
                                                                .success
                                                            : BubbleStatus
                                                                .error,
                                                    createdAt: DateTime
                                                        .fromMillisecondsSinceEpoch(
                                                            row['created']
                                                                as int),
                                                    failureMessage: [
                                                      'failed',
                                                      'interrupted'
                                                    ].contains(row['status'])
                                                        ? row['content']
                                                            as String
                                                        : null,
                                                  )
                                              ];
                                        if (snapshot.connectionState ==
                                            ConnectionState.done) {
                                          _messageViews[id] = messages;
                                        }
                                        final session = ChatSessionView(
                                          autoScrollOnMessageUpdate: false,
                                          sentTextHistory: [
                                            for (final row in rows)
                                              if (row['role'] == 'user' &&
                                                  (row['content'] as String)
                                                      .trim()
                                                      .isNotEmpty)
                                                row['content'] as String,
                                          ],
                                          controller: _composer(id),
                                          sendReady: !c.busy(id) &&
                                              !_reading.contains(id),
                                          sendGuard: () => _sendLocal(c, e),
                                          onOpenAttachment: (file) =>
                                              previewChatAttachment(
                                                  context, file,
                                                  ref: ref),
                                          runtimeControls:
                                              LocalChatModelControl(
                                            employee: e,
                                            busy: c.busy(id),
                                            permissionMode: c.permissionMode(e),
                                            onPermission: (mode) =>
                                                c.setPermission(e, mode),
                                            onWorkspace: (path) =>
                                                c.saveEmployee({
                                              ...e,
                                              'metadata': jsonEncode({
                                                ..._metadata(e),
                                                'workspace': path
                                              })
                                            }),
                                            onSelect: (provider, model) =>
                                                _action(() => c.saveEmployee({
                                                      ...e,
                                                      'provider_id': provider,
                                                      'model_id': model
                                                    })),
                                          ),
                                          onHighlightConsumed: () {
                                            if (mounted && _highlight != null) {
                                              setState(() => _highlight = null);
                                            }
                                          },
                                          showServerTools: false,
                                          key: ValueKey(id),
                                          state: ChatWorkspaceState(
                                              activeConversationId: id,
                                              sessions: {
                                                id: ChatSessionState(
                                                    conversationId: id,
                                                    messages: messages,
                                                    draft: ChatComposerDraft(
                                                        revision: 0,
                                                        composer: _composer(id)
                                                            .snapshotDraft(),
                                                        text: _composer(id)
                                                            .textWithoutAttachmentTokens,
                                                        hasContent: _composer(
                                                                id)
                                                            .hasRichContent),
                                                    highlightMessageUuid:
                                                        _highlight,
                                                    highlightToken:
                                                        _highlightToken,
                                                    isSending: c.busy(id),
                                                    isLoadingMessages:
                                                        !snapshot.hasData)
                                              }),
                                          agentSkills: _boundSkills(c, e),
                                          onAddSkill: () => _edit(c, e),
                                          onPickAttachment: (kind) =>
                                              _pickLocalFiles(id, kind),
                                          onPickFromDrive: () =>
                                              BotToast.showText(
                                                  text: '云盘需要登录后使用'),
                                          onSend: (_, skills) {},
                                          onStop: () => c.stop(id),
                                          onLoadMoreHistory: () {},
                                          onNotify: (text) =>
                                              BotToast.showText(text: text),
                                          emptyStateMessage:
                                              digitalEmployeeWelcomeMessage(
                                                  _agent(c, e)),
                                        );
                                        final historyOpen = ref.watch(
                                            chatHistoryPanelOpenProvider);
                                        return LayoutBuilder(
                                            builder: (context, constraints) =>
                                                Row(children: [
                                                  Expanded(
                                                      child: DesktopDrop(
                                                    onDropFiles: (files) =>
                                                        _pickLocalFiles(
                                                            id,
                                                            ChatAttachmentPickKind
                                                                .files,
                                                            droppedPaths: files
                                                                .map((f) =>
                                                                    f.path)
                                                                .toList()),
                                                    child: session,
                                                  )),
                                                  if (historyOpen &&
                                                      constraints.maxWidth >=
                                                          700)
                                                    ChatHistoryPanel(
                                                      width: 280,
                                                      localMessages: messages,
                                                      localAgentName:
                                                          e['name'] as String,
                                                      onLocalMessageSelected:
                                                          (message) =>
                                                              setState(() {
                                                        _highlight = message;
                                                        _highlightToken++;
                                                      }),
                                                    ),
                                                ]));
                                      })),
                            ])),
                ])));
  }

  Future<void> _delete(LocalWorkspaceController c, LocalRow e) async {
    final confirmed = await showUiConfirmDialog(
      context,
      title: '删除数字员工',
      description: '将同时删除该员工保存在本机的全部聊天记录，此操作无法撤销。',
      confirmLabel: '删除',
      danger: true,
    );
    if (confirmed == true) {
      await _action(() => c.deleteEmployee(e['id'] as String));
    }
  }

  Map<String, dynamic> _metadata(LocalRow e) =>
      jsonDecode(e['metadata'] as String? ?? '{}') as Map<String, dynamic>;

  Future<void> _edit(LocalWorkspaceController c, [LocalRow? e]) async {
    await _action(() async {
      final meta = e == null ? <String, dynamic>{} : _metadata(e);
      final skills = e == null
          ? <String>[]
          : (jsonDecode(e['skills'] as String) as List).cast<String>();
      final draft = await showDialog<CreateAgentDraft>(
        context: context,
        builder: (_) => CreateAgentDialog(
          title: e == null ? '创建数字员工' : '编辑数字员工',
          submitLabel: e == null ? '创建数字员工' : '保存',
          agentId: e?['id'] as String?,
          initialDraft: e == null
              ? null
              : CreateAgentDraft(
                  name: e['name'] as String,
                  description:
                      meta['description'] as String? ?? e['prompt'] as String,
                  avatarUrl: meta['avatar_url'] as String? ?? '',
                  systemPrompt:
                      meta['system_prompt'] as String? ?? e['prompt'] as String,
                  welcomeMsg: meta['welcome_msg'] as String? ?? '',
                  internalDescription:
                      meta['internal_description'] as String? ?? '',
                  tags: (meta['tags'] as List? ?? []).cast<String>(),
                  executionLocus: 'local',
                  localEngine: meta['local_engine'] as String? ?? 'dsh',
                  skillSlugs: skills,
                  skillLabels: {
                    for (final s
                        in c.skills.where((s) => skills.contains(s['id'])))
                      s['id'] as String: s['name'] as String
                  },
                ),
          localOptions: LocalAgentEditorOptions(
            skills: [
              for (final s in c.skills.where((s) => s['executable'] != 0))
                _skill(s, {})
            ],
            saveAvatar: (path) async {
              final root = await getApplicationSupportDirectory();
              final dir = await Directory('${root.path}/community_avatars')
                  .create(recursive: true);
              final ext = path.split('.').last.toLowerCase();
              if (!['png', 'jpg', 'jpeg', 'webp', 'gif', 'heic']
                  .contains(ext)) {
                throw StateError('不支持的头像格式');
              }
              final target =
                  '${dir.path}/${LocalWorkspaceStore.uuid.v4()}.$ext';
              await File(path).copy(target);
              return File(target).uri.toString();
            },
          ),
        ),
      );
      if (draft == null || !mounted) return;
      final id = e?['id'] as String? ?? LocalWorkspaceStore.uuid.v4();
      await c.saveEmployee({
        'id': id,
        'name': draft.name,
        'prompt': draft.systemPrompt.isEmpty
            ? '你是数字员工 ${draft.name}。主要职责：${draft.description}'
            : draft.systemPrompt,
        'provider_id': e?['provider_id'] ?? '',
        'model_id': e?['model_id'] ?? '',
        'skills': jsonEncode(draft.skillSlugs),
        'created': e?['created'] ?? DateTime.now().millisecondsSinceEpoch,
        'metadata': jsonEncode({
          ...meta,
          'description': draft.description,
          'system_prompt': draft.systemPrompt,
          'avatar_url': draft.avatarUrl,
          'welcome_msg': draft.welcomeMsg,
          'tags': draft.tags,
          'internal_description': draft.internalDescription,
          'execution_locus': 'local',
          'local_engine': draft.localEngine,
        }),
      });
      _selected = id;
    });
  }
}
