/**
 * 每会话 cgroup v2 硬闸（沙箱加固方案 §3 B）。
 *
 * 为什么需要：dsh 是**共享运行时**，替换 OpenClaw（每人一个 pod）本身就是一次隔离降级。
 * `process-limits.ts` 的看门狗是 2 秒采样的**软闸**——它能事后杀，但拦不住"一个会话在采样间隔里
 * 把内存吃爆 → 触发容器级 cgroup OOM → 内核按 oom_score 选中 shim 主进程 → 容器重启 → 全员断"。
 * 这条**不需要任何恶意**，正常大任务就会撞上。本模块把 RSS / 进程数 / CPU 交给内核硬限，
 * OOM 只落在越界的那个会话里，其余会话与 shim 不受影响。
 *
 * 与看门狗的分工（**看门狗保持不变，不要改它的采样方式**）：
 * - cgroup = 硬闸，内核实时执行，越界即杀且只杀该会话；
 * - 看门狗 = 软闸 + 可解释性，仍负责 CPU 累计秒数、磁盘配额，以及在没有 cgroup 委派的环境下兜底。
 * - 进程被内核 OOM 掉时，`memory.events.oom_kill` 会 +1 —— 池据此把"神秘崩溃"归因成 rss 超限，
 *   给用户一个能读懂的错误而不是 died。
 *
 * 部署前提（**实测配方见方案 §3.2，两个坑不查文档想不到**）：容器要 `--systemd=always`
 * （否则 cgroupfs 是 ro，root 都写不了）；容器根 cgroup 必须先腾空到 `init/` 才能写
 * `cgroup.subtree_control`（cgroup v2「无内部进程」约束，否则 I/O error 且子 cgroup 里
 * 连 `memory.max` 文件都不生成）；委派给 shim 运行用户时除了 chown 子树，还要
 * `chown <user> /sys/fs/cgroup/cgroup.procs`（迁移进程要求对共同祖先有写权限）。
 *
 * **fail-open**：探测不过只记 warn 并禁用，不阻止启动 —— macOS 开发机、未委派的部署仍要能跑，
 * 那些环境退回看门狗软闸。这与读隔离（fail-closed）刻意不同：读隔离防的是跨租户数据泄露，
 * 这里防的是资源踩踏，降级可观测即可。
 */
import { mkdir, readFile, rm, rmdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import type { PoolLogger } from './process-pool.js';

/** cpu.max 的调度周期（μs），与内核缺省一致 */
const CPU_PERIOD_US = 100_000;

export interface CgroupLimits {
  /** memory.max（MB）；0 = 不限 */
  maxRssMb: number;
  /** pids.max；0 = 不限 */
  maxProcesses: number;
  /** cpu.max 配额，占单核百分比（100 = 一个核）；0 = 不限 */
  cpuPercent: number;
}

export interface CgroupOptions {
  /** 委派给本进程的 cgroup 子树，如 /sys/fs/cgroup/agents；不存在则尝试创建 */
  root: string;
  logger: PoolLogger;
}

/**
 * 会话 id → 目录名：只允许 `[A-Za-z0-9_-]`，杜绝路径穿越。
 * **点号也一并剔除**（`..` 就是穿越本身）；会话 id 形如 `ses_xxx`，正常路径不会被改写。
 */
export function cgroupDirName(sessionId: string): string {
  const safe = sessionId.replace(/[^A-Za-z0-9_-]/g, '_').slice(0, 120);
  return `sess-${safe}`;
}

export class SessionCgroups {
  private constructor(
    private readonly root: string | undefined,
    private readonly log: PoolLogger,
    readonly detail: string,
  ) {}

  /**
   * 探测委派是否真的可用。**光看目录能不能建没用**——控制器没在父级 `subtree_control` 里打开时，
   * 子 cgroup 建得出来但里面根本没有 `memory.max` 文件（表现成 ENOENT，极易误判成权限问题）。
   * 所以探针建一个真子目录，检查 `memory.max` / `pids.max` 是否存在且可写。
   */
  static async init(opts: CgroupOptions): Promise<SessionCgroups> {
    const probe = join(opts.root, `probe-${randomBytes(4).toString('hex')}`);
    try {
      await mkdir(opts.root, { recursive: true });
      await mkdir(probe, { recursive: false });
      try {
        await writeFile(join(probe, 'memory.max'), 'max', 'utf8');
        await writeFile(join(probe, 'pids.max'), 'max', 'utf8');
      } finally {
        await removeCgroupDir(probe);
      }
      opts.logger.info({ root: opts.root }, 'per-session cgroups armed (memory/pids/cpu enforced by the kernel, not by the watchdog)');
      return new SessionCgroups(opts.root, opts.logger, 'armed');
    } catch (err) {
      await removeCgroupDir(probe);
      const detail = err instanceof Error ? err.message : String(err);
      opts.logger.warn(
        { root: opts.root, detail },
        'per-session cgroups UNAVAILABLE — falling back to the sampling watchdog (soft limits only). A single session can still trip the container-level OOM killer. See docs/plans/dsh-sandbox-hardening-implementation.md §3.2',
      );
      return new SessionCgroups(undefined, opts.logger, detail);
    }
  }

  /** 显式关闭（开发/排障）：不建任何 cgroup，全部退回看门狗。 */
  static disabled(logger: PoolLogger): SessionCgroups {
    return new SessionCgroups(undefined, logger, 'disabled');
  }

  get available(): boolean {
    return this.root !== undefined;
  }

  /** 建该会话的 cgroup 并写入限额；不可用或全部限额为 0 时返回 undefined（调用方据此跳过挂载）。 */
  async create(sessionId: string, limits: CgroupLimits): Promise<string | undefined> {
    if (this.root === undefined) return undefined;
    const dir = join(this.root, cgroupDirName(sessionId));
    try {
      await mkdir(dir, { recursive: true });
      // 单项写失败（控制器没开）只记一次 warn，不让整个会话起不来——有一项是一项。
      await this.write(dir, 'memory.max', limits.maxRssMb > 0 ? String(limits.maxRssMb * 1024 * 1024) : 'max');
      // swap 一起封死，否则限了内存却在 swap 上继续膨胀，把节点拖垮
      await this.write(dir, 'memory.swap.max', '0');
      await this.write(dir, 'pids.max', limits.maxProcesses > 0 ? String(limits.maxProcesses) : 'max');
      await this.write(dir, 'cpu.max', limits.cpuPercent > 0 ? `${Math.max(1000, Math.round((limits.cpuPercent / 100) * CPU_PERIOD_US))} ${CPU_PERIOD_US}` : 'max');
      return dir;
    } catch (err) {
      this.log.warn({ session_id: sessionId, dir, detail: err instanceof Error ? err.message : String(err) }, 'failed to create session cgroup; this session runs under the watchdog only');
      return undefined;
    }
  }

  /**
   * 把 argv 包进"先把自己挂进 cgroup 再 exec"的前置。
   *
   * **必须包在 Landlock 启动器之外**：`SYSTEM_READ_ONLY` 里 `/sys/fs/cgroup` 是**只读**授权，
   * 在受限进程里写 `cgroup.procs` 会被 Landlock 拒掉。`exec` 保持 pid 不变，
   * 因此 `ps` 看门狗按装配路径定位根进程的逻辑不受影响。
   */
  static attachPrelude(argv: string[], dir: string): string[] {
    return ['/bin/sh', '-c', `echo $$ > '${dir.replace(/'/g, `'\\''`)}/cgroup.procs'; exec "$@"`, 'dsh-cgroup', ...argv];
  }

  /** 该会话是否被内核 OOM 杀过（memory.events 的 oom_kill 计数）。读不到按 0。 */
  async oomKills(sessionId: string): Promise<number> {
    if (this.root === undefined) return 0;
    try {
      const text = await readFile(join(this.root, cgroupDirName(sessionId), 'memory.events'), 'utf8');
      const m = /^oom_kill\s+(\d+)$/m.exec(text);
      return m ? Number(m[1]) : 0;
    } catch {
      return 0;
    }
  }

  /** 回收该会话的 cgroup（幂等）。进程还没死透时 rmdir 会 EBUSY，留给下次 create 复用即可。 */
  async destroy(sessionId: string): Promise<void> {
    if (this.root === undefined) return;
    await removeCgroupDir(join(this.root, cgroupDirName(sessionId)));
  }

  private async write(dir: string, file: string, value: string): Promise<void> {
    try {
      await writeFile(join(dir, file), value, 'utf8');
    } catch (err) {
      this.log.warn({ dir, file, value, detail: err instanceof Error ? err.message : String(err) }, 'cgroup knob not writable (controller not delegated?); that limit is NOT enforced');
    }
  }
}

/**
 * 回收一个 cgroup 目录。真实 cgroupfs 上 knob 文件不可 unlink，**`rmdir` 才是正解**；
 * 递归删除只作为单测 tmpdir（里面是真文件）的兜底。两者都失败就算了——进程可能还没死透（EBUSY），
 * 留着下次 create 复用即可。
 */
async function removeCgroupDir(dir: string): Promise<void> {
  try {
    await rmdir(dir);
  } catch {
    await rm(dir, { recursive: true, force: true }).catch(() => undefined);
  }
}
