import 'package:zhiban_core/utils/error_utils.dart';
import 'package:zhiban_client/pages/task/models/task_models.dart';


String taskScheduleLabel(CronJob job) {
  if (job.schedule.kind == 'cron') {
    final expr = job.schedule.expr?.trim() ?? '';
    if (expr.isEmpty) return '未配置调度';
    if (job.runOnce) {
      final at = _parseOnceLabel(expr);
      if (at != null) return '$at 执行一次';
    }
    final humanized = _humanizeCron(expr);
    // _humanizeCron 不认识时退回给运维看的原表达式，保留可调试性，
    // 但加 "Cron:" 前缀避免用户把 "* / *" 当成奇怪文案。
    return humanized ?? 'Cron: $expr';
  }
  final everyMs = job.schedule.everyMs ?? 0;
  if (everyMs <= 0) return '未配置调度';
  if (everyMs % 604800000 == 0) return '每 ${everyMs ~/ 604800000} 周';
  if (everyMs % 86400000 == 0) return '每 ${everyMs ~/ 86400000} 天';
  if (everyMs % 3600000 == 0) return '每 ${everyMs ~/ 3600000} 小时';
  return '每 ${everyMs ~/ 60000} 分钟';
}

/// 把常见 5 字段 cron 表达式翻译成人类可读中文。
/// 支持：
///   `* * * * *`         → 每分钟
///   `*/N * * * *`       → 每 N 分钟
///   `0 * * * *`         → 每小时整点
///   `0 */N * * *`       → 每 N 小时
///   `M H * * *`         → 每天 HH:MM
///   `M H * * 1-5`       → 工作日 HH:MM
///   `M H * * 0,6`       → 周末 HH:MM
///   `M H * * D`         → 每周X HH:MM
///   `M H D * *`         → 每月 D 日 HH:MM
/// 不命中任何模式时返回 null，由 caller 退回到原始 Cron 表达式。
String? _humanizeCron(String expr) {
  final parts = expr.split(RegExp(r'\s+'));
  if (parts.length != 5) return null;
  final m = parts[0]; // minute
  final h = parts[1]; // hour
  final dom = parts[2]; // day-of-month
  final mon = parts[3]; // month
  final dow = parts[4]; // day-of-week

  bool isAny(String s) => s == '*';
  if (mon != '*') return null;

  if (m == '*' && isAny(h) && isAny(dom) && isAny(dow)) {
    return '每分钟';
  }
  final everyMin = RegExp(r'^\*/(\d+)$').firstMatch(m);
  if (everyMin != null && isAny(h) && isAny(dom) && isAny(dow)) {
    return '每 ${everyMin.group(1)} 分钟';
  }
  if (m == '0' && h == '*' && isAny(dom) && isAny(dow)) {
    return '每小时整点';
  }
  final everyHour = RegExp(r'^\*/(\d+)$').firstMatch(h);
  if (m == '0' && everyHour != null && isAny(dom) && isAny(dow)) {
    return '每 ${everyHour.group(1)} 小时';
  }

  // 单值的分钟和小时
  final mn = int.tryParse(m);
  final hn = int.tryParse(h);
  if (mn == null || hn == null) return null;
  if (mn < 0 || mn > 59 || hn < 0 || hn > 23) return null;
  final hhmm =
      '${hn.toString().padLeft(2, '0')}:${mn.toString().padLeft(2, '0')}';

  if (isAny(dom) && isAny(dow)) {
    return '每天 $hhmm';
  }
  if (isAny(dom)) {
    if (dow == '1-5') return '工作日 $hhmm';
    if (dow == '0,6' || dow == '6,0') return '周末 $hhmm';
    const dowNames = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    final d = int.tryParse(dow);
    if (d != null && d >= 0 && d <= 6) return '${dowNames[d]} $hhmm';
    return null;
  }
  if (isAny(dow)) {
    final d = int.tryParse(dom);
    if (d != null && d >= 1 && d <= 31) return '每月 $d 日 $hhmm';
  }
  return null;
}

/// 把 run_once 的 `M H D Mon *` 表达式翻译成 "8月25日 14:30"。
/// 不命中时返回 null，由 caller 退回到通用的 _humanizeCron / 原始表达式。
String? _parseOnceLabel(String expr) {
  final parts = expr.split(RegExp(r'\s+'));
  if (parts.length != 5) return null;
  final mn = int.tryParse(parts[0]);
  final hn = int.tryParse(parts[1]);
  final dn = int.tryParse(parts[2]);
  final monN = int.tryParse(parts[3]);
  if (mn == null || hn == null || dn == null || monN == null) return null;
  if (mn < 0 || mn > 59 || hn < 0 || hn > 23) return null;
  if (dn < 1 || dn > 31 || monN < 1 || monN > 12) return null;
  final hhmm =
      '${hn.toString().padLeft(2, '0')}:${mn.toString().padLeft(2, '0')}';
  return '$monN月$dn日 $hhmm';
}

String taskFormatDateTime(int? ms) {
  if (ms == null || ms <= 0) return '—';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final h = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  return '$m/$d $h:$min';
}

String taskDurationText(int? ms) {
  if (ms == null || ms <= 0) return '—';
  if (ms < 1000) return '${ms}ms';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final seconds = (ms / 1000).round();
  final minutes = seconds ~/ 60;
  final remain = seconds % 60;
  return '${minutes}m ${remain}s';
}

String taskIntervalUnitText(String value) {
  switch (value) {
    case 'minute':
      return '分钟';
    case 'hour':
      return '小时';
    case 'day':
      return '天';
    case 'week':
      return '周';
    case 'month':
      return '月';
    default:
      return value;
  }
}

String taskUserMessage(Object error) {
  if (isTransientNetworkError(error)) {
    return '网络异常，请检查网络后重试';
  }
  var text = error.toString().trim();
  if (text.startsWith('Exception: ')) {
    text = text.substring('Exception: '.length).trim();
  }
  final executionMessage = taskExecutionErrorMessage(text);
  if (executionMessage != text) return executionMessage;
  const localErrors = {
    'cron.local_offline': '电脑当前离线，请在电脑端登录并保持应用运行后再试。',
    'cron.local_conflict': '检测到多台在线电脑，请只保留一台电脑在线后再试。',
    'cron.local_upgrade_required': '请更新电脑客户端并检查本地引擎状态后再试。',
    'cron.local_unavailable': '本机任务服务暂不可用，请稍后重试。',
    'cron.local_direct_only': '本地数字员工的任务只能投递到该员工的单聊。',
    'cron.run_active': '该任务正在排队或执行，请等待本次完成。',
  };
  for (final entry in localErrors.entries) {
    if (text.contains(entry.key)) return entry.value;
  }
  // 后端错误码 → 用户可读文案。分钟间隔已在表单层拦截（<5 不让提交），
  // 这里兜底 Cron 表达式模式触发的同款错误（如 */3 * * * *）。
  if (text.contains('cron.frequency_below_min')) {
    return '执行频率过高：任务间隔不能小于 5 分钟，请调大间隔。';
  }
  if (text.contains('cron.direct_delivery_unavailable')) {
    return '暂时无法准备该数字员工的单聊，请稍后重试。';
  }
  if (text.contains('cron.delivery_conversation_not_found')) {
    return '投递会话已失效，请重新选择后再试。';
  }
  if (text.contains('cron.agent_not_supported')) {
    return '该数字员工当前不支持自动任务，请更换数字员工或联系管理员。';
  }
  return text.isEmpty ? '请求失败，请稍后重试。' : text;
}
