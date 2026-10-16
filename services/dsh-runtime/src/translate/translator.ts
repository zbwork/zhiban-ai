/**
 * 南侧会话事件 → ZAP SSE 帧（reference/dsh2zap.py 的 TS 移植，按 Bus chat.go 口径修正了 block 类型）。
 *
 *   turn/start                         → message.created（若尚未发出）
 *   reasoning 增量（散 chunk + 批量）     → message.reasoning（增量）
 *   text 增量（散 chunk + 批量）          → message.block.delta {type:markdown,text:Δ}
 *                                        (turn,step,index) → 消息内连续 block_index
 *   tool/call（权威完整 args）           → message.tool_call(running)
 *   tool/result                        → message.tool_result(succeeded|failed)
 *   assistant/message                  → 收终稿 text block + 累计 usage
 *   turn/end reason.kind               → completed / max-tokens → message.completed
 *                                        error → message.failed(zap.upstream_failure)
 *                                        aborted → message.cancelled
 *                                        blocked → 有正文按 completed，否则 failed
 *
 * 只发**真增量**；tool args 以 tool/call 为权威（chunk 流可能缺尾字符，ADR §4.1）。
 * 两种 chunk 形态必须都消费（wire 上是散 assistant/chunk，持久化文件里是批量 *-chunks）。
 */
import { ZapErrorCode } from '../server/errors.js';
import { eventData, type DshContentBlock, type DshEvent, type DshMessage, type DshUsage } from './dsh-events.js';
import { frames, type ZapFrame, type ZapUsage } from './sse.js';

const TOOL_RESULT_MAX_CHARS = 2000;

export type TurnEnd =
  | { kind: 'completed' }
  | { kind: 'failed'; code: string }
  | { kind: 'cancelled' };

export class TurnTranslator {
  private createdEmitted = false;
  private ended = false;
  private readonly blockIndex = new Map<string, number>();
  private readonly textAcc = new Map<string, string>();
  private readonly finalBlocks: Array<Record<string, unknown>> = [];
  private readonly pendingTools = new Map<string, string>();
  private usage: ZapUsage | undefined;
  private _end: TurnEnd | undefined;
  private _toolCalls = 0;
  private _toolErrors = 0;

  constructor(readonly messageId: string, private readonly options: { strictTerminal?: boolean } = {}) {}

  /** 本轮终态（turn/end 之后可读） */
  get end(): TurnEnd | undefined {
    return this._end;
  }

  /** 本轮观测摘要（F24 口径：工具数/失败数/累计 usage），供汇总日志与指标。 */
  stats(): { toolCalls: number; toolErrors: number; usage: ZapUsage | undefined } {
    return { toolCalls: this._toolCalls, toolErrors: this._toolErrors, usage: this.usage };
  }

  /** 本轮助手正文（终稿优先，否则增量拼接），供会话 transcript 记录。 */
  finalText(): string {
    const blocks = this.finalBlocks.length > 0 ? this.finalBlocks : this.fallbackBlocksFromDeltas();
    return blocks.map((b) => String(b['text'] ?? '')).join('\n\n');
  }

  /** 服务端在请求受理时先发 created（spawn 前即可给客户端首帧）；之后 turn/start 不再重复。 */
  created(): ZapFrame[] {
    if (this.createdEmitted) return [];
    this.createdEmitted = true;
    return [frames.created(this.messageId)];
  }

  push(ev: DshEvent): ZapFrame[] {
    if (this.ended) return [];
    switch (ev.type) {
      case 'turn/start':
        return this.created();
      case 'assistant/chunk':
        return this.onChunk(ev);
      case 'reasoning-chunks': {
        const d = eventData<{ texts?: string[] }>(ev);
        const delta = (d.texts ?? []).join('');
        return delta ? [frames.reasoning(this.messageId, delta)] : [];
      }
      case 'text-chunks': {
        const d = eventData<{ turn?: number; step?: number; index?: number; texts?: string[] }>(ev);
        const delta = (d.texts ?? []).join('');
        return delta ? [this.textDelta(keyOf(d.turn, d.step, d.index), delta)] : [];
      }
      case 'tool/call': {
        const d = eventData<{ callId?: string; name?: string; arguments?: string }>(ev);
        if (!d.callId) return [];
        if (!this.pendingTools.has(d.callId)) this._toolCalls += 1;
        this.pendingTools.set(d.callId, d.name ?? '');
        return [frames.toolCall(this.messageId, d.callId, d.name ?? '', d.arguments ?? '')];
      }
      case 'tool/result':
        return this.onToolResult(ev);
      case 'assistant/message':
        this.onAssistantMessage(ev);
        return [];
      case 'turn/end':
        return this.onTurnEnd(ev);
      default:
        return [];
    }
  }

  /** 进程中途死亡 / 超时等外部终止：由服务端调用，保证流有终态帧。 */
  fail(code: string, message: string): ZapFrame[] {
    if (this.ended) return [];
    this.ended = true;
    this._end = { kind: 'failed', code };
    return [...this.created(), ...this.interruptTools(), frames.failed(this.messageId, code, message)];
  }

  cancel(): ZapFrame[] {
    if (this.ended) return [];
    this.ended = true;
    this._end = { kind: 'cancelled' };
    return [...this.created(), ...this.interruptTools(), frames.cancelled(this.messageId)];
  }

  private interruptTools(): ZapFrame[] {
    if (!this.options.strictTerminal) return [];
    const out = [...this.pendingTools].map(([id, name]) => frames.toolResult(this.messageId, id, name, false, '工具调用已中断，结果未确认。'));
    this._toolErrors += this.pendingTools.size;
    this.pendingTools.clear();
    return out;
  }

  private onChunk(ev: DshEvent): ZapFrame[] {
    const d = eventData<{ turn?: number; step?: number; chunk?: { type?: string; index?: number; text?: string } }>(ev);
    const c = d.chunk;
    if (!c || !c.text) return [];
    if (c.type === 'reasoning-delta') return [frames.reasoning(this.messageId, c.text)];
    if (c.type === 'text-delta') return [this.textDelta(keyOf(d.turn, d.step, c.index), c.text)];
    return [];
  }

  private textDelta(key: string, delta: string): ZapFrame {
    let bi = this.blockIndex.get(key);
    if (bi === undefined) {
      bi = this.blockIndex.size;
      this.blockIndex.set(key, bi);
    }
    this.textAcc.set(key, (this.textAcc.get(key) ?? '') + delta);
    return frames.blockDelta(this.messageId, bi, delta);
  }

  private onToolResult(ev: DshEvent): ZapFrame[] {
    const d = eventData<{ message?: DshMessage }>(ev);
    const out: ZapFrame[] = [];
    for (const b of d.message?.content ?? []) {
      if (b.type !== 'tool-result' || !b.toolCallId) continue;
      const name = this.pendingTools.get(b.toolCallId);
      this.pendingTools.delete(b.toolCallId);
      if (b.isError) this._toolErrors += 1;
      out.push(frames.toolResult(this.messageId, b.toolCallId, name, !b.isError, renderToolResult(b.content)));
    }
    return out;
  }

  private onAssistantMessage(ev: DshEvent): void {
    const d = eventData<{ message?: DshMessage; usage?: DshUsage }>(ev);
    for (const b of d.message?.content ?? []) {
      if (b.type === 'text' && typeof b.text === 'string' && b.text !== '') this.finalBlocks.push({ type: 'markdown', text: b.text });
    }
    if (d.usage) {
      const input = d.usage.inputTokens ?? 0;
      const output = d.usage.outputTokens ?? 0;
      const model = modelOf(d.message) ?? this.usage?.model;
      const prev = this.usage ?? { input_tokens: 0, output_tokens: 0, total_tokens: 0 };
      this.usage = {
        input_tokens: prev.input_tokens + input,
        output_tokens: prev.output_tokens + output,
        total_tokens: prev.total_tokens + input + output,
        ...(model ? { model } : {}),
      };
    }
  }

  private onTurnEnd(ev: DshEvent): ZapFrame[] {
    const d = eventData<{ reason?: { kind?: string; error?: { code?: string } } }>(ev);
    if (this.options.strictTerminal) {
      if (d.reason?.kind === 'aborted') return this.cancel();
      if (d.reason?.kind === 'error') return this.fail('zap.local_model_unavailable', '模型服务调用失败，请切换模型或检查模型服务配置。');
      if (d.reason?.kind !== 'completed' || this.pendingTools.size > 0) {
        return this.fail('zap.incomplete_turn', '任务未完整结束，已保留部分输出；请检查结果后续跑。');
      }
    }
    const kind = d.reason?.kind ?? 'completed';
    this.ended = true;
    const blocks = this.finalBlocks.length > 0 ? this.finalBlocks : this.fallbackBlocksFromDeltas();
    switch (kind) {
      case 'completed':
      case 'max-tokens':
        this._end = { kind: 'completed' };
        return [...this.created(), frames.completed(this.messageId, blocks, this.usage)];
      case 'aborted':
        this._end = { kind: 'cancelled' };
        return [...this.created(), frames.cancelled(this.messageId)];
      case 'blocked':
        if (blocks.length > 0) {
          this._end = { kind: 'completed' };
          return [...this.created(), frames.completed(this.messageId, blocks, this.usage)];
        }
        this._end = { kind: 'failed', code: ZapErrorCode.upstreamFailure };
        return [...this.created(), frames.failed(this.messageId, ZapErrorCode.upstreamFailure, 'turn blocked before producing output')];
      default: {
        const code = d.reason?.error?.code;
        this._end = { kind: 'failed', code: ZapErrorCode.upstreamFailure };
        return [
          ...this.created(),
          frames.failed(this.messageId, ZapErrorCode.upstreamFailure, code ? `upstream model call failed (${code})` : 'upstream model call failed'),
        ];
      }
    }
  }

  private fallbackBlocksFromDeltas(): Array<Record<string, unknown>> {
    return [...this.textAcc.values()].filter((t) => t !== '').map((text) => ({ type: 'markdown', text }));
  }
}

function keyOf(turn: number | undefined, step: number | undefined, index: number | undefined): string {
  return `${turn ?? 0}:${step ?? 0}:${index ?? 0}`;
}

function modelOf(m: DshMessage | undefined): string | undefined {
  const source = (m as { source?: { model?: string } } | undefined)?.source;
  return typeof source?.model === 'string' ? source.model : undefined;
}

function renderToolResult(content: unknown): string {
  let text: string;
  if (Array.isArray(content) && content.every((c) => typeof c === 'object' && c !== null && (c as DshContentBlock).type === 'text')) {
    text = (content as DshContentBlock[]).map((c) => c.text ?? '').join('');
  } else if (typeof content === 'string') {
    text = content;
  } else {
    text = JSON.stringify(content ?? null);
  }
  return text.length > TOOL_RESULT_MAX_CHARS ? text.slice(0, TOOL_RESULT_MAX_CHARS) : text;
}
