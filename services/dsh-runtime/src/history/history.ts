/**
 * 会话历史双写 PG（ADR-0035 决策 5 / CLAUDE.md 边界 4）：dsh 磁盘会话文件是可丢弃缓存，**权威历史在这里**。
 *
 * 用途（P2）：
 * 1. 进程重建（空闲回收 / 崩溃 / 升级）后按 conversation 重放 transcript 注入首轮——替代 P1 的纯内存 transcript；
 * 2. shim 重启 / 滚动发布后，Bus 复用的 `zap_session_id` 仍能找回（rehydrate），不必 404 重建；
 *    Bus 即便重建会话，也带同一 `conversation_id`，历史照样接上；
 * 3. 多副本：任一副本都能从 PG 冷启动一个会话（亲和退化为热窗口优化，不再是正确性前提）。
 *
 * 纪律：
 * - 只存**北侧 ZAP 词汇**的事件（user.message / message.created / tool_call / tool_result / completed / failed / cancelled），
 *   不存 block.delta（终稿已在 completed）与 reasoning（F24 O3：思考正文不落库）。不存任何凭据。
 * - 写路径 fire-and-forget：SSE 主链路永不等 PG；失败只打日志 + 计数。读路径失败回落内存 transcript。
 * - 库纪律同百工：独立 database（推荐 `dsh_runtime`）或独立 schema（DSN 带 `options=-c search_path=...`）；
 *   **禁止**指向 Bus 的 `agent_bus` 库。零手写迁移：建表 `CREATE TABLE IF NOT EXISTS`，启动时执行。
 * - 所有查询按 tenant_id 限定；跨 conversation 重放还要求同一 agent_key。
 */
import pg from 'pg';
import type { SessionRecord } from '../sessions/session-store.js';
import { skillsFromSnapshot, snapshotOf, type SkillsSnapshot } from '../skills/skills.js';

export interface TranscriptEntry {
  role: 'user' | 'assistant';
  text: string;
}

export interface HistoryEvent {
  event: string;
  message_id: string;
  payload: Record<string, unknown>;
}

export interface TranscriptLimits {
  maxEntries: number;
  maxChars: number;
}

export interface HistoryLogger {
  info(obj: Record<string, unknown>, msg: string): void;
  warn(obj: Record<string, unknown>, msg: string): void;
}

export interface HistoryMetrics {
  observeHistoryWrite(ok: boolean, rows: number): void;
}

export interface HistoryStore {
  readonly kind: 'memory' | 'pg';
  sessionCreated(rec: SessionRecord): Promise<void>;
  sessionCancelled(sessionId: string): Promise<void>;
  sessionDeleted(sessionId: string): Promise<void>;
  /** 技能状态机持久化（§11.4 第 6 条：current_seq 与技能集随会话落库，重启找回后重新落盘） */
  sessionSkillsUpdated(rec: SessionRecord): Promise<void>;
  /** 追加一条消息产生的事件（调用方已按 rec.event_seq 编号）。不抛、不等。 */
  appendEvents(rec: SessionRecord, events: Array<HistoryEvent & { seq: number }>): void;
  /** 按 (tenant, agent, conversation) 重放 transcript，最新在后，按 limits 从最早处裁。 */
  loadTranscript(scope: { tenant_id: string; agent_key: string; conversation_id: string }, limits: TranscriptLimits): Promise<TranscriptEntry[]>;
  /** shim 重启后找回会话（已取消/已删除/已过期的不返回）。 */
  findSession(sessionId: string, now?: number): Promise<SessionRecord | undefined>;
  /**
   * 跨副本会话互斥：同一 session_id 同时只允许一个副本跑一条消息（共享卷上两个进程互踩 / 历史错序）。
   * 拿到 → 返回释放函数；拿不到 → null（调用方返 zap.session_busy）。PG 不可用时放行并告警（历史是尽力而为，不能让锁把服务拖死）。
   */
  lockSession(sessionId: string): Promise<(() => Promise<void>) | null>;
  close(): Promise<void>;
}

/** 未配 PG：一切 no-op，读返回空让调用方回落内存 transcript。 */
export class MemoryHistory implements HistoryStore {
  private readonly locked = new Set<string>();

  async lockSession(sessionId: string): Promise<(() => Promise<void>) | null> {
    if (this.locked.has(sessionId)) return null;
    this.locked.add(sessionId);
    return async () => {
      this.locked.delete(sessionId);
    };
  }

  readonly kind = 'memory' as const;
  async sessionCreated(): Promise<void> {}
  async sessionCancelled(): Promise<void> {}
  async sessionDeleted(): Promise<void> {}
  async sessionSkillsUpdated(): Promise<void> {}
  appendEvents(): void {}
  async loadTranscript(): Promise<TranscriptEntry[]> {
    return [];
  }
  async findSession(): Promise<SessionRecord | undefined> {
    return undefined;
  }
  async close(): Promise<void> {}
}

const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS dsh_runtime_sessions (
  session_id      text PRIMARY KEY,
  tenant_id       text NOT NULL,
  user_id         text NOT NULL,
  agent_key       text NOT NULL,
  agent_id        text NOT NULL DEFAULT '',
  conversation_id text NOT NULL DEFAULT '',
  purpose         text NOT NULL,
  session_kind    text NOT NULL,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL,
  expires_at      timestamptz NOT NULL,
  last_active_at  timestamptz,
  cancelled_at    timestamptz,
  deleted_at      timestamptz,
  skill_seq       bigint NOT NULL DEFAULT 0,
  skills          jsonb NOT NULL DEFAULT '{}'::jsonb
);
ALTER TABLE dsh_runtime_sessions ADD COLUMN IF NOT EXISTS skill_seq bigint NOT NULL DEFAULT 0;
ALTER TABLE dsh_runtime_sessions ADD COLUMN IF NOT EXISTS skills jsonb NOT NULL DEFAULT '{}'::jsonb;
CREATE INDEX IF NOT EXISTS dsh_runtime_sessions_conv_idx
  ON dsh_runtime_sessions (tenant_id, agent_key, conversation_id, created_at);
CREATE TABLE IF NOT EXISTS dsh_runtime_session_events (
  session_id  text NOT NULL,
  seq         bigint NOT NULL,
  message_id  text NOT NULL DEFAULT '',
  event       text NOT NULL,
  payload     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (session_id, seq)
);
`;

/** 只重放这两类事件；其余（tool_call/result、failed、cancelled）是排障/审计用，不进提示词。 */
const REPLAY_EVENTS = ['user.message', 'message.completed'];
const INSERT_BATCH = 200;

export class PgHistory implements HistoryStore {
  readonly kind = 'pg' as const;
  private readonly pool: pg.Pool;
  private pending: Promise<unknown> = Promise.resolve();

  constructor(
    dsn: string,
    private readonly log: HistoryLogger,
    private readonly metrics?: HistoryMetrics,
    poolFactory: (cfg: pg.PoolConfig) => pg.Pool = (cfg) => new pg.Pool(cfg),
  ) {
    this.pool = poolFactory({ connectionString: dsn, max: 4, connectionTimeoutMillis: 5_000, idleTimeoutMillis: 30_000 });
    this.pool.on('error', (err) => this.log.warn({ detail: err.message }, 'history pg pool error'));
  }

  /**
   * PG advisory lock（会话级，跨副本）：独占一个连接持锁到消息结束。key = hashtext(session_id)（int4 足够：锁冲突只是误报 busy）。
   * 连不上 / 连接池满 → 放行 + 告警（不让锁把聊天拖死；此时退化为单副本内存互斥）。
   */
  async lockSession(sessionId: string): Promise<(() => Promise<void>) | null> {
    let client: pg.PoolClient;
    try {
      client = await this.pool.connect();
    } catch (err) {
      this.metrics?.observeHistoryWrite(false, 0);
      this.log.warn({ session_id: sessionId, detail: err instanceof Error ? err.message : String(err) }, 'session lock unavailable (pg); proceeding without cross-replica guard');
      return async () => {};
    }
    try {
      const res = await client.query<{ ok: boolean }>('SELECT pg_try_advisory_lock(hashtext($1)) AS ok', [sessionId]);
      if (!res.rows[0]?.ok) {
        client.release();
        return null;
      }
    } catch (err) {
      client.release(err instanceof Error ? err : undefined);
      this.log.warn({ session_id: sessionId, detail: err instanceof Error ? err.message : String(err) }, 'session lock query failed; proceeding without cross-replica guard');
      return async () => {};
    }
    let released = false;
    return async () => {
      if (released) return;
      released = true;
      try {
        await client.query('SELECT pg_advisory_unlock(hashtext($1))', [sessionId]);
        client.release();
      } catch (err) {
        client.release(err instanceof Error ? err : undefined);
      }
    };
  }

  /** 建表（幂等）。连不上直接抛：操作者显式配了 DSN，就不该带病运行。 */
  async init(): Promise<void> {
    await this.pool.query(SCHEMA_SQL);
    this.log.info({ kind: 'pg' }, 'session history store ready');
  }

  async sessionCreated(rec: SessionRecord): Promise<void> {
    await this.guarded('session insert', () =>
      this.pool.query(
        `INSERT INTO dsh_runtime_sessions (session_id, tenant_id, user_id, agent_key, agent_id, conversation_id, purpose, session_kind, metadata, created_at, expires_at, skill_seq, skills)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,to_timestamp($10/1000.0),to_timestamp($11/1000.0),$12,$13)
         ON CONFLICT (session_id) DO NOTHING`,
        [rec.session_id, rec.tenant_id, rec.user_id, rec.agent_key, rec.agent_id, rec.conversation_id, rec.purpose, rec.session_kind, JSON.stringify(rec.metadata ?? {}), rec.created_at, rec.expires_at, rec.skills.seq, JSON.stringify(snapshotOf(rec.skills))],
      ),
    );
  }

  async sessionCancelled(sessionId: string): Promise<void> {
    await this.guarded('session cancel', () => this.pool.query(`UPDATE dsh_runtime_sessions SET cancelled_at = now() WHERE session_id = $1 AND cancelled_at IS NULL`, [sessionId]));
  }

  async sessionDeleted(sessionId: string): Promise<void> {
    await this.guarded('session delete', () => this.pool.query(`UPDATE dsh_runtime_sessions SET deleted_at = now() WHERE session_id = $1 AND deleted_at IS NULL`, [sessionId]));
  }

  async sessionSkillsUpdated(rec: SessionRecord): Promise<void> {
    await this.guarded('session skills update', () =>
      this.pool.query(`UPDATE dsh_runtime_sessions SET skill_seq = $2, skills = $3 WHERE session_id = $1`, [rec.session_id, rec.skills.seq, JSON.stringify(snapshotOf(rec.skills))]),
    );
  }

  appendEvents(rec: SessionRecord, events: Array<HistoryEvent & { seq: number }>): void {
    if (events.length === 0) return;
    // 串行化写入（同会话事件按 seq 落库；跨会话也不争连接），任何失败只记日志与指标。
    this.pending = this.pending.then(async () => {
      try {
        for (let i = 0; i < events.length; i += INSERT_BATCH) {
          const batch = events.slice(i, i + INSERT_BATCH);
          const values: unknown[] = [];
          const tuples = batch.map((e, j) => {
            values.push(rec.session_id, e.seq, e.message_id, e.event, JSON.stringify(e.payload));
            const b = j * 5;
            return `($${b + 1},$${b + 2},$${b + 3},$${b + 4},$${b + 5})`;
          });
          await this.pool.query(`INSERT INTO dsh_runtime_session_events (session_id, seq, message_id, event, payload) VALUES ${tuples.join(',')} ON CONFLICT DO NOTHING`, values);
        }
        await this.pool.query(`UPDATE dsh_runtime_sessions SET last_active_at = now() WHERE session_id = $1`, [rec.session_id]);
        this.metrics?.observeHistoryWrite(true, events.length);
      } catch (err) {
        this.metrics?.observeHistoryWrite(false, events.length);
        this.log.warn({ session_id: rec.session_id, rows: events.length, detail: err instanceof Error ? err.message : String(err) }, 'history write failed (events dropped)');
      }
    });
  }

  async loadTranscript(scope: { tenant_id: string; agent_key: string; conversation_id: string }, limits: TranscriptLimits): Promise<TranscriptEntry[]> {
    if (!scope.conversation_id) return [];
    try {
      const res = await this.pool.query<{ event: string; payload: Record<string, unknown> }>(
        `SELECT e.event, e.payload
           FROM dsh_runtime_session_events e
           JOIN dsh_runtime_sessions s ON s.session_id = e.session_id
          WHERE s.tenant_id = $1 AND s.agent_key = $2 AND s.conversation_id = $3 AND e.event = ANY($4::text[])
          ORDER BY s.created_at DESC, e.seq DESC
          LIMIT $5`,
        [scope.tenant_id, scope.agent_key, scope.conversation_id, REPLAY_EVENTS, limits.maxEntries],
      );
      const entries: TranscriptEntry[] = [];
      for (const row of res.rows.reverse()) {
        const text = row.event === 'user.message' ? String(row.payload['text'] ?? '') : blocksText(row.payload['blocks']);
        if (text) entries.push({ role: row.event === 'user.message' ? 'user' : 'assistant', text });
      }
      let chars = entries.reduce((n, e) => n + e.text.length, 0);
      while (chars > limits.maxChars && entries.length > 2) chars -= entries.shift()!.text.length;
      return entries;
    } catch (err) {
      this.log.warn({ conversation_id: scope.conversation_id, detail: err instanceof Error ? err.message : String(err) }, 'history read failed (falling back to in-memory transcript)');
      return [];
    }
  }

  async findSession(sessionId: string, now = Date.now()): Promise<SessionRecord | undefined> {
    try {
      const res = await this.pool.query<{
        session_id: string; tenant_id: string; user_id: string; agent_key: string; agent_id: string; conversation_id: string; purpose: string; session_kind: string;
        metadata: Record<string, unknown>; created_at: Date; expires_at: Date; cancelled_at: Date | null; deleted_at: Date | null; next_seq: string;
        skill_seq: string; skills: SkillsSnapshot | Record<string, never>;
      }>(
        `SELECT s.*, COALESCE((SELECT MAX(seq) + 1 FROM dsh_runtime_session_events e WHERE e.session_id = s.session_id), 0)::text AS next_seq
           FROM dsh_runtime_sessions s WHERE s.session_id = $1`,
        [sessionId],
      );
      const r = res.rows[0];
      if (!r || r.cancelled_at || r.deleted_at || r.expires_at.getTime() <= now) return undefined;
      return {
        session_id: r.session_id,
        tenant_id: r.tenant_id,
        user_id: r.user_id,
        agent_key: r.agent_key,
        agent_id: r.agent_id,
        conversation_id: r.conversation_id,
        purpose: r.purpose,
        session_kind: r.session_kind,
        metadata: r.metadata ?? {},
        created_at: r.created_at.getTime(),
        expires_at: r.expires_at.getTime(),
        cancelled: false,
        inflight: false,
        turns: 0,
        transcript: [],
        event_seq: Number(r.next_seq),
        skills: skillsFromSnapshot(r.skills && 'agent_skills' in r.skills ? (r.skills as SkillsSnapshot) : undefined, Number(r.skill_seq ?? 0)),
        skillsReady: Promise.resolve(),
      };
    } catch (err) {
      this.log.warn({ session_id: sessionId, detail: err instanceof Error ? err.message : String(err) }, 'history lookup failed');
      return undefined;
    }
  }

  /** 等待在途写入落盘（测试/优雅关闭用）。 */
  async flush(): Promise<void> {
    await this.pending;
  }

  async close(): Promise<void> {
    await this.flush();
    await this.pool.end();
  }

  private async guarded(what: string, fn: () => Promise<unknown>): Promise<void> {
    try {
      await fn();
    } catch (err) {
      this.log.warn({ detail: err instanceof Error ? err.message : String(err) }, `history ${what} failed`);
    }
  }
}

function blocksText(blocks: unknown): string {
  if (!Array.isArray(blocks)) return '';
  return blocks
    .map((b) => (typeof b === 'object' && b !== null && typeof (b as { text?: unknown }).text === 'string' ? (b as { text: string }).text : ''))
    .filter((t) => t !== '')
    .join('\n\n');
}
