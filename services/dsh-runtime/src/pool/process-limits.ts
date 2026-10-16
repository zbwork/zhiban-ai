/**
 * 每进程资源上限（ADR-0035 §6.3 资源隔离）：
 *
 * - **启动 prelude**（`/bin/sh -c 'ulimit …; exec "$@"'`）给整棵 agent 进程树设 RLIMIT_CPU / RLIMIT_NOFILE 兜底。
 *   只用单位无歧义的两项（秒 / 个数）；RLIMIT_AS 会打断 node/chromium 的虚拟地址预留、RLIMIT_FSIZE 各 sh 的块单位不一致，不用。
 * - **shim 侧看门狗**（pool 定时调 `sampleProcessTrees`）：按会话装配路径在 `ps` 输出里找到 agent 根进程及其子孙，
 *   累计 RSS / CPU 时间；超 `maxRssMb` / `cpuSeconds` 由池杀进程（reason=rss_limit / cpu_limit，对用户有明确错误）。
 *   同 uid 下没有 cgroup 委派时这是最可移植的内存闸（macOS/Linux 同一套代码）。
 * - **工作区磁盘软配额**：`du -sk <tenant>/<user>`，超 `workspaceQuotaMb` → 本轮杀进程 + 后续消息在 spawn 前拒绝
 *   （reason=disk_quota / zap.workspace_quota_exceeded），直到用户清理 outbox/。
 *
 * 不在这里做：cgroup（容器需委派）、网络限速（出口代理层）、按租户独立 uid（F11 专属池 / CAP_SETUID 方案）。
 */
import { execFile } from 'node:child_process';
import { statfsSync } from 'node:fs';

export interface ProcessLimits {
  /** 进程树累计 CPU 秒上限；0 = 不限 */
  cpuSeconds: number;
  /** 每进程打开文件数上限（RLIMIT_NOFILE）；0 = 不设 */
  nofile: number;
  /** 进程树 RSS 上限（MB）；0 = 不限 */
  maxRssMb: number;
  /** 进程树进程数上限（fork 炸弹 / 线程风暴）；0 = 不限 */
  maxProcesses: number;
  /** 用户可写根合计磁盘软配额（MB）；0 = 不限 */
  workspaceQuotaMb: number;
  /** 租户合计（该租户所有用户的可写根）磁盘软配额（MB）；0 = 不限。几个用户各自在配额内也打满盘的口子 */
  tenantQuotaMb: number;
  /** 数据卷剩余空间下限（MB）；低于此拒开新轮（zap.disk_full）；0 = 不查 */
  minFreeMb: number;
  /** 看门狗采样间隔（ms） */
  checkIntervalMs: number;
}

export const DEFAULT_LIMITS: ProcessLimits = { cpuSeconds: 1800, nofile: 4096, maxRssMb: 2048, maxProcesses: 64, workspaceQuotaMb: 2048, tenantQuotaMb: 20480, minFreeMb: 2048, checkIntervalMs: 2_000 };

/** 把 argv 包进 ulimit prelude（无任何上限时原样返回）。`exec "$@"` 保持 pid 不变、不多一层进程。 */
export function limitsPrelude(argv: string[], limits: Pick<ProcessLimits, 'cpuSeconds' | 'nofile'>): string[] {
  if (process.platform === 'win32') return argv; // Desktop native Job Object owns limits before resume.
  const parts: string[] = [];
  // RLIMIT_CPU 作为看门狗的兜底：设成 2 倍，正常情况下看门狗先以可解释的错误杀掉
  if (limits.cpuSeconds > 0) parts.push(`ulimit -t ${Math.max(1, Math.floor(limits.cpuSeconds * 2))} 2>/dev/null`);
  if (limits.nofile > 0) parts.push(`ulimit -n ${Math.floor(limits.nofile)} 2>/dev/null`);
  if (parts.length === 0) return argv;
  return ['/bin/sh', '-c', `${parts.join('; ')}; exec "$@"`, 'dsh-limits', ...argv];
}

export interface ProcessTreeSample {
  rootPid: number;
  processes: number;
  rssKb: number;
  cpuSeconds: number;
}

interface PsRow {
  pid: number;
  ppid: number;
  rssKb: number;
  cpuSeconds: number;
  args: string;
}

/** `ps` 一次，按 `matchArg`（每会话唯一的装配文件路径）定位各会话根进程并累计子孙。找不到的 key 不出现在结果里。 */
export async function sampleProcessTrees(matchArgs: string[], runPs: () => Promise<string> = defaultPs): Promise<Map<string, ProcessTreeSample>> {
  const out = new Map<string, ProcessTreeSample>();
  if (matchArgs.length === 0) return out;
  const rows = parsePs(await runPs());
  const children = new Map<number, PsRow[]>();
  for (const r of rows) {
    const list = children.get(r.ppid) ?? [];
    list.push(r);
    children.set(r.ppid, list);
  }
  for (const key of matchArgs) {
    // 根 = 参数里含装配路径、且父进程不含的那个（prelude sh 已 exec 成 node，所以就是 agent 进程本身）
    const candidates = rows.filter((r) => r.args.includes(key));
    if (candidates.length === 0) continue;
    const pids = new Set(candidates.map((r) => r.pid));
    const root = candidates.find((r) => !pids.has(r.ppid)) ?? candidates[0]!;
    const sample: ProcessTreeSample = { rootPid: root.pid, processes: 0, rssKb: 0, cpuSeconds: 0 };
    const stack = [root];
    const seen = new Set<number>();
    while (stack.length > 0) {
      const r = stack.pop()!;
      if (seen.has(r.pid)) continue;
      seen.add(r.pid);
      sample.processes += 1;
      sample.rssKb += r.rssKb;
      sample.cpuSeconds += r.cpuSeconds;
      for (const c of children.get(r.pid) ?? []) stack.push(c);
    }
    out.set(key, sample);
  }
  return out;
}

function defaultPs(): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile('ps', ['-axo', 'pid=,ppid=,rss=,time=,args='], { maxBuffer: 16 * 1024 * 1024 }, (err, stdout) => {
      if (err) reject(err);
      else resolve(stdout);
    });
  });
}

/** 解析 `ps -o pid=,ppid=,rss=,time=,args=`；time 形如 `mm:ss.xx` / `hh:mm:ss` / `dd-hh:mm:ss`。 */
export function parsePs(stdout: string): PsRow[] {
  const rows: PsRow[] = [];
  for (const line of stdout.split('\n')) {
    const m = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/.exec(line);
    if (!m) continue;
    rows.push({ pid: Number(m[1]), ppid: Number(m[2]), rssKb: Number(m[3]), cpuSeconds: parseCpuTime(m[4]!), args: m[5] ?? '' });
  }
  return rows;
}

export function parseCpuTime(s: string): number {
  let days = 0;
  let rest = s;
  const dm = /^(\d+)-(.*)$/.exec(rest);
  if (dm) {
    days = Number(dm[1]);
    rest = dm[2]!;
  }
  const parts = rest.split(':').map(Number);
  if (parts.some((n) => !Number.isFinite(n))) return 0;
  let secs = 0;
  for (const p of parts) secs = secs * 60 + p;
  return days * 86400 + secs;
}

/**
 * 一组目录的占用合计（KB），一次 `du -sk a b c`；不存在的目录忽略（du 对不存在项报错但仍输出其它行，exit≠0 也照样解析）。
 * 配额口径 = 该用户所有可写根：工作区（含 .tmp/.home/outbox）+ DSH_HOME + 会话持久化根——agent 进程能写到哪，配额就量到哪。
 */
export function dirSizeKb(dirs: string | string[]): Promise<number> {
  const list = [...new Set((Array.isArray(dirs) ? dirs : [dirs]).filter((d) => d && d.trim() !== ''))];
  if (list.length === 0) return Promise.resolve(0);
  return new Promise((resolve) => {
    execFile('du', ['-sk', ...list], { maxBuffer: 1024 * 1024 }, (_err, stdout) => {
      let total = 0;
      for (const line of String(stdout ?? '').split('\n')) {
        const n = Number(line.trim().split(/\s+/)[0]);
        if (Number.isFinite(n)) total += n;
      }
      resolve(total);
    });
  });
}

/** 数据卷剩余空间（MB）；路径不存在/不支持 → Infinity（不误拦） */
export function freeSpaceMb(path: string): number {
  try {
    const st = statfsSync(path);
    return Math.floor((Number(st.bavail) * Number(st.bsize)) / (1024 * 1024));
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

/** 该会话受配额约束的可写根（去重；池级缺省 DSH_HOME 也算进去——它就是进程能写的地方） */
export function quotaRoots(spec: { workspace: string; dshHome?: string; readWrite?: string[] }, defaultDshHome: string): string[] {
  return [...new Set([spec.workspace, spec.dshHome ?? defaultDshHome, ...(spec.readWrite ?? [])])];
}
