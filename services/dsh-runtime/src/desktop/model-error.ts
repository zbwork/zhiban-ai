/** Public contract mirrored by Bus modelerror and the Flutter formatter. No raw provider text. */
const messages: Record<string, string> = {
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
  'billing.insufficient_credits': '积分不足，请先购买积分包或升级套餐后再试',
};
export interface ModelFailure { code: string; message: string }
export function modelFailure(code: string, status = 0): ModelFailure {
  const safeCode = Object.hasOwn(messages, code) ? code : 'model.upstream_failure';
  const suffix = Number.isInteger(status) && status >= 400 && status <= 599 && safeCode.startsWith('model.') ? `（HTTP ${status}）` : '';
  return { code: safeCode, message: `${messages[safeCode]}${suffix}。` };
}

/** Read only a bounded Bus error envelope; discard all detail except the stable code. */
export async function readModelFailure(response: Response, signal: AbortSignal): Promise<ModelFailure> {
  const reader = response.body?.getReader();
  let raw = '';
  if (reader) {
    const cancel = () => { void reader.cancel().catch(() => {}); };
    const timer = setTimeout(cancel, 5000);
    signal.addEventListener('abort', cancel, { once: true });
    try {
      const parts: Uint8Array[] = []; let size = 0;
      while (!signal.aborted) {
        const part = await reader.read();
        if (part.done) { raw = Buffer.concat(parts).toString('utf8'); break; }
        size += part.value.length;
        if (size > 8192) break;
        parts.push(part.value);
      }
    } catch { /* Unknown or interrupted body keeps a safe generic failure. */ }
    finally { clearTimeout(timer); signal.removeEventListener('abort', cancel); await reader.cancel().catch(() => {}); reader.releaseLock(); }
  }
  let code = 'model.upstream_failure';
  try {
    const data: unknown = JSON.parse(raw);
    if (data && typeof data === 'object' && 'message' in data && typeof data.message === 'string') {
      const candidate = data.message.split(':', 1)[0]!.trim();
      if (Object.hasOwn(messages, candidate)) code = candidate;
    }
  } catch { /* Non-JSON errors are not user-facing. */ }
  const status = response.headers.get('x-local-model-upstream-status') ?? '';
  return modelFailure(code, /^[45][0-9]{2}$/.test(status) ? Number(status) : 0);
}
