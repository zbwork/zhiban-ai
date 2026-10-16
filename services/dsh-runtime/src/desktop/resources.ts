import { execFile } from 'node:child_process';
import { parseCpuTime } from '../pool/process-limits.js';

export interface CommandLimits { maxRssMb: number; maxProcesses: number; cpuSeconds: number; intervalMs: number }
export const COMMAND_LIMITS: CommandLimits = { maxRssMb: 1024, maxProcesses: 32, cpuSeconds: 60, intervalMs: 1000 };

/** Narrow the sampling blind spot right after spawn, when a child is most likely to setsid() away. */
export const FAST_SAMPLE_MS = 200;
export const FAST_SAMPLE_WINDOW_MS = 3000;

interface ProcessRow { pid: number; parent: number; group: number; rss: number; cpu: number }

/** Samples only PID/parent/group/resource fields; command arguments may contain private task data. */
function parseRows(stdout: string): ProcessRow[] {
  return stdout.split('\n').flatMap((line) => {
    const match = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s*$/.exec(line);
    return match ? [{ pid: Number(match[1]), parent: Number(match[2]), group: Number(match[3]), rss: Number(match[4]), cpu: parseCpuTime(match[5]!) }] : [];
  });
}

/**
 * Descendants of `pid` by process group OR by transitive parentage.
 *
 * A child that calls setsid() leaves the original group, and once our parent exits its ppid is
 * reparented to 1, so neither relation can find it later. The caller therefore has to accumulate
 * every sample: a process observed on the tree at any point stays on the kill list.
 */
function ownedTree(pid: number, rows: ProcessRow[]): Set<number> {
  const owned = new Set([pid, ...rows.filter((row) => row.group === pid).map((row) => row.pid)]);
  let expanded = true;
  while (expanded) {
    expanded = false;
    for (const row of rows) if (owned.has(row.parent) && !owned.has(row.pid)) { owned.add(row.pid); expanded = true; }
  }
  return owned;
}

function readProcessTable(): Promise<ProcessRow[]> {
  return new Promise((resolve, reject) => {
    execFile('/bin/ps', ['-axo', 'pid=,ppid=,pgid=,rss=,time='], { timeout: 3000, maxBuffer: 4 * 1024 * 1024 }, (error, stdout) => {
      if (error) { reject(error instanceof Error ? error : new Error('ps failed')); return; }
      const rows = parseRows(stdout);
      if (!rows.length) { reject(new Error('empty process table')); return; }
      resolve(rows);
    });
  });
}

/** One-shot sample used immediately before termination so the last-moment descendants are on the kill list. */
export async function sampleOwnedTree(pid: number): Promise<Set<number>> {
  return ownedTree(pid, await readProcessTable());
}

/** Which of `pids` are still alive. Used to decide between escalation and a partial-stop report. */
export async function livePids(pids: Iterable<number>): Promise<Set<number>> {
  const wanted = new Set(pids);
  const rows = await readProcessTable();
  return new Set(rows.filter((row) => wanted.has(row.pid)).map((row) => row.pid));
}

export function watchOwnedTree(
  pid: number,
  stop: (code: string) => void,
  limits: CommandLimits = COMMAND_LIMITS,
  onSample?: (owned: Set<number>) => void,
): () => void {
  let closed = false; let busy = false;
  const started = Date.now();
  let timer: NodeJS.Timeout;
  const tick = () => {
    if (closed || busy) return;
    busy = true;
    execFile('/bin/ps', ['-axo', 'pid=,ppid=,pgid=,rss=,time='], { timeout: 3000, maxBuffer: 4 * 1024 * 1024 }, (error, stdout) => {
      busy = false;
      if (closed) return;
      if (error) { stop('local.resource_monitor_failed'); return; }
      const rows = parseRows(stdout);
      if (!rows.length) { stop('local.resource_monitor_failed'); return; }
      const owned = ownedTree(pid, rows);
      // Report before the limit checks: a tree that is about to be stopped still has to be reapable.
      onSample?.(owned);
      const tree = rows.filter((row) => owned.has(row.pid));
      if (tree.length > limits.maxProcesses) stop('local.command_process_limit');
      else if (tree.reduce((sum, row) => sum + row.rss, 0) > limits.maxRssMb * 1024) stop('local.command_memory_limit');
      else if (tree.reduce((sum, row) => sum + row.cpu, 0) > limits.cpuSeconds) stop('local.command_cpu_limit');
    });
  };
  const schedule = () => {
    const fast = Date.now() - started < FAST_SAMPLE_WINDOW_MS;
    const interval = fast ? Math.min(FAST_SAMPLE_MS, Math.max(100, limits.intervalMs)) : Math.max(100, limits.intervalMs);
    timer = setTimeout(() => { tick(); if (!closed) schedule(); }, interval);
    timer.unref();
  };
  schedule();
  return () => { closed = true; clearTimeout(timer); };
}
