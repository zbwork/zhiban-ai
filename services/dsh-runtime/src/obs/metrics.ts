/**
 * 运行时自身的指标出口（Prometheus 文本格式，零依赖）——P2「观测对齐 F24」的运行时侧。
 *
 * 分工：F24 的 run/step（per 租户/员工/会话的耗时、工具、token）由 Bus 从 SSE 事件流观察并落库；
 * 本服务只暴露**进程池与链路健康**的聚合指标，**不带租户/员工/会话标签**（基数 + 隐私，F24 O3）。
 * per-message 的归因字段走结构化日志（server/chat.ts「message stream finished」）。
 */

const DURATION_BUCKETS = [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600];

type Labels = Record<string, string>;

function labelKey(labels: Labels): string {
  const keys = Object.keys(labels).sort();
  if (keys.length === 0) return '';
  return '{' + keys.map((k) => `${k}="${escapeLabel(labels[k] ?? '')}"`).join(',') + '}';
}

function escapeLabel(v: string): string {
  return v.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
}

function fmt(n: number): string {
  return String(n);
}

class Counter {
  private readonly series = new Map<string, number>();
  constructor(readonly name: string, readonly help: string) {}
  inc(labels: Labels = {}, by = 1): void {
    const k = labelKey(labels);
    this.series.set(k, (this.series.get(k) ?? 0) + by);
  }
  render(out: string[]): void {
    out.push(`# HELP ${this.name} ${this.help}`, `# TYPE ${this.name} counter`);
    if (this.series.size === 0) out.push(`${this.name} 0`);
    for (const [k, v] of this.series) out.push(`${this.name}${k} ${fmt(v)}`);
  }
}

class Histogram {
  private readonly counts: number[];
  private sum = 0;
  private count = 0;
  constructor(readonly name: string, readonly help: string, private readonly buckets: number[] = DURATION_BUCKETS) {
    this.counts = buckets.map(() => 0);
  }
  observe(v: number): void {
    if (!Number.isFinite(v) || v < 0) return;
    this.sum += v;
    this.count += 1;
    for (let i = 0; i < this.buckets.length; i += 1) if (v <= (this.buckets[i] as number)) this.counts[i] = (this.counts[i] as number) + 1;
  }
  render(out: string[]): void {
    out.push(`# HELP ${this.name} ${this.help}`, `# TYPE ${this.name} histogram`);
    for (let i = 0; i < this.buckets.length; i += 1) out.push(`${this.name}_bucket{le="${this.buckets[i]}"} ${this.counts[i]}`);
    out.push(`${this.name}_bucket{le="+Inf"} ${this.count}`, `${this.name}_sum ${fmt(this.sum)}`, `${this.name}_count ${this.count}`);
  }
}

export interface PoolGauges {
  live: number;
  busy: number;
  max: number;
  queued: number;
}

export interface MessageObservation {
  outcome: 'completed' | 'failed' | 'cancelled' | 'unknown';
  errorCode?: string;
  ttftMs?: number;
  totalMs: number;
  toolCalls: number;
  toolErrors: number;
  inputTokens?: number;
  outputTokens?: number;
}

/** 池侧观察口（process-pool 只依赖这个窄接口）。 */
export interface PoolMetrics {
  observeSpawn(ok: boolean, ms: number): void;
  observeReap(reason: string): void;
  observeQueueWait(ms: number): void;
  observeQueueReject(reason: string): void;
  /** 资源看门狗自身故障（采样失败等）——闸失效必须可见 */
  observeWatchdogError?(kind: string): void;
}

export class RuntimeMetrics implements PoolMetrics {
  private readonly spawns = new Counter('dsh_runtime_spawns_total', 'agent process spawn attempts by result');
  private readonly spawnSeconds = new Histogram('dsh_runtime_spawn_duration_seconds', 'spawn + initialize handshake duration');
  private readonly reaps = new Counter('dsh_runtime_reaps_total', 'agent processes reaped by reason');
  private readonly queueWait = new Histogram('dsh_runtime_queue_wait_seconds', 'time spent waiting for a process slot (admitted only)');
  private readonly queueRejects = new Counter('dsh_runtime_queue_rejections_total', 'spawn requests rejected at capacity by reason');
  private readonly watchdogErrors = new Counter('dsh_runtime_watchdog_errors_total', 'resource watchdog failures by kind (limits not enforced that tick)');
  private readonly messages = new Counter('dsh_runtime_messages_total', 'message streams by terminal outcome');
  private readonly failures = new Counter('dsh_runtime_message_failures_total', 'failed message streams by zap error code');
  private readonly ttft = new Histogram('dsh_runtime_ttft_seconds', 'time from request accept to first text delta');
  private readonly turn = new Histogram('dsh_runtime_turn_duration_seconds', 'message stream wall time');
  private readonly tools = new Counter('dsh_runtime_tool_calls_total', 'tool invocations observed by status');
  private readonly tokens = new Counter('dsh_runtime_tokens_total', 'tokens reported by the model by kind');
  private readonly historyWrites = new Counter('dsh_runtime_history_writes_total', 'session history (PG) write batches by result');
  private readonly historyRows = new Counter('dsh_runtime_history_rows_total', 'session history (PG) event rows by result');
  private readonly skillPackages = new Counter('dsh_runtime_skill_packages_total', 'skill package resolutions by result');
  private poolSource: (() => PoolGauges) | undefined;
  private sessionsSource: (() => number) | undefined;

  bindPool(source: () => PoolGauges): void {
    this.poolSource = source;
  }

  bindSessions(source: () => number): void {
    this.sessionsSource = source;
  }

  observeSpawn(ok: boolean, ms: number): void {
    this.spawns.inc({ result: ok ? 'ok' : 'failed' });
    if (ok) this.spawnSeconds.observe(ms / 1000);
  }

  observeReap(reason: string): void {
    this.reaps.inc({ reason });
  }

  observeQueueWait(ms: number): void {
    this.queueWait.observe(ms / 1000);
  }

  observeWatchdogError(kind: string): void {
    this.watchdogErrors.inc({ kind });
  }

  observeQueueReject(reason: string): void {
    this.queueRejects.inc({ reason });
  }

  observeMessage(m: MessageObservation): void {
    this.messages.inc({ outcome: m.outcome });
    if (m.outcome === 'failed') this.failures.inc({ code: m.errorCode ?? 'unknown' });
    if (m.ttftMs !== undefined) this.ttft.observe(m.ttftMs / 1000);
    this.turn.observe(m.totalMs / 1000);
    if (m.toolCalls > 0) this.tools.inc({ status: 'succeeded' }, m.toolCalls - m.toolErrors);
    if (m.toolErrors > 0) this.tools.inc({ status: 'failed' }, m.toolErrors);
    if (m.inputTokens) this.tokens.inc({ kind: 'input' }, m.inputTokens);
    if (m.outputTokens) this.tokens.inc({ kind: 'output' }, m.outputTokens);
  }

  observeSkillPackage(result: 'cached' | 'downloaded' | 'failed'): void {
    this.skillPackages.inc({ result });
  }

  observeHistoryWrite(ok: boolean, rows: number): void {
    const result = ok ? 'ok' : 'failed';
    this.historyWrites.inc({ result });
    this.historyRows.inc({ result }, rows);
  }

  /** Prometheus 文本格式（text/plain; version=0.0.4）。 */
  render(): string {
    const out: string[] = [];
    const pool = this.poolSource?.();
    if (pool) {
      out.push('# HELP dsh_runtime_pool_processes live agent processes by state', '# TYPE dsh_runtime_pool_processes gauge');
      out.push(`dsh_runtime_pool_processes{state="busy"} ${pool.busy}`, `dsh_runtime_pool_processes{state="idle"} ${Math.max(0, pool.live - pool.busy)}`);
      out.push('# HELP dsh_runtime_pool_max_processes configured process cap', '# TYPE dsh_runtime_pool_max_processes gauge', `dsh_runtime_pool_max_processes ${pool.max}`);
      out.push('# HELP dsh_runtime_pool_queue_depth spawn requests waiting for a slot', '# TYPE dsh_runtime_pool_queue_depth gauge', `dsh_runtime_pool_queue_depth ${pool.queued}`);
    }
    const sessions = this.sessionsSource?.();
    if (sessions !== undefined) out.push('# HELP dsh_runtime_sessions live session records', '# TYPE dsh_runtime_sessions gauge', `dsh_runtime_sessions ${sessions}`);
    for (const c of [this.spawns, this.reaps, this.queueRejects, this.messages, this.failures, this.tools, this.tokens, this.historyWrites, this.historyRows, this.skillPackages]) c.render(out);
    for (const h of [this.spawnSeconds, this.queueWait, this.ttft, this.turn]) h.render(out);
    return out.join('\n') + '\n';
  }
}
