/**
 * Skills Carrier（ZAP-1.1 §11 / F03）runtime 侧：Bus 下发的技能包 → 标准 SKILL.md 目录 → dsh `skill-filesystem` 发现。
 *
 * 三件事分三块：
 * - 校验/状态机（纯函数）：`parseSkillsNode` / `parsePatch` / `applyPatch`（严格 patch_seq = current+1）。
 * - 包缓存 `SkillPackages`：按 sha256 缓存 zip（`<cache>/skill-packages/<sha>.zip`），下载限大小、校验 sha、
 *   解压防 zip-slip（纯 JS fflate，不依赖系统 unzip）。
 * - 会话落盘 `SkillCarrier`：`<cache>/skills/<session_id>/<code>/SKILL.md`，整套/单个落盘与删除。
 *
 * 纪律：包体与 URL 都是租户数据，不进日志；技能目录只读授权给 agent 进程（pool/read-isolation）；
 * 任何单个技能失败只跳过该技能（日志 + 指标），不影响会话。
 */
import { createHash, randomBytes } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { Unzip, UnzipInflate } from 'fflate';
import { setImmediate } from 'node:timers/promises';

export interface AgentSkill {
  skill_id: string;
  code: string;
  version: string;
  package_url: string;
  package_sha256: string;
  package_size_bytes?: number;
  default_params?: Record<string, unknown>;
  frontmatter?: Record<string, unknown>;
}

export interface BuiltinSkill {
  skill_id: string;
  code: string;
  builtin_key?: string;
  name?: string;
  execution_mode?: string;
  default_params?: Record<string, unknown>;
}

export interface SkillsSnapshot {
  agent_skills: AgentSkill[];
  builtin_skills: BuiltinSkill[];
}

/** 会话内技能状态（挂在 SessionRecord.skills 上，随 PG 持久化） */
export interface SessionSkills {
  seq: number;
  agent: Map<string, AgentSkill>;
  builtin: BuiltinSkill[];
}

export interface SkillsPatch {
  patch_seq: number;
  added: AgentSkill[];
  updated: Array<Partial<AgentSkill> & { skill_id: string }>;
  removed: string[];
}

export type PatchOutcome =
  | { kind: 'applied'; materialize: AgentSkill[]; remove: AgentSkill[] }
  | { kind: 'outdated'; current_seq: number }
  | { kind: 'gap'; current_seq: number; expected_seq: number; received_seq: number };

const SAFE_CODE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const SHA256_RE = /^[0-9a-f]{64}$/i;
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v);
const str = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');

export function emptySkills(): SessionSkills {
  return { seq: 0, agent: new Map(), builtin: [] };
}

export function snapshotOf(s: SessionSkills): SkillsSnapshot {
  return { agent_skills: [...s.agent.values()], builtin_skills: [...s.builtin] };
}

export function skillsFromSnapshot(snap: SkillsSnapshot | undefined, seq = 0): SessionSkills {
  const s = emptySkills();
  s.seq = seq;
  for (const a of snap?.agent_skills ?? []) s.agent.set(a.skill_id, a);
  s.builtin = [...(snap?.builtin_skills ?? [])];
  return s;
}

function parseAgentSkill(v: unknown, errors: string[], where: string, partial = false): AgentSkill | (Partial<AgentSkill> & { skill_id: string }) | undefined {
  if (!isObj(v)) {
    errors.push(`${where}: must be an object`);
    return undefined;
  }
  const skill_id = str(v['skill_id']);
  if (!SAFE_ID.test(skill_id)) errors.push(`${where}.skill_id: required safe identifier`);
  const out: Partial<AgentSkill> & { skill_id: string } = { skill_id };
  const code = str(v['code']);
  if (code || !partial) {
    if (!SAFE_CODE.test(code)) errors.push(`${where}.code: required, [A-Za-z0-9._-]{1,64}`);
    out.code = code;
  }
  const version = str(v['version']);
  if (version || !partial) {
    if (!version || version.length > 64) errors.push(`${where}.version: required`);
    out.version = version;
  }
  const url = str(v['package_url']);
  if (url || !partial) {
    if (!/^https?:\/\//i.test(url)) errors.push(`${where}.package_url: must be http(s) URL`);
    out.package_url = url;
  }
  const sha = str(v['package_sha256']).toLowerCase();
  if (sha || !partial) {
    if (!SHA256_RE.test(sha)) errors.push(`${where}.package_sha256: must be 64 hex chars`);
    out.package_sha256 = sha;
  }
  if (v['package_size_bytes'] !== undefined) {
    const n = Number(v['package_size_bytes']);
    if (!Number.isFinite(n) || n < 0) errors.push(`${where}.package_size_bytes: must be a non-negative number`);
    else out.package_size_bytes = n;
  }
  if (v['default_params'] !== undefined) {
    if (!isObj(v['default_params'])) errors.push(`${where}.default_params: must be an object`);
    else out.default_params = v['default_params'];
  }
  if (v['frontmatter'] !== undefined) {
    if (!isObj(v['frontmatter'])) errors.push(`${where}.frontmatter: must be an object`);
    else out.frontmatter = v['frontmatter'];
  }
  return out as AgentSkill;
}

function parseBuiltinSkill(v: unknown, errors: string[], where: string): BuiltinSkill | undefined {
  if (!isObj(v)) {
    errors.push(`${where}: must be an object`);
    return undefined;
  }
  const skill_id = str(v['skill_id']);
  const code = str(v['code']);
  if (!SAFE_ID.test(skill_id)) errors.push(`${where}.skill_id: required safe identifier`);
  if (!SAFE_CODE.test(code)) errors.push(`${where}.code: required`);
  return {
    skill_id,
    code,
    ...(str(v['builtin_key']) ? { builtin_key: str(v['builtin_key']) } : {}),
    ...(str(v['name']) ? { name: str(v['name']) } : {}),
    ...(str(v['execution_mode']) ? { execution_mode: str(v['execution_mode']) } : {}),
    ...(isObj(v['default_params']) ? { default_params: v['default_params'] } : {}),
  };
}

/** `POST /sessions` / resync 的 `skills` 节。返回快照或错误列表。 */
export function parseSkillsNode(v: unknown): { snapshot: SkillsSnapshot; errors: string[] } {
  const errors: string[] = [];
  const snapshot: SkillsSnapshot = { agent_skills: [], builtin_skills: [] };
  if (!isObj(v)) {
    errors.push('skills: must be an object');
    return { snapshot, errors };
  }
  const agents = v['agent_skills'] ?? [];
  const builtins = v['builtin_skills'] ?? [];
  if (!Array.isArray(agents)) errors.push('skills.agent_skills: must be an array');
  else agents.forEach((a, i) => {
    const s = parseAgentSkill(a, errors, `skills.agent_skills[${i}]`);
    if (s) snapshot.agent_skills.push(s as AgentSkill);
  });
  if (!Array.isArray(builtins)) errors.push('skills.builtin_skills: must be an array');
  else builtins.forEach((b, i) => {
    const s = parseBuiltinSkill(b, errors, `skills.builtin_skills[${i}]`);
    if (s) snapshot.builtin_skills.push(s);
  });
  const codes = new Set<string>();
  for (const a of snapshot.agent_skills) {
    if (codes.has(a.code)) errors.push(`skills.agent_skills: duplicate code ${a.code}`);
    codes.add(a.code);
  }
  return { snapshot, errors };
}

/** `PATCH /sessions/:sid/skills` body。 */
export function parsePatch(v: unknown): { patch: SkillsPatch; errors: string[] } {
  const errors: string[] = [];
  const patch: SkillsPatch = { patch_seq: 0, added: [], updated: [], removed: [] };
  if (!isObj(v)) {
    errors.push('body: must be an object');
    return { patch, errors };
  }
  const seq = Number(v['patch_seq']);
  if (!Number.isInteger(seq) || seq < 1) errors.push('patch_seq: must be a positive integer');
  else patch.patch_seq = seq;
  for (const key of ['added', 'updated', 'removed'] as const) {
    const arr = v[key] ?? [];
    if (!Array.isArray(arr)) {
      errors.push(`${key}: must be an array`);
      continue;
    }
    arr.forEach((item, i) => {
      if (key === 'removed') {
        const id = str(item);
        if (!SAFE_ID.test(id)) errors.push(`removed[${i}]: must be a skill_id`);
        else patch.removed.push(id);
      } else {
        const s = parseAgentSkill(item, errors, `${key}[${i}]`, key === 'updated');
        if (s) (key === 'added' ? patch.added : patch.updated).push(s as AgentSkill);
      }
    });
  }
  return { patch, errors };
}

/** 严格 seq 状态机（§11.2.A）。applied 时已就地更新 state，并返回需要落盘/删除的技能。 */
export function applyPatch(state: SessionSkills, patch: SkillsPatch): PatchOutcome {
  if (patch.patch_seq <= state.seq) return { kind: 'outdated', current_seq: state.seq };
  if (patch.patch_seq > state.seq + 1) return { kind: 'gap', current_seq: state.seq, expected_seq: state.seq + 1, received_seq: patch.patch_seq };
  const materialize: AgentSkill[] = [];
  const remove: AgentSkill[] = [];
  for (const id of patch.removed) {
    const prev = state.agent.get(id);
    if (prev) {
      state.agent.delete(id);
      remove.push(prev);
    }
  }
  for (const a of patch.added) {
    const prev = state.agent.get(a.skill_id);
    if (prev && prev.code !== a.code) remove.push(prev);
    state.agent.set(a.skill_id, a);
    materialize.push(a);
  }
  for (const u of patch.updated) {
    const prev = state.agent.get(u.skill_id);
    if (!prev) continue; // 更新一个不存在的技能：按 upsert 需要完整字段，缺字段则忽略
    const next: AgentSkill = { ...prev, ...stripUndefined(u) };
    if (prev.code !== next.code) remove.push(prev);
    state.agent.set(u.skill_id, next);
    materialize.push(next);
  }
  state.seq = patch.patch_seq;
  return { kind: 'applied', materialize, remove };
}

function stripUndefined<T extends object>(o: T): Partial<T> {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined)) as Partial<T>;
}

/** 请求级幂等缓存（§11.2.B：Idempotency-Key 只缓存响应，不参与状态机）。 */
export class IdempotencyCache {
  private readonly entries = new Map<string, { at: number; status: number; body: unknown }>();
  constructor(
    private readonly ttlMs = 3600_000,
    private readonly max = 10_000,
  ) {}

  get(key: string, now = Date.now()): { status: number; body: unknown } | undefined {
    const e = this.entries.get(key);
    if (!e) return undefined;
    if (now - e.at > this.ttlMs) {
      this.entries.delete(key);
      return undefined;
    }
    return { status: e.status, body: e.body };
  }

  set(key: string, status: number, body: unknown, now = Date.now()): void {
    if (this.entries.size >= this.max) {
      for (const [k, e] of this.entries) {
        if (now - e.at > this.ttlMs || this.entries.size >= this.max) this.entries.delete(k);
        else break;
      }
    }
    this.entries.set(key, { at: now, status, body });
  }
}

// ---------------------------------------------------------------------------------------------
// 包缓存 + 解压

export interface SkillsLogger {
  info(obj: Record<string, unknown>, msg: string): void;
  warn(obj: Record<string, unknown>, msg: string): void;
}

export interface SkillsMetrics {
  observeSkillPackage(result: 'cached' | 'downloaded' | 'failed'): void;
}

export interface SkillPackagesOptions {
  dir: string;
  maxBytes: number;
  logger: SkillsLogger;
  metrics?: SkillsMetrics;
  fetchImpl?: typeof fetch;
  downloadTimeoutMs?: number;
}

const MAX_ENTRIES = 5000;
const MAX_EXTRACTED_BYTES = 200 * 1024 * 1024;

export class SkillPackageError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SkillPackageError';
  }
}

export class SkillPackages {
  private readonly inflight = new Map<string, Promise<string>>();

  constructor(private readonly opts: SkillPackagesOptions) {}

  pathFor(sha256: string): string {
    return join(this.opts.dir, `${sha256.toLowerCase()}.zip`);
  }

  isCached(sha256: string): boolean {
    return SHA256_RE.test(sha256) && existsSync(this.pathFor(sha256));
  }

  /** 有缓存直接用；否则下载（限大小）→ 校验 sha256 → 原子落盘。同 sha 并发只下载一次。 */
  async ensure(skill: AgentSkill): Promise<string> {
    const sha = skill.package_sha256.toLowerCase();
    const path = this.pathFor(sha);
    if (existsSync(path)) {
      this.opts.metrics?.observeSkillPackage('cached');
      return path;
    }
    const pending = this.inflight.get(sha);
    if (pending) return pending;
    const task = this.download(skill, sha, path).finally(() => this.inflight.delete(sha));
    this.inflight.set(sha, task);
    return task;
  }

  private async download(skill: AgentSkill, sha: string, path: string): Promise<string> {
    const fetchImpl = this.opts.fetchImpl ?? fetch;
    try {
      const res = await fetchImpl(skill.package_url, { signal: AbortSignal.timeout(this.opts.downloadTimeoutMs ?? 60_000), redirect: 'follow' });
      if (!res.ok || !res.body) throw new SkillPackageError(`download failed: HTTP ${res.status}`);
      const declared = Number(res.headers.get('content-length') ?? '0');
      if (declared > this.opts.maxBytes) throw new SkillPackageError(`package too large: ${declared} > ${this.opts.maxBytes}`);
      const chunks: Uint8Array[] = [];
      let total = 0;
      const reader = res.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        total += value.byteLength;
        if (total > this.opts.maxBytes) {
          await reader.cancel().catch(() => undefined);
          throw new SkillPackageError(`package too large: > ${this.opts.maxBytes}`);
        }
        chunks.push(value);
      }
      const buf = Buffer.concat(chunks);
      const actual = createHash('sha256').update(buf).digest('hex');
      if (actual !== sha) throw new SkillPackageError('package sha256 mismatch');
      await mkdir(this.opts.dir, { recursive: true });
      const tmp = `${path}.${randomBytes(4).toString('hex')}.tmp`;
      await writeFile(tmp, buf);
      await rename(tmp, path);
      this.opts.metrics?.observeSkillPackage('downloaded');
      this.opts.logger.info({ skill_id: skill.skill_id, code: skill.code, version: skill.version, bytes: total }, 'skill package downloaded');
      return path;
    } catch (err) {
      this.opts.metrics?.observeSkillPackage('failed');
      throw err instanceof SkillPackageError ? err : new SkillPackageError(err instanceof Error ? err.message : String(err));
    }
  }
}

/** 校验 zip 内路径：无绝对路径、无 `..`、无反斜杠、无空段。返回规范化段或 null。 */
export function safeZipSegments(entry: string): string[] | null {
  if (entry.includes('\\') || entry.startsWith('/')) return null;
  const segs = entry.split('/').filter((s, i, arr) => !(s === '' && i === arr.length - 1));
  if (segs.length === 0) return null;
  // eslint-disable-next-line no-control-regex -- portable paths must reject control characters
  for (const s of segs) if (s === '' || s === '.' || s === '..' || /[<>:"|?*\x00-\x1f]/.test(s) || /[. ]$/.test(s) || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(s)) return null;
  return segs;
}

/**
 * 解压到 destDir（整体替换：先写临时目录再 rename）。根须有 SKILL.md；若 zip 只有一个顶层目录且其下有 SKILL.md 则剥前缀。
 * 只写普通文件，目录按需创建；条目数与总大小封顶。
 */
export async function extractSkillPackage(zipBytes: Uint8Array, destDir: string, options: { signal?: AbortSignal; maxBytes?: number } = {}): Promise<number> {
  // Feed bounded compressed chunks so even dishonest ZIP size headers cannot allocate an unbounded output buffer.
  const files: Record<string, Uint8Array> = Object.create(null) as Record<string, Uint8Array>;
  const namesSeen = new Set<string>();
  let expanded = 0;
  const maxBytes = options.maxBytes ?? MAX_EXTRACTED_BYTES;
  const archive = new Unzip((file) => {
    const key = file.name.toLowerCase();
    if (!safeZipSegments(file.name) || namesSeen.has(key) || namesSeen.size >= MAX_ENTRIES) throw new SkillPackageError('unsafe path or duplicate package entry');
    namesSeen.add(key);
    if (file.originalSize !== undefined && file.originalSize > maxBytes) throw new SkillPackageError('package expands beyond limit');
    const chunks: Uint8Array[] = []; let bytes = 0;
    file.ondata = (error, data, final) => {
      if (error) throw new SkillPackageError('invalid compressed package');
      options.signal?.throwIfAborted();
      expanded += data.length; bytes += data.length;
      if (expanded > maxBytes) throw new SkillPackageError('package expands beyond limit');
      chunks.push(data);
      if (final) files[file.name] = Buffer.concat(chunks, bytes);
    };
    file.start();
  });
  archive.register(UnzipInflate);
  for (let offset = 0; offset < zipBytes.length; offset += 1024) {
    options.signal?.throwIfAborted();
    archive.push(zipBytes.subarray(offset, offset + 1024), offset + 1024 >= zipBytes.length);
    if (offset % (128 * 1024) === 0) await setImmediate();
  }
  if (namesSeen.size !== Object.keys(files).length) throw new SkillPackageError('incomplete package');
  const names = Object.keys(files);
  if (names.length > MAX_ENTRIES) throw new SkillPackageError(`too many entries in package (${names.length})`);
  const entries: Array<{ segs: string[]; data: Uint8Array }> = [];
  let total = 0;
  for (const name of names) {
    if (name.endsWith('/')) continue; // 目录条目
    const segs = safeZipSegments(name);
    if (!segs) throw new SkillPackageError(`unsafe path in package: ${name.slice(0, 80)}`);
    const data = files[name] as Uint8Array;
    total += data.byteLength;
    if (total > MAX_EXTRACTED_BYTES) throw new SkillPackageError('package expands beyond limit');
    entries.push({ segs, data });
  }
  let strip = 0;
  if (!entries.some((e) => e.segs.length === 1 && e.segs[0] === 'SKILL.md')) {
    const tops = new Set(entries.map((e) => e.segs[0] as string));
    const [only] = tops;
    if (tops.size === 1 && only && entries.some((e) => e.segs.length === 2 && e.segs[1] === 'SKILL.md')) strip = 1;
    else throw new SkillPackageError('package has no SKILL.md at its root');
  }
  const tmp = `${destDir}.${randomBytes(4).toString('hex')}.tmp`;
  await rm(tmp, { recursive: true, force: true });
  await mkdir(tmp, { recursive: true });
  for (const e of entries) {
    const rel = e.segs.slice(strip);
    if (rel.length === 0) continue;
    const target = join(tmp, ...rel);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, e.data);
  }
  await rm(destDir, { recursive: true, force: true });
  await mkdir(dirname(destDir), { recursive: true });
  await rename(tmp, destDir);
  return total;
}

// ---------------------------------------------------------------------------------------------
// 会话落盘

export interface SkillCarrierOptions {
  /** 会话技能根：<cache>/skills */
  sessionsDir: string;
  packages: SkillPackages;
  logger: SkillsLogger;
}

export class SkillCarrier {
  constructor(private readonly opts: SkillCarrierOptions) {}

  sessionDir(sessionId: string): string {
    return join(this.opts.sessionsDir, sessionId);
  }

  skillDir(sessionId: string, code: string): string {
    return join(this.sessionDir(sessionId), code);
  }

  async prepareSession(sessionId: string): Promise<string> {
    const dir = this.sessionDir(sessionId);
    await mkdir(dir, { recursive: true });
    return dir;
  }

  /** 落盘一个技能；失败返回 false（已记日志），不抛。 */
  async materialize(sessionId: string, skill: AgentSkill): Promise<boolean> {
    try {
      const zipPath = await this.opts.packages.ensure(skill);
      const { readFile } = await import('node:fs/promises');
      const bytes = new Uint8Array(await readFile(zipPath));
      await extractSkillPackage(bytes, this.skillDir(sessionId, skill.code));
      return true;
    } catch (err) {
      this.opts.logger.warn(
        { session_id: sessionId, skill_id: skill.skill_id, code: skill.code, version: skill.version, detail: err instanceof Error ? err.message : String(err) },
        'skill package not materialized (skipped)',
      );
      return false;
    }
  }

  /** 整套落盘（create / resync / rehydrate）：并发有限，单个失败跳过。返回落盘成功数。 */
  async materializeAll(sessionId: string, skills: Iterable<AgentSkill>, concurrency = 3): Promise<number> {
    const list = [...skills];
    let ok = 0;
    let i = 0;
    const worker = async () => {
      for (;;) {
        const idx = i++;
        const s = list[idx];
        if (!s) return;
        if (await this.materialize(sessionId, s)) ok += 1;
      }
    };
    await Promise.all(Array.from({ length: Math.min(concurrency, list.length) }, worker));
    return ok;
  }

  async remove(sessionId: string, code: string): Promise<void> {
    await rm(this.skillDir(sessionId, code), { recursive: true, force: true }).catch(() => undefined);
  }

  /** resync：清掉不在新快照里的目录后整套落盘。 */
  async replaceAll(sessionId: string, skills: Iterable<AgentSkill>): Promise<number> {
    const keep = new Set([...skills].map((s) => s.code));
    const { readdir } = await import('node:fs/promises');
    const dir = await this.prepareSession(sessionId);
    for (const name of await readdir(dir).catch(() => [] as string[])) if (!keep.has(name)) await this.remove(sessionId, name);
    return this.materializeAll(sessionId, skills);
  }

  async removeSession(sessionId: string): Promise<void> {
    await rm(this.sessionDir(sessionId), { recursive: true, force: true }).catch(() => undefined);
  }

  /** `skill_packages_cached`：本地已有包的 `skill_id@version` */
  cachedList(skills: Iterable<AgentSkill>): string[] {
    return [...skills].filter((s) => this.opts.packages.isCached(s.package_sha256)).map((s) => `${s.skill_id}@${s.version}`);
  }
}
