/** Local-only authority. Never serialize credentials or DSH session files here. */
import { createHash } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import type { ArtifactMeta } from './artifacts.js';
import { frames, type ZapFrame } from '../translate/sse.js';

export interface LocalIdentity {
  tenant: string;
  account: string;
  loginSession: string;
  device: string;
}

export interface LocalTask extends LocalIdentity {
  engine?: 'dsh' | 'codex_app_server';
  run: string;
  messageId: string;
  employee: string;
  conversation: string;
  fence: number;
  expiresAt: number;
  source: 'desktop' | 'mobile';
  message: string;
  model: string;
}

export type RunStatus = 'accepted' | 'running' | 'completed' | 'failed' | 'cancelled';
export interface StoredRun {
  task: LocalTask;
  status: RunStatus;
  ack: number;
  seq: number;
}
export interface LocalEvent { run: string; fence: number; seq: number; frame: ZapFrame }

export class LocalError extends Error {
  constructor(readonly code: string) { super(code); }
}

export function fingerprint(value: unknown): string {
  const stable = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(stable);
    if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).sort(([a], [b]) => a.localeCompare(b)).map(([k, val]) => [k, stable(val)]));
    return v;
  };
  return createHash('sha256').update(JSON.stringify(stable(value))).digest('hex');
}

export function sameIdentity(a: LocalIdentity, b: LocalIdentity): boolean {
  return a.tenant === b.tenant && a.account === b.account && a.loginSession === b.loginSession && a.device === b.device;
}

export function assertTask(task: LocalTask): void {
  for (const id of [task.run, task.messageId, task.tenant, task.account, task.loginSession, task.device, task.employee, task.conversation]) {
    if (!/^[a-zA-Z0-9_-]{1,128}$/.test(id)) throw new LocalError('local.invalid_identity');
  }
  if (!['desktop', 'mobile'].includes(task.source) || !Number.isSafeInteger(task.fence) || task.fence <= 0 || !Number.isSafeInteger(task.expiresAt)) throw new LocalError('local.invalid_task');
  if (!task.model || task.model.length > 1024 || !task.message || task.message.length > 100_000) throw new LocalError('local.invalid_task');
  if (task.engine !== undefined && !['dsh', 'codex_app_server'].includes(task.engine)) throw new LocalError('local.invalid_task');
}

const terminal = new Map<string, RunStatus>([
  ['message.completed', 'completed'], ['message.failed', 'failed'], ['message.cancelled', 'cancelled'],
]);

export class LocalLedger {
  private readonly db: DatabaseSync;

  constructor(path: string) {
    this.db = new DatabaseSync(path);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS runs (
        run TEXT PRIMARY KEY, identity TEXT NOT NULL, conversation TEXT NOT NULL, task TEXT NOT NULL,
        digest TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('accepted','running','completed','failed','cancelled')),
        ack INTEGER NOT NULL DEFAULT 0, seq INTEGER NOT NULL DEFAULT 0
      ) STRICT;
      CREATE UNIQUE INDEX IF NOT EXISTS active_conversation ON runs(identity,conversation) WHERE status IN ('accepted','running');
      CREATE TABLE IF NOT EXISTS events (
        run TEXT NOT NULL REFERENCES runs(run), seq INTEGER NOT NULL, frame TEXT NOT NULL, PRIMARY KEY(run,seq)
      ) STRICT;
      CREATE TABLE IF NOT EXISTS result_outbox (
        run TEXT PRIMARY KEY REFERENCES runs(run), artifacts TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL DEFAULT 0
      ) STRICT;
      CREATE TABLE IF NOT EXISTS media_jobs (
        id TEXT PRIMARY KEY, run TEXT NOT NULL REFERENCES runs(run), digest TEXT NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('prepared','submitting','unknown','completed','failed')),
        remote_id TEXT, result TEXT
      ) STRICT;`);
  }

  close(): void { this.db.close(); }

  private atomic<T>(fn: () => T): T {
    this.db.exec('BEGIN IMMEDIATE');
    try { const value = fn(); this.db.exec('COMMIT'); return value; }
    catch (err) { this.db.exec('ROLLBACK'); throw err; }
  }

  get(run: string): StoredRun | undefined {
    const row = this.db.prepare('SELECT task,status,ack,seq FROM runs WHERE run=?').get(run);
    return row ? { task: JSON.parse(String(row['task'])) as LocalTask, status: row['status'] as RunStatus, ack: Number(row['ack']), seq: Number(row['seq']) } : undefined;
  }

  unacknowledged(identity: LocalIdentity): StoredRun[] {
    return this.db.prepare("SELECT run FROM runs WHERE identity=? AND (ack<seq OR status IN ('accepted','running'))").all(fingerprint(identity))
      .map((row) => this.get(String(row['run']))!);
  }

  /** Commit before returning accepted; duplicate delivery must never execute again. */
  accept(task: LocalTask, identity: LocalIdentity, now = Date.now()): { fresh: boolean; run: StoredRun } {
    assertTask(task);
    if (!sameIdentity(task, identity)) throw new LocalError('local.identity_mismatch');
    return this.atomic(() => {
      const old = this.get(task.run);
      if (old) {
        if (fingerprint(old.task) !== fingerprint(task)) throw new LocalError('local.task_conflict');
        return { fresh: false, run: old };
      }
      if (task.expiresAt <= now) throw new LocalError('local.lease_expired');
      const owner = fingerprint(identity);
      if (this.db.prepare("SELECT run FROM runs WHERE identity=? AND conversation=? AND status IN ('accepted','running')").get(owner, task.conversation)) throw new LocalError('local.conversation_busy');
      // Serialize only the declared public task fields. Unknown input properties cannot persist keys.
      const clean: LocalTask = {
        tenant: task.tenant, account: task.account, loginSession: task.loginSession, device: task.device,
        employee: task.employee, conversation: task.conversation, run: task.run, messageId: task.messageId, fence: task.fence,
        expiresAt: task.expiresAt, source: task.source, message: task.message, model: task.model,
        ...(task.engine ? { engine: task.engine } : {}),
      };
      this.db.prepare("INSERT INTO runs(run,identity,conversation,task,digest,status) VALUES(?,?,?,?,?,'accepted')").run(task.run, owner, task.conversation, JSON.stringify(clean), fingerprint(clean));
      return { fresh: true, run: this.get(task.run)! };
    });
  }

  start(run: string): void {
    if (this.db.prepare("UPDATE runs SET status='running' WHERE run=? AND status='accepted'").run(run).changes !== 1) throw new LocalError('local.run_not_accepted');
  }

  append(run: string, fence: number, frame: ZapFrame): LocalEvent {
    return this.atomic(() => this.appendInside(run, fence, frame));
  }

  private appendInside(run: string, fence: number, frame: ZapFrame): LocalEvent {
    const current = this.get(run);
    if (!current || current.task.fence !== fence) throw new LocalError('local.fence_mismatch');
    if (current.status !== 'running' && current.status !== 'accepted') throw new LocalError('local.run_settled');
    if (current.seq - current.ack >= 2000 && !terminal.has(frame.event)) throw new LocalError('local.replay_window_exceeded');
    const seq = current.seq + 1;
    this.db.prepare('INSERT INTO events(run,seq,frame) VALUES(?,?,?)').run(run, seq, JSON.stringify(frame));
    this.db.prepare('UPDATE runs SET seq=?,status=? WHERE run=?').run(seq, terminal.get(frame.event) ?? current.status, run);
    if (terminal.has(frame.event) && Array.isArray(frame.data['blocks'])) {
      const artifacts = frame.data['blocks'].filter((b: Record<string, unknown>) => b['local_artifact']).map((b: Record<string, unknown>) => { const { type: _type, ...meta } = b; return meta; });
      if (artifacts.length) this.db.prepare('INSERT OR IGNORE INTO result_outbox(run,artifacts) VALUES(?,?)').run(run, JSON.stringify(artifacts));
    }
    return { run, fence, seq, frame };
  }

  acknowledge(run: string, fence: number, seq: number): void {
    const current = this.get(run);
    if (!current || current.task.fence !== fence) throw new LocalError('local.fence_mismatch');
    if (!Number.isSafeInteger(seq) || seq < 0 || seq > current.seq) throw new LocalError('local.invalid_ack');
    this.db.prepare('UPDATE runs SET ack=max(ack,?) WHERE run=?').run(seq, run);
  }

  replay(run: string, fence: number, after?: number): LocalEvent[] {
    const current = this.get(run);
    if (!current || current.task.fence !== fence) throw new LocalError('local.fence_mismatch');
    const from = after ?? current.ack;
    if (!Number.isSafeInteger(from) || from < 0 || from > current.seq) throw new LocalError('local.invalid_ack');
    return this.db.prepare('SELECT seq,frame FROM events WHERE run=? AND seq>? ORDER BY seq').all(run, from)
      .map((row) => ({ run, fence, seq: Number(row['seq']), frame: JSON.parse(String(row['frame'])) as ZapFrame }));
  }

  /** Crash/sleep recovery never re-executes a possibly side-effecting task or media submission. */
  recover(): LocalEvent[] {
    return this.atomic(() => {
      const out: LocalEvent[] = [];
      for (const row of this.db.prepare("SELECT run FROM runs WHERE status IN ('accepted','running')").all()) {
        const run = this.get(String(row['run']))!;
        if (!run.seq) out.push(this.appendInside(run.task.run, run.task.fence, { event: 'message.created', data: { message_id: run.task.messageId, role: 'assistant', status: 'streaming' } }));
        const pending = new Map<string, string>();
        for (const event of this.replay(run.task.run, run.task.fence, 0)) {
          const id = event.frame.data['tool_call_id'];
          if (typeof id !== 'string') continue;
          if (event.frame.event === 'message.tool_call') pending.set(id, String(event.frame.data['tool_name'] ?? ''));
          if (event.frame.event === 'message.tool_result') pending.delete(id);
        }
        for (const [id, name] of pending) out.push(this.appendInside(run.task.run, run.task.fence, frames.toolResult(run.task.messageId, id, name, false, '本机执行中断；请检查操作是否已生效后续跑。')));
        out.push(this.appendInside(run.task.run, run.task.fence, { event: 'message.failed', data: { message_id: run.task.messageId, error_code: 'zap.runtime_interrupted', error_message: '本机任务因应用退出或电脑休眠中断，请检查已有结果后续跑。' } }));
      }
      this.db.exec("UPDATE media_jobs SET state='unknown' WHERE state='submitting'");
      return out;
    });
  }

  pendingResults(identity: LocalIdentity, now = Date.now()): { task: LocalTask; artifacts: ArtifactMeta[]; attempts: number }[] {
    return this.db.prepare(`SELECT o.run,o.artifacts,o.attempts FROM result_outbox o JOIN runs r ON r.run=o.run
      WHERE r.identity=? AND o.next_at<=? AND o.attempts<12 AND json_extract(r.task,'$.expiresAt') + 604800000 > ? ORDER BY o.next_at LIMIT 4`).all(fingerprint(identity), now, now)
      .map((row) => ({ task: this.get(String(row['run']))!.task, artifacts: JSON.parse(String(row['artifacts'])) as ArtifactMeta[], attempts: Number(row['attempts']) }))
      .filter(({task}) => task.expiresAt + 7 * 24 * 60 * 60 * 1000 > now);
  }

  saveResultAttempt(run: string, artifacts: ArtifactMeta[], complete: boolean): void {
    if (complete) { this.db.prepare('DELETE FROM result_outbox WHERE run=?').run(run); return; }
    this.db.prepare(`UPDATE result_outbox SET artifacts=?, attempts=attempts+1,
      next_at=? + min(300000, 1000 * (1 << min(attempts,8))) WHERE run=?`).run(JSON.stringify(artifacts), Date.now(), run);
  }

  prepareMedia(id: string, run: string, request: unknown): 'prepared' | 'submitting' | 'unknown' | 'completed' | 'failed' {
    const digest = fingerprint(request);
    return this.atomic(() => {
      const old = this.db.prepare('SELECT run,digest,state FROM media_jobs WHERE id=?').get(id);
      if (old) {
        if (old['run'] !== run || old['digest'] !== digest) throw new LocalError('local.media_conflict');
        return old['state'] as 'prepared' | 'submitting' | 'unknown' | 'completed' | 'failed';
      }
      this.db.prepare("INSERT INTO media_jobs(id,run,digest,state) VALUES(?,?,?,'prepared')").run(id, run, digest);
      return 'prepared';
    });
  }

  beginMedia(id: string): void {
    if (this.db.prepare("UPDATE media_jobs SET state='submitting' WHERE id=? AND state='prepared'").run(id).changes !== 1) throw new LocalError('local.media_reconcile_required');
  }

  settleMedia(id: string, state: 'unknown' | 'completed' | 'failed', remoteId?: string): void {
    if (this.db.prepare("UPDATE media_jobs SET state=?,remote_id=coalesce(?,remote_id) WHERE id=? AND state IN ('submitting','unknown')").run(state, remoteId ?? null, id).changes !== 1) throw new LocalError('local.media_invalid_state');
  }
}
