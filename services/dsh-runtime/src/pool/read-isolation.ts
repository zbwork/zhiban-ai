/**
 * 多租户读隔离（CLAUDE.md 边界 6 / ADR-0035 §4.4，P2 门禁）。
 *
 * 为什么是进程级 Landlock，而不是 ADR 原文的 bwrap 挂载视图：
 * - dsh 自己的沙箱只包**每条工具命令**（bash），而 tool-fs 的文件读取在 agent 进程**内**发生——
 *   读隔离必须套在整棵 agent 进程树上，而不是某条命令上。
 * - 容器/k8s（默认 seccomp，无 user namespace）里 bwrap 基本不可用；Landlock 是独立 syscall 族，
 *   不需要 namespace，只需宿主内核 ≥ 5.13。
 * - dsh 闭包自带官方 `@deepseek-ai/node-addon-landlock-run`：静态 C 启动器，`--ro/--rw` allow-list，
 *   对自己施加 ruleset 后 exec，整棵进程树继承；失败 exit 125 不执行命令（fail-closed）。
 *   版本随 dsh 闭包成对钉死（边界 3）。
 *
 * 授权模型（Landlock 只有 allow-list）：
 * - 只读：系统目录、本服务代码（node_modules/dist/assets）、本会话的装配目录、本员工配置目录。
 *   **不授 `/proc`**（只给 `/proc/self` 与几个只读信息文件）：同 uid 下 `/proc/<pid>/environ` 能读到
 *   其它会话的 per-account 模型凭据。**不授 `/tmp`**：跨租户共享的可写目录就是读通道；会话私有 TMPDIR。
 * - 可写：本会话工作区、按租户/账号分的 DSH_HOME 与会话持久化根、会话私有 TMPDIR、/dev/null。
 * - 租户根 `<tenantsDir>` 本身不授——兄弟租户目录既不可列也不可读（Landlock 不拦路径穿越，
 *   所以工作区自身的绝对路径仍可正常访问）。
 *
 * 门禁：启动时跑**跨租户读探针**（真实 spawn 一个受限 node，读兄弟目录必须 EACCES），
 * `required` 模式探针不过 = 进程拒绝启动。macOS 开发机无 Landlock，只能 `off`（日志 warn）。
 */
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { grantArgs, launcherPath, probe, LAUNCHER_FAILURE_EXIT } from '@deepseek-ai/node-addon-landlock-run';
import type { PoolLogger } from './process-pool.js';

export type IsolationMode = 'required' | 'off';
export type IsolationBackend = 'landlock' | 'off';
export type IsolationEnforcement = 'full' | 'partial' | 'none';

export interface SessionGrants {
  /** 本会话额外只读根（装配目录、员工配置目录）；不存在的自动剔除 */
  readOnly?: string[];
  /** 本会话可写根（工作区、DSH_HOME、会话持久化根、TMPDIR）；必须已存在 */
  readWrite: string[];
}

export interface ReadIsolationOptions {
  mode: IsolationMode;
  /** 全体会话共享的只读根；不存在的自动剔除 */
  readOnly: string[];
  /** 探针临时目录根（cacheDir 下，探针结束即删） */
  probeDir: string;
  /** 额外探针目录（多卷部署：durable 卷 + cache 卷都要过） */
  probeDirs?: string[];
  logger: PoolLogger;
  /** 测试钩子：替换启动器路径 */
  launcher?: string;
  probeTimeoutMs?: number;
}

export class ReadIsolationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ReadIsolationError';
  }
}

/** 任何平台都要给的系统只读根（按存在性过滤）。刻意不含 /proc、/tmp、/run、/var、/home、/root。 */
export const SYSTEM_READ_ONLY = [
  '/usr',
  '/lib',
  '/lib32',
  '/lib64',
  '/bin',
  '/sbin',
  '/etc',
  '/opt',
  '/dev/urandom',
  '/dev/random',
  '/dev/zero',
  '/proc/self',
  '/proc/cpuinfo',
  '/proc/meminfo',
  '/proc/stat',
  '/proc/loadavg',
  '/proc/uptime',
  '/proc/version',
  '/proc/sys/kernel',
  '/sys/devices/system/cpu',
  '/sys/fs/cgroup',
];

const ALWAYS_READ_WRITE = ['/dev/null'];

export class ReadIsolation {
  private constructor(
    private readonly launcher: string | undefined,
    readonly readOnly: readonly string[],
    readonly backend: IsolationBackend,
    readonly enforcement: IsolationEnforcement,
    private readonly log: PoolLogger,
  ) {}

  static async init(opts: ReadIsolationOptions): Promise<ReadIsolation> {
    const readOnly = dedupe(opts.readOnly.filter(existsSync));
    if (opts.mode === 'off') {
      opts.logger.warn({ platform: process.platform }, 'read isolation OFF — cross-tenant reads are NOT prevented; never run production this way');
      return new ReadIsolation(undefined, readOnly, 'off', 'none', opts.logger);
    }
    const launcher = opts.launcher ?? launcherPath();
    const verdict = probe(launcher, { timeoutMs: opts.probeTimeoutMs ?? 3000 });
    if (verdict === 'unusable') {
      throw new ReadIsolationError(
        `read isolation is required but the Landlock launcher is unusable (${launcher}): needs Linux kernel >= 5.13 with Landlock enabled and the landlock syscalls allowed by seccomp`,
      );
    }
    const iso = new ReadIsolation(launcher, readOnly, 'landlock', verdict, opts.logger);
    // 探针跑在每个真实数据卷上：durable（可能是 NFS/NAS）与 cache（本地盘）——Landlock 规则按 inode，文件系统不同结果可能不同
    for (const dir of [...new Set([opts.probeDir, ...(opts.probeDirs ?? [])])]) await iso.selfTest(dir, opts.probeTimeoutMs ?? 5000);
    opts.logger.info({ backend: 'landlock', enforcement: verdict, read_only_roots: readOnly.length }, 'read isolation armed (cross-tenant read probe passed)');
    return iso;
  }

  status(): { mode: IsolationMode; backend: IsolationBackend; enforcement: IsolationEnforcement } {
    return { mode: this.launcher ? 'required' : 'off', backend: this.backend, enforcement: this.enforcement };
  }

  /** 把要 spawn 的 argv 包进启动器；`off` 原样返回。 */
  confine(argv: string[], grants: SessionGrants): string[] {
    if (!this.launcher) return argv;
    const readOnly = dedupe([...this.readOnly, ...(grants.readOnly ?? []).filter(existsSync)]);
    const readWrite = dedupe([...grants.readWrite, ...ALWAYS_READ_WRITE]);
    return [this.launcher, ...grantArgs({ readOnly, readWrite }), '--', ...argv];
  }

  /**
   * 跨租户读探针：建 `<probeDir>/<rand>/{mine,other}`，以 mine 为工作区 spawn 一个受限 node，
   * 断言：读/写 mine 成功；读 other 文件、列 other 目录、列父目录、写 other、读 /proc/<ppid>/environ 全部 EACCES。
   * 任何一条不成立 → 抛错（门禁）。
   */
  async selfTest(probeDir: string, timeoutMs: number): Promise<void> {
    if (!this.launcher) return;
    const root = join(probeDir, `probe-${randomBytes(4).toString('hex')}`);
    const mine = join(root, 'tenant-a', 'user-1');
    const other = join(root, 'tenant-b', 'user-2');
    try {
      await mkdir(mine, { recursive: true });
      await mkdir(other, { recursive: true });
      await writeFile(join(mine, 'secret.txt'), 'mine', 'utf8');
      await writeFile(join(other, 'secret.txt'), 'theirs', 'utf8');
      const argv = this.confine([process.execPath, '-e', PROBE_SCRIPT], { readWrite: [mine] });
      const result = await run(argv, { PROBE_MINE: mine, PROBE_OTHER: other, PROBE_PARENT: root, PATH: process.env.PATH ?? '' }, timeoutMs);
      if (result.code === LAUNCHER_FAILURE_EXIT && /landlock-run/.test(result.stderr)) {
        throw new ReadIsolationError(`Landlock launcher refused to run the probe: ${firstLine(result.stderr)}`);
      }
      if (result.code !== 0) {
        throw new ReadIsolationError(`cross-tenant read probe FAILED (exit ${result.code}): ${firstLine(result.stdout || result.stderr)}`);
      }
    } finally {
      await rm(root, { recursive: true, force: true }).catch(() => undefined);
    }
  }
}

const PROBE_SCRIPT = `
const fs = require('node:fs');
const mine = process.env.PROBE_MINE, other = process.env.PROBE_OTHER, parent = process.env.PROBE_PARENT;
const failures = [];
const expect = (name, fn, wantDenied) => {
  try { fn(); if (wantDenied) failures.push(name + ': unexpectedly ALLOWED'); }
  catch (e) { if (!wantDenied) failures.push(name + ': failed ' + (e && e.code)); else if (e.code !== 'EACCES' && e.code !== 'EPERM') failures.push(name + ': denied with ' + e.code + ' (expected EACCES)'); }
};
expect('read own file', () => fs.readFileSync(mine + '/secret.txt', 'utf8'), false);
expect('write own file', () => fs.writeFileSync(mine + '/out.txt', 'x'), false);
expect('list own dir', () => fs.readdirSync(mine), false);
expect('read sibling tenant file', () => fs.readFileSync(other + '/secret.txt', 'utf8'), true);
expect('list sibling tenant dir', () => fs.readdirSync(other), true);
expect('list tenants root', () => fs.readdirSync(parent), true);
expect('write sibling tenant', () => fs.writeFileSync(other + '/evil.txt', 'x'), true);
expect('read parent process environ', () => fs.readFileSync('/proc/' + process.ppid + '/environ'), true);
if (failures.length) { console.log(failures.join('; ')); process.exit(1); }
console.log('ok');
`;

function run(argv: string[], env: NodeJS.ProcessEnv, timeoutMs: number): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const [cmd, ...args] = argv as [string, ...string[]];
    const child = spawn(cmd, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d: Buffer) => (stdout += d.toString()));
    child.stderr.on('data', (d: Buffer) => (stderr += d.toString()));
    const timer = setTimeout(() => child.kill('SIGKILL'), timeoutMs);
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
}

function dedupe(list: string[]): string[] {
  return [...new Set(list)];
}

function firstLine(s: string): string {
  return s.split('\n').find((l) => l.trim() !== '')?.trim().slice(0, 300) ?? '';
}
