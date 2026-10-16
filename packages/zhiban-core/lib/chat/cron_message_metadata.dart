/// CronMessageMetadata · F08 §8.2 #11
///
/// 解析 message.metadata 中由 cron service 写入的字段, 区分:
///  - `CronMessageKind.trigger`: 由 cron scheduler 触发数字员工的 system 消息;
///    后端 sender 双 NULL, 客户端按 owner 与 job 信息渲染 "来自定时任务 …" chip.
///  - `CronMessageKind.failureNotice`: 连续失败到阈值后由 cron service 在原会话
///    发的"任务已自动暂停"道歉系统消息; 后端 sender_agent_id 落数字员工 id.
///
/// 设计原则 (与 F08 v0.4 文档对齐):
///  - 字段 key 兼容老 (`job_uuid` / `run_uuid`) + 新 (`cron_*`) 两套.
///  - 不展示完整 rendered_prompt; 不假造 owner display name (拿不到就只显示任务名).
///  - 解析失败统一返 null, caller 渲染层判 null 即不显示 chip, 不抛异常.
class CronMessageMetadata {
  const CronMessageMetadata({
    required this.kind,
    required this.jobName,
    this.jobUuid,
    this.runUuid,
    this.ownerAccountId,
    this.agentUuid,
    this.agentId,
    this.consecutiveFailures,
    this.failureThreshold,
    this.lastErrorMessage,
    this.runStatus,
  });

  final CronMessageKind kind;

  /// 任务展示名; 兜底 "定时任务" 由 chip 层负责, 这里如缺直接 null.
  final String? jobName;

  /// 反查任务用; 兼容老 `job_uuid` / 新 `cron_job_uuid`.
  final String? jobUuid;

  /// 反查运行记录用; 兼容老 `run_uuid` / 新 `cron_run_uuid`.
  final String? runUuid;

  /// 设置者 account id; UI 拿到客户端 account display name 时优先用 name, 否则
  /// 文案里不展示设置者 (不假造 "设置者 #42").
  final int? ownerAccountId;

  /// 数字员工 uuid / id; failure notice chip 用来反查 agent display name.
  final String? agentUuid;
  final int? agentId;

  /// 仅 failure notice 上携带 (用于"已连续失败 N/M 次"提示).
  final int? consecutiveFailures;
  final int? failureThreshold;
  final String? lastErrorMessage;

  /// 2026-06-12 run 终态语义: trigger 消息初始 "running", run 终态时后端 patch 为
  /// "succeeded"/"failed"/"cancelled"; null = 老消息，卡片按已推送处理。
  final String? runStatus;

  /// 解析 message.metadata; 不是 cron 消息返 null.
  ///
  /// 识别规则 (与 F08 §1.3 / §4.5 对齐):
  ///  1. metadata.triggered_by == "cron" → trigger
  ///  2. metadata.kind == "cron_failure_notice" → failureNotice
  ///  3. 未来 WuKong extra 用同一份 `kind`/`triggered_by`, 也会走这条路径.
  static CronMessageMetadata? tryParse(Map<String, dynamic>? metadata) {
    if (metadata == null || metadata.isEmpty) return null;

    final triggeredBy = _readString(metadata['triggered_by']);
    final kindRaw = _readString(metadata['kind']);

    final CronMessageKind? kind;
    if (kindRaw == 'cron_failure_notice') {
      kind = CronMessageKind.failureNotice;
    } else if (triggeredBy == 'cron' ||
        kindRaw == 'cron_trigger' /* future WuKong extra */) {
      kind = CronMessageKind.trigger;
    } else {
      kind = null;
    }
    if (kind == null) return null;

    return CronMessageMetadata(
      kind: kind,
      jobName: _readString(metadata['cron_job_name']),
      jobUuid: _readString(metadata['cron_job_uuid']) ??
          _readString(metadata['job_uuid']),
      runUuid: _readString(metadata['cron_run_uuid']) ??
          _readString(metadata['run_uuid']),
      ownerAccountId: _readInt(metadata['cron_owner_account_id']),
      agentUuid: _readString(metadata['cron_agent_uuid']),
      agentId: _readInt(metadata['cron_agent_id']),
      consecutiveFailures: _readInt(metadata['cron_consecutive_failures']),
      failureThreshold: _readInt(metadata['cron_failure_threshold']),
      lastErrorMessage: _readString(metadata['last_error_message']),
      runStatus: _readString(metadata['cron_run_status']),
    );
  }

  bool get isTrigger => kind == CronMessageKind.trigger;
  bool get isFailureNotice => kind == CronMessageKind.failureNotice;

  /// chip 显示文案 (任务名, 不含设置者; 设置者由 UI 视上下文决定是否拼接).
  /// 任务名缺失时 fallback 到通用文案, 避免显示空 chip.
  String get displayJobLabel {
    final name = (jobName ?? '').trim();
    if (name.isEmpty) return '定时任务';
    return name;
  }
}

enum CronMessageKind {
  trigger,
  failureNotice,
}

String? _readString(dynamic v) {
  if (v == null) return null;
  if (v is String) {
    final t = v.trim();
    return t.isEmpty ? null : t;
  }
  return v.toString();
}

int? _readInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
