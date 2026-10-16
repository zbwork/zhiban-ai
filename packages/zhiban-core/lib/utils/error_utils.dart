import 'package:dio/dio.dart';

/// 暂时的传输故障；HTTP 权限/业务失败不属于离线状态。
bool isTransientNetworkError(Object? error) =>
    error is DioException &&
    (const {
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
    }.contains(error.type) ||
        (error.type == DioExceptionType.unknown && error.response == null));

/// ResponseInterceptor 将业务错误 message 放在 DioException.error 字段，
/// response.data 此时已被替换为内层 data，不含顶层 message。
String formatError(Object error, {String fallback = '操作失败，请稍后重试'}) {
  String raw;
  if (error is DioException) {
    final e = error.error;
    if (e is String && e.isNotEmpty) {
      raw = e;
    } else if (error.message != null && error.message!.isNotEmpty) {
      raw = error.message!;
    } else {
      return fallback;
    }
  } else {
    raw = error.toString();
    if (raw.startsWith('Exception: ')) {
      raw = raw.replaceFirst('Exception: ', '');
    }
  }
  return formatBackendErrorMessage(raw, fallback: fallback);
}

/// agent-bus 后端 apperr.*.Withf 会把 message 拼成 "{kind}: {detail}"
/// (例 "unauthorized: 验证码错误或已过期"). 终端用户不关心 kind, 去前缀。
const _kBackendErrorPrefixes = <String>[
  'unauthorized: ',
  'forbidden: ',
  'bad_request: ',
  'invalid_params: ',
  'invalid params: ',
  'invalid param: ',
  'not_found: ',
  'conflict: ',
  'too_many_requests: ',
  'internal: ',
];

const _kQuotaErrorCodes = <String>[
  'billing.insufficient_credits',
  'billing.entitlement_exceeded',
  'billing.feature_not_available',
  'billing.entitlement_not_configured',
  'kb.quota_exceeded',
  'drive.quota_exceeded',
  'cron.account_job_limit_reached',
  'cron.tenant_job_limit_reached',
];

bool isQuotaErrorMessage(String raw) {
  if (formatKnownModelFailure(raw.trim()) != null) return false;
  final lower = raw.toLowerCase();
  return _kQuotaErrorCodes.any(lower.contains);
}

/// 发消息前置检查(同步 HTTP 拒绝，走不到 SSE stream)命中积分不足时为 true，
/// 供调用方顺带触发钱包余额刷新（侧边栏积分展示否则要等下次刷新时机才会更新）。
bool isInsufficientCreditsError(Object error) {
  String raw;
  if (error is DioException) {
    final e = error.error;
    if (e is String && e.isNotEmpty) {
      raw = e;
    } else if (error.message != null && error.message!.isNotEmpty) {
      raw = error.message!;
    } else {
      return false;
    }
  } else {
    raw = error.toString();
  }
  return raw.toLowerCase().contains('billing.insufficient_credits');
}

// Fixed public model errors; never render arbitrary provider details.
const _modelFailureMessages = <String, String>{
  'model.refused': '模型拒绝了本次请求，请调整内容或切换模型',
  'model.empty_response': '模型未返回有效内容，请重试或切换模型',
  'model.response_incomplete': '模型响应未完整结束，请重试',
  'model.response_failed': '模型平台返回失败，请重试或切换模型',
  'model.messages_required': '模型请求缺少 messages 字段',
  'model.request_invalid': '模型请求格式错误',
  'model.context_limit': '对话内容超出模型上下文长度限制',
  'model.token_limit': '模型输出长度参数不受支持',
  'model.temperature_invalid': '模型温度参数不受支持',
  'model.tools_invalid': '模型工具调用参数不兼容',
  'model.upstream_quota': '模型平台账户额度不足，请检查模型平台余额',
  'model.authentication_failed': '模型平台鉴权失败，请检查模型凭据或权限',
  'model.unavailable': '当前模型在模型平台不可用，请切换模型',
  'model.rate_limited': '模型平台请求过于频繁，请稍后重试',
  'model.timeout': '模型平台响应超时，请稍后重试',
  'model.connection_failed': '模型平台连接失败，请稍后重试',
  'model.upstream_failure': '模型平台处理请求失败，请稍后重试',
  'billing.model_access_recovering': '积分已到账，正在恢复模型使用权限，请稍后重试',
};

String? formatKnownModelFailure(String raw) {
  final code = raw.split(':').first.trim();
  final base = _modelFailureMessages[code];
  if (base == null) return null;
  final match = RegExp(r'（HTTP ([45][0-9]{2})）。$').firstMatch(raw);
  final status = match?.group(1);
  // Only preserve the canonical, fixed server message, never echoed text.
  final canonical = status == null ? '' : '$base（HTTP $status）。';
  final detail =
      raw.contains(':') ? raw.substring(raw.indexOf(':') + 1).trim() : '';
  return code.startsWith('model.') &&
          detail == canonical &&
          canonical.isNotEmpty
      ? canonical
      : '$base。';
}

String formatBackendErrorMessage(
  String raw, {
  String fallback = '操作失败，请稍后重试',
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return fallback;
  final modelFailure = formatKnownModelFailure(trimmed);
  if (modelFailure != null) return modelFailure;
  final lower = trimmed.toLowerCase();
  if (lower.contains('skill.runtime_mismatch')) {
    return '该技能暂不支持当前数字员工的运行引擎，请选择兼容的技能。';
  }
  if (lower.contains('chat.model_configuration_unavailable')) {
    return '模型服务配置不可用，请检查平台地址和 API Key 后重试。';
  }
  if (lower.contains('chat.model_unavailable')) {
    return '当前模型已不可用，请切换模型后重试。';
  }
  if (lower.contains('chat.local_upgrade_required')) {
    return '电脑已在线，请更新电脑端后再派活。';
  }
  if (lower.contains('chat.local_offline') ||
      lower.contains('chat.local_unavailable')) {
    return '电脑未在线或授权已失效，请打开电脑端知办AI。';
  }
  if (lower.contains('chat.agent_unavailable') ||
      lower.contains('messages.agent_unavailable')) {
    return '数字员工当前不可用。请联系管理员到管理后台「数字员工」中发布该数字员工，并开启「允许加入群聊/对话邀请」后再试。';
  }
  if (lower.contains('runtime.warming') ||
      lower.contains('chat.runtime_warming')) {
    return '数字员工正在准备中，请稍后重试。';
  }
  if (lower.contains('chat.runtime_control_plane_not_ready') ||
      lower.contains('agent_key not synced to runtime') ||
      lower.contains('zap_agent_instance_initialize_not_declared')) {
    return '数字员工运行环境未就绪：Agent Key 尚未同步到运行时。请联系管理员到管理后台「数字员工」中重新保存/发布该数字员工，并确认自定义运行环境已开启 Agent 管理能力。';
  }
  if (lower.contains('zap_session_create_failed') ||
      lower.contains('zapsessioncreate_failed')) {
    return '数字员工暂时无法连接，请稍后重试。若持续失败，请联系管理员检查该数字员工的运行环境配置。';
  }
  if (lower.contains('chat.too_many_pending')) {
    return '当前会话消息较多，请稍后再试。';
  }
  if (lower.contains('membership.inactive') ||
      lower.contains('membership.suspended')) {
    return '您在当前企业的账号已被管理员暂停，请联系管理员或切换到其他企业。';
  }
  if (lower.contains('cron.agent_not_supported')) {
    return '该数字员工当前不支持自动任务，请更换数字员工或联系管理员。';
  }
  if (lower.contains('chat.tenant_backlog_exceeded')) {
    return '当前组织消息较多，请稍后再试。';
  }
  if (lower.contains('aigc.model_not_allowed') || lower.contains('模型不被允许')) {
    return '数字员工暂时无法回复：当前模型未授权，请联系管理员检查 AIGC 模型权限。';
  }
  if (lower.contains('aigc.channel_api_key_missing') ||
      lower.contains('渠道apikey不能为空') ||
      lower.contains('api key 未配置')) {
    return '数字员工暂时无法回复：AIGC 通道 API Key 未配置，请联系管理员检查模型网关配置。';
  }
  if (lower.contains('chat.deliverable_missing') ||
      lower.contains('zap.deliverable_missing')) {
    return '未生成全部要求的文件。已验证的文件仍可查看。';
  }
  if (lower.contains('chat.deliverable_content_mismatch') ||
      lower.contains('zap.deliverable_content_mismatch')) {
    return '文件已生成，但内容或大小未满足交付要求。已验证的文件仍可查看。';
  }
  if (lower.contains('chat.deliverable_verification_failed') ||
      lower.contains('zap.deliverable_verification_failed')) {
    return '部分文件未通过交付校验。已验证的文件仍可查看。';
  }
  if (lower.contains('chat.runtime_upstream_failure') ||
      lower.contains('zap.upstream_failure') ||
      lower.contains('agent runtime returned an error') ||
      lower.contains('message generation failed')) {
    return '数字员工暂时无法回复，请稍后再试。';
  }
  if (isQuotaErrorMessage(trimmed)) {
    if (lower.contains('billing.insufficient_credits')) {
      return '积分不足，请先购买积分包或升级套餐后再试。';
    }
    if (lower.contains('kb.quota_exceeded')) {
      return '知识库容量已达当前套餐上限，请升级套餐或清理文件后再试。';
    }
    if (lower.contains('drive.quota_exceeded')) {
      return '云盘容量已达当前套餐上限，请升级套餐或清理文件后再试。';
    }
    if (lower.contains('billing.feature_not_available')) {
      return '当前套餐未开通该功能，请升级套餐后再试。';
    }
    if (lower.contains('billing.entitlement_not_configured')) {
      return '当前套餐配置缺失，请联系管理员处理。';
    }
    if (lower.contains('cron.account_job_limit_reached') ||
        lower.contains('cron.tenant_job_limit_reached')) {
      return '自动任务数量已达平台安全上限，请联系管理员处理。';
    }
    return '已达当前套餐上限，请升级套餐后再试。';
  }
  final visible = _stripMachineCodePrefix(_stripBackendErrorPrefix(trimmed));
  return _looksLikeMachineCode(visible) ? fallback : visible;
}

/// SSE / 历史消息同时带稳定 error_code 与内部 error_message 时，必须让稳定码
/// 参与映射；否则 `hermes runtime instance not ready` 之类英文会遮住
/// `chat.runtime_warming` 的用户文案。
String formatBackendErrorPayload({
  String errorCode = '',
  String errorMessage = '',
  String fallback = '操作失败，请稍后重试',
}) {
  final code = errorCode.trim();
  final message = errorMessage.trim();
  if (code.isEmpty) {
    return formatBackendErrorMessage(message, fallback: fallback);
  }
  final combined = message.isEmpty ? code : '$code: $message';
  return formatBackendErrorMessage(combined, fallback: fallback);
}

String formatChatSendError(Object error) {
  final message = formatError(error, fallback: '发送失败，请稍后重试');
  if (message.trim().isEmpty) return '发送失败，请稍后重试';
  return message;
}

String _stripBackendErrorPrefix(String s) {
  for (final p in _kBackendErrorPrefixes) {
    if (s.startsWith(p)) return s.substring(p.length);
  }
  return s;
}

String _stripMachineCodePrefix(String s) {
  final idx = s.indexOf(':');
  if (idx <= 0 || idx > 80) return s;
  final code = s.substring(0, idx);
  if (code.contains('.') && !code.contains(' ')) {
    return s.substring(idx + 1).trimLeft();
  }
  return s;
}

bool _looksLikeMachineCode(String value) {
  if (!value.contains('_') && !value.contains('.')) return false;
  return RegExp(r'^[A-Za-z][A-Za-z0-9_.-]*$').hasMatch(value);
}
