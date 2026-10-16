/**
 * 员工配置库（P1：文件系统）。一个数字员工 = 一份 agent.yml + skills/ 目录，不创建任何常驻进程。
 * 布局：<agentsConfigDir>/<agent_key>/agent.yml
 *
 * agent_key 由 Bus 托管生成并随请求下发（ZAP-1.1 §2.1a），本库只校验、不生成、原样回显。
 */
import { randomBytes } from 'node:crypto';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { mkdir, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { parse as parseYaml, stringify as toYaml } from 'yaml';
import { zapErrors } from '../server/errors.js';

export interface AgentModel {
  primary?: string;
  fallbacks?: string[];
  temperature?: number;
  context_window?: number;
}

export interface AgentRecord {
  agent_key: string;
  name: string;
  system_prompt: string;
  model?: AgentModel;
  tools?: unknown;
  ui_components?: string[];
  interaction_modes?: Record<string, boolean>;
  limits?: Record<string, number>;
  metadata?: Record<string, unknown>;
  created_at: string;
  updated_at: string;
  /** 每次写入 +1；assemble 用它判断缓存是否过期 */
  revision: number;
}

/** POST /agents 入参（字段子集，见 ZAP-1.1 §2.1） */
export type AgentCreateInput = Pick<AgentRecord, 'agent_key'> & Partial<AgentPatch>;
/** PATCH /agents/{key} 入参（§2.2：字段子集，拒绝未知字段） */
export type AgentPatch = Pick<
  AgentRecord,
  'name' | 'system_prompt' | 'model' | 'tools' | 'ui_components' | 'interaction_modes' | 'limits' | 'metadata'
>;

export const PATCHABLE_FIELDS: ReadonlySet<string> = new Set([
  'name',
  'system_prompt',
  'model',
  'tools',
  'ui_components',
  'interaction_modes',
  'limits',
  'metadata',
]);

const AGENT_KEY_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;

export function validateAgentKey(key: unknown): string {
  if (typeof key !== 'string' || !AGENT_KEY_RE.test(key) || key.includes('..')) {
    throw zapErrors.invalidRequest('agent_key must match ^[a-z0-9][a-z0-9._-]{0,63}$');
  }
  return key;
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** 只接受 §2.2 允许的字段；类型粗校验，未知字段 fail-closed。 */
export function validatePatch(raw: unknown, { allowAgentKey }: { allowAgentKey?: string } = {}): Partial<AgentPatch> {
  if (!isPlainObject(raw)) throw zapErrors.invalidRequest('body must be a JSON object');
  const out: Partial<AgentPatch> = {};
  for (const [k, v] of Object.entries(raw)) {
    if (k === 'agent_key') {
      if (allowAgentKey !== undefined && v !== allowAgentKey) throw zapErrors.invalidRequest('agent_key cannot be changed');
      continue;
    }
    if (!PATCHABLE_FIELDS.has(k)) throw zapErrors.invalidRequest(`unknown field: ${k}`);
    if (v === undefined || v === null) continue;
    switch (k) {
      case 'name':
      case 'system_prompt':
        if (typeof v !== 'string') throw zapErrors.invalidRequest(`${k} must be a string`);
        out[k] = v;
        break;
      case 'model':
        if (!isPlainObject(v)) throw zapErrors.invalidRequest('model must be an object');
        if (v.primary !== undefined && typeof v.primary !== 'string') throw zapErrors.invalidRequest('model.primary must be a string');
        if (v.fallbacks !== undefined && !(Array.isArray(v.fallbacks) && v.fallbacks.every((x) => typeof x === 'string')))
          throw zapErrors.invalidRequest('model.fallbacks must be string[]');
        out.model = v as AgentModel;
        break;
      case 'ui_components':
        if (!(Array.isArray(v) && v.every((x) => typeof x === 'string'))) throw zapErrors.invalidRequest('ui_components must be string[]');
        out.ui_components = v as string[];
        break;
      case 'interaction_modes':
      case 'limits':
      case 'metadata':
        if (!isPlainObject(v)) throw zapErrors.invalidRequest(`${k} must be an object`);
        out[k] = v as never;
        break;
      case 'tools':
        out.tools = v;
        break;
    }
  }
  return out;
}

export type AgentChangeListener = (agentKey: string, kind: 'upsert' | 'delete') => void;

export class AgentStore {
  private readonly agents = new Map<string, AgentRecord>();
  /** agent.yml mtime（读穿透用；与 agents 同步增删） */
  private readonly mtimes = new Map<string, number>();
  private readonly listeners = new Set<AgentChangeListener>();
  private loaded = false;

  constructor(readonly rootDir: string) {}

  agentDir(agentKey: string): string {
    return resolve(this.rootDir, validateAgentKey(agentKey));
  }

  skillsDir(agentKey: string): string {
    return join(this.agentDir(agentKey), 'skills');
  }

  private filePath(agentKey: string): string {
    return join(this.agentDir(agentKey), 'agent.yml');
  }

  onChange(listener: AgentChangeListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** 启动时扫描磁盘重建索引；坏文件跳过并返回其 key 供日志告警。 */
  async load(): Promise<{ loaded: number; skipped: string[] }> {
    await mkdir(this.rootDir, { recursive: true });
    const skipped: string[] = [];
    this.agents.clear();
    for (const entry of await readdir(this.rootDir, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      try {
        const raw = parseYaml(await readFile(join(this.rootDir, entry.name, 'agent.yml'), 'utf8')) as unknown;
        const rec = normalizeRecord(raw);
        if (rec.agent_key !== entry.name) throw new Error('agent_key/dir mismatch');
        this.agents.set(rec.agent_key, rec);
        this.mtimes.set(rec.agent_key, statSync(join(this.rootDir, entry.name, 'agent.yml')).mtimeMs);
      } catch {
        skipped.push(entry.name);
      }
    }
    this.loaded = true;
    return { loaded: this.agents.size, skipped };
  }

  /**
   * 多副本（共享 durable 卷）读穿透：内存只是缓存，磁盘是权威。
   * 另一副本 POST/PATCH/DELETE 过的员工，本副本按 agent.yml 的 mtime 发现变化即重读；文件没了即从缓存摘除。
   * 每次 get 一次 stat（本地盘/NAS 都是微秒~毫秒级），比 watcher 可靠（NFS 上 inotify 不工作）。
   */
  private refresh(agentKey: string): AgentRecord | undefined {
    let key: string;
    try {
      key = validateAgentKey(agentKey);
    } catch {
      return undefined;
    }
    const file = join(this.rootDir, key, 'agent.yml');
    let mtimeMs: number;
    try {
      mtimeMs = statSync(file).mtimeMs;
    } catch {
      if (this.agents.delete(key)) this.mtimes.delete(key);
      return undefined;
    }
    const cached = this.agents.get(key);
    if (cached && this.mtimes.get(key) === mtimeMs) return cached;
    try {
      const rec = normalizeRecord(parseYaml(readFileSync(file, 'utf8')) as unknown);
      if (rec.agent_key !== key) return cached;
      this.agents.set(key, rec);
      this.mtimes.set(key, mtimeMs);
      return rec;
    } catch {
      return cached; // 半写入/坏文件：沿用旧缓存，下次 mtime 变了再读
    }
  }

  list(): AgentRecord[] {
    let names: string[] = [];
    try {
      names = readdirSync(this.rootDir, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
    } catch {
      names = [...this.agents.keys()];
    }
    const out: AgentRecord[] = [];
    for (const name of new Set([...names, ...this.agents.keys()])) {
      const rec = this.refresh(name);
      if (rec) out.push(rec);
    }
    return out.sort((a, b) => a.agent_key.localeCompare(b.agent_key));
  }

  get(agentKey: string): AgentRecord | undefined {
    return this.refresh(agentKey);
  }

  has(agentKey: string): boolean {
    return this.refresh(agentKey) !== undefined;
  }

  async create(input: AgentCreateInput): Promise<AgentRecord> {
    this.assertLoaded();
    const key = validateAgentKey(input.agent_key);
    if (this.refresh(key)) throw zapErrors.agentKeyExists(key);
    const now = new Date().toISOString();
    const rec: AgentRecord = {
      agent_key: key,
      name: input.name ?? key,
      system_prompt: input.system_prompt ?? '',
      ...pickDefined(input, ['model', 'tools', 'ui_components', 'interaction_modes', 'limits', 'metadata']),
      created_at: now,
      updated_at: now,
      revision: 1,
    };
    await this.persist(rec);
    return rec;
  }

  async update(agentKey: string, patch: Partial<AgentPatch>): Promise<AgentRecord> {
    this.assertLoaded();
    const key = validateAgentKey(agentKey);
    const prev = this.refresh(key);
    if (!prev) throw zapErrors.agentKeyNotFound(key);
    const rec: AgentRecord = {
      ...prev,
      ...pickDefined(patch, ['name', 'system_prompt', 'model', 'tools', 'ui_components', 'interaction_modes', 'limits', 'metadata']),
      updated_at: new Date().toISOString(),
      revision: prev.revision + 1,
    };
    await this.persist(rec);
    return rec;
  }

  /** 幂等：不存在返回 false。 */
  async delete(agentKey: string): Promise<boolean> {
    this.assertLoaded();
    const key = validateAgentKey(agentKey);
    const existed = this.refresh(key) !== undefined;
    this.agents.delete(key);
    this.mtimes.delete(key);
    await rm(this.agentDir(key), { recursive: true, force: true });
    if (existed) this.emit(key, 'delete');
    return existed;
  }

  private async persist(rec: AgentRecord): Promise<void> {
    const dir = this.agentDir(rec.agent_key);
    await mkdir(join(dir, 'skills'), { recursive: true });
    const tmp = join(dir, `agent.yml.${process.pid}.${randomBytes(4).toString('hex')}.tmp`);
    await writeFile(tmp, toYaml(rec), 'utf8');
    await rename(tmp, this.filePath(rec.agent_key));
    this.agents.set(rec.agent_key, rec);
    try {
      this.mtimes.set(rec.agent_key, statSync(this.filePath(rec.agent_key)).mtimeMs);
    } catch {
      this.mtimes.delete(rec.agent_key);
    }
    this.emit(rec.agent_key, 'upsert');
  }

  private emit(key: string, kind: 'upsert' | 'delete'): void {
    for (const l of this.listeners) l(key, kind);
  }

  private assertLoaded(): void {
    if (!this.loaded) throw new Error('AgentStore.load() must be awaited before writes');
  }
}

function pickDefined<T extends object, K extends keyof T>(src: T, keys: readonly K[]): Partial<Pick<T, K>> {
  const out: Partial<Pick<T, K>> = {};
  for (const k of keys) if (src[k] !== undefined) out[k] = src[k];
  return out;
}

function normalizeRecord(raw: unknown): AgentRecord {
  if (!isPlainObject(raw)) throw new Error('agent.yml is not a mapping');
  const key = validateAgentKey(raw.agent_key);
  const { created_at: _c, updated_at: _u, revision: _r, ...fields } = raw;
  const patch = validatePatch(fields, { allowAgentKey: key });
  return {
    agent_key: key,
    name: typeof raw.name === 'string' ? raw.name : key,
    system_prompt: typeof raw.system_prompt === 'string' ? raw.system_prompt : '',
    ...pickDefined(patch, ['model', 'tools', 'ui_components', 'interaction_modes', 'limits', 'metadata']),
    created_at: typeof raw.created_at === 'string' ? raw.created_at : new Date(0).toISOString(),
    updated_at: typeof raw.updated_at === 'string' ? raw.updated_at : new Date(0).toISOString(),
    revision: typeof raw.revision === 'number' ? raw.revision : 1,
  };
}
