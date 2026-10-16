/**
 * 会话表（P1：内存态，单副本）。ZAP session_id ↔ 南侧 sessionId 同值直传（方案 §B）。
 * 会话记录本身是北侧契约对象；上下文连续性由进程池里的会话进程承担，进程重建时用 transcript 兜底。
 */
import { randomBytes } from 'node:crypto';
import { emptySkills, type SessionSkills } from '../skills/skills.js';

export interface ConversationModelBinding {
  model: string; protocol: 'openai-compatible' | 'anthropic-messages';
  base_url: string; api_key: string; provider_id?: string;
}

export interface SessionRecord {
  /** Current run proxy credential, memory only. Never serialize into history. */
  conversationModelBinding?: ConversationModelBinding;
  session_id: string;
  agent_key: string;
  tenant_id: string;
  user_id: string;
  conversation_id: string;
  purpose: string;
  session_kind: string;
  /** Bus 解析出的当前数字员工 UUID（可选） */
  agent_id: string;
  created_at: number;
  expires_at: number;
  metadata: Record<string, unknown>;
  cancelled: boolean;
  /** 已有一条消息在流式处理中 */
  inflight: boolean;
  /** 本会话已完成的轮数 */
  turns: number;
  /** 进程重建时的上下文兜底：按时间顺序的 user/assistant 文本对 */
  transcript: Array<{ role: 'user' | 'assistant'; text: string }>;
  /** 已分配给历史事件的下一个 seq（PG 双写用；rehydrate 时从 MAX(seq)+1 续） */
  event_seq: number;
  /** 技能状态（ZAP §11：seq 状态机 + 当前技能集） */
  skills: SessionSkills;
  /** 技能落盘链（create/PATCH/resync 的文件操作串在这上面；首条消息有界等待） */
  skillsReady: Promise<void>;
  /** 在途消息结束时 resolve（技能文件操作推迟到本轮之后，§11.4） */
  inflightDone?: Promise<void>;
  /** 工具桥每会话随机 key（反向通道启用时才有） */
  bridgeKey?: string;
  /**
   * 会话级**假** LLM key（P1-c）：下发给 agent 子进程的 `DEEPSEEK_API_KEY`。
   * 真的账号级凭据只在 IdentityRegistry 内存里，由回环代理在转发时换上——agent 能出网，
   * 真 key 一旦进它的 env 就等于可外泄。每次 spawn 重新生成。**不得写日志。**
   */
  llmKey?: string;
  /** Selected member route must not fall back to a stale employee BYOK key. */
  llmMemberKeyOnly?: boolean;
  /** 已回传的 outbox 文件（path → mtime:size），避免同一文件跨轮重复回传 */
  outboxSeen?: Map<string, string>;
  /** 上一轮归档失败的文件，仅在后续消息中重试补传，不重新执行模型任务。 */
  outboxRetry?: Set<string>;
}

export interface CreateSessionInput {
  agent_key: string;
  tenant_id: string;
  user_id: string;
  conversation_id: string;
  purpose: string;
  session_kind: string;
  agent_id: string;
  metadata: Record<string, unknown>;
}

export const TRANSCRIPT_MAX_ENTRIES = 40;
export const TRANSCRIPT_MAX_CHARS = 24_000;

export function newSessionId(): string {
  return 'ses_' + randomBytes(12).toString('base64url');
}

export function newSessionToken(): string {
  return randomBytes(32).toString('base64url');
}

export function newMessageId(): string {
  return 'msg_' + randomBytes(8).toString('base64url');
}

export class SessionStore {
  private readonly sessions = new Map<string, SessionRecord>();

  constructor(private readonly ttlSeconds: number) {}

  create(input: CreateSessionInput, now = Date.now()): SessionRecord {
    const rec: SessionRecord = {
      ...input,
      session_id: newSessionId(),
      created_at: now,
      expires_at: now + this.ttlSeconds * 1000,
      cancelled: false,
      inflight: false,
      turns: 0,
      transcript: [],
      event_seq: 0,
      skills: emptySkills(),
      skillsReady: Promise.resolve(),
    };
    this.sessions.set(rec.session_id, rec);
    return rec;
  }

  /** shim 重启后从历史库找回的会话放回内存表（已存在则返回内存里的）。 */
  rehydrate(rec: SessionRecord): SessionRecord {
    const existing = this.sessions.get(rec.session_id);
    if (existing) return existing;
    this.sessions.set(rec.session_id, rec);
    return rec;
  }

  /** 过期即不存在（惰性清理）。 */
  /** 回环代理 by-key 入口：按会话级假 key 反查会话（假 key 每会话唯一，见 chat.ts spawnSpecFor）。线性扫描，会话数 ≤ 进程数量级。 */
  findByLlmKey(key: string, now = Date.now()): SessionRecord | undefined {
    if (!key) return undefined;
    for (const rec of this.sessions.values()) {
      if (rec.llmKey && rec.llmKey === key && rec.expires_at > now) return rec;
    }
    return undefined;
  }

  get(sessionId: string, now = Date.now()): SessionRecord | undefined {
    const rec = this.sessions.get(sessionId);
    if (!rec) return undefined;
    if (rec.expires_at <= now) {
      this.sessions.delete(sessionId);
      return undefined;
    }
    return rec;
  }

  cancel(sessionId: string): SessionRecord | undefined {
    const rec = this.get(sessionId);
    if (rec) rec.cancelled = true;
    return rec;
  }

  delete(sessionId: string): boolean {
    return this.sessions.delete(sessionId);
  }

  /** 记录一轮（用于进程重建时的上下文兜底），超限按条数/字符数从最早处裁掉。 */
  recordTurn(rec: SessionRecord, userText: string, assistantText: string): void {
    rec.turns += 1;
    rec.transcript.push({ role: 'user', text: userText }, { role: 'assistant', text: assistantText });
    while (rec.transcript.length > TRANSCRIPT_MAX_ENTRIES) rec.transcript.shift();
    let chars = rec.transcript.reduce((n, e) => n + e.text.length, 0);
    while (chars > TRANSCRIPT_MAX_CHARS && rec.transcript.length > 2) {
      const dropped = rec.transcript.shift()!;
      chars -= dropped.text.length;
    }
  }

  /** 剔除过期会话；返回清掉的记录（调用方顺手回收进程、技能目录、装配目录）。 */
  sweep(now = Date.now()): SessionRecord[] {
    const gone: SessionRecord[] = [];
    for (const [id, rec] of this.sessions) {
      if (rec.expires_at <= now) {
        this.sessions.delete(id);
        gone.push(rec);
      }
    }
    return gone;
  }

  size(): number {
    return this.sessions.size;
  }

  /** 某租户某账号的未过期会话（§10.7 状态变更时批量处理）。 */
  forUser(tenantId: string, userId: string, now = Date.now()): SessionRecord[] {
    return [...this.sessions.values()].filter((r) => r.tenant_id === tenantId && r.user_id === userId && r.expires_at > now);
  }
}
