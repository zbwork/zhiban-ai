import 'package:zhiban_client/config/client_assets.dart';
import 'dart:async';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_client/config/app_config.dart';
import 'package:zhiban_client/network/api_image_auth.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/chat/providers/chat_providers.dart';
import 'package:zhiban_core/knowledge/knowledge_models.dart';
import 'package:zhiban_client/pages/knowledge/services/knowledge_service.dart';
import 'package:zhiban_client/pages/skills/models/skill_models.dart';
import 'package:zhiban_client/pages/skills/widgets/skill_picker_dialog.dart';
import 'package:zhiban_client/pages/workbench/services/workbench_service.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_client/widgets/ui/ui_network_image.dart';
import 'package:zhiban_client/utils/file_picker_utils.dart';
import 'package:zhiban_client/utils/url_utils.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const double _dialogHorizontalPadding = 24;
const _cloudCreationUnavailable = '云端创建暂未开放，请在电脑端创建本地数字员工。';

/// 移动端全屏编辑页通过 GoRouter extra 传递的参数对象。
class CreateAgentPageArgs {
  const CreateAgentPageArgs({
    this.initialDraft,
    this.title = '创建数字员工',
    this.submitLabel = '创建数字员工',
    this.enableDeleteAction = false,
    this.agentId,
  });

  final CreateAgentDraft? initialDraft;
  final String title;
  final String submitLabel;
  final bool enableDeleteAction;
  final String? agentId;
}

class CreateAgentDialog extends StatelessWidget {
  const CreateAgentDialog({
    super.key,
    this.initialDraft,
    this.title = '创建数字员工',
    this.submitLabel = '创建数字员工',
    this.enableDeleteAction = false,
    this.agentId,
  });

  final CreateAgentDraft? initialDraft;
  final String title;
  final String submitLabel;
  final bool enableDeleteAction;
  // 编辑数字员工时传入当前 agent 的 id；为空表示新建模式。
  // 技能广场会据此调整：新建模式不展示「自定义技能」分组；
  // 编辑模式只展示当前 agent 名下的自定义技能。
  final String? agentId;

  @override
  Widget build(BuildContext context) {
    return UiContentDialog(
      child: CreateAgentEditor(
        initialDraft: initialDraft,
        title: title,
        submitLabel: submitLabel,
        enableDeleteAction: enableDeleteAction,
        agentId: agentId,
        compact: false,
      ),
    );
  }
}

/// 数字员工编辑表单核心；页面壳分别由桌面 Dialog 和移动全屏页持有。
class CreateAgentEditor extends ConsumerStatefulWidget {
  const CreateAgentEditor({
    super.key,
    this.initialDraft,
    this.title = '创建数字员工',
    this.submitLabel = '创建数字员工',
    this.enableDeleteAction = false,
    this.agentId,
    required this.compact,
  });

  final CreateAgentDraft? initialDraft;
  final String title;
  final String submitLabel;
  final bool enableDeleteAction;
  final String? agentId;
  final bool compact;

  @override
  ConsumerState<CreateAgentEditor> createState() => _CreateAgentEditorState();
}

class _CreateAgentEditorState extends ConsumerState<CreateAgentEditor> {
  final _formKey = GlobalKey<FormState>();
  bool _submitted = false;
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _internalDescriptionController;
  late final TextEditingController _welcomeController;
  late final TextEditingController _systemPromptController;
  late final TextEditingController _tagsController;
  late final TextEditingController _agentKeyController;
  // Credential routing is derived from the selected provider, never a UI type.
  String _modelPrimary = '';
  String _modelSource = 'platform_whitelist';
  String _byokEndpointType = '';
  String _byokBaseUrl = '';
  String _byokModelId = '';
  String _status = 'published';
  String _runtimeEnvironmentUuid = '';
  String _avatarUrl = '';
  String _avatarDisplayUrl = '';

  /// 上传的本地图片路径，仅在「上传成功且仍在当前对话框生命周期内」时使用。
  /// 用于即时预览，避免 S3 / 内网 URL 在客户端短暂不可达导致看不到回显。
  String? _avatarLocalPath;
  bool _uploadingAvatar = false;
  bool _allowInternetAccess = true;
  late String _executionLocus;
  late String _localEngine;
  List<RuntimeEnvironmentOption> _runtimeEnvironments = [];
  bool _loadingRuntimeEnvironments = true;
  String? _runtimeLoadError;
  String? _errorText;
  Map<String, String> _selectedSkillLabels = <String, String>{};
  Map<String, String> _selectedAppLabels = <String, String>{};
  Map<String, String> _selectedKnowledgeBaseLabels = <String, String>{};

  bool get _canSubmitExecution =>
      _executionLocus == 'local' ||
      (_executionLocus == 'cloud' &&
          (AppConfig.cloudAgentCreationEnabled ||
              widget.initialDraft?.executionLocus == 'cloud'));

  bool get _canSelectLocal =>
      PlatformUtils.isDesktop &&
      (AppConfig.cloudAgentCreationEnabled ||
          widget.initialDraft?.executionLocus != 'cloud');

  @override
  void initState() {
    super.initState();
    final initial = widget.initialDraft;
    _localEngine = initial?.localEngine ?? 'dsh';
    _executionLocus = initial?.executionLocus ??
        (PlatformUtils.isDesktop
            ? 'local'
            : AppConfig.cloudAgentCreationEnabled
                ? 'cloud'
                : '');
    _nameController = TextEditingController(text: initial?.name ?? '');
    _descriptionController = TextEditingController(
      text: initial?.description ?? '',
    );
    _internalDescriptionController = TextEditingController(
      text: initial?.internalDescription ?? '',
    );
    _welcomeController = TextEditingController(text: initial?.welcomeMsg ?? '');
    _systemPromptController =
        TextEditingController(text: initial?.systemPrompt ?? '');
    _tagsController = TextEditingController(
      text: (initial?.tags ?? const <String>[]).join('，'),
    );
    _agentKeyController = TextEditingController(
      text: initial?.agentKey ?? 'default',
    );
    _modelPrimary = initial?.modelPrimary ?? '';
    _modelSource = initial?.modelSource ?? 'platform_whitelist';
    _byokEndpointType = initial?.modelServiceEndpointType ?? '';
    _byokBaseUrl = initial?.modelServiceBaseUrl ?? '';
    _byokModelId = initial?.modelServiceModelId ?? '';
    _status = initial?.status ?? 'published';
    _runtimeEnvironmentUuid = initial?.runtimeEnvironmentUuid ?? '';
    _allowInternetAccess = initial?.allowInternetAccess ?? true;
    _avatarUrl = initial?.avatarUrl ?? '';
    _avatarDisplayUrl = initial?.avatarDisplayUrl ?? '';
    _selectedSkillLabels = Map<String, String>.from(initial?.skillLabels ?? {});
    _selectedAppLabels = Map<String, String>.from(initial?.appLabels ?? {});
    _selectedKnowledgeBaseLabels =
        Map<String, String>.from(initial?.knowledgeBaseLabels ?? {});
    // Runtime selection does not change the member model catalogue.
    _loadRuntimeEnvironments();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _internalDescriptionController.dispose();
    _welcomeController.dispose();
    _systemPromptController.dispose();
    _tagsController.dispose();
    _agentKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadRuntimeEnvironments() async {
    setState(() {
      _loadingRuntimeEnvironments = true;
      _runtimeLoadError = null;
    });
    try {
      final options =
          await ref.read(chatServiceProvider).listRuntimeEnvironments();
      if (!mounted) return;
      setState(() {
        _runtimeEnvironments =
            options.where((option) => option.isUsable).toList();
        _loadingRuntimeEnvironments = false;
        if (widget.initialDraft == null &&
            _runtimeEnvironmentUuid.isEmpty &&
            _runtimeEnvironments.isNotEmpty) {
          _runtimeEnvironmentUuid =
              _preferredRuntimeEnvironment(_runtimeEnvironments).uuid;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingRuntimeEnvironments = false;
        _runtimeLoadError = 'Agent 类型加载失败，请重试';
      });
    }
  }

  /// 创建态预选顺序: 租户默认环境 → 第一个可用的 dsh 环境 → 列表第一项。
  /// 不再依赖服务端返回顺序 (2026-09-07 新租户默认曾落到 ZAP 示例环境)。
  static RuntimeEnvironmentOption _preferredRuntimeEnvironment(
    List<RuntimeEnvironmentOption> options,
  ) {
    for (final option in options) {
      if (option.isDefault && option.isUsable) return option;
    }
    for (final option in options) {
      if (option.framework.trim().toLowerCase() == 'dsh' && option.isUsable) {
        return option;
      }
    }
    return options.first;
  }

  IconData _agentTypeIcon(RuntimeEnvironmentOption option) {
    if (option.isProfessional) {
      return switch (option.vendor.toLowerCase()) {
        'fia' => Icons.calculate_outlined,
        'talentos' => CupertinoIcons.person_2,
        'yingyan/eagle-sight' => CupertinoIcons.doc_text,
        _ => CupertinoIcons.briefcase,
      };
    }
    return switch (option.agentTypeLabel) {
      'OpenClaw' => CupertinoIcons.cube,
      'DSH' => Icons.psychology_outlined,
      _ => Icons.smart_toy_outlined,
    };
  }

  List<UiSelectOption<String>> _agentTypeOptions() {
    final general =
        _runtimeEnvironments.where((option) => !option.isProfessional).toList();
    const typeOrder = ['OpenClaw', 'Hermes', 'DSH'];
    int rank(RuntimeEnvironmentOption option) {
      final index = typeOrder.indexOf(option.agentTypeLabel);
      return index < 0 ? typeOrder.length : index;
    }

    general.sort((a, b) {
      final order = rank(a).compareTo(rank(b));
      return order != 0
          ? order
          : _runtimeEnvironments
              .indexOf(a)
              .compareTo(_runtimeEnvironments.indexOf(b));
    });
    final ordered = [
      ...general,
      ..._runtimeEnvironments.where((option) => option.isProfessional),
    ];
    return [
      for (final option in ordered)
        UiSelectOption(
          value: option.uuid,
          label: option.agentTypeLabel,
          icon: _agentTypeIcon(option),
          group: option.agentGroup,
          description: ordered
                      .where((item) =>
                          item.agentTypeLabel == option.agentTypeLabel)
                      .length >
                  1
              ? option.name
              : option.agentDescription,
        ),
    ];
  }

  Widget _buildCloudRuntime() {
    if (_loadingRuntimeEnvironments) {
      return const Row(children: [
        CupertinoActivityIndicator(radius: 8),
        SizedBox(width: 8),
        Expanded(child: Text('正在加载 Agent 类型…')),
      ]);
    }
    if (_runtimeLoadError != null || _runtimeEnvironments.isEmpty) {
      return Row(children: [
        Expanded(child: Text(_runtimeLoadError ?? '暂无可用的 Agent 类型')),
        TextButton(
            onPressed: _loadRuntimeEnvironments, child: const Text('重试')),
      ]);
    }
    final available = _runtimeEnvironments
        .any((option) => option.uuid == _runtimeEnvironmentUuid);
    return _FieldBlock(
      label: 'Agent 类型',
      child: UiSelect<String>(
        value: available ? _runtimeEnvironmentUuid : null,
        placeholder: _runtimeEnvironmentUuid.isEmpty
            ? '请选择 Agent 类型'
            : '原 Agent 类型已不可用，请重新选择',
        menuMaxHeight: 390,
        groupTabs: const ['通用智能体', '职业模板'],
        searchPlaceholder: '搜索 Agent 类型...',
        options: _agentTypeOptions(),
        onChanged: (value) => setState(() {
          _runtimeEnvironmentUuid = value ?? '';
          _errorText = null;
        }),
      ),
    );
  }

  Future<void> _pickAvatar() async {
    final file = await pickSingleImage();
    if (file == null || file.path.isEmpty) return;
    setState(() {
      _uploadingAvatar = true;
      // 选中的瞬间就用本地文件先把头像顶上去，保证用户能立刻看到所选图片，
      // 即便后续 S3/内网 URL 客户端无法访问，预览也不会"白屏"。
      _avatarLocalPath = file.path;
      _errorText = null;
    });
    try {
      final uploaded = await ref.read(chatServiceProvider).uploadAgentAvatar(
            filePath: file.path,
            fileName: file.name
          );
      if (!mounted) return;
      setState(() {
        _avatarUrl = uploaded.storageUri;
        _avatarDisplayUrl = uploaded.displayUrl;
        _uploadingAvatar = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _uploadingAvatar = false;
        // 上传失败要清掉本地预览，避免误导以为已经上传成功。
        _avatarLocalPath = null;
        _errorText = '头像上传失败：$error';
      });
    }
  }

  void _useDefaultAvatar() {
    setState(() {
      _avatarUrl = '';
      _avatarDisplayUrl = '';
      _avatarLocalPath = null;
      _errorText = null;
    });
  }

  Future<void> _pickSkills() async {
    // picker 和 CreateAgentDialog 在同一个 Navigator 上叠了两层，
    // 切回 chat 时需要把这两层都 pop 掉再触发上层导航。
    final navigator = Navigator.of(context);

    Map<String, String>? picked;

    void tapCustomSkill(String agentId, String slug) {
      final router = GoRouter.of(context);
      navigator.pop(); // SkillPickerDialog
      navigator.pop(); // CreateAgentDialog / Page
      unawaited(_jumpToAgentChat(agentId, createSkill: false, router: router));
    }

    Future<void> addCustomSkill(BuildContext ctx, SkillGroup group) =>
        _handleAddCustomSkill(navigator, group);

    if (widget.compact) {
      picked = await navigator.push<Map<String, String>>(
        PageRouteBuilder(
          fullscreenDialog: true,
          transitionDuration: const Duration(milliseconds: 320),
          reverseTransitionDuration: const Duration(milliseconds: 280),
          pageBuilder: (_, __, ___) => SkillPickerDialog(
            asPage: true,
            initialSelected: _selectedSkillLabels,
            agentId: widget.agentId,
            onTapCustomSkill: tapCustomSkill,
            onAddCustomSkill: addCustomSkill,
          ),
          transitionsBuilder: (_, animation, __, child) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
            child: child,
          ),
        ),
      );
    } else {
      picked = await showDialog<Map<String, String>>(
        context: context,
        builder: (_) => UncontrolledProviderScope(
          container: ref.container,
          child: SkillPickerDialog(
            initialSelected: _selectedSkillLabels,
            agentId: widget.agentId,
            onTapCustomSkill: tapCustomSkill,
            onAddCustomSkill: addCustomSkill,
          ),
        ),
      );
    }

    if (picked == null || !mounted) return;
    setState(() => _selectedSkillLabels = picked!);
  }

  Future<void> _pickApps() async {
    final picked = await _showCapabilityPicker(
      title: '选择应用',
      subtitle: '选择需要装配到数字员工的客户端应用',
      searchHint: '搜索应用',
      initialSelected: _selectedAppLabels,
      loadOptions: _loadAppOptions,
    );
    if (picked == null || !mounted) return;
    setState(() => _selectedAppLabels = picked);
  }

  Future<void> _pickKnowledgeBases() async {
    final picked = await _showCapabilityPicker(
      title: '选择知识库',
      subtitle: '选择数字员工回答时可参考的知识库',
      searchHint: '搜索知识库',
      initialSelected: _selectedKnowledgeBaseLabels,
      loadOptions: _loadKnowledgeBaseOptions,
    );
    if (picked == null || !mounted) return;
    setState(() => _selectedKnowledgeBaseLabels = picked);
  }

  Future<Map<String, String>?> _showCapabilityPicker({
    required String title,
    required String subtitle,
    required String searchHint,
    required Map<String, String> initialSelected,
    required Future<List<_CapabilityOption>> Function() loadOptions,
  }) {
    // _CapabilityPickerDialog 不读 ref，不依赖 ProviderScope，可直接挂根 navigator（默认值）。
    return showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _CapabilityPickerDialog(
        title: title,
        subtitle: subtitle,
        searchHint: searchHint,
        initialSelected: initialSelected,
        loadOptions: loadOptions,
      ),
    );
  }

  Future<List<_CapabilityOption>> _loadAppOptions() async {
    final categories = await WorkbenchService().fetchApps();
    final seen = <String>{};
    final out = <_CapabilityOption>[];
    for (final category in categories) {
      for (final app in category.apps) {
        final uuid = app.uuid.trim();
        if (uuid.isEmpty || !seen.add(uuid)) continue;
        out.add(
          _CapabilityOption(
            id: uuid,
            label: app.name.isNotEmpty ? app.name : uuid,
            subtitle: _joinNonEmpty([
              category.categoryName,
              app.description
            ]),
            iconUrl: app.icon,
            fallbackIcon: Icons.apps_rounded,
          ),
        );
      }
    }
    return out;
  }

  Future<List<_CapabilityOption>> _loadKnowledgeBaseOptions() async {
    final service = KnowledgeService();
    final lists = await Future.wait([
      service.listKB('personal'),
      service.listKB('org'),
    ]);
    final seen = <String>{};
    final out = <_CapabilityOption>[];
    for (final kb in lists.expand((items) => items)) {
      final uuid = kb.uuid.trim();
      if (uuid.isEmpty || !seen.add(uuid)) continue;
      out.add(
        _CapabilityOption(
          id: uuid,
          label: kb.name.isNotEmpty ? kb.name : uuid,
          subtitle: _knowledgeBaseSubtitle(kb),
          iconUrl: kb.avatarUrl,
          fallbackIcon: Icons.menu_book_rounded,
        ),
      );
    }
    return out;
  }

  String _knowledgeBaseSubtitle(KbItem kb) {
    final scope =
        kb.spaceKind == 'tenant' || kb.scope == 'shared' ? '组织知识库' : '个人知识库';
    return _joinNonEmpty([scope, kb.totalDocumentsLabel]);
  }

  String _joinNonEmpty(List<String> values) {
    return values
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .join(' · ');
  }

  // 处理「添加自定义技能」：
  //   编辑模式直接用当前 agentId；新建模式从 customGroup 反推 agent 列表。
  Future<void> _handleAddCustomSkill(
    NavigatorState navigator,
    SkillGroup customGroup,
  ) async {
    final currentAgentId = widget.agentId?.trim() ?? '';
    if (currentAgentId.isNotEmpty) {
      final router = GoRouter.of(context);
      navigator.pop();
      navigator.pop();
      unawaited(
          _jumpToAgentChat(currentAgentId, createSkill: true, router: router));
      return;
    }
    final agents = <String, String>{};
    for (final s in customGroup.skills) {
      final id = s.agentId;
      if (id == null || id.isEmpty) continue;
      agents[id] = s.agentName ?? id;
    }
    if (agents.isEmpty) {
      BotToast.showText(text: '请先选择数字员工');
      return;
    }
    if (agents.length == 1) {
      final router = GoRouter.of(context);
      navigator.pop();
      navigator.pop();
      unawaited(_jumpToAgentChat(agents.keys.first,
          createSkill: true, router: router));
      return;
    }
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择数字员工'),
        children: agents.entries
            .map(
              (e) => SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(e.key),
                child: Text(e.value),
              ),
            )
            .toList(),
      ),
    );
    if (picked != null && mounted) {
      final router = GoRouter.of(context);
      navigator.pop();
      navigator.pop();
      unawaited(_jumpToAgentChat(picked, createSkill: true, router: router));
    }
  }

  // 在 pop 前捕获 router 及所有 provider 引用，确保 state dispose 后 async 操作仍能完成。
  Future<void> _jumpToAgentChat(
    String? agentId, {
    required bool createSkill,
    required GoRouter router,
  }) async {
    if (agentId == null || agentId.isEmpty) {
      BotToast.showText(text: '请先选择数字员工');
      return;
    }
    // 在第一个 await 前把所有 ref 引用同步读出来。
    final chatService = ref.read(chatServiceProvider);
    final selectedNotifier = ref.read(selectedAgentProvider.notifier);
    final chatFuture = ref.read(chatProvider.future);

    AgentItem? target;
    try {
      final agents = await chatService.listAgents();
      for (final a in agents) {
        if (a.agentId == agentId) {
          target = a;
          break;
        }
      }
    } catch (_) {}

    if (target != null) selectedNotifier.select(target);
    await chatFuture;

    final location = createSkill
        ? '${RoutePaths.chat}?create_skill=true&agentId=$agentId'
        : RoutePaths.chat;
    router.go(location);
  }

  List<String> _readTags() {
    final seen = <String>{};
    final out = <String>[];
    for (final part in _tagsController.text.split(RegExp(r'[,，\n]'))) {
      final value = part.trim();
      if (value.isEmpty || !seen.add(value)) continue;
      out.add(value);
    }
    return out;
  }

  Future<void> _submit() async {
    if (!_canSubmitExecution) {
      setState(() => _errorText = _cloudCreationUnavailable);
      return;
    }
    setState(() => _submitted = true);
    if (!validateUiForm(_formKey)) return;
    final name = _nameController.text.trim();
    // 头像不再强制：后端会用默认数字员工头像兜底。

    Navigator.of(context).pop(
      CreateAgentDraft(
        name: name,
        description: _descriptionController.text.trim(),
        internalDescription: _internalDescriptionController.text.trim(),
        welcomeMsg: _welcomeController.text.trim(),
        systemPrompt: _systemPromptController.text.trim(),
        tags: _readTags(),
        modelPrimary: _modelPrimary,
        modelSource: _modelSource,
        modelServiceEndpointType: _byokEndpointType,
        modelServiceBaseUrl: _byokBaseUrl,
        modelServiceModelId: _byokModelId,
        modelServiceApiKey: null,
        visibility: 'private',
        status: _status,
        runtimeEnvironmentUuid:
            _executionLocus == 'local' ? '' : _runtimeEnvironmentUuid.trim(),
        executionLocus: _executionLocus,
        localEngine: _localEngine,
        agentKey: _agentKeyController.text.trim(),
        allowInternetAccess: _allowInternetAccess,
        contactEnabled: true,
        allowInviteToGroup: true,
        avatarUrl: _avatarUrl.trim(),
        avatarDisplayUrl: _avatarDisplayUrl.trim(),
        position: '',
        positionLabel: '',
        skillSlugs: _selectedSkillLabels.keys.toList(growable: false),
        skillLabels: _selectedSkillLabels,
        appUuids: _selectedAppLabels.keys.toList(growable: false),
        appLabels: _selectedAppLabels,
        knowledgeBaseUuids:
            _selectedKnowledgeBaseLabels.keys.toList(growable: false),
        knowledgeBaseLabels: _selectedKnowledgeBaseLabels,
      ),
    );
  }

  Future<void> _deleteAgent() async {
    final confirmed = await showUiConfirmDialog(
      context,
      title: '删除数字员工',
      description: '删除后不可恢复，确认删除该数字员工吗？',
      confirmLabel: '删除',
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop(const CreateAgentDraft.deleteRequest());
  }

  Widget _buildErrorBanner({double horizontalPadding = 28}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF1F0),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFFFCCC7)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 14, color: Color(0xFFF53F3F)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _errorText!,
                style: const TextStyle(fontSize: 12, color: Color(0xFFF53F3F)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormScroll({EdgeInsetsGeometry? padding}) {
    final basicFields = <Widget>[
      _FieldBlock(
        label: '数字员工名称',
        requiredMark: true,
        child: UiInputField(
          controller: _nameController,
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入数字员工名称' : null,
          hintText: '例如：招聘助手',
          borderRadius: 10,
          onChanged: (_) {
            if (_errorText != null) setState(() => _errorText = null);
          },
        ),
      ),
      const SizedBox(height: 14),
      _FieldBlock(
        label: '主要职责',
        requiredMark: true,
        child: UiInputField(
          controller: _descriptionController,
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入主要职责' : null,
          hintText: '例如：帮助处理招聘流程与候选人答疑',
          minLines: 2,
          maxLines: 3,
          maxLength: 200,
          showCounter: true,
          borderRadius: 10,
        ),
      ),
      const SizedBox(height: 14),
      // 人设写 metadata.system_prompt (与后台"人设"字段同源), 留空由 Bus 按名称/职责渲染兜底。
      _FieldBlock(
        label: '人设（系统提示词）',
        child: UiInputField(
          controller: _systemPromptController,
          hintText: '例如：你是招聘助手，回答专业、简洁。留空则按名称和职责自动生成',
          minLines: 3,
          maxLines: 8,
          maxLength: 4000,
          showCounter: true,
          borderRadius: 10,
        ),
      ),
    ];
    final capabilityFields = <Widget>[
      _FieldBlock(
        label: '核心技能',
        requiredMark: true,
        validator: (_) => _selectedSkillLabels.isEmpty ? '请至少选择一项核心技能' : null,
        child: _CapabilityAssemblyRow(
          buttonLabel: '选择技能',
          selectedLabels: _selectedSkillLabels,
          onTap: _pickSkills,
          onRemove: (id) {
            setState(() {
              _selectedSkillLabels = Map.of(_selectedSkillLabels)..remove(id);
            });
          },
        ),
      ),
      const SizedBox(height: 14),
      _FieldBlock(
        label: '应用',
        child: _CapabilityAssemblyRow(
          buttonLabel: '选择应用',
          selectedLabels: _selectedAppLabels,
          onTap: _pickApps,
          onRemove: (id) {
            setState(() {
              _selectedAppLabels = Map.of(_selectedAppLabels)..remove(id);
            });
          },
        ),
      ),
      const SizedBox(height: 14),
      _FieldBlock(
        label: '知识库',
        child: _CapabilityAssemblyRow(
          buttonLabel: '选择知识库',
          selectedLabels: _selectedKnowledgeBaseLabels,
          onTap: _pickKnowledgeBases,
          onRemove: (id) {
            setState(() {
              _selectedKnowledgeBaseLabels =
                  Map.of(_selectedKnowledgeBaseLabels)..remove(id);
            });
          },
        ),
      ),
    ];
    final welcomeFields = <Widget>[
      _FieldBlock(
        label: '欢迎语',
        child: UiInputField(
          controller: _welcomeController,
          hintText: '例如：你好，我是您的招聘助手，有任何问题都可以问我。',
          minLines: 1,
          maxLines: 3,
          maxLength: 160,
          showCounter: false,
          borderRadius: 10,
        ),
      ),
      const SizedBox(height: 14),
      _FieldBlock(
        label: '标签',
        child: UiInputField(
          controller: _tagsController,
          hintText: '输入标签，按回车添加',
          borderRadius: 10,
        ),
      ),
    ];
    final notesFields = <Widget>[
      _FieldBlock(
        label: '备注（可选）',
        child: UiInputField(
            controller: _internalDescriptionController,
            hintText: '补充给团队成员或维护者看的配置说明，可选',
            minLines: 2,
            maxLines: 3,
            maxLength: 300,
            showCounter: true,
            borderRadius: 10),
      ),
    ];
    final runtimeFields =
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _FieldLabel('运行位置'),
      const SizedBox(height: 10),
      LayoutBuilder(builder: (context, constraints) {
        final choices = <Widget>[
          if (PlatformUtils.isDesktop || _executionLocus == 'local')
            _ExecutionChoice(
              label: '这台电脑',
              subtitle: '处理本机文件、办公和编程',
              badge: '默认',
              icon: CupertinoIcons.desktopcomputer,
              selected: _executionLocus == 'local',
              onTap: _canSelectLocal
                  ? () => setState(() {
                        _executionLocus = 'local';
                        _errorText = null;
                      })
                  : null,
            ),
          _ExecutionChoice(
            label: '云端',
            subtitle: '在云端持续运行',
            badge: AppConfig.cloudAgentCreationEnabled ? null : '暂未开放',
            icon: CupertinoIcons.cloud,
            selected: _executionLocus == 'cloud',
            onTap: AppConfig.cloudAgentCreationEnabled
                ? () => setState(() {
                      _executionLocus = 'cloud';
                      _errorText = null;
                    })
                : null,
          ),
        ];
        if (constraints.maxWidth < 400 ||
            MediaQuery.textScalerOf(context).scale(14) > 21) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < choices.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  choices[i],
                ],
              ]);
        }
        return Row(children: [
          for (var i = 0; i < choices.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: choices[i]),
          ],
        ]);
      }),
      if (!_canSubmitExecution) ...[
        const SizedBox(height: 8),
        Text(_cloudCreationUnavailable,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
      if (_executionLocus == 'local') ...[
        const SizedBox(height: 14),
        const _FieldLabel('本地引擎'),
        const SizedBox(height: 8),
        UiSelect<String>(
          key: const ValueKey('local-engine-select'),
          value: _localEngine,
          enabled: widget.initialDraft?.executionLocus != 'local' &&
              PlatformUtils.isDesktop,
          options: [
            const UiSelectOption(value: 'dsh', label: 'DeepSeek Harness'),
            const UiSelectOption(
                value: 'codex_app_server', label: 'Codex App Server'),
            if (!['dsh', 'codex_app_server'].contains(_localEngine))
              UiSelectOption(value: _localEngine, label: '当前版本不支持的引擎'),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _localEngine = value);
          },
        ),
        const SizedBox(height: 6),
        Text(
            widget.initialDraft?.executionLocus == 'local'
                ? '创建后引擎固定，如需更换请创建新的数字员工。'
                : '由这台电脑运行，模型和工作目录在对话中选择。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
      if (_executionLocus == 'cloud') ...[
        const SizedBox(height: 14),
        FormField<String>(
          validator: (_) => _status == 'published' &&
                  (_loadingRuntimeEnvironments ||
                      _runtimeLoadError != null ||
                      !_runtimeEnvironments.any(
                          (option) => option.uuid == _runtimeEnvironmentUuid))
              ? '请选择可用的 Agent 类型'
              : null,
          builder: (field) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCloudRuntime(),
              UiFormError(field.errorText)
            ],
          ),
        ),
      ],
    ]);
    Widget fields(List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: padding ?? const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AvatarProfileCard(
            compact: widget.compact,
            avatarUrl: _avatarUrl,
            localPath: _avatarLocalPath,
            uploading: _uploadingAvatar,
            onTap: _pickAvatar,
            onUseDefault: _useDefaultAvatar,
          ),
          const SizedBox(height: 16),
          if (widget.compact) ...[
            UiFormSection(title: '基础信息', child: fields(basicFields)),
            const SizedBox(height: 16),
            UiFormSection(title: '能力装配', child: fields(capabilityFields)),
            const SizedBox(height: 16),
            UiFormSection(title: '对话设置', child: fields(welcomeFields)),
            const SizedBox(height: 16),
            UiFormSection(
              title: '运行配置',
              child: fields([
                runtimeFields,
                const SizedBox(height: 16),
                ...notesFields,
              ]),
            ),
          ] else ...[
            const _SectionTitle('基础信息'),
            const SizedBox(height: 14),
            ...basicFields,
            const SizedBox(height: 14),
            ...capabilityFields,
            const SizedBox(height: 14),
            ...welcomeFields,
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                border: Border.all(
                    color: UiFieldStyle.enabledBorderColor(
                        Theme.of(context).colorScheme)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: runtimeFields,
            ),
            const SizedBox(height: 18),
            ...notesFields,
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      autovalidateMode:
          _submitted ? AutovalidateMode.always : AutovalidateMode.disabled,
      child: _buildEditor(context),
    );
  }

  Widget _buildEditor(BuildContext context) {
    if (widget.compact) {
      return Column(
        children: [
          if (_errorText != null) ...[
            const SizedBox(height: 8),
            _buildErrorBanner(),
            const SizedBox(height: 4),
          ],
          Expanded(
            child: _buildFormScroll(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            ),
          ),
          UiFormFooter(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.enableDeleteAction) ...[
                  TextButton(
                    onPressed: _deleteAgent,
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    child: const Text('删除数字员工'),
                  ),
                  const SizedBox(height: 8),
                ],
                UiFormActions(
                  primaryLabel: widget.submitLabel,
                  onPrimary: _canSubmitExecution ? _submit : null,
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            _dialogHorizontalPadding,
            18,
            _dialogHorizontalPadding,
            14,
          ),
          child: UiSheetHeader(
            title: widget.title,
            subtitle: '配置数字员工的基本信息、能力与协作方式',
            onClose: () => Navigator.pop(context),
          ),
        ),
        if (_errorText != null) ...[
          _buildErrorBanner(
            horizontalPadding: _dialogHorizontalPadding
          ),
          const SizedBox(height: 12),
        ],
        Flexible(
          child: _buildFormScroll(
            padding: const EdgeInsets.fromLTRB(
              _dialogHorizontalPadding,
              0,
              _dialogHorizontalPadding,
              0,
            ),
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(
            _dialogHorizontalPadding,
            12,
            _dialogHorizontalPadding,
            16,
          ),
          decoration: const BoxDecoration(
            color: Color(0xF5FFFFFF),
            border: Border(top: BorderSide(color: Color(0xFFEDF2F8))),
            boxShadow: [
              BoxShadow(
                color: Color(0x080F172A),
                blurRadius: 18,
                offset: Offset(0, -8),
              ),
            ],
          ),
          child: Column(
            children: [
              if (widget.enableDeleteAction) ...[
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: _deleteAgent,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFF53F3F),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: const Text('删除数字员工'),
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '* 为必填项',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF667085)
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 140,
                    child: _SecondaryOutlineButton(
                      label: '取消',
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  const SizedBox(width: 14),
                  SizedBox(
                    width: 180,
                    child: _PrimaryGradientButton(
                      label: widget.submitLabel,
                      onPressed: _submit,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =========================== 小组件 =============================

class _FieldBlock extends StatelessWidget {
  const _FieldBlock({
    required this.label,
    required this.child,
    this.requiredMark = false,
    this.validator,
  });

  final String label;
  final Widget child;
  final bool requiredMark;
  final FormFieldValidator<Object?>? validator;

  @override
  Widget build(BuildContext context) {
    if (validator != null) {
      return FormField<Object?>(
        validator: validator,
        builder: (field) => _buildField(field.errorText),
      );
    }
    return _buildField(null);
  }

  Widget _buildField(String? errorText) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label, requiredMark: requiredMark),
        const SizedBox(height: 6),
        child,
        UiFormError(errorText),
      ],
    );
  }
}

class _AvatarProfileCard extends StatelessWidget {
  const _AvatarProfileCard({
    required this.compact,
    required this.avatarUrl,
    required this.localPath,
    required this.uploading,
    required this.onTap,
    required this.onUseDefault,
  });

  final bool compact;
  final String avatarUrl;
  final String? localPath;
  final bool uploading;
  final VoidCallback onTap;
  final VoidCallback onUseDefault;

  @override
  Widget build(BuildContext context) {
    if (compact) return UiFormSection(child: _buildCompactLayout(context));
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 104),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 18,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDFE7F2)),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFFFF), Color(0xFFFBFDFF)],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x080F172A),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: _buildRegularLayout(),
    );
  }

  Widget _buildCompactLayout(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: 56,
            height: 56,
            child: _AvatarUploadPanel(
              avatarUrl: avatarUrl,
              localPath: localPath,
              uploading: uploading,
              onTap: onTap,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '数字员工形象',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                uploading ? '上传中...' : '点击头像更换',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              TextButton(
                onPressed: onUseDefault,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                  minimumSize: const Size(44, 36),
                ),
                child: const Text('恢复默认'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRegularLayout() {
    return Row(
      children: [
        _AvatarUploadPanel(
          avatarUrl: avatarUrl,
          localPath: localPath,
          uploading: uploading,
          onTap: onTap,
        ),
        const SizedBox(width: 22),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '数字员工形象',
                style: TextStyle(
                  fontSize: 16,
                  height: 22 / 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '支持 JPG/PNG 格式，建议尺寸 512×512px 以上',
                style: TextStyle(
                  fontSize: 12,
                  height: 18 / 12,
                  color: Color(0xFF64748B),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: 150,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _UploadAvatarButton(
                uploading: uploading,
                onTap: onTap
              ),
              const SizedBox(height: 8),
              _UseDefaultAvatarButton(onTap: onUseDefault),
            ],
          ),
        ),
      ],
    );
  }
}

class _UploadAvatarButton extends StatelessWidget {
  const _UploadAvatarButton({
    required this.uploading,
    required this.onTap
  });

  final bool uploading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor:
          uploading ? SystemMouseCursors.progress : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: uploading ? null : onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF9DBDFF)),
          ),
          alignment: Alignment.center,
          child: Text(
            uploading ? '上传中...' : '上传头像',
            style: const TextStyle(
              fontSize: 13,
              height: 18 / 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1769FF),
            ),
          ),
        ),
      ),
    );
  }
}

class _UseDefaultAvatarButton extends StatelessWidget {
  const _UseDefaultAvatarButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE4E7EC)),
          ),
          child: const Text(
            '使用默认头像',
            style: TextStyle(
              fontSize: 13,
              height: 18 / 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF162033),
            ),
          ),
        ),
      ),
    );
  }
}

/// 表单字段标签：14/w500/#1D2129。
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text, {this.requiredMark = false});

  final String text;
  final bool requiredMark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return UiFieldStyle.labelText(
      requiredMark ? '$text *' : text,
      TextStyle(
          fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface),
      scheme,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 16,
          decoration: BoxDecoration(
            color: const Color(0xFF2F7BFF),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Color(0xFF162033),
          ),
        ),
      ],
    );
  }
}

class _CapabilityAssemblyRow extends StatelessWidget {
  const _CapabilityAssemblyRow({
    required this.buttonLabel,
    required this.selectedLabels,
    required this.onTap,
    required this.onRemove,
  });

  final String buttonLabel;
  final Map<String, String> selectedLabels;
  final VoidCallback onTap;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 36),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...selectedLabels.entries.map((it) {
            return _SkillChip(
              label: it.value.isEmpty ? it.key : it.value,
              onRemove: () => onRemove(it.key),
            );
          }),
          AgentCapabilitySelectorButton(label: buttonLabel, onTap: onTap),
        ],
      ),
    );
  }
}

/// 已选技能 chip：浅蓝底 + 文字 + 关闭叉。
class _SkillChip extends StatelessWidget {
  const _SkillChip({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F6FF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE0EAFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
              child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF1D2129),
              fontWeight: FontWeight.w500,
            ),
          )),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onRemove,
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: Color(0xFF86909C),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 主操作按钮：满宽蓝色渐变（#4080FF → #165DFF），白字加粗。
class _PrimaryGradientButton extends StatefulWidget {
  const _PrimaryGradientButton({
    required this.label,
    required this.onPressed
  });

  final String label;
  final VoidCallback onPressed;

  @override
  State<_PrimaryGradientButton> createState() => _PrimaryGradientButtonState();
}

class _PrimaryGradientButtonState extends State<_PrimaryGradientButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        // 主按钮 hover 仅保留状态切换，不做过渡动画。
        child: Container(
          width: double.infinity,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: _hover
                  ? const [Color(0xFF5B95FF), Color(0xFF2C6FFF)]
                  : const [Color(0xFF4080FF), Color(0xFF165DFF)],
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF165DFF).withValues(alpha: 0.32),
                blurRadius: _hover ? 18 : 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Text(
            widget.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryOutlineButton extends StatelessWidget {
  const _SecondaryOutlineButton({
    required this.label,
    required this.onPressed
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFDFE7F2)),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 15,
              height: 22 / 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF0F172A),
            ),
          ),
        ),
      ),
    );
  }
}

/// 能力选择按钮：跟随已选 chip 的轻量 pill。
class AgentCapabilitySelectorButton extends StatelessWidget {
  const AgentCapabilitySelectorButton(
      {super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return UiTapSurface(
      onTap: onTap,
      color: scheme.primary.withValues(alpha: 0.035),
      borderRadius: BorderRadius.circular(8),
      child: CustomPaint(
        painter: _DashedRectPainter(
            color: scheme.primary.withValues(alpha: 0.35), radius: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 118, minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add, size: 14, color: scheme.primary),
                const SizedBox(width: 4),
                Flexible(
                    child: Text(label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13,
                            color: scheme.primary,
                            fontWeight: FontWeight.w600))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆角矩形虚线 painter：技能选择按钮使用。
class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dash = 6.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      double dist = 0;
      while (dist < metric.length) {
        canvas.drawPath(
          metric.extractPath(dist, (dist + dash).clamp(0, metric.length)),
          paint,
        );
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter old) =>
      old.color != color || old.radius != radius;
}

class _CapabilityOption {
  const _CapabilityOption({
    required this.id,
    required this.label,
    required this.fallbackIcon,
    this.subtitle = '',
    this.iconUrl = '',
  });

  final String id;
  final String label;
  final String subtitle;
  final String iconUrl;
  final IconData fallbackIcon;

  bool matches(String keyword) {
    final q = keyword.trim().toLowerCase();
    if (q.isEmpty) return true;
    return id.toLowerCase().contains(q) ||
        label.toLowerCase().contains(q) ||
        subtitle.toLowerCase().contains(q);
  }
}

class _CapabilityPickerDialog extends StatefulWidget {
  const _CapabilityPickerDialog({
    required this.title,
    required this.subtitle,
    required this.searchHint,
    required this.initialSelected,
    required this.loadOptions,
  });

  final String title;
  final String subtitle;
  final String searchHint;
  final Map<String, String> initialSelected;
  final Future<List<_CapabilityOption>> Function() loadOptions;

  @override
  State<_CapabilityPickerDialog> createState() =>
      _CapabilityPickerDialogState();
}

class _CapabilityPickerDialogState extends State<_CapabilityPickerDialog> {
  late final TextEditingController _searchController;
  late Map<String, String> _selected;
  List<_CapabilityOption> _options = const [];
  bool _loading = true;
  String _keyword = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected = Map<String, String>.from(widget.initialSelected);
    _searchController = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final options = await widget.loadOptions();
      if (!mounted) return;
      setState(() {
        _options = options;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  List<_CapabilityOption> get _visibleOptions {
    return _options.where((item) => item.matches(_keyword)).toList();
  }

  void _toggle(_CapabilityOption option) {
    setState(() {
      if (_selected.containsKey(option.id)) {
        _selected = Map.of(_selected)..remove(option.id);
      } else {
        _selected = Map.of(_selected)..[option.id] = option.label;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleOptions;
    return UiPickerDialog(
      size: UiDialogSize.standard,
      maxHeight: MediaQuery.sizeOf(context).height - 64,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 18, 14),
            child: UiSheetHeader(
              title: widget.title,
              subtitle: widget.subtitle,
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFEDEFF5)),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 12),
            child: UiSearchField(
              controller: _searchController,
              hintText: widget.searchHint,
              onChanged: (value) => setState(() => _keyword = value),
              borderRadius: 12,
              fillColor: Colors.white,
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CupertinoActivityIndicator(radius: 11))
                : _error != null
                    ? _CapabilityPickerStateView(
                        icon: Icons.error_outline_rounded,
                        title: '加载失败',
                        subtitle: _error!,
                        actionLabel: '重试',
                        onAction: () {
                          setState(() {
                            _loading = true;
                            _error = null;
                          });
                          _load();
                        },
                      )
                    : visible.isEmpty
                        ? const _CapabilityPickerStateView(
                            icon: Icons.inbox_outlined,
                            title: '暂无可选项',
                            subtitle: '换个关键词试试',
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
                            itemBuilder: (context, index) {
                              final option = visible[index];
                              return _CapabilityOptionTile(
                                option: option,
                                selected: _selected.containsKey(option.id),
                                onTap: () => _toggle(option),
                              );
                            },
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemCount: visible.length,
                          ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFEDEFF5))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已选 ${_selected.length} 项',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ),
                SizedBox(
                  width: 112,
                  child: _SecondaryOutlineButton(
                    label: '取消',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 132,
                  child: _PrimaryGradientButton(
                    label: '确定',
                    onPressed: () => Navigator.of(context).pop(_selected),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CapabilityOptionTile extends StatelessWidget {
  const _CapabilityOptionTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final _CapabilityOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFF2F6FF) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color:
                  selected ? const Color(0xFF9DBDFF) : const Color(0xFFE4E7EC),
            ),
          ),
          child: Row(
            children: [
              _CapabilityOptionIcon(option: option),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 21 / 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    if (option.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        option.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 18 / 12,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 22,
                color: selected
                    ? const Color(0xFF1769FF)
                    : const Color(0xFFCBD5E1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CapabilityOptionIcon extends StatelessWidget {
  const _CapabilityOptionIcon({required this.option});

  final _CapabilityOption option;

  @override
  Widget build(BuildContext context) {
    final iconUrl = option.iconUrl.trim();
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFFF2F6FF),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: iconUrl.isNotEmpty
          ? Image.network(
              iconUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Icon(
                option.fallbackIcon,
                size: 24,
                color: const Color(0xFF1769FF),
              ),
            )
          : Icon(
              option.fallbackIcon,
              size: 24,
              color: const Color(0xFF1769FF)
            ),
    );
  }
}

class _CapabilityPickerStateView extends StatelessWidget {
  const _CapabilityPickerStateView({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel = '',
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: const Color(0xFF94A3B8)),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Color(0xFF162033),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
            if (actionLabel.isNotEmpty && onAction != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 圆形头像上传区：参考稿——圆形 + 虚线描边 + 浅蓝光晕，
/// 默认展示 bot_icon.jpeg 作为预留，右下角带蓝色 "+" 角标。
class _AvatarUploadPanel extends StatefulWidget {
  const _AvatarUploadPanel({
    required this.avatarUrl,
    required this.localPath,
    required this.uploading,
    required this.onTap,
  });

  final String avatarUrl;
  final String? localPath;
  final bool uploading;
  final VoidCallback onTap;

  @override
  State<_AvatarUploadPanel> createState() => _AvatarUploadPanelState();
}

class _AvatarUploadPanelState extends State<_AvatarUploadPanel> {
  late String _resolvedAvatarUrl;
  Future<Map<String, String>>? _headersFuture;

  @override
  void initState() {
    super.initState();
    _resolveAvatar();
  }

  @override
  void didUpdateWidget(covariant _AvatarUploadPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.avatarUrl != widget.avatarUrl) {
      _resolveAvatar();
    }
  }

  void _resolveAvatar() {
    final value = widget.avatarUrl.trim();
    _resolvedAvatarUrl = apiImageNeedsAuth(value)
        ? apiImageResolveUrl(value)
        : resolveAgentAvatarUrl(value);
    _headersFuture =
        _resolvedAvatarUrl.isEmpty ? null : apiImageLoadHeaders(value);
  }

  bool get _hasLocalPreview {
    final p = widget.localPath;
    return p != null && p.trim().isNotEmpty;
  }

  Widget _buildAvatarCore() {
    if (_hasLocalPreview) {
      return Image.file(
        File(widget.localPath!),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) =>
            const _DefaultAvatarTile(color: Color(0xFF165DFF)),
      );
    }
    if (_resolvedAvatarUrl.isNotEmpty) {
      return FutureBuilder<Map<String, String>>(
        future: _headersFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _DefaultAvatarTile(color: Color(0xFF165DFF));
          }
          return UiNetworkImage(
            imageUrl: _resolvedAvatarUrl,
            fit: BoxFit.cover,
            clip: false,
            httpHeaders: snap.data,
            cacheKey: _resolvedAvatarUrl,
            placeholderBuilder: (_, __) =>
                const _DefaultAvatarTile(color: Color(0xFF165DFF)),
            errorBuilder: (_, __, ___) =>
                const _DefaultAvatarTile(color: Color(0xFF165DFF)),
          );
        },
      );
    }
    return const _DefaultAvatarTile(color: Color(0xFF165DFF));
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.uploading
          ? SystemMouseCursors.progress
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.uploading ? null : widget.onTap,
        child: SizedBox(
          width: 92,
          height: 92,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 92,
                height: 92,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Color(0x33165DFF),
                      Color(0x00165DFF)
                    ],
                    stops: [0.4, 1],
                  ),
                ),
              ),
              CustomPaint(
                size: const Size(86, 86),
                painter: _DashedCirclePainter(
                  color: const Color(0xFFB7CCFF)
                ),
              ),
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildAvatarCore(),
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: const Color(0xFF165DFF),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.add,
                    size: 11,
                    color: Colors.white
                  ),
                ),
              ),
              if (widget.uploading)
                Positioned.fill(
                  child: ClipOval(
                    child: ColoredBox(
                      color: const Color(0xFF101828).withValues(alpha: 0.32),
                      child: const Center(
                        child: CupertinoActivityIndicator(
                          radius: 11,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 圆形虚线 painter：用在头像外圈。
class _DashedCirclePainter extends CustomPainter {
  _DashedCirclePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: size.width / 2,
    );
    final path = Path()..addOval(rect);
    const dash = 5.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      double dist = 0;
      while (dist < metric.length) {
        canvas.drawPath(
          metric.extractPath(dist, (dist + dash).clamp(0, metric.length)),
          paint,
        );
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter old) => old.color != color;
}

/// 头像未选/加载失败时的默认预留：直接展示产品提供的萌系机器人图。
class _DefaultAvatarTile extends StatelessWidget {
  const _DefaultAvatarTile({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      package: ClientAssets.packageName,
      'assets/bot_icon.jpeg',
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color.withValues(alpha: 0.16),
              color.withValues(alpha: 0.06),
            ],
          ),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.smart_toy_rounded,
          size: 44,
          color: color.withValues(alpha: 0.65),
        ),
      ),
    );
  }
}

class _ExecutionChoice extends StatelessWidget {
  const _ExecutionChoice(
      {required this.label,
      required this.icon,
      required this.selected,
      this.subtitle,
      this.badge,
      this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final String? subtitle;
  final String? badge;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Semantics(
        selected: selected,
        enabled: enabled,
        button: true,
        child: Material(
          color: !enabled
              ? UiFieldStyle.disabledFillColor(scheme)
              : selected
                  ? scheme.primaryContainer.withValues(alpha: .22)
                  : scheme.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                  color: !enabled
                      ? UiFieldStyle.disabledBorderColor(scheme)
                      : selected
                          ? scheme.primary
                          : UiFieldStyle.enabledBorderColor(scheme))),
          child: InkWell(
            onTap: onTap,
            canRequestFocus: enabled,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                          color: selected && enabled
                              ? scheme.primary.withValues(alpha: .06)
                              : null,
                          shape: BoxShape.circle),
                      child: Icon(icon,
                          size: 28,
                          color: enabled
                              ? scheme.primary
                              : scheme.onSurfaceVariant)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                        Wrap(
                            spacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(label,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: onTap == null
                                          ? scheme.onSurfaceVariant
                                          : scheme.onSurface)),
                              if (badge != null)
                                Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                        color: enabled
                                            ? scheme.primaryContainer
                                            : UiFieldStyle.disabledFillColor(
                                                scheme),
                                        borderRadius: BorderRadius.circular(4)),
                                    child: Text(badge!,
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: enabled
                                                ? scheme.onPrimaryContainer
                                                : scheme.onSurfaceVariant))),
                            ]),
                        if (subtitle != null) ...[
                          const SizedBox(height: 5),
                          Text(subtitle!,
                              style: TextStyle(
                                  fontSize: 12, color: scheme.onSurfaceVariant))
                        ],
                      ])),
                  ...[
                    const SizedBox(width: 8),
                    Icon(
                        selected
                            ? CupertinoIcons.largecircle_fill_circle
                            : CupertinoIcons.circle,
                        size: 18,
                        color: selected && enabled
                            ? scheme.primary
                            : scheme.outlineVariant)
                  ],
                ],),
          ),
        ),
      ),
    );
  }
}
