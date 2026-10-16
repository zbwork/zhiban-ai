const String taskDirectDeliveryTargetPrefix = 'direct-agent:';

String taskDirectDeliveryTargetId(String agentUuid) =>
    '$taskDirectDeliveryTargetPrefix${agentUuid.trim()}';

bool isTaskDirectDeliveryTarget(String value) =>
    value.startsWith(taskDirectDeliveryTargetPrefix) &&
    value.substring(taskDirectDeliveryTargetPrefix.length).trim().isNotEmpty;

class CronJob {
  const CronJob({
    required this.id,
    required this.name,
    required this.description,
    required this.agentId,
    required this.conversationUuid,
    required bool enabled,
    required this.schedule,
    required this.timezone,
    required this.sessionTarget,
    required this.wakeMode,
    required this.payload,
    required this.delivery,
    required this.state,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.runOnce = false,
    this.status = '',
    this.adminDisabled = false,
  }) : _enabled = enabled;

  final String id;
  final String name;
  final String description;
  final String agentId;
  final String conversationUuid;
  final bool _enabled;
  final String status;
  final bool adminDisabled;
  bool get enabled =>
      _enabled && (status.isEmpty || status == 'active') && !adminDisabled;
  bool get requiresResume => status == 'error';
  bool get canToggle => !adminDisabled && status != 'archived';
  bool get canRunNow =>
      canToggle &&
      !requiresResume &&
      !(runOnce && !enabled && (state.lastRunAtMs ?? 0) > 0);
  String get schedulingStatusLabel => adminDisabled
      ? '管理员停用'
      : status == 'archived'
          ? '已归档'
          : requiresResume
              ? '异常暂停'
              : '已暂停';
  final CronSchedule schedule;
  final String timezone;
  final String sessionTarget;
  final String wakeMode;
  final CronPayload payload;
  final CronDelivery delivery;
  final CronState state;
  final int createdAtMs;
  final int updatedAtMs;

  /// 「单次执行」变通实现回显：后端 metadata.run_once=true。标准 cron 无年字段，
  /// 落库表达式只能表达"每年这个月这天这个时间点"；后端在任务第一次跑到终态后
  /// 立即自动禁用，防止真的等到下一年重新触发。见 F08 doc「一次性 at-job」范围说明。
  final bool runOnce;

  /// 部分更新副本——主要给前端 toggle / busy 时做乐观刷新用：CupertinoSwitch
  /// 是受控组件，必须父级在 onChanged 触发后立刻喂入新 value 才不会回弹回旧值。
  CronJob copyWith({
    bool? enabled,
    CronState? state,
    String? status
  }) {
    return CronJob(
      id: id,
      name: name,
      description: description,
      agentId: agentId,
      conversationUuid: conversationUuid,
      enabled: enabled ?? _enabled,
      schedule: schedule,
      timezone: timezone,
      sessionTarget: sessionTarget,
      wakeMode: wakeMode,
      payload: payload,
      delivery: delivery,
      state: state ?? this.state,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs,
      runOnce: runOnce,
      status: status ?? this.status,
      adminDisabled: adminDisabled,
    );
  }

  factory CronJob.fromJson(Map<String, dynamic> json) {
    final delivery = CronDelivery.fromJson(
      (json['delivery'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
    final payload = CronPayload.fromJson(
      (json['payload'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
    return CronJob(
      id: (json['uuid'] ?? json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      agentId: (json['agent_uuid'] ?? json['agentId'] ?? 'main').toString(),
      conversationUuid: delivery.conversationUuid,
      enabled: json['enabled'] == true,
      status: (json['status'] ?? '').toString(),
      adminDisabled: json['admin_disabled'] == true,
      schedule: CronSchedule.fromJson(
        json
      ),
      timezone: (json['timezone'] ?? '').toString(),
      sessionTarget: (json['sessionTarget'] ?? 'isolated').toString(),
      wakeMode: (json['wakeMode'] ?? 'now').toString(),
      payload: payload,
      delivery: delivery,
      state: CronState.fromJson(json),
      createdAtMs: _readMs(json['created_at'] ?? json['createdAtMs']),
      updatedAtMs: _readMs(json['updated_at'] ?? json['updatedAtMs']),
      runOnce: json['run_once'] == true,
    );
  }
}

class CronSchedule {
  const CronSchedule({
    required this.kind,
    this.everyMs,
    this.expr
  });

  final String kind;
  final int? everyMs;
  final String? expr;

  factory CronSchedule.fromJson(Map<String, dynamic> json) {
    final nested = (json['schedule'] as Map?)?.cast<String, dynamic>() ?? json;
    final cronExpr = (json['schedule_cron'] ?? nested['expr'])?.toString();
    return CronSchedule(
      kind: cronExpr == null || cronExpr.isEmpty
          ? (nested['kind'] ?? '').toString()
          : 'cron',
      everyMs: nested['everyMs'] == null ? null : _readInt(nested['everyMs']),
      expr: cronExpr,
    );
  }
}

class CronPayload {
  const CronPayload({
    required this.kind,
    this.message,
    this.text
  });

  final String kind;
  final String? message;
  final String? text;

  String get displayText => (message ?? text ?? '').trim();

  factory CronPayload.fromJson(Map<String, dynamic> json) {
    final prompt = json['prompt']?.toString();
    return CronPayload(
      kind: (json['kind'] ?? (prompt == null ? '' : 'agentTurn')).toString(),
      message: json['message']?.toString() ?? prompt,
      text: json['text']?.toString(),
    );
  }
}

class CronDelivery {
  const CronDelivery({
    required this.mode,
    required this.to,
    required this.conversationUuid,
  });

  final String mode;
  final String to;
  final String conversationUuid;

  factory CronDelivery.fromJson(Map<String, dynamic> json) {
    final conv = (json['conversation_uuid'] ?? json['conversationUuid'] ?? '')
        .toString();
    return CronDelivery(
      mode:
          (json['mode'] ?? (conv.isEmpty ? 'none' : 'conversation')).toString(),
      to: (json['to'] ?? conv).toString(),
      conversationUuid: conv,
    );
  }
}

class CronState {
  const CronState({
    this.nextRunAtMs,
    this.lastRunAtMs,
    this.lastRunStatus,
    this.lastDurationMs,
    this.lastDeliveryStatus,
    this.consecutiveErrors = 0,
    this.lastError,
  });

  final int? nextRunAtMs;
  final int? lastRunAtMs;
  final String? lastRunStatus;
  final int? lastDurationMs;
  final String? lastDeliveryStatus;
  final int consecutiveErrors;
  final String? lastError;

  factory CronState.fromJson(Map<String, dynamic> json) {
    final nested = (json['state'] as Map?)?.cast<String, dynamic>() ?? json;
    final rawStatus =
        (json['last_run_status'] ?? nested['lastRunStatus'])?.toString();
    return CronState(
      nextRunAtMs:
          _readNullableMs(json['next_run_at'] ?? nested['nextRunAtMs']),
      lastRunAtMs:
          _readNullableMs(json['last_run_at'] ?? nested['lastRunAtMs']),
      lastRunStatus: _normalizeRunStatus(rawStatus),
      lastDurationMs: nested['lastDurationMs'] == null
          ? null
          : _readInt(nested['lastDurationMs']),
      lastDeliveryStatus: nested['lastDeliveryStatus']?.toString(),
      consecutiveErrors:
          _readInt(json['consecutive_failures'] ?? nested['consecutiveErrors']),
      lastError: json['last_run_summary']?.toString() ??
          nested['lastError']?.toString(),
    );
  }
}

class CronRunEntry {
  const CronRunEntry({
    required this.ts,
    required this.jobId,
    required this.jobName,
    required this.action,
    required this.status,
    required this.summary,
    required this.runAtMs,
    required this.durationMs,
    this.nextRunAtMs,
    this.model,
    this.provider,
    required this.delivered,
    required this.deliveryStatus,
    this.deliveryError,
    this.error,
    this.sessionId,
    this.sessionKey,
    this.conversationUuid,
    this.messageUuid,
    this.jobDeleted = false,
  });

  final int ts;
  final String jobId;
  final String jobName;
  final String action;
  final String status;
  final String summary;
  final int runAtMs;
  final int durationMs;
  final int? nextRunAtMs;
  final String? model;
  final String? provider;
  final bool delivered;
  final String deliveryStatus;
  final String? deliveryError;
  final String? error;
  final String? sessionId;
  final String? sessionKey;

  /// cron-done webhook 已经把这条 run 落到主会话的 conversation_messages 里，
  /// 这里就是那条主会话的 uuid。前端「在对话中查看」直接跳，不用再调 openRunChat。
  final String? conversationUuid;

  /// 那条 cron 消息的 uuid（形如 `cron-<runId>`），用于跳转后 scrollToMessage + 高亮。
  final String? messageUuid;

  /// 任务在 ai-office 镜像表里已软删（OpenClaw 已 cron.remove）。前端展示「已删除」标识。
  final bool jobDeleted;

  bool get isCancelled => status == 'cancelled';

  String get displaySummary {
    final reason = (error ?? '').trim();
    if (isCancelled && (reason.isEmpty || reason == _legacyCancelledRunError)) {
      return '本次执行已停止';
    }
    return reason.isEmpty ? summary.trim() : taskExecutionErrorMessage(reason);
  }

  bool get hasDisplayError => !isCancelled && (error ?? '').trim().isNotEmpty;

  CronRunEntry copyWith({String? jobName}) {
    return CronRunEntry(
      ts: ts,
      jobId: jobId,
      jobName: jobName ?? this.jobName,
      action: action,
      status: status,
      summary: summary,
      runAtMs: runAtMs,
      durationMs: durationMs,
      nextRunAtMs: nextRunAtMs,
      model: model,
      provider: provider,
      delivered: delivered,
      deliveryStatus: deliveryStatus,
      deliveryError: deliveryError,
      error: error,
      sessionId: sessionId,
      sessionKey: sessionKey,
      conversationUuid: conversationUuid,
      messageUuid: messageUuid,
      jobDeleted: jobDeleted,
    );
  }

  factory CronRunEntry.fromJson(Map<String, dynamic> json) {
    final startedAt = json['started_at'] ?? json['runAtMs'] ?? json['ts'];
    var status = _normalizeRunStatus(json['status']?.toString());
    final error =
        json['error_message']?.toString() ?? json['error']?.toString();
    // Older Bus versions collapsed cancellation into failed. Only this exact
    // diagnostic is safe to reinterpret; other failures retain their meaning.
    if (status == 'error' && error?.trim() == _legacyCancelledRunError) {
      status = 'cancelled';
    }
    final runUuid = (json['uuid'] ?? json['run_uuid'] ?? '').toString();
    final jobUuid = (json['job_uuid'] ?? json['jobId'] ?? '').toString();
    return CronRunEntry(
      ts: _readMs(startedAt),
      jobId: jobUuid,
      jobName: (json['jobName'] ?? '').toString(),
      action: (json['trigger_kind'] ?? json['action'] ?? '').toString(),
      status: status ?? '',
      summary: (json['summary'] ?? json['rendered_prompt_snapshot'] ?? '')
          .toString(),
      runAtMs: _readMs(startedAt),
      durationMs: _readInt(json['duration_ms'] ?? json['durationMs']),
      nextRunAtMs: _readNullableMs(json['nextRunAtMs']),
      model: json['model']?.toString(),
      provider: json['provider']?.toString(),
      delivered: (json['message_uuid'] ?? json['messageUuid'] ?? '')
          .toString()
          .isNotEmpty,
      deliveryStatus: (json['deliveryStatus'] ?? '').toString(),
      deliveryError: json['deliveryError']?.toString(),
      error: error,
      sessionId: runUuid.isEmpty ? json['sessionId']?.toString() : runUuid,
      sessionKey: json['sessionKey']?.toString(),
      conversationUuid: json['conversation_uuid']?.toString() ??
          json['conversationUuid']?.toString(),
      messageUuid:
          json['message_uuid']?.toString() ?? json['messageUuid']?.toString(),
      jobDeleted: json['jobDeleted'] == true,
    );
  }
}

/// Shared by history cards and action errors; preserve unrecognized diagnostics.
String taskExecutionErrorMessage(String text) {
  const messages = {
    'cron.job_requires_resume': '任务因异常已暂停，请检查执行记录与定时规则后重新启用。',
    'cron.resume_blocked_by_admin': '任务已被管理员停用，请联系管理员恢复。',
    'cron.job_archived': '任务已归档，无法执行。',
    'cron.job_paused': '任务已暂停，本次未执行。',
  };
  for (final entry in messages.entries) {
    if (text.contains(entry.key)) return entry.value;
  }
  if (text == 'job disabled or in error/archived state') {
    return '任务已暂停、因失败停用或已归档，本次未执行。请检查任务状态后重试。';
  }
  if (text == '请从当前电脑的桌面应用发起本机任务') {
    return '本机执行上下文不可用，请确认桌面已登录在线；定时任务持续失败时请联系管理员检查调度服务版本。';
  }
  return text;
}

class CronRunOpenChatResponse {
  const CronRunOpenChatResponse({
    required this.conversationId,
    required this.alias,
    required this.agentId,
    required this.agentName,
    required this.createdAt,
    this.messageUuid,
  });

  final String conversationId;
  final String alias;
  final String agentId;
  final String agentName;
  final String createdAt;

  /// 当跳到「已存在的 cron 消息」时携带的目标消息 uuid（形如 `cron-<runId>`），
  /// 前端用它在 ChatMessageList 里 ScrollableEnsureVisible + 高亮。
  /// 兜底新建独立会话路径下为 null。
  final String? messageUuid;

  factory CronRunOpenChatResponse.fromJson(Map<String, dynamic> json) {
    return CronRunOpenChatResponse(
      conversationId:
          (json['conversation_uuid'] ?? json['conversationId'] ?? '')
              .toString(),
      alias: (json['alias'] ?? '').toString(),
      agentId: (json['agentId'] ?? '').toString(),
      agentName: (json['agentName'] ?? '').toString(),
      createdAt: (json['createdAt'] ?? '').toString(),
      messageUuid:
          json['message_uuid']?.toString() ?? json['messageUuid']?.toString(),
    );
  }
}

/// 历史 tab 下拉用：账号下"曾经出现过"的所有任务（含已删除）。
class CronJobDistinctEntry {
  const CronJobDistinctEntry({
    required this.jobId,
    required this.name,
    required this.description,
    required this.agentId,
    required this.deleted,
    required this.updatedAtMs,
    this.deletedAtMs,
  });

  final String jobId;
  final String name;
  final String description;
  final String agentId;
  final bool deleted;
  final int updatedAtMs;
  final int? deletedAtMs;

  factory CronJobDistinctEntry.fromJson(Map<String, dynamic> json) {
    return CronJobDistinctEntry(
      jobId: (json['jobId'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      agentId: (json['agentId'] ?? '').toString(),
      deleted: json['deleted'] == true,
      updatedAtMs: _readInt(json['updatedAtMs']),
      deletedAtMs:
          json['deletedAtMs'] == null ? null : _readInt(json['deletedAtMs']),
    );
  }

  /// 从已拉取的 job 列表派生历史下拉条目（Bus F08 暂无 distinct endpoint，
  /// 复用同一份数据避免重复打一次 /cron/jobs）。
  factory CronJobDistinctEntry.fromJob(CronJob job) {
    return CronJobDistinctEntry(
      jobId: job.id,
      name: job.name,
      description: job.description,
      agentId: job.agentId,
      deleted: false,
      updatedAtMs: job.updatedAtMs,
    );
  }
}

/// [CronJobDraft.parseIntervalFromCron] 的反推结果。
class ParsedCronInterval {
  const ParsedCronInterval(
    this.interval,
    this.unit, {
    this.weekday = 1,
    this.monthDay = 1,
    this.scheduleHour = 0,
    this.scheduleMinute = 0,
  });

  final int interval;
  final String unit; // minute | hour | day | week | month
  final int weekday; // 仅 unit=='week'：cron DOW 0=周日,1=周一…6=周六
  final int monthDay; // 仅 unit=='month'：1..31
  final int scheduleHour; // 仅 day/week/month：0..23
  final int scheduleMinute; // 仅 day/week/month：0..59
}

class CronJobDraft {
  const CronJobDraft({
    required this.name,
    required this.description,
    required this.agentId,
    required this.conversationUuid,
    required this.enabled,
    required this.scheduleType,
    required this.interval,
    required this.intervalUnit,
    required this.schedule,
    required this.sessionTarget,
    required this.payloadKind,
    required this.message,
    required this.wakeMode,
    required this.timeout,
    required this.deliveryMode,
    required this.deliveryChannel,
    required this.deliveryRecipient,
    this.weekday = 1,
    this.monthDay = 1,
    this.scheduleHour = 0,
    this.scheduleMinute = 0,
    this.runOnceAt,
    this.promptTemplateUuid,
    this.promptTemplateVariables = const <String, dynamic>{},
  });

  final String name;
  final String description;
  final String agentId;
  final String conversationUuid;
  final bool enabled;
  final String scheduleType;
  final int? interval;
  final String intervalUnit;
  final String schedule;
  final String sessionTarget;
  final String payloadKind;
  final String message;
  final String wakeMode;
  final int? timeout;
  final String deliveryMode;
  final String deliveryChannel;
  final String deliveryRecipient;

  /// 周模式的星期几（cron DOW：0=周日,1=周一…6=周六）。仅 intervalUnit=='week' 时使用。
  /// cron 表达不了「每 N 周」，周模式固定为「每周的星期 X」（编辑器锁定 N=1）。
  final int weekday;

  /// 月模式的执行日期。仅 intervalUnit=='month' 时使用。
  final int monthDay;

  /// 日/周/月模式的执行时间。新建默认 00:00。
  final int scheduleHour;
  final int scheduleMinute;

  /// 「单次执行」（重复方式=once）选中的日期时间。标准 cron 无年字段，落库时只
  /// 取月/日/时/分四段——真正的"仅触发一次"由后端在任务第一次跑到终态后自动
  /// 禁用来保证，见 [toCreateJson] 里的 `run_once` 标记。
  final DateTime? runOnceAt;
  final String? promptTemplateUuid;
  final Map<String, dynamic> promptTemplateVariables;

  Map<String, dynamic> toCreateJson() {
    final logicalDirect = isTaskDirectDeliveryTarget(conversationUuid.trim());
    return {
      'name': name.trim(),
      if (description.trim().isNotEmpty) 'description': description.trim(),
      if (agentId.trim().isNotEmpty) 'agent_uuid': agentId.trim(),
      'enabled': enabled,
      'schedule_cron': toScheduleCron(),
      if (scheduleType == 'once') 'run_once': true,
      if ((promptTemplateUuid ?? '').trim().isNotEmpty) ...{
        'prompt_template_uuid': promptTemplateUuid!.trim(),
        'prompt_template_variables': promptTemplateVariables,
      } else
        'prompt': message.trim(),
      if (logicalDirect)
        'delivery_kind': 'direct'
      else if (conversationUuid.trim().isNotEmpty)
        'conversation_uuid': conversationUuid.trim(),
    };
  }

  /// PATCH 必须显式声明 `run_once` 的 true/false（不能像 CREATE 一样省略 false）：
  /// 编辑已有任务把重复方式从「单次执行」切回「固定频率/Cron」保存时，如果省略
  /// 这个字段，后端会当成"不改"，旧 metadata.run_once 标记不会被清掉，下次执行
  /// 成功后仍会被误自动禁用。
  Map<String, dynamic> toUpdateJson() {
    final json = toCreateJson();
    json['run_once'] = scheduleType == 'once';
    return json;
  }

  String toScheduleCron() {
    if (scheduleType == 'cron') return schedule.trim();
    if (scheduleType == 'once') {
      final at = runOnceAt ?? DateTime.now().add(const Duration(hours: 1));
      return '${_clampInt(at.minute, 0, 59)} ${_clampInt(at.hour, 0, 23)} '
          '${_clampInt(at.day, 1, 31)} ${_clampInt(at.month, 1, 12)} *';
    }
    final n = interval == null || interval! <= 0 ? 30 : interval!;
    final hour = _clampInt(scheduleHour, 0, 23);
    final minute = _clampInt(scheduleMinute, 0, 59);
    switch (intervalUnit) {
      case 'minute':
        return n <= 1 ? '* * * * *' : '*/$n * * * *';
      case 'hour':
        return n <= 1 ? '0 * * * *' : '0 */$n * * *';
      case 'day':
        // 日字段 */N 每月 1 日重新起算，表达不了准确的「每 N 天」；
        // 与周模式同理锁定每天，隔 N 天的需求走 Cron 模式。
        return '$minute $hour * * *';
      case 'week':
        // cron 表达不了「每 N 周」；周模式固定为「每周星期 X」（编辑器锁 N=1）。
        return '$minute $hour * * ${weekday >= 0 && weekday <= 6 ? weekday : 1}';
      case 'month':
        return '$minute $hour ${_clampInt(monthDay, 1, 31)} * *';
      default:
        return '*/30 * * * *';
    }
  }

  factory CronJobDraft.fromJob(CronJob job) {
    // 「单次执行」变通实现必须最先判断：run_once=true 的任务落库的 5 字段 cron
    // 形如 `M H D Mon *`，跟「每月 D 日 HH:MM」的月模式表达式长得一样，如果走
    // 下面的常规反推会被误判成固定频率月模式，编辑时丢失「单次执行」语义。
    if (job.runOnce) {
      return CronJobDraft(
        name: job.name,
        description: job.description,
        agentId: job.agentId,
        conversationUuid: job.conversationUuid,
        enabled: job.enabled,
        scheduleType: 'once',
        interval: null,
        intervalUnit: 'hour',
        runOnceAt: _parseOnceFromCron((job.schedule.expr ?? '').trim()),
        schedule: job.schedule.expr ?? '',
        sessionTarget: job.sessionTarget,
        payloadKind: job.payload.kind.isEmpty ? 'agentTurn' : job.payload.kind,
        message: job.payload.displayText,
        wakeMode: job.wakeMode,
        timeout: null,
        deliveryMode: job.delivery.mode,
        deliveryChannel: job.delivery.conversationUuid.isEmpty
            ? job.delivery.to
            : job.delivery.conversationUuid,
        deliveryRecipient: '',
        promptTemplateUuid: null,
        promptTemplateVariables: const <String, dynamic>{},
      );
    }
    // 后端只存 schedule_cron：先把表达式反推回「固定频率」模式回显，
    // 让「每 30 分钟」再次编辑时仍是人话而不是裸 cron（往返对称）。
    // 反推不了（用户手写的复杂表达式）才落到 Cron 模式。
    final expr = (job.schedule.expr ?? '').trim();
    final parsed = expr.isEmpty ? null : parseIntervalFromCron(expr);
    var isInterval = parsed != null || job.schedule.kind != 'cron';
    var interval = parsed != null
        ? parsed.interval
        : (isInterval ? _intervalFromEveryMs(job.schedule.everyMs) : null);
    var intervalUnit = parsed != null
        ? parsed.unit
        : (isInterval
            ? _intervalUnitFromEveryMs(job.schedule.everyMs)
            : 'hour');
    var schedule = job.schedule.expr ?? '';
    // 编辑器已不提供「每隔 N 天」：everyMs 折算出 N>1 天的存量任务回落 Cron
    // 模式，合成等价表达式回显（与旧版保存时的近似一致），避免界面显示
    // 「每天」而实际隔 N 天执行。
    if (isInterval && intervalUnit == 'day' && (interval ?? 1) > 1) {
      schedule = '0 0 */$interval * *';
      isInterval = false;
      interval = null;
      intervalUnit = 'hour';
    }
    final scheduleType = isInterval ? 'interval' : 'cron';
    return CronJobDraft(
      name: job.name,
      description: job.description,
      agentId: job.agentId,
      conversationUuid: job.conversationUuid,
      enabled: job.enabled,
      scheduleType: scheduleType,
      interval: interval,
      intervalUnit: intervalUnit,
      weekday: parsed?.weekday ?? 1,
      monthDay: parsed?.monthDay ?? 1,
      scheduleHour: parsed?.scheduleHour ?? 0,
      scheduleMinute: parsed?.scheduleMinute ?? 0,
      schedule: schedule,
      sessionTarget: job.sessionTarget,
      payloadKind: job.payload.kind.isEmpty ? 'agentTurn' : job.payload.kind,
      message: job.payload.displayText,
      wakeMode: job.wakeMode,
      timeout: null,
      deliveryMode: job.delivery.mode,
      deliveryChannel: job.delivery.conversationUuid.isEmpty
          ? job.delivery.to
          : job.delivery.conversationUuid,
      deliveryRecipient: '',
      promptTemplateUuid: null,
      promptTemplateVariables: const <String, dynamic>{},
    );
  }

  /// 把 [toScheduleCron] 生成的标准形态反推回间隔模式（往返对称）：
  ///   `* * * * *` / `*/N * * * *`  → 每 1/N 分钟
  ///   `0 * * * *` / `0 */N * * *`  → 每 1/N 小时
  ///   `M H * * *`                  → 每天 HH:MM
  ///   `M H * * D`（D∈0-6）         → 每周星期 D HH:MM
  ///   `M H D * *`（D∈1-31）        → 每月 D 日 HH:MM
  /// 其余形态（手写复杂表达式，含存量「每隔 N 天」`M H */N * *`——编辑器已
  /// 不提供该档位）返回 null → 编辑器按 Cron 模式回显真实表达式。
  static ParsedCronInterval? parseIntervalFromCron(String expr) {
    final parts = expr.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return null;
    final m = parts[0], h = parts[1], dom = parts[2], mon = parts[3];
    final dow = parts[4];
    if (mon != '*') return null;
    int? stepOf(String field) {
      if (field == '*') return 1;
      final match = RegExp(r'^\*/(\d+)$').firstMatch(field);
      final n = match == null ? null : int.tryParse(match.group(1)!);
      return n == null || n <= 0 ? null : n;
    }

    // 每 N 分钟：分钟位为 * 或 */N，其余全 *。
    // （'0 * * * *' 分钟位是具体数值，落到下面的小时分支。）
    if (h == '*' && dom == '*' && dow == '*') {
      final n = stepOf(m);
      if (n != null) return ParsedCronInterval(n, 'minute');
    }
    // 每 N 小时（0 */N * * *）；'0 9 * * *' 这种具体小时落到「每 1 天」。
    if (m == '0' && dom == '*' && dow == '*') {
      final n = stepOf(h);
      if (n != null) return ParsedCronInterval(n, 'hour');
    }

    final minute = int.tryParse(m);
    final hour = int.tryParse(h);
    if (minute == null || hour == null) return null;
    if (minute < 0 || minute > 59 || hour < 0 || hour > 23) return null;

    // 每天 HH:MM：M H * * *。（日字段 */N 不反推：编辑器已不提供「每隔 N 天」，
    // 存量表达式落到 Cron 模式回显，避免显示「每天」实跑隔 N 天。）
    if (dow == '*') {
      if (dom == '*') {
        return ParsedCronInterval(
          1,
          'day',
          scheduleHour: hour,
          scheduleMinute: minute,
        );
      }
      final monthDay = int.tryParse(dom);
      if (monthDay != null && monthDay >= 1 && monthDay <= 31) {
        return ParsedCronInterval(
          1,
          'month',
          monthDay: monthDay,
          scheduleHour: hour,
          scheduleMinute: minute,
        );
      }
      return null;
    }

    // 每周星期 D：M H * * D。
    if (dom == '*') {
      final d = int.tryParse(dow);
      if (d != null && d >= 0 && d <= 6) {
        return ParsedCronInterval(
          1,
          'week',
          weekday: d,
          scheduleHour: hour,
          scheduleMinute: minute,
        );
      }
    }
    return null;
  }

  /// 把「单次执行」落库的 `M H D Mon *` 反推回 [DateTime]（往返对称，供编辑回显）。
  /// cron 无年字段，年份按「离现在最近的未来那次」补：今年这个月日时分还没过就用
  /// 今年，已经过了就用明年——跟后端 finalizeRun 的自动禁用语义一致（真正只会
  /// 触发一次，年份只是回显用的近似值，不影响实际调度）。解析失败返回 null，
  /// 编辑器会要求用户重新选择。
  static DateTime? _parseOnceFromCron(String expr) {
    final parts = expr.split(RegExp(r'\s+'));
    if (parts.length != 5) return null;
    final minute = int.tryParse(parts[0]);
    final hour = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    final month = int.tryParse(parts[3]);
    if (minute == null || hour == null || day == null || month == null) {
      return null;
    }
    if (minute < 0 ||
        minute > 59 ||
        hour < 0 ||
        hour > 23 ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31) {
      return null;
    }
    final now = DateTime.now();
    var candidate = DateTime(now.year, month, day, hour, minute);
    if (candidate.isBefore(now)) {
      candidate = DateTime(now.year + 1, month, day, hour, minute);
    }
    return candidate;
  }

  static int _clampInt(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  static int? _intervalFromEveryMs(int? everyMs) {
    if (everyMs == null || everyMs <= 0) return null;
    if (everyMs % 604800000 == 0) return everyMs ~/ 604800000;
    if (everyMs % 86400000 == 0) return everyMs ~/ 86400000;
    if (everyMs % 3600000 == 0) return everyMs ~/ 3600000;
    if (everyMs % 60000 == 0) return everyMs ~/ 60000;
    return null;
  }

  static String _intervalUnitFromEveryMs(int? everyMs) {
    if (everyMs == null || everyMs <= 0) return 'hour';
    if (everyMs % 604800000 == 0) return 'week';
    if (everyMs % 86400000 == 0) return 'day';
    if (everyMs % 3600000 == 0) return 'hour';
    return 'minute';
  }
}

class CronJobsOverview {
  const CronJobsOverview({
    required this.total,
    required this.enabled,
    required this.runningHealthy,
    required this.withErrors,
  });

  final int total;
  final int enabled;
  final int runningHealthy;
  final int withErrors;
}

int _readInt(dynamic value) {
  if (value is int) return value;
  if (value == null) return 0;
  return int.tryParse(value.toString()) ?? 0;
}

int _readMs(dynamic value) => _readNullableMs(value) ?? 0;

int? _readNullableMs(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  final parsedInt = int.tryParse(text);
  if (parsedInt != null) return parsedInt;
  final dt = DateTime.tryParse(text);
  return dt?.toLocal().millisecondsSinceEpoch;
}

const _legacyCancelledRunError = 'agent run terminal: message.cancelled';

String? _normalizeRunStatus(String? raw) {
  final s = (raw ?? '').trim();
  switch (s) {
    case 'succeeded':
    case 'success':
    case 'ok':
      return 'ok';
    case 'failed':
    case 'error':
      return 'error';
    default:
      return s.isEmpty ? null : s;
  }
}
