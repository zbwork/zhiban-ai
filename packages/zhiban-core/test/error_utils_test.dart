import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:zhiban_core/utils/error_utils.dart';

DioException _dioError(String message) => DioException(
      requestOptions: RequestOptions(path: '/api/agent-bus/v1/auth/sms/send'),
      error: message,
    );

void main() {
  test('stream failures and refusals use safe messages, not credit errors', () {
    for (final code in [
      'model.refused',
      'model.empty_response',
      'model.response_failed',
      'model.response_incomplete'
    ]) {
      final text = formatBackendErrorPayload(
          errorCode: code, errorMessage: 'SECRET billing.insufficient_credits');
      expect(text, isNot(contains('SECRET')));
      expect(text, isNot(contains('积分不足')));
      expect(isQuotaErrorMessage(code), isFalse);
    }
  });
  test('upstream missing messages field keeps its specific reason and HTTP 500',
      () {
    expect(
        formatBackendErrorPayload(
            errorCode: 'model.messages_required',
            errorMessage: '模型请求缺少 messages 字段（HTTP 500）。'),
        '模型请求缺少 messages 字段（HTTP 500）。');
  });
  test('model request errors retain safe details in both SSE and history', () {
    expect(
        formatBackendErrorPayload(
            errorCode: 'model.request_invalid',
            errorMessage: '模型请求格式错误（HTTP 400）。'),
        '模型请求格式错误（HTTP 400）。');
    expect(
        formatBackendErrorMessage(
            'model.request_invalid: SECRET https://internal/（HTTP 400）。'),
        '模型请求格式错误。');
    expect(
        formatBackendErrorPayload(
            errorCode: 'model.upstream_quota',
            errorMessage: 'billing.insufficient_credits SECRET'),
        '模型平台账户额度不足，请检查模型平台余额。');
    expect(
        formatBackendErrorMessage(
            'billing.model_access_recovering: internal state'),
        '积分已到账，正在恢复模型使用权限，请稍后重试。');
    expect(isQuotaErrorMessage('billing.model_access_recovering'), isFalse);
    expect(isQuotaErrorMessage('model.upstream_quota'), isFalse);
    expect(
        isQuotaErrorMessage(
            'model.upstream_quota: billing.insufficient_credits SECRET'),
        isFalse);
    expect(formatBackendErrorMessage('billing.insufficient_credits'),
        contains('积分不足'));
  });

  test('skill runtime mismatch gives an actionable message', () {
    expect(formatBackendErrorMessage('invalid params: skill.runtime_mismatch'),
        '该技能暂不支持当前数字员工的运行引擎，请选择兼容的技能。');
  });

  test('deliverable errors use fixed safe text', () {
    for (final kind in ['missing', 'content_mismatch', 'verification_failed']) {
      final message = formatBackendErrorPayload(
        errorCode: 'chat.deliverable_$kind',
        errorMessage: 'https://private.example secret /Users/private',
      );
      expect(message, contains('已验证的文件仍可查看'));
      expect(message, isNot(contains('secret')));
      expect(message, isNot(contains('/Users')));
    }
  });

  test('model preflight failures keep explicit safe instructions', () {
    expect(
        formatBackendErrorMessage('chat.model_unavailable'), contains('请切换模型'));
    expect(formatBackendErrorMessage('chat.local_offline'), contains('电脑未在线'));
    expect(formatBackendErrorMessage('chat.local_upgrade_required'),
        contains('更新电脑端'));
    expect(formatBackendErrorMessage('chat.model_configuration_unavailable'),
        contains('API Key'));
  });

  test('stable runtime warming code wins over internal English detail', () {
    expect(
      formatBackendErrorPayload(
        errorCode: 'chat.runtime_warming',
        errorMessage: 'hermes runtime instance not ready',
      ),
      '数字员工正在准备中，请稍后重试。',
    );
  });

  test('formatError hides invalid params backend prefix', () {
    expect(
      formatError(_dioError('invalid params: 图形验证码错误')),
      '图形验证码错误',
    );
  });

  test('formatError maps agent unavailable to actionable Chinese message', () {
    expect(
      formatError(_dioError(
        'conflict: chat.agent_unavailable: agent unpublished or invite-disabled',
      )),
      '数字员工当前不可用。请联系管理员到管理后台「数字员工」中发布该数字员工，并开启「允许加入群聊/对话邀请」后再试。',
    );
  });

  test('formatChatSendError maps runtime warming and queue limits', () {
    expect(
      formatChatSendError(_dioError('runtime.warming')),
      '数字员工正在准备中，请稍后重试。',
    );
    expect(
      formatChatSendError(_dioError('chat.too_many_pending')),
      '当前会话消息较多，请稍后再试。',
    );
  });

  test('formatChatSendError maps custom agent control-plane setup errors', () {
    expect(
      formatChatSendError(_dioError(
        'chat.runtime_control_plane_not_ready: zap dispatch: agent_key not synced to runtime',
      )),
      '数字员工运行环境未就绪：Agent Key 尚未同步到运行时。请联系管理员到管理后台「数字员工」中重新保存/发布该数字员工，并确认自定义运行环境已开启 Agent 管理能力。',
    );
  });

  test('ZAP session create failure never exposes the internal stage code', () {
    expect(
      formatBackendErrorPayload(
        errorCode: 'chat.runtime_protocol_unsupported',
        errorMessage: 'zap_session_create_failed',
      ),
      '数字员工暂时无法连接，请稍后重试。若持续失败，请联系管理员检查该数字员工的运行环境配置。',
    );
    expect(
      formatBackendErrorMessage('zapsessioncreate_failed'),
      '数字员工暂时无法连接，请稍后重试。若持续失败，请联系管理员检查该数字员工的运行环境配置。',
    );
  });

  test('unknown machine code uses the caller fallback', () {
    expect(
      formatBackendErrorMessage(
        'runtime.some_future_failure',
        fallback: '发送失败，请稍后重试',
      ),
      '发送失败，请稍后重试',
    );
  });

  test('formatError hides internal cron capability details', () {
    expect(
      formatError(_dioError(
        'cron.agent_not_supported: cron requires a chat-capable runtime; agent 5123d597-2fef-4061-848d-73a70e79049c runtime framework="custom"',
      )),
      '该数字员工当前不支持自动任务，请更换数字员工或联系管理员。',
    );
  });
}
