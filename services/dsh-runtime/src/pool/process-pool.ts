/**
 * 进程池：key = session_id，每会话一个 jsonrpc-agent 子进程（ADR-0035 决策 3）。
 *
 * 生命周期：首条消息 spawn → initialize(cwd=租户工作区, provider, model 定死) → 多轮 prompt 续接
 *           → 空闲超时回收 / 取消=杀进程 / 异常退出收割 → 下条消息重建。
 * 只经官方 @deepseek-ai/dsh-sdk-client 驱动（边界 2）；wire 无 cancel，杀进程即取消（边界 5）。
 */
import { mkdir, rm } from 'node:fs/promises';
import { dirname } from 'node:path';
import { HarnessClient, TransportClosedError } from '@deepseek-ai/dsh-sdk-client';
import type { ContentBlock, HarnessNotification, NotificationSubscription } from '@deepseek-ai/dsh-sdk-client';
import type { PoolMetrics } from '../obs/metrics.js';
import type { DshEvent } from '../translate/dsh-events.js';
import { buildChildEnv } from './child-env.js';
import { dirSizeKb, freeSpaceMb, limitsPrelude, quotaRoots, sampleProcessTrees, type ProcessLimits } from './process-limits.js';
import { SessionCgroups } from './cgroup.js';
import type { SessionGrants } from './read-isolation.js';

export interface PoolLogger {
  info(obj: Record<string, unknown>, msg: string): void;
  warn(obj: Record<string, unknown>, msg: string): void;
  error(obj: Record<string, unknown>, msg: string): void;
}

export interface PoolOptions {
  agentBin: string;
  idleTimeoutMs: number;
  maxProcesses: number;
  spawnTimeoutMs: number;
  /**
   * 满员且无可驱逐进程时允许排队等待的请求数上限（FIFO）。0 = 不排队，立即 CapacityError（P1 行为）。
   * 队列之外的请求立即拒绝 = 背压信号，Bus 侧落 `zap.capacity_exhausted`。
   */
  maxQueue?: number;
  /** 排队等待名额的上限（ms），超时按 CapacityError(queue_timeout) 拒绝 */
  queueTimeoutMs?: number;
  /** 子进程 DSH_HOME 缺省值（spec.dshHome 未给时用；生产按租户/账号分目录见 SpawnSpec） */
  dshHome: string;
  logger: PoolLogger;
  metrics?: PoolMetrics;
  /**
   * 读隔离：把要 spawn 的 argv 包进 Landlock 启动器（见 read-isolation.ts）。
   * 未提供 = 不隔离（仅测试/macOS 开发）。
   */
  confine?: (argv: string[], grants: SessionGrants) => string[];
  /**
   * 按租户 / 按用户 的并发进程上限（0 = 不限）。超限的请求只能排队或驱逐**自己**的空闲进程，不能挤占别人；
   * 队列按全局 FIFO 放行但跳过被自身配额卡住的等待者（不产生队头阻塞）。
   */
  maxPerTenant?: number;
  maxPerUser?: number;
  /** 单个用户最多占用的队列名额（0 = 不限）；防止一个用户把整条队列灌满 */
  maxQueuePerUser?: number;
  /** 每进程资源上限 + 工作区配额（见 process-limits.ts）；未提供 = 不限（仅测试/开发） */
  limits?: ProcessLimits;
  /**
   * 每会话 cgroup 硬闸（见 cgroup.ts）。与 `limits` 的看门狗是**互补**关系不是替代：
   * cgroup 由内核实时执行、越界只杀该会话；看门狗仍管 CPU 累计秒数与磁盘配额，并在没有
   * cgroup 委派的环境下兜底。未提供 = 只有看门狗。
   */
  cgroups?: SessionCgroups;
  /** cgroup cpu.max 配额（占单核百分比，100=一个核；0=不限）。看门狗的 cpuSeconds 是累计量，二者语义不同。 */
  cpuPercent?: number;
  /** 测试注入：替换进程树采样（默认一次 ps） */
  sampler?: typeof sampleProcessTrees;
  /** 测试注入：替换数据卷剩余空间查询（默认 statfs） */
  diskFree?: (path: string) => number;
  parentEnv?: NodeJS.ProcessEnv;
  /** 测试注入：替换 HarnessClient 构造 */
  clientFactory?: (opts: ConstructorParameters<typeof HarnessClient>[0]) => HarnessClient;
}

export interface SpawnSpec {
  /** 池内 key = ZAP session_id */
  sessionId: string;
  /**
   * 南侧 wire 上用的会话 id。**每次 spawn 必须换新值**（建议 `<session_id>--g<代数>`）：
   * 持久化层拒绝在新进程里 create 一个磁盘上已有日志的 id（"refusing to materialize … load/resume it instead"），
   * 而 jsonrpc 服务端只会 create 不会 resume。上下文连续性由调用方在新进程首轮注入 transcript 兜底。
   */
  wireSessionId: string;
  /** 渲染好的 per-agent 装配文件 */
  cordisPath: string;
  /** 进程 cwd（shim 自己的目录；禁止是租户工作区，见 child-env.ts） */
  processCwd: string;
  /** initialize.cwd：租户工作区 */
  workspace: string;
  provider: string;
  model: string;
  /**
   * 员工配置版本指纹（登记 revision）。同一会话再次 ensure 时若与在跑进程的指纹不同（员工换了模型/模型服务/人设），
   * 且进程空闲，则先杀掉再按新配置 spawn——否则"换模型下个会话生效"会变成同一会话里怎么重试都用旧模型
   * （2026-09-08 测试机实测：进程被每次重试续命，10 分钟空闲回收永远到不了）。缺省不比较。
   */
  configRevision?: string;
  /** 观测标签（conversation_uuid / tenant / user / agent_key），只进日志 */
  labels: Record<string, string>;
  /** 配额归属（租户 / 用户）；缺省取 labels.tenant_id / labels.user_id */
  tenant?: string;
  user?: string;
  /** 租户合计配额的计量根（<tenants>/<tenant> + <cache>/dsh-home/<tenant> + <sessions>/<tenant>）；缺省不做租户级检查 */
  tenantRoots?: string[];
  /** 会话级 env 注入（白名单校验见 child-env.ts） */
  env?: Record<string, string>;
  /** 本会话的 DSH_HOME（按租户/账号分目录：`.credentials.yaml` 等状态不得跨租户共享）；缺省用池级 */
  dshHome?: string;
  /**
   * 会话私有 TMPDIR（读隔离下不授 /tmp——跨租户共享的可写目录就是读通道）。放在工作区内（<workspace>/.tmp/<sid>）
   * 才同时满足 dsh 内层沙箱"只许写工作区"（Chrome/bun/mktemp 都要写临时目录）。池负责创建并在进程回收时删除。
   */
  tmpDir?: string;
  /** 子进程 HOME（<workspace>/.home，内层沙箱可写；缺省 = dshHome） */
  homeDir?: string;
  /** 额外只读根（本员工配置目录等；装配目录由池自动加入） */
  readOnly?: string[];
  /** 额外可写根（按租户/账号分的会话持久化根等）；池负责创建 */
  readWrite?: string[];
}

export type TurnOutcome =
  | { kind: 'completed'; turn: number | undefined }
  | { kind: 'timeout' }
  | { kind: 'aborted' }
  | { kind: 'died'; detail: string; reason?: string };

export class RuntimeStartError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RuntimeStartError';
  }
}

export type CapacityReason = 'no_slot' | 'queue_full' | 'queue_timeout' | 'aborted' | 'shutdown' | 'tenant_limit' | 'user_limit' | 'user_queue_full';

export class CapacityError extends Error {
  constructor(
    readonly reason: CapacityReason,
    readonly waitedMs = 0,
  ) {
    super(`process pool at capacity (${reason})`);
    this.name = 'CapacityError';
  }
}

interface SlotWaiter {
  sessionId: string;
  spec: SpawnSpec;
  enqueuedAt: number;
  resolve: (admit: Promise<void>) => void;
  reject: (err: CapacityError) => void;
  timer: NodeJS.Timeout | undefined;
  signal: AbortSignal | undefined;
  onAbort: (() => void) | undefined;
}

type ProcState = 'starting' | 'idle' | 'busy' | 'dead';

export class SessionProcess {
  state: ProcState = 'starting';
  readonly startedAt = Date.now();
  lastActiveAt = Date.now();
  turns = 0;
  /** 拿到名额前在队列里等了多久（直接拿到 = 0） */
  queuedMs = 0;
  /** spawn + initialize 握手耗时 */
  spawnMs = 0;
  /** 被池杀掉的原因（看门狗 / 驱逐 / 超时…）；runTurn 借此把 died 翻成可解释的错误 */
  killReason: string | undefined;
  /** 最近一次工作区配额采样时间 */
  lastDiskCheckAt = 0;
  private idleTimer: NodeJS.Timeout | undefined;
  private liveness: NotificationSubscription | undefined;

  constructor(
    readonly spec: SpawnSpec,
    private readonly client: HarnessClient,
    private readonly pool: ProcessPool,
  ) {}

  get sessionId(): string {
    return this.spec.sessionId;
  }

  /** @internal */
  async boot(spawnTimeoutMs: number): Promise<void> {
    this.client.start();
    // filter=false 的订阅永远收不到通知；只在进程死亡时 reject——用作存活探针。
    this.liveness = this.client.subscribe(() => false);
    void this.liveness.next().catch((err: unknown) => this.pool.onProcessExit(this, err));
    let timer: NodeJS.Timeout | undefined;
    try {
      await Promise.race([
        this.client.initialize({ cwd: this.spec.workspace, provider: this.spec.provider, model: this.spec.model }),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new RuntimeStartError(`initialize timed out after ${spawnTimeoutMs}ms`)), spawnTimeoutMs);
        }),
      ]);
    } finally {
      if (timer) clearTimeout(timer);
    }
    this.state = 'idle';
    this.armIdleTimer();
  }

  /**
   * 跑一轮：订阅 → prompt → 消费 session.event 直到本轮 turn/end。
   * 超时/中止 = 杀进程（wire 无 cancel）；进程中途死亡 → died。
   */
  async runTurn(
    blocks: ContentBlock[],
    onEvent: (ev: DshEvent) => void,
    opts: { timeoutMs: number; signal?: AbortSignal },
  ): Promise<TurnOutcome> {
    if (this.state !== 'idle') throw new Error(`session process is ${this.state}`);
    this.state = 'busy';
    this.disarmIdleTimer();
    const sid = this.spec.wireSessionId;
    const sub = this.client.subscribe(
      (n: HarnessNotification) => (n.method === 'session.event' || n.method === 'session.status') && n.params['sessionId'] === sid,
    );
    let timer: NodeJS.Timeout | undefined;
    let onAbort: (() => void) | undefined;
    const interrupted = new Promise<'timeout' | 'aborted'>((resolve) => {
      timer = setTimeout(() => resolve('timeout'), opts.timeoutMs);
      if (opts.signal) {
        if (opts.signal.aborted) resolve('aborted');
        onAbort = () => resolve('aborted');
        opts.signal.addEventListener('abort', onAbort, { once: true });
      }
    });
    let sawTurnStart = false;
    try {
      await this.client.prompt(sid, blocks);
      for (;;) {
        const next = await Promise.race([sub.next().then((n) => ({ n })), interrupted.then((why) => ({ why }))]);
        if ('why' in next) {
          await this.pool.kill(this.spec.sessionId, next.why === 'timeout' ? 'turn_timeout' : 'client_abort');
          return { kind: next.why };
        }
        const { n } = next;
        if (n.method === 'session.status') {
          if (n.params['status'] === 'idle' && sawTurnStart) return this.finishTurn(undefined);
          continue;
        }
        const ev = n.params['event'] as DshEvent | undefined;
        if (!ev || typeof ev.type !== 'string') continue;
        if (ev.type === 'turn/start') sawTurnStart = true;
        onEvent(ev);
        if (ev.type === 'turn/end') {
          const turn = ev.data && typeof ev.data['turn'] === 'number' ? (ev.data['turn'] as number) : undefined;
          return this.finishTurn(turn);
        }
      }
    } catch (err) {
      if (err instanceof TransportClosedError || (this.state as ProcState) === 'dead') {
        this.state = 'dead';
        return { kind: 'died', detail: err instanceof Error ? err.message : String(err), ...(this.killReason ? { reason: this.killReason } : {}) };
      }
      throw err;
    } finally {
      if (timer) clearTimeout(timer);
      if (onAbort && opts.signal) opts.signal.removeEventListener('abort', onAbort);
      sub.close();
    }
  }

  private finishTurn(turn: number | undefined): TurnOutcome {
    this.turns += 1;
    this.lastActiveAt = Date.now();
    if (this.state !== 'dead') {
      this.state = 'idle';
      this.armIdleTimer();
      this.pool.onProcessIdle();
    }
    return { kind: 'completed', turn };
  }

  /** @internal */
  armIdleTimer(): void {
    this.disarmIdleTimer();
    const ms = this.pool.idleTimeoutMs;
    if (ms <= 0) return;
    this.idleTimer = setTimeout(() => void this.pool.kill(this.spec.sessionId, 'idle_timeout'), ms);
    this.idleTimer.unref();
  }

  /** @internal */
  disarmIdleTimer(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = undefined;
  }

  /** @internal 走官方 close 梯子（shutdown → EOF → SIGTERM → SIGKILL），保证收割无僵尸。 */
  async terminate(): Promise<void> {
    this.state = 'dead';
    this.disarmIdleTimer();
    this.liveness?.close();
    await this.client.close();
  }
}

export class ProcessPool {
  private readonly procs = new Map<string, SessionProcess>();
  private readonly starting = new Map<string, Promise<SessionProcess>>();
  /** 已预留但尚未登记进 procs 的名额（spawn 进行中）；容量 = procs.size + reserved */
  private reserved = 0;
  private readonly queue: SlotWaiter[] = [];
  /** 已预留但尚未登记的名额按配额键计数（与 reserved 同步增减） */
  private readonly reservedByScope = new Map<string, number>();
  private closed = false;
  /** 租户用量缓存（du 一个租户目录可能很慢；按租户 30s 复用） */
  private readonly tenantUsage = new Map<string, { usedMb: number; at: number }>();
  private watchdog: NodeJS.Timeout | undefined;
  private watchdogBusy = false;
  readonly idleTimeoutMs: number;
  readonly maxQueue: number;
  readonly queueTimeoutMs: number;
  readonly maxPerTenant: number;
  readonly maxPerUser: number;
  readonly maxQueuePerUser: number;
  readonly limits: ProcessLimits | undefined;

  constructor(private readonly opts: PoolOptions) {
    this.idleTimeoutMs = opts.idleTimeoutMs;
    this.maxQueue = Math.max(0, opts.maxQueue ?? 0);
    this.queueTimeoutMs = Math.max(0, opts.queueTimeoutMs ?? 0);
    this.maxPerTenant = Math.max(0, opts.maxPerTenant ?? 0);
    this.maxPerUser = Math.max(0, opts.maxPerUser ?? 0);
    this.maxQueuePerUser = Math.max(0, opts.maxQueuePerUser ?? 0);
    this.limits = opts.limits;
    if (this.limits && (this.limits.maxRssMb > 0 || this.limits.cpuSeconds > 0 || this.limits.maxProcesses > 0 || this.limits.workspaceQuotaMb > 0)) {
      this.watchdog = setInterval(() => void this.watchdogTick(), Math.max(200, this.limits.checkIntervalMs));
      this.watchdog.unref();
    }
  }

  /** 配额键：租户 / 用户（缺省取 labels） */
  static scopeKeys(spec: SpawnSpec): { tenant: string; user: string } {
    const tenant = spec.tenant ?? spec.labels['tenant_id'] ?? '';
    const user = spec.user ?? spec.labels['user_id'] ?? '';
    return { tenant: `t:${tenant}`, user: `u:${tenant}/${user}` };
  }

  /** 某配额键下的占用 = 存活进程 + 预留中 */
  private scopeLoad(key: string): number {
    let n = this.reservedByScope.get(key) ?? 0;
    for (const p of this.procs.values()) {
      const k = ProcessPool.scopeKeys(p.spec);
      if (k.tenant === key || k.user === key) n += 1;
    }
    return n;
  }

  private bumpScope(spec: SpawnSpec, delta: number): void {
    for (const key of Object.values(ProcessPool.scopeKeys(spec))) {
      const next = (this.reservedByScope.get(key) ?? 0) + delta;
      if (next <= 0) this.reservedByScope.delete(key);
      else this.reservedByScope.set(key, next);
    }
  }

  /** 用户可写根合计是否已超软配额（chat 在 spawn 前调；无配额 → false）。roots 用 quotaRoots() 同口径。 */
  async workspaceOverQuota(roots: string | string[]): Promise<{ over: boolean; usedMb: number; quotaMb: number }> {
    const quotaMb = this.limits?.workspaceQuotaMb ?? 0;
    if (quotaMb <= 0) return { over: false, usedMb: 0, quotaMb: 0 };
    const usedMb = Math.round((await dirSizeKb(roots)) / 1024);
    return { over: usedMb > quotaMb, usedMb, quotaMb };
  }

  /** 租户合计是否已超软配额（30s 缓存；无配额 → false） */
  async tenantOverQuota(tenantKey: string, roots: string[], opts: { force?: boolean } = {}): Promise<{ over: boolean; usedMb: number; quotaMb: number }> {
    const quotaMb = this.limits?.tenantQuotaMb ?? 0;
    if (quotaMb <= 0 || roots.length === 0) return { over: false, usedMb: 0, quotaMb: 0 };
    const now = Date.now();
    const cached = this.tenantUsage.get(tenantKey);
    let usedMb: number;
    if (cached && !opts.force && now - cached.at < 30_000) usedMb = cached.usedMb;
    else {
      usedMb = Math.round((await dirSizeKb(roots)) / 1024);
      this.tenantUsage.set(tenantKey, { usedMb, at: now });
    }
    return { over: usedMb > quotaMb, usedMb, quotaMb };
  }

  /** 数据卷剩余空间是否低于下限（无下限 → false） */
  diskFull(path: string): { full: boolean; freeMb: number; minFreeMb: number } {
    const minFreeMb = this.limits?.minFreeMb ?? 0;
    if (minFreeMb <= 0) return { full: false, freeMb: Number.POSITIVE_INFINITY, minFreeMb: 0 };
    const freeMb = (this.opts.diskFree ?? freeSpaceMb)(path);
    return { full: freeMb < minFreeMb, freeMb, minFreeMb };
  }

  /** 池级缺省 DSH_HOME（chat 算配额根时要和池内口径一致） */
  get defaultDshHome(): string {
    return this.opts.dshHome;
  }

  /** 看门狗：一次 ps 采样所有存活进程树的 RSS / CPU；忙进程再按节流查工作区配额。超限 → kill（reason 可解释）。 */
  private async watchdogTick(): Promise<void> {
    if (this.watchdogBusy || this.closed || !this.limits || this.procs.size === 0) return;
    this.watchdogBusy = true;
    try {
      const byCordis = new Map<string, SessionProcess>();
      for (const p of this.procs.values()) byCordis.set(p.spec.cordisPath, p);
      const sampler = this.opts.sampler ?? sampleProcessTrees;
      let samples: Awaited<ReturnType<typeof sampleProcessTrees>>;
      try {
        samples = await sampler([...byCordis.keys()]);
      } catch (err) {
        // 采样坏了 = 闸暂时失效，必须可见（日志 + 指标），不能静默放行
        this.opts.metrics?.observeWatchdogError?.('sample_failed');
        this.opts.logger.warn({ detail: err instanceof Error ? err.message : String(err), live: this.procs.size }, 'resource watchdog sample failed; limits not enforced this tick');
        samples = new Map();
      }
      for (const [cordisPath, sample] of samples) {
        const p = byCordis.get(cordisPath);
        if (!p || p.state === 'dead') continue;
        if (this.limits.maxProcesses > 0 && sample.processes > this.limits.maxProcesses) {
          this.opts.logger.warn({ ...p.spec.labels, session_id: p.sessionId, processes: sample.processes, limit: this.limits.maxProcesses }, 'agent process tree over process-count limit');
          await this.kill(p.sessionId, 'proc_limit');
          continue;
        }
        const rssMb = Math.round(sample.rssKb / 1024);
        if (this.limits.maxRssMb > 0 && rssMb > this.limits.maxRssMb) {
          this.opts.logger.warn({ ...p.spec.labels, session_id: p.sessionId, rss_mb: rssMb, limit_mb: this.limits.maxRssMb, processes: sample.processes }, 'agent process tree over memory limit');
          await this.kill(p.sessionId, 'rss_limit');
          continue;
        }
        if (this.limits.cpuSeconds > 0 && sample.cpuSeconds > this.limits.cpuSeconds) {
          this.opts.logger.warn({ ...p.spec.labels, session_id: p.sessionId, cpu_seconds: Math.round(sample.cpuSeconds), limit_seconds: this.limits.cpuSeconds }, 'agent process tree over cpu limit');
          await this.kill(p.sessionId, 'cpu_limit');
          continue;
        }
      }
      if (this.limits.workspaceQuotaMb > 0) {
        const now = Date.now();
        for (const p of [...this.procs.values()]) {
          if (p.state !== 'busy' || now - p.lastDiskCheckAt < Math.max(this.limits.checkIntervalMs, 5_000)) continue;
          p.lastDiskCheckAt = now;
          const usedMb = Math.round((await dirSizeKb(quotaRoots(p.spec, this.opts.dshHome))) / 1024);
          if (usedMb > this.limits.workspaceQuotaMb && this.procs.get(p.sessionId) === p) {
            this.opts.logger.warn({ ...p.spec.labels, session_id: p.sessionId, used_mb: usedMb, quota_mb: this.limits.workspaceQuotaMb }, 'workspace over disk quota');
            await this.kill(p.sessionId, 'disk_quota');
            continue;
          }
          if (p.spec.tenantRoots && p.spec.tenantRoots.length > 0) {
            const tq = await this.tenantOverQuota(ProcessPool.scopeKeys(p.spec).tenant, p.spec.tenantRoots, { force: true });
            if (tq.over && this.procs.get(p.sessionId) === p) {
              this.opts.logger.warn({ ...p.spec.labels, session_id: p.sessionId, tenant_used_mb: tq.usedMb, tenant_quota_mb: tq.quotaMb }, 'tenant over disk quota');
              await this.kill(p.sessionId, 'disk_quota');
            }
          }
        }
      }
    } finally {
      this.watchdogBusy = false;
    }
  }

  get(sessionId: string): SessionProcess | undefined {
    const p = this.procs.get(sessionId);
    return p && p.state !== 'dead' ? p : undefined;
  }

  stats(): { live: number; busy: number; max: number; queued: number; max_per_tenant: number; max_per_user: number } {
    let busy = 0;
    for (const p of this.procs.values()) if (p.state === 'busy') busy += 1;
    return { live: this.procs.size, busy, max: this.opts.maxProcesses, queued: this.queue.length, max_per_tenant: this.maxPerTenant, max_per_user: this.maxPerUser };
  }

  /**
   * 已有存活进程直接复用；否则 spawn。
   * 容量满时先驱逐最久空闲（且已服务过至少一轮）的进程；仍无位则按 FIFO 排队（maxQueue>0），
   * 队满 / 等待超时 / 调用方 signal 中止 → CapacityError(reason)。
   */
  async ensure(spec: SpawnSpec, opts: { signal?: AbortSignal } = {}): Promise<SessionProcess> {
    const existing = this.get(spec.sessionId);
    if (existing) {
      const stale = spec.model !== existing.spec.model || spec.provider !== existing.spec.provider || (spec.configRevision !== undefined && existing.spec.configRevision !== undefined && existing.spec.configRevision !== spec.configRevision);
      // 忙碌中的进程不打断（本轮仍按旧配置跑完），下一次 ensure 再换。
      if (!stale || existing.state === 'busy') return existing;
      this.opts.logger.info({ ...spec.labels, session_id: spec.sessionId, from: existing.spec.configRevision, to: spec.configRevision }, 'agent config revision changed; respawning session process');
      await this.kill(spec.sessionId, 'config_revision_changed');
    }
    const pending = this.starting.get(spec.sessionId);
    if (pending) return pending;
    const task = this.spawn(spec, opts.signal).finally(() => this.starting.delete(spec.sessionId));
    this.starting.set(spec.sessionId, task);
    return task;
  }

  /**
   * 同步预留一个名额。顺序：用户配额 → 租户配额 → 全局容量。
   * 配额超限时只能驱逐**同一配额范围内**最久空闲（已服务过一轮）的进程，不能挤占别人；
   * 全局满员时驱逐全局最久空闲进程。都不行返回 null + 原因（调用方据此排队或拒绝）。
   */
  private tryReserve(spec: SpawnSpec): { admit: Promise<void> | null; reason: CapacityReason } {
    const keys = ProcessPool.scopeKeys(spec);
    const scoped: Array<{ key: string; max: number; reason: CapacityReason }> = [
      { key: keys.user, max: this.maxPerUser, reason: 'user_limit' },
      { key: keys.tenant, max: this.maxPerTenant, reason: 'tenant_limit' },
    ];
    let victim: SessionProcess | undefined;
    for (const sc of scoped) {
      if (sc.max <= 0 || this.scopeLoad(sc.key) < sc.max) continue;
      const own = this.leastRecentlyUsedIdle((p) => {
        const k = ProcessPool.scopeKeys(p.spec);
        return k.user === sc.key || k.tenant === sc.key;
      });
      if (!own) return { admit: null, reason: sc.reason };
      victim = own; // 驱逐自己的空闲进程腾出配额（同时也腾出全局名额）
    }
    if (!victim && this.procs.size + this.reserved >= this.opts.maxProcesses) {
      victim = this.leastRecentlyUsedIdle();
      if (!victim) return { admit: null, reason: 'no_slot' };
    }
    this.reserved += 1;
    this.bumpScope(spec, 1);
    if (!victim) return { admit: Promise.resolve(), reason: 'no_slot' };
    return { admit: this.kill(victim.sessionId, 'evicted_for_capacity').then(() => undefined), reason: 'no_slot' };
  }

  /** 拿名额：队列为空且能立即预留 → 直接；否则入队（FIFO），由 drainQueue 按序放行（跳过被自身配额卡住者）。 */
  private acquireSlot(spec: SpawnSpec, signal: AbortSignal | undefined): Promise<void> {
    if (this.closed) return Promise.reject(new CapacityError('shutdown'));
    let blockedBy: CapacityReason = 'no_slot';
    if (this.queue.length === 0) {
      const r = this.tryReserve(spec);
      if (r.admit) return r.admit;
      blockedBy = r.reason;
    }
    const keys = ProcessPool.scopeKeys(spec);
    const userQueued = this.queue.filter((w) => ProcessPool.scopeKeys(w.spec).user === keys.user).length;
    const rejectReason: CapacityReason | undefined =
      this.maxQueue <= 0 ? (blockedBy === 'no_slot' ? 'no_slot' : blockedBy)
      : this.queue.length >= this.maxQueue ? 'queue_full'
      : this.maxQueuePerUser > 0 && userQueued >= this.maxQueuePerUser ? 'user_queue_full'
      : undefined;
    if (rejectReason) {
      this.opts.metrics?.observeQueueReject(rejectReason);
      this.opts.logger.warn({ ...spec.labels, session_id: spec.sessionId, reason: rejectReason, ...this.stats() }, 'agent pool rejected spawn');
      return Promise.reject(new CapacityError(rejectReason));
    }
    if (signal?.aborted) return Promise.reject(new CapacityError('aborted'));
    return new Promise<void>((resolve, reject) => {
      const w: SlotWaiter = { sessionId: spec.sessionId, spec, enqueuedAt: Date.now(), resolve, reject, timer: undefined, signal, onAbort: undefined };
      const fail = (reason: CapacityReason) => {
        if (!this.dequeue(w)) return;
        this.opts.metrics?.observeQueueReject(reason);
        this.opts.logger.warn({ ...spec.labels, session_id: spec.sessionId, reason, waited_ms: Date.now() - w.enqueuedAt, ...this.stats() }, 'agent spawn left queue');
        reject(new CapacityError(reason, Date.now() - w.enqueuedAt));
      };
      if (this.queueTimeoutMs > 0) {
        w.timer = setTimeout(() => fail('queue_timeout'), this.queueTimeoutMs);
        w.timer.unref();
      }
      if (signal) {
        w.onAbort = () => fail('aborted');
        signal.addEventListener('abort', w.onAbort, { once: true });
      }
      this.queue.push(w);
      this.opts.logger.info({ ...spec.labels, session_id: spec.sessionId, blocked_by: blockedBy, ...this.stats() }, 'agent spawn queued');
    });
  }

  /** 从队列摘除并清理定时器/监听；已不在队列返回 false（已被放行或已拒绝）。 */
  private dequeue(w: SlotWaiter): boolean {
    const i = this.queue.indexOf(w);
    if (i < 0) return false;
    this.queue.splice(i, 1);
    if (w.timer) clearTimeout(w.timer);
    if (w.signal && w.onAbort) w.signal.removeEventListener('abort', w.onAbort);
    return true;
  }

  /**
   * 名额可能空出来了（kill / 崩溃 / 进程变空闲 / spawn 失败）：按 FIFO 扫描等待者，能拿到名额的放行；
   * 被自身租户/用户配额卡住的跳过（后面的人不被它挡住）；全局没位了就停。
   */
  private drainQueue(): void {
    for (const w of [...this.queue]) {
      if (this.queue.indexOf(w) < 0) continue;
      const r = this.tryReserve(w.spec);
      if (!r.admit) {
        if (r.reason === 'no_slot') return;
        continue; // 自己的配额卡住，让后面的人先走
      }
      this.dequeue(w);
      const waited = Date.now() - w.enqueuedAt;
      this.opts.metrics?.observeQueueWait(waited);
      w.resolve(r.admit.then(() => undefined));
    }
  }

  private async spawn(spec: SpawnSpec, signal: AbortSignal | undefined): Promise<SessionProcess> {
    const tq = Date.now();
    await this.acquireSlot(spec, signal);
    const queuedMs = Date.now() - tq;
    let proc: SessionProcess | undefined;
    try {
      const dshHome = spec.dshHome ?? this.opts.dshHome;
      const readWrite = [spec.workspace, dshHome, ...(spec.tmpDir ? [spec.tmpDir] : []), ...(spec.homeDir ? [spec.homeDir] : []), ...(spec.readWrite ?? [])];
      for (const dir of readWrite) await mkdir(dir, { recursive: true });
      const env = buildChildEnv({
        parent: this.opts.parentEnv ?? process.env,
        dshHome,
        ...(spec.homeDir ? { home: spec.homeDir } : {}),
        extra: { ...(spec.tmpDir ? { TMPDIR: spec.tmpDir } : {}), ...spec.env },
      });
      // 资源上限 prelude 在最内层（Landlock 里执行 /bin/sh，再 exec 成 agent；pid 不变，ps 里按装配路径可定位）
      const argv = this.limits ? limitsPrelude([process.execPath, this.opts.agentBin, spec.cordisPath], this.limits) : [process.execPath, this.opts.agentBin, spec.cordisPath];
      const confined = this.opts.confine
        ? this.opts.confine(argv, { readOnly: [dirname(spec.cordisPath), ...(spec.readOnly ?? [])], readWrite })
        : argv;
      // cgroup 挂载前置**包在 Landlock 之外**：SYSTEM_READ_ONLY 里 /sys/fs/cgroup 是只读授权，
      // 在受限进程里写 cgroup.procs 会被 Landlock 拒掉。exec 保持 pid 不变，ps 看门狗定位不受影响。
      const cgroupDir = this.opts.cgroups
        ? await this.opts.cgroups.create(spec.sessionId, {
            maxRssMb: this.limits?.maxRssMb ?? 0,
            maxProcesses: this.limits?.maxProcesses ?? 0,
            cpuPercent: this.opts.cpuPercent ?? 0,
          })
        : undefined;
      const [command, ...args] = (cgroupDir ? SessionCgroups.attachPrelude(confined, cgroupDir) : confined) as [string, ...string[]];
      const clientOpts: ConstructorParameters<typeof HarnessClient>[0] = {
        command,
        args,
        cwd: spec.processCwd,
        env,
        shutdownTimeoutMs: 500,
        disposeEofGraceMs: 500,
        disposeGraceMs: 1500,
      };
      const client = this.opts.clientFactory ? this.opts.clientFactory(clientOpts) : new HarnessClient(clientOpts);
      proc = new SessionProcess(spec, client, this);
      proc.queuedMs = queuedMs;
      this.procs.set(spec.sessionId, proc);
    } finally {
      // 名额从「预留」转为「在 procs 里」；没走到登记就失败 → 名额空出，放行队列。
      this.reserved -= 1;
      this.bumpScope(spec, -1);
      if (!proc) this.drainQueue();
    }
    const t0 = Date.now();
    try {
      await proc.boot(this.opts.spawnTimeoutMs);
    } catch (err) {
      this.procs.delete(spec.sessionId);
      await proc.terminate().catch(() => undefined);
      const detail = err instanceof Error ? err.message : String(err);
      this.opts.metrics?.observeSpawn(false, Date.now() - t0);
      this.opts.logger.error({ ...spec.labels, session_id: spec.sessionId, detail }, 'agent process failed to start');
      this.drainQueue();
      throw new RuntimeStartError(detail);
    }
    proc.spawnMs = Date.now() - t0;
    this.opts.metrics?.observeSpawn(true, proc.spawnMs);
    this.opts.logger.info(
      { ...spec.labels, session_id: spec.sessionId, model: spec.model, spawn_ms: proc.spawnMs, queued_ms: queuedMs, live: this.procs.size, queued: this.queue.length },
      'agent process spawned',
    );
    return proc;
  }

  /** 杀进程 = 取消 / 回收。幂等。 */
  async kill(sessionId: string, reason: string): Promise<boolean> {
    const proc = this.procs.get(sessionId);
    if (!proc) return false;
    proc.killReason = reason;
    this.procs.delete(sessionId);
    const t0 = Date.now();
    await proc.terminate().catch((err: unknown) =>
      this.opts.logger.warn({ session_id: sessionId, detail: String(err) }, 'agent process close reported error'),
    );
    if (proc.spec.tmpDir) await rm(proc.spec.tmpDir, { recursive: true, force: true }).catch(() => undefined);
    await this.opts.cgroups?.destroy(sessionId);
    this.opts.metrics?.observeReap(reason);
    this.opts.logger.info(
      { ...proc.spec.labels, session_id: sessionId, reason, turns: proc.turns, uptime_ms: t0 - proc.startedAt, close_ms: Date.now() - t0, live: this.procs.size },
      'agent process reaped',
    );
    this.drainQueue();
    return true;
  }

  /** @internal 进程完成一轮变空闲 → 成为驱逐候选，可能放行排队者。 */
  onProcessIdle(): void {
    this.drainQueue();
  }

  /** @internal 存活探针触发：进程自己死了（崩溃/被 OOM 杀）。 */
  onProcessExit(proc: SessionProcess, err: unknown): void {
    if (this.procs.get(proc.sessionId) !== proc) return; // 已由 kill 处理
    const wasBusy = proc.state === 'busy';
    proc.state = 'dead';
    this.procs.delete(proc.sessionId);
    proc.disarmIdleTimer();
    this.opts.metrics?.observeReap('crashed');
    this.opts.logger.warn(
      { ...proc.spec.labels, session_id: proc.sessionId, was_busy: wasBusy, detail: err instanceof Error ? err.message : String(err) },
      'agent process exited unexpectedly',
    );
    // 被内核按 cgroup 内存上限杀掉时给出可读归因（否则用户只看到"进程莫名死了"）。
    // 异步查、不挡回收路径；查完顺手回收 cgroup 目录。
    void (async () => {
      const oom = (await this.opts.cgroups?.oomKills(proc.sessionId)) ?? 0;
      if (oom > 0) {
        proc.killReason = 'rss_limit';
        this.opts.logger.warn(
          { ...proc.spec.labels, session_id: proc.sessionId, oom_kills: oom, limit_mb: this.limits?.maxRssMb ?? 0 },
          'agent process was OOM-killed inside its own cgroup (blast radius contained to this session)',
        );
      }
      await this.opts.cgroups?.destroy(proc.sessionId);
    })();
    this.drainQueue();
  }

  async shutdown(): Promise<void> {
    this.closed = true;
    if (this.watchdog) clearInterval(this.watchdog);
    for (const w of [...this.queue]) {
      this.dequeue(w);
      w.reject(new CapacityError('shutdown', Date.now() - w.enqueuedAt));
    }
    await Promise.all([...this.procs.keys()].map((sid) => this.kill(sid, 'pool_shutdown')));
  }

  /**
   * 驱逐候选 = 空闲且**已服务过至少一轮**的进程里最久未活动者。
   * 刚拉起、尚未跑首轮的进程不算：否则过载时排队者会在拿到进程后、首轮开始前被下一个排队者踢掉。
   */
  private leastRecentlyUsedIdle(filter?: (p: SessionProcess) => boolean): SessionProcess | undefined {
    let best: SessionProcess | undefined;
    for (const p of this.procs.values()) {
      if (p.state !== 'idle' || p.turns === 0) continue;
      if (filter && !filter(p)) continue;
      if (!best || p.lastActiveAt < best.lastActiveAt) best = p;
    }
    return best;
  }
}
