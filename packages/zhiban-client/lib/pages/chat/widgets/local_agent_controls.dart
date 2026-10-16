import 'package:zhiban_client/network/user_refresh.dart';
import 'dart:async';
import 'dart:io';
import 'model_picker_content.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:zhiban_client/services/local_workspace_error.dart';
import 'package:zhiban_client/services/conversation_models.dart';
import 'package:zhiban_client/routes/route_paths.dart';
import 'package:zhiban_client/pages/model_service/widgets/add_provider_dialog.dart'
    show ProviderIcon;

const permissionLabels = {'ask': '请求批准', 'assist': '帮我批准', 'full': '完全访问'};
const permissionDescriptions = {
  'ask': '编辑文件、执行命令与使用互联网前询问',
  'assist': '自动执行常规操作，风险操作前询问',
  'full': '可访问当前账户有权限的文件与网络',
};
Color localWarningColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? Colors.orange.shade300
        : Colors.orange.shade800;

/// Rich menu rows shared by directory, policy and model controls.
class AgentMenuRow extends StatelessWidget {
  const AgentMenuRow(
      {super.key,
      required this.title,
      this.subtitle,
      this.icon,
      this.leading,
      this.trailing,
      this.selected = false,
      this.badge,
      this.color});
  final String title;
  final String? subtitle, badge;
  final IconData? icon;
  final Widget? leading, trailing;
  final bool selected;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
        decoration: BoxDecoration(
            color: selected ? scheme.primary.withValues(alpha: .08) : null,
            borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          if (leading != null || icon != null) ...[
            leading ?? Icon(icon, size: 22, color: color ?? scheme.primary),
            const SizedBox(width: 10)
          ],
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                Wrap(
                    spacing: 7,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: color ??
                                  (selected
                                      ? scheme.primary
                                      : scheme.onSurface))),
                      if (badge != null)
                        Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                                color: scheme.primary.withValues(alpha: .1),
                                borderRadius: BorderRadius.circular(4)),
                            child: Text(badge!,
                                style: TextStyle(
                                    fontSize: 10, color: scheme.primary))),
                    ]),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.4,
                          color: scheme.onSurfaceVariant))
                ],
              ])),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing!
          ],
          if (selected) ...[
            const SizedBox(width: 8),
            Icon(CupertinoIcons.checkmark, size: 16, color: scheme.primary)
          ],
        ]));
  }
}

class AgentControlButton extends StatelessWidget {
  const AgentControlButton(
      {super.key,
      required this.label,
      required this.icon,
      required this.onPressed,
      this.leading,
      this.color,
      this.expanded = false,
      this.compact = false});
  final bool expanded;
  final bool compact;
  final String label;
  final IconData icon;
  final Widget? leading;
  final VoidCallback? onPressed;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.primary;
    return OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
            foregroundColor:
                color ?? (expanded ? scheme.primary : scheme.onSurface),
            backgroundColor: (expanded || compact)
                ? accent.withValues(alpha: .08)
                : scheme.surface,
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 14),
            minimumSize: Size(0, compact ? 26 : 42),
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            side: BorderSide(
                width: expanded ? 1.2 : 1,
                color: expanded
                    ? accent.withValues(alpha: .65)
                    : compact
                        ? accent.withValues(alpha: .3)
                        : color?.withValues(alpha: .4) ??
                            UiFieldStyle.enabledBorderColor(scheme)),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(compact ? 999 : 9))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Opacity(
              opacity: onPressed == null ? .45 : 1,
              child: leading ??
                  Icon(icon, size: compact ? 16 : 22, color: accent)),
          SizedBox(width: compact ? 5 : 10),
          Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: compact ? 12 : 13,
                      fontWeight: FontWeight.w500))),
          SizedBox(width: compact ? 5 : 8),
          Icon(
              expanded
                  ? CupertinoIcons.chevron_up
                  : CupertinoIcons.chevron_down,
              size: 12),
        ]));
  }
}

class LocalAgentControls extends StatefulWidget {
  const LocalAgentControls(
      {super.key,
      required this.agent,
      required this.conversation,
      this.localService,
      this.chooseWorkspaceDirectory});
  final AgentItem agent;
  final String conversation;
  final LocalAgentService? localService;
  final Future<String?> Function()? chooseWorkspaceDirectory;
  @override
  State<LocalAgentControls> createState() => _LocalAgentControlsState();
}

class _LocalAgentControlsState extends State<LocalAgentControls> {
  late final local = widget.localService ?? LocalAgentService.instance;
  final models = ConversationModels.instance;
  final directoryKey = GlobalKey(),
      permissionKey = GlobalKey(),
      modelKey = GlobalKey();
  Map<String, dynamic>? _workspace;
  String _contextId = '', _error = '', _loadError = '';
  String _directoryRecoveryContext = '';
  GlobalKey? _openMenu;
  VoidCallback? _dismissMenu;
  bool _loading = true;
  int _loadRequest = 0;
  int _onlineRevision = 0;
  late bool _wasOnline;
  bool get isLocal => widget.agent.executionLocus == 'local';
  Map<String, dynamic> get _selection =>
      (_workspace?['selection'] as Map?)?.cast<String, dynamic>() ?? {};
  @override
  void initState() {
    super.initState();
    _wasOnline = local.online;
    local.addListener(_runtimeChanged);
    models.addListener(_changed);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LocalAgentControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agent.agentId != widget.agent.agentId ||
        oldWidget.conversation != widget.conversation) {
      _dismissMenu?.call();
      _workspace = null;
      _contextId = '';
      _error = '';
      _loadError = '';
      _directoryRecoveryContext = '';
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _dismissMenu?.call();
    local.removeListener(_runtimeChanged);
    models.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _runtimeChanged() {
    final recovered = local.online && !_wasOnline;
    _wasOnline = local.online;
    if (recovered) _onlineRevision++;
    if (mounted && recovered && !_loading && isLocal) {
      unawaited(_load(refreshModels: false));
    }
    _changed();
  }

  String _workspaceErrorMessage(Object error) {
    if (local.online) {
      return error is LocalWorkspaceError ? error.message : '本地会话信息加载失败，请重试';
    }
    if (local.status == 'connecting') return '本机运行组件正在重新连接，请稍候';
    if (local.status == 'starting') return '本机运行组件正在启动，请稍候';
    return local.errorMessage.isNotEmpty
        ? local.errorMessage
        : '这台电脑的运行组件未连接，请重试';
  }

  Future<void> _load({bool refreshModels = true}) async {
    final request = ++_loadRequest;
    final onlineRevision = _onlineRevision;
    final agent = widget.agent;
    final conversation = widget.conversation;
    bool current() => mounted && request == _loadRequest;
    // Defer notifications until the parent has finished building.
    await Future<void>.delayed(Duration.zero);
    if (!current()) return;
    setState(() => _loading = true);
    if (refreshModels) unawaited(models.load(agent, conversation));
    if (!isLocal || !PlatformUtils.isDesktop) {
      setState(() => _loading = false);
      return;
    }
    try {
      final workspace =
          await local.workspace(agent.agentId, conversation, agent.displayName);
      if (!current()) return;
      final selection = workspace['selection'];
      final prepared = selection is Map ? selection['conversation'] : null;
      final id =
          prepared is String && RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(prepared)
              ? prepared
              : await local.contextId(conversation);
      if (current()) {
        setState(() {
          _workspace = workspace;
          _contextId = id;
          _loadError = '';
          _directoryRecoveryContext = '';
          if (refreshModels) _error = '';
          _loading = false;
        });
      }
    } catch (error) {
      if (current()) {
        // Recovery can happen while an old IPC request is still failing.
        if (local.online && onlineRevision != _onlineRevision) {
          unawaited(_load(refreshModels: false));
          return;
        }
        setState(() {
          _loadError = _workspaceErrorMessage(error);
          _directoryRecoveryContext = error is LocalWorkspaceError &&
                  error.canChooseDirectory &&
                  local.online
              ? error.contextId
              : '';
          _loading = false;
        });
      }
    }
  }

  Future<void> _recoverDirectory() async {
    if (_loading || !local.online || _directoryRecoveryContext.isEmpty) return;
    final employee = widget.agent.agentId;
    final conversation = widget.conversation;
    final contextId = _directoryRecoveryContext;
    final generation = local.lifecycleGeneration;
    final request = ++_loadRequest;
    bool current() =>
        mounted &&
        request == _loadRequest &&
        widget.agent.agentId == employee &&
        widget.conversation == conversation &&
        local.lifecycleGeneration == generation;
    setState(() => _loading = true);
    try {
      final path = await (widget.chooseWorkspaceDirectory?.call() ??
          getDirectoryPath(confirmButtonText: '选择工作目录'));
      if (!current() || path == null) return;
      await local.control('/app/workspaces/select', {
        'employee': employee,
        'conversation': contextId,
        'workspace': path,
        'mode': 'assist',
      });
      if (current()) await _load();
    } catch (error) {
      if (current()) {
        setState(() => _loadError =
            LocalWorkspaceError.from(error, contextId: contextId).message);
      }
    } finally {
      if (mounted && request == _loadRequest) setState(() => _loading = false);
    }
  }

  Future<String?> _menu(
      GlobalKey key, List<PopupMenuEntry<String>> items) async {
    if (_openMenu != null) return null;
    final box = key.currentContext!.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final point = box.localToGlobal(Offset.zero, ancestor: overlay);
    // Anchor above the composer, keeping long menus within the viewport.
    final maxHeight = (overlay.size.height - 40).clamp(
        0.0,
        key == modelKey
            ? 616.0
            : key == directoryKey
                ? 560.0
                : 420.0);
    final height = items
        .fold<double>(12, (h, item) => h + item.height)
        .clamp(0.0, maxHeight);
    final y = (point.dy - height - 8).clamp(8.0, overlay.size.height - 80);
    final width = (key == modelKey
            ? 440.0
            : key == permissionKey
                ? 310.0
                : 340.0)
        .clamp(0.0, overlay.size.width - 32);
    final position = RelativeRect.fromLTRB(
        point.dx,
        y,
        overlay.size.width - point.dx - box.size.width,
        overlay.size.height - y);
    final router = GoRouter.maybeOf(context)?.routerDelegate;
    final pageMatches = router?.currentConfiguration;
    ModalRoute<String>? menuRoute;
    var cancelled = false;
    var removalScheduled = false;
    void dismissMenu() {
      cancelled = true;
      if (removalScheduled) return;
      removalScheduled = true;
      // Navigation/disposal can run while Navigator is building or locked.
      // Remove only our popup, never whatever route is currently on top.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        removalScheduled = false;
        final route = menuRoute;
        if (route != null && route.isActive) {
          route.navigator?.removeRoute(route);
        }
      });
    }

    void routeChanged() {
      if (router?.currentConfiguration != pageMatches) dismissMenu();
    }

    _dismissMenu = dismissMenu;
    router?.addListener(routeChanged);
    setState(() => _openMenu = key);
    try {
      final result = await showMenu<String>(
          context: context,
          menuPadding: key == directoryKey ? EdgeInsets.zero : null,
          positionBuilder: (menuContext, constraints) {
            menuRoute = ModalRoute.of<String>(menuContext);
            if (cancelled) dismissMenu();
            return position;
          },
          constraints: BoxConstraints(
              minWidth: width, maxWidth: width, maxHeight: maxHeight),
          elevation: key == modelKey ? 4 : 8,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(key == modelKey ? 10 : 12),
              side: key == modelKey
                  ? BorderSide(
                      color: UiFieldStyle.enabledBorderColor(
                          Theme.of(context).colorScheme))
                  : BorderSide.none),
          color: Theme.of(context).colorScheme.surface,
          items: items);
      return cancelled ? null : result;
    } finally {
      router?.removeListener(routeChanged);
      _dismissMenu = null;
      if (mounted) setState(() => _openMenu = null);
    }
  }

  PopupMenuEntry<String> _row(String value, String title,
          {String? subtitle,
          IconData? icon,
          Widget? leading,
          Widget? trailing,
          bool selected = false,
          String? badge,
          Color? color}) =>
      PopupMenuItem(
          value: value,
          height: subtitle == null ? 42 : 66,
          child: AgentMenuRow(
              title: title,
              subtitle: subtitle,
              icon: icon,
              leading: leading,
              trailing: trailing,
              selected: selected,
              badge: badge,
              color: color));
  PopupMenuEntry<String> _title(String text) => PopupMenuItem(
      enabled: false,
      height: 34,
      child: Text(text,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface)));
  PopupMenuEntry<String> _note(String text) => PopupMenuItem(
      enabled: false,
      height: 38,
      child: Text(text,
          style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant)));
  Future<void> _select(
      {String? workspace, String? mode, String? confirmation}) async {
    try {
      final next = await local.control('/app/workspaces/select', {
        ..._selection,
        if (workspace != null) 'workspace': workspace,
        if (mode != null) 'mode': mode,
        if (confirmation != null) 'confirmation': confirmation
      });
      if (mounted) {
        setState(() {
          final path = '${next['workspace']}';
          _workspace = {
            ...?_workspace,
            'selection': next,
            'recent': <String>[
              path,
              for (final old in ((_workspace?['recent'] as List?) ?? []))
                if ('$old' != path) '$old'
            ].take(8).toList()
          };
          _error = '';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '目录不可用或权限更新失败，请检查读写权限后重试');
    }
  }

  String _name(String path) =>
      path
          .split(Platform.pathSeparator)
          .where((p) => p.isNotEmpty)
          .lastOrNull ??
      path;
  Future<void> _directory() async {
    final path = '${_selection['workspace']}';
    final defaultPath = '${_workspace?['defaultWorkspace']}';
    final recent = ((_workspace?['recent'] as List?) ?? [])
        .map((p) => '$p')
        .where((p) => p != path && p != defaultPath);
    PopupMenuEntry<String> directoryRow(String value, String name,
            {bool selected = false, bool employeeDirectory = false}) =>
        PopupMenuItem(
            value: value,
            height: 62,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: LocalDirectoryRow(
                path: value,
                name: name,
                selected: selected,
                employeeDirectory: employeeDirectory));
    final scheme = Theme.of(context).colorScheme;
    final availableHeight = MediaQuery.sizeOf(context).height - 56;
    final contentHeight = 222.0 +
        68 * (1 + (path == defaultPath ? 0 : 1) + recent.length) +
        (recent.isEmpty ? 0 : 32);
    final value = await _menu(directoryKey, [
      LocalDirectoryMenuEntry(
        height: contentHeight.clamp(0.0, availableHeight.clamp(0.0, 520.0)),
        header: UiSheetHeader(
            title: '工作目录',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(CupertinoIcons.desktopcomputer,
                  size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text('本机',
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ])),
        directories: [
          _note('当前使用'),
          directoryRow(path,
              path == defaultPath ? widget.agent.displayName : _name(path),
              selected: true, employeeDirectory: path == defaultPath),
          if (path != defaultPath)
            directoryRow(defaultPath, widget.agent.displayName,
                employeeDirectory: true),
          if (recent.isNotEmpty) ...[
            _note('最近使用'),
            for (final p in recent) directoryRow(p, _name(p)),
          ],
        ],
        actions: [
          _row('choose', '选择已有文件夹…', icon: CupertinoIcons.folder_open),
          _row('new', '新建工作目录…', icon: CupertinoIcons.folder_badge_plus),
        ],
      ),
    ]);
    if (value == null || !mounted) return;
    if (value == 'new') {
      final created = await showDialog<String>(
          context: context,
          builder: (_) => NewLocalDirectoryDialog(parent: path));
      if (created != null) await _select(workspace: created);
    } else if (value == 'choose') {
      final picked = await getDirectoryPath(confirmButtonText: '选择工作目录');
      if (picked != null) await _select(workspace: picked);
    } else {
      await _select(workspace: value);
    }
  }

  Future<void> _permission() async {
    final mode = '${_selection['mode'] ?? 'assist'}';
    final choice = await _menu(permissionKey, [
      _title('访问权限'),
      for (final key in permissionLabels.keys)
        _row(key, permissionLabels[key]!,
            subtitle: permissionDescriptions[key],
            icon: key == 'full'
                ? CupertinoIcons.lock_open
                : key == 'ask'
                    ? CupertinoIcons.person_badge_plus
                    : CupertinoIcons.checkmark_shield,
            selected: key == mode,
            color: key == 'full' ? localWarningColor(context) : null),
      const PopupMenuDivider(),
      _note('开启完全访问需要再次确认。'),
    ]);
    if (choice == null || choice == mode || !mounted) return;
    if (choice != 'full') {
      await _select(mode: choice);
      return;
    }
    final approved = await showDialog<bool>(
        context: context, builder: (_) => const FullLocalAccessDialog());
    if (approved != true || !mounted) return;
    try {
      final proof = await local.control(
          '/app/workspaces/full-confirmation', {'conversation': _contextId});
      await _select(mode: 'full', confirmation: '${proof['id']}');
    } catch (_) {
      if (mounted) setState(() => _error = '权限确认已过期，请重试');
    }
  }

  Future<void> _model() async {
    final agent = widget.agent;
    final conversation = widget.conversation;
    final state = models.state(agent.agentId, conversation);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await _menu(modelKey, [
      ModelPickerEntry(
        height: (overlay.size.height - 56).clamp(0.0, 600.0),
        models: state.models,
        selected: state.selected,
        error: state.error,
        modelIcon: _modelIcon,
        platform: _modelPlatform,
        onRefresh: () => UserRefresh.run(() async {
          await models.load(agent, conversation, refresh: true);
          return models.state(agent.agentId, conversation);
        }),
      ),
    ]);
    if (selected == null || !mounted) return;
    if (selected == '@settings') {
      context.push(RoutePaths.modelService);
      return;
    }
    try {
      await models.select(agent.agentId, conversation, selected);
    } catch (_) {
      if (mounted) setState(() => _error = '模型选择未保存，请重试');
    }
  }

  Widget? _modelPlatform(LlmModelOption model) {
    if (model.providerName.isEmpty) return null;
    return Tooltip(
      message: '模型平台：${model.providerName}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 105),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          ProviderIcon(
              iconAssetPath: model.providerIconAssetPath,
              name: model.providerName,
              size: 20),
          const SizedBox(width: 8),
          Flexible(
              child: Text(model.providerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface))),
        ]),
      ),
    );
  }

  Widget _modelIcon(String id, {double size = 24}) {
    final name = id.toLowerCase().split('/').last;
    final provider = name.startsWith('claude')
        ? 'anthropic'
        : name.startsWith('gemini')
            ? 'google'
            : name.startsWith('deepseek')
                ? 'deepseek'
                : name.startsWith('qwen')
                    ? 'qwen'
                    : name.startsWith('kimi') || name.startsWith('moonshot')
                        ? 'moonshot'
                        : name.startsWith('gpt-') ||
                                RegExp(r'^o[1-9](?:-|$)').hasMatch(name)
                            ? 'openai'
                            : null;
    return provider == null
        ? Icon(CupertinoIcons.sparkles,
            size: size, color: Theme.of(context).colorScheme.primary)
        : ProviderIcon(
            iconAssetPath: 'assets/icons/providers/$provider.svg',
            name: id,
            size: size);
  }

  @override
  Widget build(BuildContext context) {
    final displayError = _loadError.isEmpty ? _error : _loadError;
    final state = models.state(widget.agent.agentId, widget.conversation);
    final mode = '${_selection['mode'] ?? 'assist'}';
    final path = '${_selection['workspace'] ?? ''}';
    final selectedModel =
        state.models.where((m) => m.id == state.selected).firstOrNull;
    final label = state.selectionLabel;
    if (PlatformUtils.isMobile) {
      final error = displayError;
      return Tooltip(
        message: error.isEmpty ? label : '$label\n$error',
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: AgentControlButton(
            key: modelKey,
            compact: true,
            label: label,
            icon: CupertinoIcons.sparkles,
            leading: state.loading
                ? const CupertinoActivityIndicator(radius: 7)
                : selectedModel == null
                    ? null
                    : _modelIcon(
                        selectedModel.modelId.isEmpty
                            ? selectedModel.id
                            : selectedModel.modelId,
                        size: 16),
            color: error.isEmpty ? null : Theme.of(context).colorScheme.error,
            expanded: _openMenu == modelKey,
            onPressed: state.loading ? null : _model,
          ),
        ),
      );
    }
    return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isLocal && PlatformUtils.isDesktop && !local.online)
                Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text('本地运行未连接，不会自动转到云端。',
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant))),
              Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (_loading || state.loading)
                      const CupertinoActivityIndicator(radius: 7),
                    if (isLocal && PlatformUtils.isDesktop) ...[
                      ConstrainedBox(
                          constraints: const BoxConstraints(
                              minWidth: 112, maxWidth: 156),
                          child: AgentControlButton(
                              key: directoryKey,
                              label: path.isEmpty ||
                                      path == _workspace?['defaultWorkspace']
                                  ? widget.agent.displayName
                                  : _name(path),
                              icon: CupertinoIcons.folder,
                              expanded: _openMenu == directoryKey,
                              onPressed:
                                  _workspace == null ? null : _directory)),
                      AgentControlButton(
                          key: permissionKey,
                          label: permissionLabels[mode]!,
                          icon: CupertinoIcons.shield,
                          color: mode == 'full'
                              ? localWarningColor(context)
                              : null,
                          expanded: _openMenu == permissionKey,
                          onPressed: _workspace == null ? null : _permission),
                    ],
                    ConstrainedBox(
                        constraints:
                            const BoxConstraints(minWidth: 168, maxWidth: 210),
                        child: AgentControlButton(
                            key: modelKey,
                            label: label,
                            icon: CupertinoIcons.sparkles,
                            leading: selectedModel == null
                                ? null
                                : _modelIcon(selectedModel.modelId.isEmpty
                                    ? selectedModel.id
                                    : selectedModel.modelId),
                            expanded: _openMenu == modelKey,
                            onPressed: state.loading ? null : _model)),
                  ]),
              if (displayError.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          Text(displayError,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context).colorScheme.error)),
                          TextButton(
                              onPressed: _loading
                                  ? null
                                  : () {
                                      setState(() => _loading = true);
                                      unawaited(_load());
                                    },
                              child: const Text('重试')),
                          if (_directoryRecoveryContext.isNotEmpty)
                            TextButton(
                                onPressed: _loading || !local.online
                                    ? null
                                    : _recoverDirectory,
                                child: const Text('选择工作目录')),
                        ])),
            ]));
  }
}

class FullLocalAccessDialog extends StatefulWidget {
  const FullLocalAccessDialog({super.key});
  @override
  State<FullLocalAccessDialog> createState() => _FullLocalAccessDialogState();
}

class _FullLocalAccessDialogState extends State<FullLocalAccessDialog> {
  bool accepted = false;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final warning = localWarningColor(context);
    Widget capability(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          Icon(icon, size: 19, color: scheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
              child: Text(text,
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)))
        ]));
    return UiDialogShell(
        size: UiDialogSize.compact,
        child: Padding(
            padding: const EdgeInsets.all(26),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: warning,
                            borderRadius: BorderRadius.circular(14)),
                        child: Icon(CupertinoIcons.checkmark_shield,
                            color: scheme.surface, size: 24)),
                    const SizedBox(width: 20),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          const UiSheetHeader(title: '开启完全访问？'),
                          const SizedBox(height: 8),
                          Text('该数字员工可在当前系统账户权限内读取、修改文件，并访问互联网。',
                              style: TextStyle(
                                  fontSize: 12,
                                  height: 1.6,
                                  color: scheme.onSurfaceVariant)),
                        ])),
                  ]),
                  const SizedBox(height: 14),
                  Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          border: Border.all(
                              color:
                                  scheme.outlineVariant.withValues(alpha: .4)),
                          borderRadius: BorderRadius.circular(10)),
                      child: Column(children: [
                        capability(CupertinoIcons.doc_text, '可操作工作目录以外的文件'),
                        capability(CupertinoIcons.gear, '常规操作不再逐次询问'),
                        capability(CupertinoIcons.person_2, '不会自动获得系统管理员权限'),
                      ])),
                  const SizedBox(height: 12),
                  Text('仅对当前数字员工在这台电脑上生效，可随时切回「帮我批准」。',
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  InkWell(
                      onTap: () => setState(() => accepted = !accepted),
                      borderRadius: BorderRadius.circular(6),
                      child: Row(children: [
                        SizedBox(
                            width: 26,
                            height: 32,
                            child: Checkbox(
                                value: accepted,
                                activeColor: warning,
                                onChanged: (value) =>
                                    setState(() => accepted = value ?? false))),
                        const SizedBox(width: 6),
                        const Expanded(
                            child: Text('我了解并接受上述风险',
                                style: TextStyle(fontSize: 12))),
                      ])),
                  const SizedBox(height: 10),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    OutlinedButton(
                        style: OutlinedButton.styleFrom(
                            foregroundColor: scheme.onSurface,
                            side: BorderSide(color: scheme.outlineVariant),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8))),
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    const SizedBox(width: 10),
                    FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: warning,
                            disabledBackgroundColor:
                                warning.withValues(alpha: .22),
                            disabledForegroundColor: scheme.surface),
                        onPressed: accepted
                            ? () => Navigator.pop(context, true)
                            : null,
                        child: const Text('确认开启')),
                  ]),
                ])));
  }
}

class LocalDirectoryMenuEntry extends PopupMenuEntry<String> {
  const LocalDirectoryMenuEntry(
      {super.key,
      required this.height,
      required this.header,
      required this.directories,
      required this.actions});
  @override
  final double height;
  final Widget header;
  final List<Widget> directories, actions;
  @override
  bool represents(String? value) => false;
  @override
  State<LocalDirectoryMenuEntry> createState() =>
      _LocalDirectoryMenuEntryState();
}

class _LocalDirectoryMenuEntryState extends State<LocalDirectoryMenuEntry> {
  final scroll = ScrollController();
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
      height: widget.height,
      child: Column(children: [
        Padding(padding: const EdgeInsets.all(16), child: widget.header),
        const Divider(height: 1),
        Expanded(
            child: Scrollbar(
                controller: scroll,
                thickness: 3,
                child: SingleChildScrollView(
                    controller: scroll,
                    child: Column(children: widget.directories)))),
        const Divider(height: 1),
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(children: widget.actions)),
        const Divider(height: 1),
        const Padding(
            padding: EdgeInsets.all(16),
            child: LocalDirectoryHint('切换后仅对新任务生效，原文件保留')),
      ]));
}

String _directoryName(String path) =>
    path
        .split(Platform.pathSeparator)
        .where((part) => part.isNotEmpty)
        .lastOrNull ??
    path;

String _shortDirectoryPath(String path) {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  var display = path;
  if (home != null && path.startsWith('$home${Platform.pathSeparator}')) {
    display = '~${path.substring(home.length)}';
  }
  final parts = display.split(Platform.pathSeparator);
  if (parts.length > 4) {
    display = [
      ...parts.take(3),
      '…',
      ...parts.skip(parts.length > 5 ? parts.length - 2 : parts.length - 1)
    ].join(Platform.pathSeparator);
  }
  return display;
}

class LocalDirectoryHint extends StatelessWidget {
  const LocalDirectoryHint(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(children: [
      Icon(CupertinoIcons.info, size: 16, color: color),
      const SizedBox(width: 8),
      Expanded(
          child: Text(text,
              style: TextStyle(fontSize: 11, height: 1.5, color: color))),
    ]);
  }
}

class LocalDirectoryRow extends StatelessWidget {
  const LocalDirectoryRow(
      {super.key,
      required this.path,
      required this.name,
      this.selected = false,
      this.employeeDirectory = false,
      this.trailing});
  final String path, name;
  final bool selected, employeeDirectory;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: .08) : null,
          borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(CupertinoIcons.folder, size: 26, color: scheme.primary),
        const SizedBox(width: 14),
        Expanded(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(children: [
                Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface))),
                if (employeeDirectory) ...[
                  const SizedBox(width: 8),
                  Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(5)),
                      child: Text('员工目录',
                          style: TextStyle(
                              fontSize: 10, color: scheme.onSurfaceVariant))),
                ],
              ]),
              const SizedBox(height: 4),
              Tooltip(
                  message: path,
                  child: Text(_shortDirectoryPath(path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant))),
            ])),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        if (selected) ...[
          const SizedBox(width: 12),
          Icon(CupertinoIcons.checkmark, size: 18, color: scheme.primary),
        ],
      ]),
    );
  }
}

class NewLocalDirectoryDialog extends StatefulWidget {
  const NewLocalDirectoryDialog({super.key, required this.parent});
  final String parent;
  @override
  State<NewLocalDirectoryDialog> createState() =>
      _NewLocalDirectoryDialogState();
}

class _NewLocalDirectoryDialogState extends State<NewLocalDirectoryDialog> {
  final input = TextEditingController();
  late String parent = widget.parent;
  String error = '';
  bool saving = false;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> create() async {
    setState(() {
      saving = true;
      error = '';
    });
    try {
      final result = await LocalAgentService.instance.control(
          '/app/workspaces/create',
          {'parent': parent, 'name': input.text.trim()});
      if (mounted) Navigator.pop(context, '${result['workspace']}');
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '创建失败：请检查名称、读写权限，以及是否存在同名文件夹。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = input.text.trim();
    final outline = OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: UiFieldStyle.enabledBorderColor(scheme)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)));
    return UiDialogShell(
        size: UiDialogSize.standard,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          UiSheetHeader(
                              title: '新建工作目录',
                              subtitle: '为这次工作整理一个独立文件夹',
                              closeEnabled: !saving,
                              onClose: () => Navigator.pop(context)),
                          const SizedBox(height: 24),
                          UiInputField(
                              controller: input,
                              autofocus: true,
                              enabled: !saving,
                              onChanged: (_) => setState(() {}),
                              label: '文件夹名称',
                              hintText: '例如：季度经营分析'),
                          const SizedBox(height: 20),
                          Text('创建位置',
                              style: TextStyle(
                                  fontSize: 12, color: scheme.onSurface)),
                          const SizedBox(height: 8),
                          Container(
                            decoration: BoxDecoration(
                                color: scheme.surfaceContainerLow,
                                border: Border.all(
                                    color: UiFieldStyle.enabledBorderColor(
                                        scheme)),
                                borderRadius: BorderRadius.circular(10)),
                            child: LocalDirectoryRow(
                                path: parent,
                                name: _directoryName(parent),
                                trailing: OutlinedButton(
                                    style: outline,
                                    onPressed: saving
                                        ? null
                                        : () async {
                                            final path = await getDirectoryPath(
                                                confirmButtonText: '选择创建位置');
                                            if (path != null && mounted) {
                                              setState(() => parent = path);
                                            }
                                          },
                                    child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text('更改…',
                                              style: TextStyle(fontSize: 12)),
                                          SizedBox(width: 8),
                                          Icon(CupertinoIcons.chevron_down,
                                              size: 12),
                                        ]))),
                          ),
                          const SizedBox(height: 10),
                          Tooltip(
                              message: name.isEmpty
                                  ? parent
                                  : '$parent${Platform.pathSeparator}$name',
                              child: Text(
                                  '将创建：${_directoryName(parent)} / ${name.isEmpty ? '文件夹名称' : name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant))),
                          if (error.isNotEmpty)
                            Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(error,
                                    style: TextStyle(
                                        fontSize: 12, color: scheme.error))),
                        ])),
                const Divider(height: 1),
                Padding(
                    padding: const EdgeInsets.all(16),
                    child: LayoutBuilder(builder: (context, constraints) {
                      const hint = LocalDirectoryHint('新任务使用此目录，已有文件保持原位');
                      final actions =
                          Row(mainAxisSize: MainAxisSize.min, children: [
                        OutlinedButton(
                            style: outline,
                            onPressed:
                                saving ? null : () => Navigator.pop(context),
                            child: const Text('取消')),
                        const SizedBox(width: 10),
                        FilledButton(
                            onPressed: saving || name.isEmpty ? null : create,
                            child: saving
                                ? const CupertinoActivityIndicator(radius: 8)
                                : const Text('创建并使用')),
                      ]);
                      if (constraints.maxWidth < 480) {
                        return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              hint,
                              const SizedBox(height: 14),
                              Align(
                                  alignment: Alignment.centerRight,
                                  child: actions)
                            ]);
                      }
                      return Row(children: [
                        const Expanded(child: hint),
                        const SizedBox(width: 12),
                        actions
                      ]);
                    })),
              ],),
        ),
      ),
    );
  }
}
