import { modelFailure, type ModelFailure } from './model-error.js';

type Protocol = 'responses' | 'chat/completions' | 'messages';
type Obj = Record<string, unknown>;
const object = (v: unknown): Obj => v && typeof v === 'object' && !Array.isArray(v) ? v as Obj : {};
const limit = 128 * 1024;

/** Observes only protocol status/content presence. It never changes bytes or
 * keeps provider text in the public failure. Tools are valid model output. */
class Outcome {
  text = false;
  tool = false;
  terminal = false;
  opaque = false;
  failure?: ModelFailure;
  constructor(readonly protocol: Protocol, readonly report: (failure?: ModelFailure) => void) {}
  fail(code: string) {
    this.failure = modelFailure(code);
    this.report(this.failure);
  }
  error(value: unknown) {
    const err = object(value);
    const code = `${err['code'] ?? ''} ${err['type'] ?? ''}`.toLowerCase();
    const mapped = /model_not_found/.test(code) ? 'model.unavailable'
      : /insufficient_quota|quota_exceeded/.test(code) ? 'model.upstream_quota'
      : /authentication|invalid_api_key/.test(code) ? 'model.authentication_failed'
      : /rate_limit/.test(code) ? 'model.rate_limited'
      : /invalid_request|invalidparameter/.test(code) ? 'model.request_invalid'
      : 'model.response_failed';
    this.fail(mapped);
  }
  blocks(value: unknown) {
    if (!Array.isArray(value)) return;
    for (const raw of value) {
      const b = object(raw);
      if (['text', 'output_text'].includes(String(b['type'])) && typeof b['text'] === 'string' && b['text'].trim()) this.text = true;
      if (['tool_use', 'function_call', 'custom_tool_call', 'computer_call'].includes(String(b['type']))) this.tool = true;
      if (b['type'] === 'refusal') this.fail('model.refused');
      this.blocks(b['content']);
    }
  }
  read(value: unknown) {
    const d = object(value), type = d['type'];
    if (d['error']) this.error(d['error']);
    if (type === 'error') this.error(d['error']);
    if (this.protocol === 'responses') {
      if (type === 'response.output_text.delta' && typeof d['delta'] === 'string' && d['delta'].trim()) this.text = true;
      if (type === 'response.refusal.delta' || type === 'response.refusal.done') this.fail('model.refused');
      this.blocks([d['item']]);
      const response = type ? object(d['response']) : d;
      this.blocks(response['output']);
      if (type === 'response.failed' || response['status'] === 'failed') this.error(response['error']);
      if (type === 'response.incomplete' || response['status'] === 'incomplete') this.fail('model.response_incomplete');
      if (type === 'response.completed' || response['status'] === 'completed') this.terminal = true;
    } else if (this.protocol === 'messages') {
      this.blocks([d['content_block']]); this.blocks(d['content']);
      const delta = object(d['delta']);
      if (delta['type'] === 'text_delta' && typeof delta['text'] === 'string' && delta['text'].trim()) this.text = true;
      const reason = delta['stop_reason'] ?? d['stop_reason'];
      if (reason === 'refusal') this.fail('model.refused');
      if (reason === 'max_tokens') this.fail('model.response_incomplete');
      if (type === 'message_stop' || (type === 'message' && reason)) this.terminal = true;
    } else {
      const choices = d['choices'];
      if (Array.isArray(choices)) for (const raw of choices) {
        const c = object(raw), delta = object(c['delta'] ?? c['message']);
        if (typeof delta['content'] === 'string' && delta['content'].trim()) this.text = true;
        if (Array.isArray(delta['tool_calls']) && delta['tool_calls'].length || delta['function_call']) this.tool = true;
        if (delta['refusal'] || c['finish_reason'] === 'content_filter') this.fail('model.refused');
        if (c['finish_reason'] === 'length') this.fail('model.response_incomplete');
        if (c['finish_reason']) this.terminal = true;
      }
    }
  }
  done() {
    if (this.failure) return;
    // Oversized tool/terminal frames pass through untouched; absence cannot be
    // inferred from an observation that was deliberately skipped.
    if (this.opaque) return;
    if (!this.terminal) this.fail('model.response_incomplete');
    else if (!this.text && !this.tool) this.fail('model.empty_response');
    else this.report(undefined);
  }
}

export async function* observeModelResponse(response: Response, protocol: Protocol, signal: AbortSignal,
  report: (failure?: ModelFailure) => void): AsyncGenerator<Uint8Array> {
  const outcome = new Outcome(protocol, report);
  const reader = response.body!.getReader(), decoder = new TextDecoder();
  const sse = response.headers.get('content-type')?.includes('text/event-stream');
  let pending = '', data = '', skipLine = false, skipEvent = false, ended = false;
  const parse = (raw: string) => {
    if (!raw.trim() || raw.trim() === '[DONE]') return;
    try { outcome.read(JSON.parse(raw)); } catch { outcome.fail('model.response_failed'); }
  };
  const line = (value: string) => {
    if (value.endsWith('\r')) value = value.slice(0,-1);
    if (value === '') {
      if (!skipEvent) parse(data);
      data = ''; skipEvent = false;
    } else if (value.startsWith('data:') && !skipEvent) {
      data += value.slice(5).trimStart() + '\n';
      if (data.length > limit) { data = ''; skipEvent = true; outcome.opaque = true; }
    }
  };
  try {
    while (!signal.aborted) {
      const part = await reader.read();
      if (part.done) { ended = true; break; }
      const text = decoder.decode(part.value, { stream:true });
      if (sse) {
        const lines = (pending + text).split('\n'); pending = lines.pop()!;
        for (const value of lines) {
          if (skipLine) { skipLine = false; continue; }
          if (value.length > limit) { outcome.opaque = true; skipEvent = true; data = ''; continue; }
          line(value);
        }
        if (pending.length > limit) { pending = ''; skipLine = true; skipEvent = true; outcome.opaque = true; }
      } else if (!outcome.opaque) {
        pending += text;
        if (pending.length > limit) { pending = ''; outcome.opaque = true; }
      }
      yield part.value;
    }
    if (ended && !signal.aborted) {
      pending += decoder.decode();
      if (sse) { if (pending && !skipLine) line(pending); if (!skipEvent) parse(data); }
      else if (!outcome.opaque) parse(pending);
      outcome.done();
    }
  } catch (error) {
    if (!signal.aborted) outcome.fail('model.response_incomplete');
    throw error;
  } finally {
    if (!ended && !signal.aborted && !outcome.failure) outcome.fail('model.response_incomplete');
    await reader.cancel().catch(() => {}); reader.releaseLock();
  }
}
