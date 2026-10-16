/**
 * LLM 网关 SSE 归一化：把公司 AIGC 网关的流式响应改写成 DeepSeek SDK 能正确消费的形态。
 *
 * 为什么需要这层（2026-08-25 抓包实证，两处都不是我们的 bug，也都不违反 OpenAI 规范）：
 *
 *  1. **工具调用的名字被冲掉（致命）**：OpenAI 流式 tool_calls 的约定是"名字和 id 只在首帧出现，
 *     后续帧只增量拼 arguments"。公司网关在后续帧里把 `id` / `function.name` 显式写成 `null`，
 *     而 `@deepseek-ai/dsh-llm-deepseek`（rc.8 与最新 0.1.1-rc.2 均如此）用
 *     `if (call.function?.name !== void 0) block.name = call.function.name` 累积 ——
 *     `null !== undefined` 成立，于是首帧存好的名字被覆盖成 null。最终发出的请求里
 *     `"name":""`、`"tool_call_id":""`，模型侧报 `unknown tool ""`，**所有工具全部不可用**
 *     （平台工具 kb/memory/a2a + dsh 自带的 bash/fs 一起废）。
 *     DeepSeek 官方 API 省略这些字段（undefined），所以只有"dsh + 公司网关"这个组合才触发。
 *     归一化做法：删掉 tool_calls 增量帧里值为 null 的 id / function.name —— 还原成"字段缺省"，
 *     SDK 的累积逻辑即恢复正常。**不改上游 SDK、不逆向内部 API**，只在协议层抹平差异。
 *
 *  2. **缺少 `data: [DONE]` 终止符**：测试环境网关（aigc-api.aigc.paas.test）发完 usage 分片就关连接，
 *     SDK 判协议违例抛 STREAM_CLOSED —— 模型明明答完了整轮也算失败。生产网关（.corp）是发的。
 *     归一化做法：上游正常结束但没见过 [DONE] 时补一个。
 *
 * 上游修好后（把 `!== void 0` 改成 `!= null`）本层可整体撤除，故所有改写都收敛在这一个文件里。
 */

/** 一行 SSE `data:` 载荷的归一化结果。 */
export interface NormalizeResult {
  /** 改写后的载荷（未改写时原样返回，保持字节级透传）。 */
  data: string;
  /** 该行是否为 `[DONE]` 终止符。 */
  done: boolean;
}

/** tool_calls 增量帧里允许被"缺省化"的 null 字段。arguments 不动（SDK 有 ?? '' 兜底）。 */
function stripNullToolCallFields(call: Record<string, unknown>): boolean {
  let changed = false;
  if (call['id'] === null) {
    delete call['id'];
    changed = true;
  }
  const fn = call['function'];
  if (fn !== null && typeof fn === 'object') {
    const f = fn as Record<string, unknown>;
    if (f['name'] === null) {
      delete f['name'];
      changed = true;
    }
  }
  return changed;
}

/**
 * 归一化一行 SSE 载荷（`data:` 后面的部分，不含前缀）。
 * 非 JSON / 无 tool_calls 的行原样返回——不解析、不重排，避免无谓的语义漂移。
 */
export function normalizeSsePayload(payload: string): NormalizeResult {
  const trimmed = payload.trim();
  if (trimmed === '[DONE]') return { data: payload, done: true };
  // 快速排除：绝大多数帧是纯文本 delta，不必进 JSON 解析。
  if (!trimmed.startsWith('{') || !trimmed.includes('tool_calls')) return { data: payload, done: false };

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return { data: payload, done: false }; // 解析不了就别动它
  }
  if (parsed === null || typeof parsed !== 'object') return { data: payload, done: false };

  const choices = (parsed as Record<string, unknown>)['choices'];
  if (!Array.isArray(choices)) return { data: payload, done: false };

  let changed = false;
  for (const choice of choices) {
    if (choice === null || typeof choice !== 'object') continue;
    const delta = (choice as Record<string, unknown>)['delta'];
    if (delta === null || typeof delta !== 'object') continue;
    const calls = (delta as Record<string, unknown>)['tool_calls'];
    if (!Array.isArray(calls)) continue;
    for (const call of calls) {
      if (call === null || typeof call !== 'object') continue;
      if (stripNullToolCallFields(call as Record<string, unknown>)) changed = true;
    }
  }
  return { data: changed ? JSON.stringify(parsed) : payload, done: false };
}

/**
 * 流式改写器：按行消费上游 SSE，逐行归一化后吐出；上游结束时若从未见过 [DONE] 则补一个。
 * 保持逐帧透传（不缓冲整条响应），首字延迟不受影响。
 */
export class SseNormalizer {
  private buf = '';
  private sawDone = false;

  /** 消费一段上游字节，返回应当写给下游的字节（可能为空串）。 */
  push(chunk: string): string {
    this.buf += chunk;
    let out = '';
    let idx: number;
    // SSE 以 \n 分行；保留最后一段不完整的行等下一批。
    while ((idx = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, idx);
      this.buf = this.buf.slice(idx + 1);
      out += this.rewriteLine(line) + '\n';
    }
    return out;
  }

  /** 上游结束：吐出残留缓冲，并在缺失时补 [DONE]。 */
  flush(): string {
    let out = '';
    if (this.buf.length > 0) {
      out += this.rewriteLine(this.buf);
      this.buf = '';
    }
    if (!this.sawDone) out += (out.endsWith('\n') || out === '' ? '' : '\n') + 'data: [DONE]\n\n';
    return out;
  }

  private rewriteLine(line: string): string {
    if (!line.startsWith('data:')) return line;
    const payload = line.slice('data:'.length);
    const lead = payload.startsWith(' ') ? ' ' : '';
    const res = normalizeSsePayload(lead ? payload.slice(1) : payload);
    if (res.done) this.sawDone = true;
    return 'data:' + lead + res.data;
  }
}
