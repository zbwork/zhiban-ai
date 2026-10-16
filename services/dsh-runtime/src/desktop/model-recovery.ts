import { setTimeout as delay } from 'node:timers/promises';

export interface RecoveryCandidate { slot: number; label: string }
/** Controlled enum. Upstream error text must never reach the Bus or the run record. */
export type RetryReason = 'upstream_unavailable' | 'header_timeout' | 'transport_error';
export interface FallbackStep { slot: number; reason: RetryReason }
export interface RecoveryState {
  effectiveSlot: number; extraAttempts: number; calls: number; usedSlots: number[];
  /** Every extra attempt, in order — the run record's fallback_chain. */
  chain: FallbackStep[];
  lastReason?: RetryReason;
}
export const recoveryState = (): RecoveryState => ({ effectiveSlot: 0, extraAttempts: 0, calls: 0, usedSlots: [], chain: [] });

/** Keep the wire body intact. Unknown vendor content cannot be safely moved to
 * another model; original-model retry is still allowed. Mirrored at the Bus. */
export function portableRecoveryBody(body: Record<string, unknown>): boolean {
  if (Buffer.byteLength(JSON.stringify(body)) > 64 * 1024) return false;
  const allowed = new Set(['model', 'messages', 'stream', 'stream_options', 'tools', 'tool_choice', 'max_tokens', 'max_completion_tokens', 'temperature', 'top_p', 'stop', 'store']);
  if ('store' in body && body['store'] !== false) return false;
  if (Object.keys(body).some((key) => !allowed.has(key)) || !Array.isArray(body['messages'])) return false;
  return body['messages'].every((raw: unknown) => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return false;
    const msg = raw as Record<string, unknown>;
    if (Object.keys(msg).some((key) => !['role', 'content', 'tool_calls', 'tool_call_id', 'name'].includes(key))) return false;
    const content = msg['content'];
    return content === null || typeof content === 'string' || (Array.isArray(content) && content.every((p: unknown) => p && typeof p === 'object' && (p as Record<string, unknown>)['type'] === 'text'));
  });
}

/** Retries inference only, before handing a successful response stream to DSH.
 * There is deliberately no retry after a reader has consumed response bytes. */
export async function recoverModelRequest(options: {
  state: RecoveryState; candidates: RecoveryCandidate[]; body: Record<string, unknown>; signal: AbortSignal;
  request(slot: number, signal: AbortSignal): Promise<Response>;
  progress(text: string): void;
  wait?(milliseconds: number, signal: AbortSignal): Promise<void>;
}): Promise<Response> {
  const { state, signal, candidates } = options;
  const portable = portableRecoveryBody(options.body);
  const first = portable ? state.effectiveSlot : 0;
  const slots = [first, first, ...candidates.filter((c) => portable && c.slot > first).map((c) => c.slot)].slice(0, 4);
  state.calls++;
  let previous: Response | undefined;
  let failure: unknown;
  let reason: RetryReason | undefined;
  for (let attempt = 0; attempt < slots.length; attempt++) {
    signal.throwIfAborted();
    if (attempt > 0) {
      if (state.extraAttempts >= 6) break;
      state.extraAttempts++;
      state.chain.push({ slot: slots[attempt]!, reason: reason ?? 'upstream_unavailable' });
      state.lastReason = reason ?? 'upstream_unavailable';
      const slot = slots[attempt]!;
      const label = candidates.find((c) => c.slot === slot)?.label;
      options.progress(slot === first && attempt === 1 ? '模型服务暂不可用，正在重试当前模型（1/1）' : `正在临时切换至 ${label ?? '备用模型'}`);
      await previous?.body?.cancel();
      await (options.wait ?? ((ms, abort) => delay(ms, undefined, { signal: abort })))(500 * attempt + Math.floor(Math.random() * 250), signal);
    }
    const slot = slots[attempt]!;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(new Error('local.model_header_timeout')), 90_000);
    try {
      const response = await options.request(slot, AbortSignal.any([signal, controller.signal]));
      previous = response;
      if (response.ok) {
        state.effectiveSlot = slot;
        if (!state.usedSlots.includes(slot)) state.usedSlots.push(slot);
        if (attempt > 0 || slot !== 0) options.progress(slot === 0 ? '当前模型已恢复，继续执行' : `本任务临时使用 ${candidates.find((c) => c.slot === slot)?.label ?? '备用模型'}`);
        return response;
      }
      // Bus explicitly classifies provider failures. Never mistake its generic
      // 502 envelope (auth/config/quota errors included) for a transient 503.
      if (response.headers.get('x-local-model-retryable') !== '1') return response;
      reason = 'upstream_unavailable';
    } catch (err) {
      signal.throwIfAborted();
      failure = err;
      // Only fetch transport failure or our header timeout is retryable.
      if (!(err instanceof TypeError) && !controller.signal.aborted) throw err;
      reason = controller.signal.aborted ? 'header_timeout' : 'transport_error';
    } finally { clearTimeout(timeout); }
  }
  if (previous) return previous;
  throw failure ?? new Error('local.model_recovery_exhausted');
}
