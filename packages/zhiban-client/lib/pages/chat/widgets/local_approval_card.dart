import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:zhiban_client/services/local_agent_service.dart';
import 'package:zhiban_client/services/local_runtime_api.dart';
import 'package:zhiban_ui/utils/platform_utils.dart';
import 'package:zhiban_ui/widgets/ui_sheet_header.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'local_agent_controls.dart' show localWarningColor;

class LocalApprovalPanel extends ConsumerStatefulWidget {
  const LocalApprovalPanel(
      {super.key,
      required this.conversation,
      this.showRequests = true,
      this.showStatus = true});
  final String conversation;
  final bool showRequests;
  final bool showStatus;
  @override
  ConsumerState<LocalApprovalPanel> createState() => _LocalApprovalPanelState();
}

class _LocalApprovalPanelState extends ConsumerState<LocalApprovalPanel>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _loading = false, _foreground = true;
  int _epoch = 0;
  List<Map<String, dynamic>> _pending = [];
  late final LocalRuntimeApi _api;
  @override
  void initState() {
    super.initState();
    _api = ref.read(localRuntimeApiProvider);
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed ||
        (PlatformUtils.isDesktop &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.inactive);
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_foreground) return;
    _timer = Timer(Duration.zero, () => unawaited(_refresh()));
  }

  Future<void> _refresh() async {
    if (!mounted || !_foreground || _loading) return;
    _loading = true;
    final epoch = _epoch;
    try {
      final status = await _api.desktopStatus();
      final online = status.available;
      final pending = online && widget.showRequests
          ? await _api.approvals(widget.conversation)
          : <Map<String, dynamic>>[];
      if (!mounted || !_foreground || epoch != _epoch) return;
      ref.read(localDesktopOnlineProvider.notifier).state = online;
      ref.read(localDesktopStatusMessageProvider.notifier).state =
          status.message;
      setState(() => _pending = pending);
    } catch (_) {
      if (!mounted || !_foreground || epoch != _epoch) return;
      ref.read(localDesktopOnlineProvider.notifier).state = false;
      ref.read(localDesktopStatusMessageProvider.notifier).state =
          '暂时无法确认电脑状态，请检查网络';
      setState(() => _pending = []);
    } finally {
      _loading = false;
      if (mounted && _foreground) {
        _timer?.cancel();
        _timer = Timer(const Duration(seconds: 1), () => unawaited(_refresh()));
      }
    }
  }

  @override
  void didUpdateWidget(covariant LocalApprovalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversation != widget.conversation ||
        oldWidget.showRequests != widget.showRequests) {
      _epoch++;
      _pending = [];
      _schedule();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _epoch++;
    _foreground = state == AppLifecycleState.resumed ||
        (PlatformUtils.isDesktop && state == AppLifecycleState.inactive);
    _timer?.cancel();
    if (!_foreground) {
      ref.read(localDesktopOnlineProvider.notifier).state = false;
      setState(() => _pending = []);
    } else {
      _schedule();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the published availability alive even when only this panel is mounted.
    ref.watch(localDesktopOnlineProvider);
    final statusMessage = ref.watch(localDesktopStatusMessageProvider);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (widget.showStatus && !PlatformUtils.isDesktop)
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Text(statusMessage,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant))),
      if (_pending.isNotEmpty)
        ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: SingleChildScrollView(
                child: Column(children: [
              for (final request in _pending)
                LocalApprovalCard(
                    key: ValueKey(request['id']),
                    request: {
                      ...request,
                      'intent': PlatformUtils.isDesktop &&
                              LocalAgentService
                                      .instance.approvals[request['id']] !=
                                  null
                          ? LocalAgentService
                              .instance.approvals[request['id']]!['intent']
                          : {
                              'tool': request['display']?['tool'],
                              'operation': request['display']?['operation'],
                              'args': {'name': request['display']?['target']}
                            },
                    },
                    onAnswer: (approved, scope) async {
                      await _api.decide(request, approved, scope);
                      if (!mounted) return;
                      _epoch++;
                      setState(() => _pending
                          .removeWhere((item) => item['id'] == request['id']));
                      unawaited(_refresh());
                    }),
            ]))),
    ]);
  }
}

class LocalApprovalCard extends StatefulWidget {
  const LocalApprovalCard(
      {super.key,
      required this.request,
      required this.onAnswer,
      this.inSheet = false,
      this.inDialog = false});
  final Map<String, dynamic> request;
  final Future<void> Function(bool approved, String scope) onAnswer;
  final bool inSheet;
  final bool inDialog;
  @override
  State<LocalApprovalCard> createState() => _LocalApprovalCardState();
}

class _LocalApprovalCardState extends State<LocalApprovalCard> {
  bool busy = false;
  String error = '';
  Future<void> answer(bool approved, String scope) async {
    setState(() => busy = true);
    try {
      await widget.onAnswer(approved, scope);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '审批已过期或任务已停止，请查看任务状态';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final intent = widget.request['intent'] as Map? ?? {};
    final args = intent['args'] as Map? ?? {};
    final operation = '${intent['operation'] ?? ''}';
    final search = intent['tool'] == 'search_files';
    final computer = intent['tool'] == 'computer';
    final name = const {
          'read': '读取文件',
          'write': '新建文件',
          'overwrite': '覆盖文件',
          'delete': '删除文件',
          'shell': '执行命令',
          'network': '访问网络',
          'browser': '操作浏览器',
          'desktop': '操作桌面',
          'upload': '上传文件'
        }[operation] ??
        '本机操作';
    String? target;
    for (final value in [
      args['path'],
      args['relativePath'],
      args['url'],
      args['command'],
      args['app'],
      args['name']
    ]) {
      if (value is String && value.trim().isNotEmpty) {
        target = value;
        break;
      }
    }
    // A remote display may contain only the redundant tool identifier.
    if (target == intent['tool'] && target == operation) target = null;
    if (search && args['scope'] != null) {
      target =
          '${args['scope'] == 'home' ? '用户主目录' : '当前工作目录'}${args['path'] == '' ? '' : ' / ${args['path']}'}';
    }
    if (computer && args['action'] != null) {
      target = [
        target,
        if (args['text'] != null) '输入：${args['text']}',
        if (args['key'] != null) '按键：${args['modifiers']} ${args['key']}',
        if (args['element'] != null) '控件：${args['element']}',
        if (args['x'] != null) '窗口坐标：${args['x']}, ${args['y']}',
        if (args['direction'] != null) '方向：${args['direction']}',
      ].whereType<String>().join('\n');
    }
    final employeeName = '${widget.request['employee_name'] ?? ''}'.trim();
    final embedded = widget.inSheet || widget.inDialog;
    final warning = localWarningColor(context);
    final outsideRead = operation == 'read';
    final actionTitle = search
        ? '检索本机文件'
        : outsideRead
            ? '读取文件'
            : name;
    final actionSubtitle = search
        ? '统计文件数量或搜索文件名'
        : computer
            ? (const {
                  'list_apps': '查找已安装的应用',
                  'open_app': '打开应用',
                  'inspect': '读取应用界面',
                  'screenshot': '截取应用窗口',
                  'click': '点击界面控件',
                  'click_at': '点击窗口内的位置',
                  'type_text': '填写文本',
                  'key': '发送按键',
                  'scroll': '滚动界面'
                }[args['action']] ??
                '操作指定应用')
            : outsideRead
                ? '查看工作目录外的文件内容'
                : operation == 'browser'
                    ? '访问网页、点击按钮或填写表单'
                    : operation == 'shell'
                        ? '在授权工作目录内执行命令'
                        : '对当前任务中的目标执行本次操作';
    final risk = search
        ? '只检索文件名和数量，不读取文件内容。'
        : outsideRead
            ? '本次只读取文件，不会修改或删除原件。'
            : operation == 'overwrite' || operation == 'delete'
                ? '此操作会修改或删除已有内容，请确认对象后批准。'
                : null;
    return Container(
      margin:
          embedded ? EdgeInsets.zero : const EdgeInsets.fromLTRB(14, 6, 14, 8),
      padding: EdgeInsets.all(widget.inDialog
          ? 28
          : widget.inSheet
              ? 20
              : 16),
      decoration: embedded
          ? null
          : BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: .55)),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: warning.withValues(alpha: .12),
                shape: BoxShape.circle,
              ),
              child: Icon(CupertinoIcons.clock, color: warning, size: 23),
            ),
            const SizedBox(width: 14),
            Expanded(
                child: UiSheetHeader(
              title: '等待你的批准',
              subtitle:
                  '${employeeName.isEmpty ? '本地助手' : employeeName}申请使用以下能力',
              trailing:
                  busy ? const CupertinoActivityIndicator(radius: 8) : null,
            )),
          ]),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              border: Border.all(color: scheme.primary.withValues(alpha: .12)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Icon(
                operation == 'network' || operation == 'browser'
                    ? CupertinoIcons.globe
                    : operation == 'shell'
                        ? CupertinoIcons.chevron_left_slash_chevron_right
                        : CupertinoIcons.folder_fill,
                color: scheme.primary,
                size: 28,
              ),
              const SizedBox(width: 16),
              Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(actionTitle,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      )),
                  const SizedBox(height: 4),
                  Text(actionSubtitle,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      )),
                  if (target != null) ...[
                    const SizedBox(height: 8),
                    SelectableText(target,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: scheme.onSurface,
                        )),
                  ],
                ],
              )),
            ]),
          ),
          if (risk != null) ...[
            const SizedBox(height: 12),
            Text(risk,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: outsideRead ? scheme.onSurfaceVariant : warning,
                )),
          ],
          const SizedBox(height: 16),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(CupertinoIcons.shield,
                color: scheme.onSurfaceVariant, size: 20),
            const SizedBox(width: 10),
            Expanded(
                child: Text(
              operation == 'upload'
                  ? '上传文件需逐次批准，仅允许本次操作'
                  : '本次任务允许后，相同操作及参数不再询问\n任务结束后授权自动失效',
              style: TextStyle(
                  fontSize: 12, height: 1.5, color: scheme.onSurfaceVariant),
            )),
          ]),
          const SizedBox(height: 24),
          LayoutBuilder(builder: (context, constraints) {
            final stacked = widget.inSheet ||
                constraints.maxWidth < 440 ||
                MediaQuery.textScalerOf(context).scale(14) > 18;
            final buttonStyle = FilledButton.styleFrom(
              visualDensity: VisualDensity.standard,
              minimumSize: Size.fromHeight(stacked ? 48 : 44),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              textStyle: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            );
            ButtonStyle outlinedStyle(Color foreground, Color border) =>
                buttonStyle.copyWith(
                  foregroundColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.disabled)
                          ? scheme.onSurface.withValues(alpha: .38)
                          : foreground),
                  side: WidgetStateProperty.resolveWith((states) => BorderSide(
                      color: states.contains(WidgetState.disabled)
                          ? scheme.onSurface.withValues(alpha: .12)
                          : border)),
                );
            final buttons = <Widget>[
              FilledButton(
                style: buttonStyle,
                onPressed: busy ? null : () => answer(true, 'once'),
                child: const Text('允许本次'),
              ),
              if (operation != 'upload')
                OutlinedButton(
                  style: outlinedStyle(scheme.primary, scheme.primary),
                  onPressed: busy ? null : () => answer(true, 'task'),
                  child: const Text('本次任务允许'),
                ),
              OutlinedButton(
                style: outlinedStyle(scheme.onSurfaceVariant,
                    scheme.onSurfaceVariant.withValues(alpha: .45)),
                onPressed: busy ? null : () => answer(false, 'once'),
                child: const Text('拒绝'),
              ),
            ];
            if (stacked) {
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < buttons.length; i++) ...[
                      if (i > 0) const SizedBox(height: 8),
                      buttons[i],
                    ],
                  ]);
            }
            return Row(children: [
              for (var i = 0; i < buttons.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: buttons[i]),
              ],
            ]);
          }),
          if (error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(error,
                style:
                    TextStyle(fontSize: 12, height: 1.5, color: scheme.error)),
          ],
        ],
      ),
    );
  }
}
