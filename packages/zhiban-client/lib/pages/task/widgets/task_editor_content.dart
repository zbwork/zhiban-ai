import 'dart:async';

import 'package:zhiban_client/cron/models/prompt_template.dart';
import 'package:zhiban_client/cron/services/prompt_template_service.dart';
import 'package:zhiban_core/chat/chat_models.dart';
import 'package:zhiban_client/pages/task/models/task_models.dart';
import 'package:zhiban_client/pages/task/utils/task_utils.dart';
import 'package:zhiban_ui/zhiban_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class TaskEditorContent extends StatefulWidget {
  const TaskEditorContent({
    required this.onCancel,
    required this.onSubmit,
    this.job,
    this.agents = const <AgentItem>[],
    this.conversations = const <ConversationItem>[],
    this.promptTemplateService,
    this.showHeader = true,
    this.compact = false,
    super.key,
  });

  final CronJob? job;
  final List<AgentItem> agents;
  final List<ConversationItem> conversations;
  final CronPromptTemplateService? promptTemplateService;
  final VoidCallback onCancel;
  final ValueChanged<CronJobDraft> onSubmit;
  final bool showHeader;
  final bool compact;

  @override
  State<TaskEditorContent> createState() => _TaskEditorContentState();
}

class _TaskEditorContentState extends State<TaskEditorContent> {
  final _formKey = GlobalKey<FormState>();
  bool _submitted = false;
  late final TextEditingController _nameController;
  late final TextEditingController _intervalController;
  late final TextEditingController _cronController;
  late final TextEditingController _messageController;

  late bool _enabled;
  late String _scheduleType;
  late String _intervalUnit;
  late int _weekday;
  late int _monthDay;
  late int _scheduleHour;
  late int _scheduleMinute;
  late DateTime? _runOnceAt;
  late String _agentId;
  late String _conversationUuid;
  String _promptMode = 'custom';
  String _templateUuid = '';
  bool _templatesLoading = false;
  List<PromptTemplateSummary> _templates = const <PromptTemplateSummary>[];
  String? _feedbackText;
  bool _feedbackIsError = true;
  Timer? _feedbackTimer;

  @override
  void initState() {
    super.initState();
    final draft = widget.job == null
        ? const CronJobDraft(
            name: '',
            description: '',
            agentId: 'main',
            conversationUuid: '',
            enabled: true,
            scheduleType: 'interval',
            interval: 30,
            intervalUnit: 'minute',
            schedule: '0 0 * * *',
            sessionTarget: 'isolated',
            payloadKind: 'agentTurn',
            message: '',
            wakeMode: 'now',
            timeout: null,
            deliveryMode: 'none',
            deliveryChannel: 'last',
            deliveryRecipient: '',
            promptTemplateUuid: null,
            promptTemplateVariables: <String, dynamic>{},
          )
        : CronJobDraft.fromJob(widget.job!);
    _nameController = TextEditingController(text: draft.name);
    _intervalController = TextEditingController(
      text: draft.interval?.toString() ?? '30',
    );
    _cronController = TextEditingController(text: draft.schedule);
    _messageController = TextEditingController(text: draft.message);
    _enabled = draft.enabled;
    _scheduleType = draft.scheduleType;
    _intervalUnit = draft.intervalUnit;
    _weekday = draft.weekday;
    _monthDay = draft.monthDay;
    _scheduleHour = draft.scheduleHour;
    _scheduleMinute = draft.scheduleMinute;
    _runOnceAt = draft.runOnceAt;
    _agentId = _initialAgentId(draft);
    _conversationUuid = _initialConversationUuid(draft);
    _loadTemplates();
  }

  static final ButtonStyle _cancelButtonStyle = OutlinedButton.styleFrom(
    foregroundColor: const Color(0xFF1F2329),
    side: const BorderSide(color: Color(0xFFE5E6EB)),
    textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  );

  static final ButtonStyle _submitButtonStyle = FilledButton.styleFrom(
    backgroundColor: const Color(0xFF2563EB),
    foregroundColor: Colors.white,
    textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  );

  // cron DOW 取值顺序按周一..周日展示（0=周日排最后）。
  static const List<int> _weekdayItems = [1, 2, 3, 4, 5, 6, 0];
  static final List<int> _monthDayItems =
      List<int>.generate(31, (index) => index + 1);
  static final List<int> _hourItems = List<int>.generate(24, (index) => index);
  static final List<int> _minuteItems =
      List<int>.generate(60, (index) => index);

  static String _weekdayText(int value) {
    switch (value) {
      case 1:
        return '周一';
      case 2:
        return '周二';
      case 3:
        return '周三';
      case 4:
        return '周四';
      case 5:
        return '周五';
      case 6:
        return '周六';
      default:
        return '周日';
    }
  }

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    _nameController.dispose();
    _intervalController.dispose();
    _cronController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Widget _buildScheduleFields(bool isNarrow) {
    final typeField = _TaskEditorSelect<String>(
      label: '重复方式',
      value: _scheduleType,
      items: const ['interval', 'cron', 'once'],
      labelBuilder: (value) => switch (value) {
        'cron' => 'Cron 表达式',
        'once' => '单次执行',
        _ => '固定频率',
      },
      onChanged: (value) => setState(() => _scheduleType = value),
    );
    final cronField = _TaskEditorInput(
      label: 'Cron 表达式 *',
      controller: _cronController,
      hintText: '如：0 8 * * *',
      validator: (value) => _requiredText(value, '请输入 Cron 表达式'),
    );
    final unitField = _TaskEditorSelect<String>(
      label: '单位',
      value: _intervalUnit,
      items: const ['minute', 'hour', 'day', 'week', 'month'],
      labelBuilder: taskIntervalUnitText,
      onChanged: (value) => setState(() => _intervalUnit = value),
    );
    // day 不提供「每隔 N」：5 字段 cron 的日字段 */N 每月 1 日重新起算，
    // 表达不了准确的「每 N 天」，与周模式同理锁 N=1（详见 F08）。
    final showIntervalField =
        _intervalUnit == 'minute' || _intervalUnit == 'hour';
    final intervalField = _TaskEditorInput(
      label: '每隔 *',
      controller: _intervalController,
      hintText: '30',
      validator: _validateInterval,
      keyboardType: TextInputType.number,
    );
    final onceField = _TaskEditorDateTimeField(
      label: '执行时间 *',
      value: _runOnceAt,
      validator: _validateRunOnce,
      onChanged: (value) => setState(() => _runOnceAt = value),
    );

    // 重复方式 + 每隔（分钟/小时档才有）+ 单位 / Cron 表达式 / 执行时间，统一放
    // 同一行；每隔排在单位前面（原顺序是"先选单位、再展示每隔"，现在对调）。
    final topRowFields = <Widget>[
      typeField,
      if (_scheduleType == 'interval' && showIntervalField) intervalField,
      if (_scheduleType == 'interval') unitField,
      if (_scheduleType == 'cron') cronField,
      if (_scheduleType == 'once') onceField,
    ];
    final showDetailRow = _scheduleType == 'interval' &&
        (_intervalUnit == 'day' ||
            _intervalUnit == 'week' ||
            _intervalUnit == 'month');

    if (isNarrow) {
      return Column(
        children: [
          for (var i = 0; i < topRowFields.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            topRowFields[i],
          ],
          if (showDetailRow) ...[
            const SizedBox(height: 14),
            _buildIntervalDetailFields(isNarrow: true),
          ],
        ],
      );
    }

    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < topRowFields.length; i++) ...[
              if (i > 0) const SizedBox(width: 18),
              Expanded(child: topRowFields[i]),
            ],
          ],
        ),
        if (showDetailRow) ...[
          const SizedBox(height: 14),
          _buildIntervalDetailFields(isNarrow: false),
        ],
      ],
    );
  }

  Widget _buildIntervalDetailFields({required bool isNarrow}) {
    final fields = <Widget>[];
    if (_intervalUnit == 'week') {
      fields.add(
        _TaskEditorSelect<int>(
          label: '星期 *',
          value: _weekday,
          items: _weekdayItems,
          labelBuilder: _weekdayText,
          onChanged: (value) => setState(() => _weekday = value),
        ),
      );
    }
    if (_intervalUnit == 'month') {
      fields.add(
        _TaskEditorSelect<int>(
          label: '每月日期 *',
          value: _monthDay,
          items: _monthDayItems,
          labelBuilder: (value) => '$value 日',
          onChanged: (value) => setState(() => _monthDay = value),
        ),
      );
    }
    if (_intervalUnit == 'day' ||
        _intervalUnit == 'week' ||
        _intervalUnit == 'month') {
      fields
        ..add(
          _TaskEditorSelect<int>(
            label: '时',
            value: _scheduleHour,
            items: _hourItems,
            labelBuilder: _twoDigits,
            onChanged: (value) => setState(() => _scheduleHour = value),
          ),
        )
        ..add(
          _TaskEditorSelect<int>(
            label: '分',
            value: _scheduleMinute,
            items: _minuteItems,
            labelBuilder: _twoDigits,
            onChanged: (value) => setState(() => _scheduleMinute = value),
          ),
        );
    }

    if (isNarrow) {
      return Column(
        children: [
          for (var i = 0; i < fields.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            fields[i],
          ],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < fields.length; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          Expanded(child: fields[i]),
        ],
      ],
    );
  }

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');

  Future<void> _loadTemplates() async {
    setState(() => _templatesLoading = true);
    try {
      final items =
          await (widget.promptTemplateService ?? CronPromptTemplateService())
              .listVisibleTemplates();
      if (!mounted) return;
      setState(() {
        _templates = items;
        _templatesLoading = false;
      });
      if (_promptMode == 'template' &&
          _templateUuid.isEmpty &&
          items.isNotEmpty) {
        await _selectTemplate(items.first.uuid);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _templatesLoading = false);
    }
  }

  /// 选模板 = 把模板正文直接粘进「助手任务提示」输入框，员工可继续编辑；
  /// 提交时按普通自定义提示词发送（客户端不再走变量表单 / template_uuid 链路，
  /// 产品决策 2026-06-12：变量能力保留在后台，客户端用「粘贴后自由编辑」交互）。
  Future<void> _selectTemplate(String uuid) async {
    setState(() => _templateUuid = uuid);
    if (uuid.trim().isEmpty) return;
    try {
      final detail =
          await (widget.promptTemplateService ?? CronPromptTemplateService())
              .getVariables(uuid);
      if (!mounted) return;
      setState(() {
        _messageController.text = detail.templateBody;
      });
    } catch (_) {
      if (!mounted) return;
      _showFeedback('模板已下线或无权限');
    }
  }

  void _showFeedback(String text, {bool isError = true}) {
    _feedbackTimer?.cancel();
    setState(() {
      _feedbackText = text;
      _feedbackIsError = isError;
    });
    _feedbackTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _feedbackText = null);
    });
  }

  String? _validateInterval(String? value) {
    final n = int.tryParse(value?.trim() ?? '');
    if (n == null || n <= 0) return '请输入有效的间隔数值（大于 0）';
    if (_intervalUnit == 'minute' && n < 5) {
      return '执行间隔最少 5 分钟（平台限制），请调大间隔';
    }
    if (_intervalUnit == 'minute' && n > 59) {
      return '分钟间隔最大 59，更长间隔请改用小时单位';
    }
    return null;
  }

  String? _validateRunOnce(String? _) {
    if (_runOnceAt == null) return '请选择执行时间';
    if (_runOnceAt!.isBefore(DateTime.now())) return '执行时间不能早于当前时间';
    return null;
  }

  String? _requiredText(String? value, String message) =>
      value == null || value.trim().isEmpty ? message : null;

  void _submit() {
    setState(() => _submitted = true);
    if (!validateUiForm(_formKey)) return;
    final groupWarning = _groupMembershipWarning;
    if (groupWarning != null) {
      _showFeedback(groupWarning);
      return;
    }
    widget.onSubmit(
      CronJobDraft(
        name: _nameController.text.trim(),
        description: widget.job?.description ?? '',
        agentId: _agentId,
        conversationUuid: _conversationUuid,
        enabled: _enabled,
        scheduleType: _scheduleType,
        // 天/周/月模式不展示「每隔 N」，统一锁 N=1；仅分钟/小时读输入框。
        interval: _intervalUnit == 'minute' || _intervalUnit == 'hour'
            ? int.tryParse(_intervalController.text.trim())
            : 1,
        intervalUnit: _intervalUnit,
        weekday: _weekday,
        monthDay: _monthDay,
        scheduleHour: _scheduleHour,
        scheduleMinute: _scheduleMinute,
        runOnceAt: _runOnceAt,
        schedule: _cronController.text.trim(),
        sessionTarget: widget.job?.sessionTarget ?? 'isolated',
        payloadKind: widget.job?.payload.kind.isNotEmpty == true
            ? widget.job!.payload.kind
            : 'agentTurn',
        message: _messageController.text.trim(),
        wakeMode: widget.job?.wakeMode ?? 'now',
        timeout: null,
        deliveryMode: widget.job?.delivery.mode ?? 'none',
        deliveryChannel: widget.job?.delivery.to == 'last'
            ? 'last'
            : widget.job?.delivery.to ?? 'last',
        deliveryRecipient: '',
        // 客户端统一按渲染后的纯文本 prompt 提交；模板只是「内容起点」，
        // 选完即粘贴可编辑，不再回传 template_uuid / variables。
        promptTemplateUuid: null,
        promptTemplateVariables: const <String, dynamic>{},
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
    final agentIds = _agentIds();
    final conversationIds = _conversationIds();
    final isNarrow = widget.compact;
    return Column(
      mainAxisSize: widget.showHeader ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (widget.showHeader)
          Padding(
            padding: EdgeInsets.fromLTRB(
              isNarrow ? 16 : 20,
              18,
              isNarrow ? 16 : 20,
              0,
            ),
            child: UiSheetHeader(
              title: widget.job == null ? '新建任务' : '编辑任务',
              onClose: widget.onCancel,
            ),
          ),
        if (_feedbackText != null) ...[
          const SizedBox(height: 12),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: isNarrow ? 16 : 20),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10
              ),
              decoration: BoxDecoration(
                color: _feedbackIsError
                    ? const Color(0xFFFFF1EF)
                    : const Color(0xFFE8F8F2),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _feedbackIsError
                      ? const Color(0xFFFECACA)
                      : const Color(0xFFB7E4C7),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _feedbackIsError
                        ? CupertinoIcons.exclamationmark_triangle_fill
                        : CupertinoIcons.check_mark_circled_solid,
                    size: 16,
                    color: _feedbackIsError
                        ? const Color(0xFFB42318)
                        : const Color(0xFF157F5A),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _feedbackText!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _feedbackIsError
                            ? const Color(0xFFB42318)
                            : const Color(0xFF157F5A),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Flexible(
          fit: widget.compact ? FlexFit.tight : FlexFit.loose,
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isNarrow ? 16 : 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TaskEditorSection(
                    compact: widget.compact,
                    title: '基本信息',
                    subtitle: '命名、填写提示并设置启用状态。',
                    child: isNarrow
                        ? Column(
                            children: [
                              _TaskEditorInput(
                                label: '名称 *',
                                controller: _nameController,
                                hintText: '如：晨间简报',
                                validator: (value) =>
                                    _requiredText(value, '请输入任务名称'),
                              ),
                              const SizedBox(height: 14),
                              _TaskEditorSwitchField(
                                label: '启用',
                                caption: '创建后立即启用',
                                value: _enabled,
                                onChanged: (value) =>
                                    setState(() => _enabled = value),
                              ),
                              const SizedBox(height: 14),
                              _buildPromptEditor(),
                            ],
                          )
                        : Column(
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _TaskEditorInput(
                                      label: '名称 *',
                                      controller: _nameController,
                                      hintText: '如：晨间简报',
                                      validator: (value) =>
                                          _requiredText(value, '请输入任务名称'),
                                    ),
                                  ),
                                  const SizedBox(width: 18),
                                  Expanded(
                                    child: _TaskEditorSwitchField(
                                      label: '启用',
                                      caption: '创建后立即启用',
                                      value: _enabled,
                                      onChanged: (value) =>
                                          setState(() => _enabled = value),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              _buildPromptEditor(),
                            ],
                          ),
                  ),
                  const SizedBox(height: 16),
                  _TaskEditorSection(
                    compact: widget.compact,
                    title: '执行',
                    subtitle: _selectedAgentIsLocal
                        ? '电脑需保持登录和在线；离线错过的任务恢复后补跑一次。沿用投递会话的模型与工作目录。'
                        : '到点由哪个数字员工执行这个任务。',
                    child: _TaskEditorSelect<String>(
                      label: widget.job == null ? '数字员工 *' : '数字员工（创建后不可更改）',
                      value: agentIds.contains(_agentId)
                          ? _agentId
                          : (agentIds.isEmpty ? '' : agentIds.first),
                      items: agentIds.isEmpty ? const [''] : agentIds,
                      labelBuilder: _agentLabel,
                      validator: (_) => _requiredText(_agentId, '请选择数字员工'),
                      onChanged: _onAgentChanged,
                      enabled: widget.job == null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _TaskEditorSection(
                    compact: widget.compact,
                    title: '调度',
                    subtitle: '控制任务运行时间。',
                    child: _buildScheduleFields(isNarrow),
                  ),
                  const SizedBox(height: 16),
                  _TaskEditorSection(
                    compact: widget.compact,
                    title: '投递',
                    subtitle: _selectedAgentIsLocal
                        ? '执行结果发到该数字员工的单聊。'
                        : '执行结果发到哪个会话（该数字员工的单聊，或它所在的群聊）。',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _TaskEditorSelect<String>(
                          label: '投递会话 *',
                          value: conversationIds.contains(_conversationUuid)
                              ? _conversationUuid
                              : (conversationIds.isEmpty
                                  ? ''
                                  : conversationIds.first),
                          items: conversationIds.isEmpty
                              ? const ['']
                              : conversationIds,
                          labelBuilder: _conversationLabel,
                          validator: (_) =>
                              _requiredText(_conversationUuid, '请选择投递会话'),
                          onChanged: _selectConversation,
                        ),
                        if (_groupMembershipWarning != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _groupMembershipWarning!,
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: Color(0xFFDC2626),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
        if (widget.compact)
          UiFormFooter(
            child: UiFormActions(
              primaryLabel: widget.job == null ? '创建' : '保存',
              onPrimary: _submit,
              secondaryLabel: '取消',
              onSecondary: widget.onCancel,
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  style: _cancelButtonStyle,
                  onPressed: widget.onCancel,
                  child: const Text('取消'),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  style: _submitButtonStyle,
                  onPressed: _submit,
                  child: Text(widget.job == null ? '创建' : '保存'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  bool get _selectedAgentIsLocal => widget.agents.any(
      (agent) => agent.agentId == _agentId && agent.executionLocus == 'local');

  List<AgentItem> get _usableAgents => widget.agents
      .where((a) => a.agentId.trim().isNotEmpty)
      .toList(growable: false);

  List<ConversationItem> get _usableConversations => widget.conversations
      .where((c) =>
          c.conversationId.trim().isNotEmpty &&
          !c.conversationId.startsWith('pending:') &&
          (c.agentId.trim().isNotEmpty || c.isGroup))
      .toList(growable: false);

  /// 当前执行者可投递的真实会话：它自己的既有单聊 + 已创建且能明确
  /// 确认包含该数字员工的群聊；缺成员数据的群不进候选，后端 R8 继续最终严校。
  List<ConversationItem> get _conversationsForAgent =>
      _usableConversations.where((c) {
        if (_selectedAgentIsLocal) {
          return !c.isGroup &&
              (c.roomUuid ?? '').isEmpty &&
              c.kind == 'single' &&
              c.agentId == _agentId;
        }
        if (!c.isGroup) return c.agentId == _agentId;
        return c.participants
            .any((p) => p.kind == 'agent' && p.agentUuid == _agentId);
      }).toList(growable: false);

  List<String> _agentIds() =>
      _usableAgents.map((a) => a.agentId).toSet().toList(growable: false);

  List<String> _conversationIds() {
    if (_agentId.trim().isEmpty) return const <String>[];
    final candidates = _conversationsForAgent;
    String? existingDirect;
    for (final c in candidates) {
      if (!c.isGroup && c.agentId == _agentId) {
        existingDirect = c.conversationId;
        break;
      }
    }
    final ids = <String>{
      existingDirect ?? taskDirectDeliveryTargetId(_agentId),
      ...candidates.where((c) => c.isGroup).map((c) => c.conversationId),
    }.toList(growable: false);
    return ids;
  }

  /// 切换执行者后默认回到该数字员工的单聊目标；若真实单聊尚不存在，使用
  /// 仅存在于表单内的逻辑 target，提交时转成 delivery_kind=direct 交给 Bus ensure。
  void _onAgentChanged(String value) {
    setState(() {
      _agentId = value;
      _conversationUuid = _defaultDirectTargetId(value);
    });
  }

  String _defaultDirectTargetId(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) return '';
    for (final c in _usableConversations) {
      if (!c.isGroup && c.agentId == normalized) return c.conversationId;
    }
    return taskDirectDeliveryTargetId(normalized);
  }

  /// 选了群聊但执行者不在群里 → 表单内联提示（后端 R8 双向成员校验会拒，
  /// 提前在客户端给出可读提示）。新候选已排除成员信息不明的群。
  String? get _groupMembershipWarning {
    if (_agentId.trim().isEmpty || _conversationUuid.trim().isEmpty) {
      return null;
    }
    ConversationItem? conv;
    for (final c in widget.conversations) {
      if (c.conversationId == _conversationUuid) {
        conv = c;
        break;
      }
    }
    if (conv == null || !conv.isGroup || conv.participants.isEmpty) {
      return null;
    }
    final inGroup = conv.participants
        .any((p) => p.kind == 'agent' && p.agentUuid == _agentId);
    if (inGroup) return null;
    return '「${_agentLabel(_agentId)}」不在该群聊中，请先在群里添加它，再创建此任务';
  }

  String _initialAgentId(CronJobDraft draft) {
    final fromDraft = draft.agentId.trim();
    if (fromDraft.isNotEmpty && fromDraft != 'main') return fromDraft;
    // 新建任务的默认执行者只能来自可选数字员工；历史会话
    // 是下游投递候选，不能反向决定执行者。
    return _usableAgents.isEmpty ? '' : _usableAgents.first.agentId;
  }

  String _initialConversationUuid(CronJobDraft draft) {
    final fromDraft = draft.conversationUuid.trim();
    if (fromDraft.isNotEmpty && _conversationIds().contains(fromDraft)) {
      return fromDraft;
    }
    // 默认始终回到执行者自己的单聊；不存在真实会话时使用
    // 逻辑 target，也不退到其它员工/群聊。
    return _defaultDirectTargetId(_agentId);
  }

  String _agentLabel(String id) {
    if (id.isEmpty) return '暂无可用数字员工';
    for (final a in _usableAgents) {
      if (a.agentId == id) return a.displayName;
    }
    return id;
  }

  String _conversationLabel(String id) {
    if (id.isEmpty) return '暂无可用会话';
    if (isTaskDirectDeliveryTarget(id)) {
      return '单聊 · ${_agentLabel(_agentId)}';
    }
    for (final c in _usableConversations) {
      if (c.conversationId == id) {
        final kind = c.isGroup ? '群聊' : '单聊';
        final title = c.title.trim().isEmpty ? id : c.title.trim();
        return '$kind · $title';
      }
    }
    return id;
  }

  void _selectConversation(String value) {
    // 执行数字员工决定投递候选范围；选择投递目标不能反向改写执行者。
    setState(() => _conversationUuid = value);
  }

  Widget _buildPromptEditor() {
    final templateIds = _templates.map((e) => e.uuid).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TaskEditorSelect<String>(
          label: '执行内容来源',
          value: _promptMode,
          items: const ['custom', 'template'],
          labelBuilder: (value) => value == 'template' ? '使用模板' : '自定义提示',
          onChanged: (value) {
            setState(() => _promptMode = value);
            if (value == 'template' &&
                _templateUuid.isEmpty &&
                _templates.isNotEmpty) {
              _selectTemplate(_templates.first.uuid);
            }
          },
        ),
        const SizedBox(height: 14),
        if (_promptMode == 'template') ...[
          _TaskEditorSelect<String>(
            label: '任务模板',
            value: templateIds.contains(_templateUuid)
                ? _templateUuid
                : (templateIds.isEmpty ? '' : templateIds.first),
            items: templateIds.isEmpty ? const [''] : templateIds,
            labelBuilder: _templateLabel,
            onChanged: _selectTemplate,
          ),
          if (_templatesLoading) ...[
            const SizedBox(height: 10),
            const Text(
              '模板加载中…',
              style: TextStyle(fontSize: 12, color: Color(0xFF667085)),
            ),
          ],
          const SizedBox(height: 14),
          // 选完模板正文直接粘贴到下面，可继续编辑后提交（与自定义提示同一输入框）。
          _TaskEditorInput(
            label: '助手任务提示 *',
            controller: _messageController,
            validator: (value) => _requiredText(
                value, _promptMode == 'template' ? '请选择模板并确认提示内容' : '请输入执行内容'),
            hintText: '选择模板后内容会填充到这里，可继续修改。',
            minLines: 5,
            maxLines: 8,
          ),
        ] else
          _TaskEditorInput(
            label: '助手任务提示 *',
            controller: _messageController,
            validator: (value) => _requiredText(
                value, _promptMode == 'template' ? '请选择模板并确认提示内容' : '请输入执行内容'),
            hintText: '描述你希望代理定时执行的任务。',
            minLines: 5,
            maxLines: 8,
          ),
      ],
    );
  }

  String _templateLabel(String uuid) {
    if (uuid.isEmpty) return '暂无可用模板';
    for (final t in _templates) {
      if (t.uuid == uuid) return t.name;
    }
    return uuid;
  }
}

class _TaskEditorSection extends StatelessWidget {
  const _TaskEditorSection({
    required this.title,
    required this.subtitle,
    required this.child,
    this.compact = false,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return UiFormSection(title: title, subtitle: subtitle, child: child);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE7ECF5)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF101828).withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Color(0xFF162033),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF667085)
            ),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _TaskEditorInput extends StatelessWidget {
  const _TaskEditorInput({
    required this.label,
    required this.controller,
    required this.hintText,
    this.keyboardType,
    this.validator,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final FormFieldValidator<String>? validator;
  final String label;
  final TextEditingController controller;
  final String hintText;
  final TextInputType? keyboardType;
  final int minLines;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return UiInputField(
      label: label,
      validator: validator,
      controller: controller,
      hintText: hintText,
      keyboardType: keyboardType,
      minLines: minLines,
      maxLines: maxLines,
    );
  }
}

/// 「单次执行」的日期+时间选择器：外观跟 [_TaskEditorInput] 一致（复用
/// `UiInputField` 的 label/边框），点击态是禁用输入的只读展示——用
/// `AbsorbPointer` 挡住键盘/光标，外层 `GestureDetector` 接管点击，串联系统
/// 日期选择器 + 时间选择器（先选日期，再选时间；跟 emp_blocks_view 里
/// datetime 字段同款交互）。
class _TaskEditorDateTimeField extends StatefulWidget {
  const _TaskEditorDateTimeField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.validator,
  });

  final FormFieldValidator<String>? validator;
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;

  @override
  State<_TaskEditorDateTimeField> createState() =>
      _TaskEditorDateTimeFieldState();
}

class _TaskEditorDateTimeFieldState extends State<_TaskEditorDateTimeField> {
  late final TextEditingController _controller =
      TextEditingController(text: _format(widget.value));

  @override
  void didUpdateWidget(covariant _TaskEditorDateTimeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _controller.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _pick,
      child: AbsorbPointer(
        child: UiInputField(
          label: widget.label,
          validator: widget.validator,
          controller: _controller,
          hintText: '选择日期和时间',
          suffixIcon: const Icon(CupertinoIcons.calendar, size: 18),
        ),
      ),
    );
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final current = widget.value;
    final initialDate = current != null && current.isAfter(now)
        ? current
        : now.add(const Duration(minutes: 5));
    if (PlatformUtils.isDesktop) {
      // 桌面端鼠标滚轮无法驱动 Cupertino 滚轮选择器，走系统日历 + 时间两步弹框。
      final date = await showDatePicker(
        context: context,
        initialDate: initialDate,
        firstDate: now,
        lastDate: DateTime(now.year + 5),
      );
      if (date == null || !mounted) return;
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(
          hour: initialDate.hour,
          minute: initialDate.minute,
        ),
      );
      if (time == null) return;
      widget.onChanged(
        DateTime(date.year, date.month, date.day, time.hour, time.minute),
      );
      return;
    }
    var picked = initialDate;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    onPressed: () => Navigator.of(sheetContext).pop(false),
                    child: const Text('取消'),
                  ),
                  CupertinoButton(
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                    child: const Text('确定'),
                  ),
                ],
              ),
              SizedBox(
                height: 216,
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.dateAndTime,
                  use24hFormat: true,
                  minimumDate: now,
                  maximumDate: DateTime(now.year + 5),
                  initialDateTime: initialDate,
                  onDateTimeChanged: (value) => picked = value,
                ),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true) return;
    widget.onChanged(picked);
  }

  static String _format(DateTime? dt) {
    if (dt == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _TaskEditorSelect<T> extends StatelessWidget {
  const _TaskEditorSelect({
    required this.label,
    required this.value,
    required this.items,
    required this.labelBuilder,
    required this.onChanged,
    this.enabled = true,
    this.validator,
  });

  final FormFieldValidator<T>? validator;
  final String label;
  final T value;
  final List<T> items;
  final String Function(T value) labelBuilder;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (validator != null) {
      return FormField<T>(
        initialValue: value,
        validator: (_) => validator!(value),
        builder: (field) => _buildSelect(context, field.errorText),
      );
    }
    return _buildSelect(context, null);
  }

  Widget _buildSelect(BuildContext context, String? errorText) {
    final labelColor = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UiFieldStyle.labelText(
          label,
          TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: labelColor,
          ),
          Theme.of(context).colorScheme,
        ),
        const SizedBox(height: 6),
        UiSelect<T>(
          value: value,
          enabled: enabled,
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
          placeholder: label,
          menuMaxHeight: 220,
          options: items
              .map(
                (item) => UiSelectOption<T>(
                  value: item,
                  label: labelBuilder(item)
                ),
              )
              .toList(),
        ),
        UiFormError(errorText),
      ],
    );
  }
}

class _TaskEditorSwitchField extends StatelessWidget {
  const _TaskEditorSwitchField({
    required this.label,
    required this.caption,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String caption;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final labelColor = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: labelColor,
          ),
        ),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              UiSwitch(
                value: value,
                onChanged: onChanged
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  caption,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: labelColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
