import { spawn } from 'node:child_process';
import { StringDecoder } from 'node:string_decoder';
import { LocalError } from './ledger.js';
import { limitsPrelude } from '../pool/process-limits.js';
import { COMMAND_LIMITS, livePids, sampleOwnedTree, watchOwnedTree, type CommandLimits } from './resources.js';

export interface CommandResult { code: number; stdout: string; stderr: string }

/**
 * Stop was requested but descendants outlived both SIGTERM and SIGKILL.
 *
 * macOS has no kernel process container (no cgroup equivalent), so termination is best-effort by
 * construction. The product contract requires reporting that honestly instead of claiming the task
 * stopped; `residual` drives the workspace stop-lock.
 */
export class PartialStopError extends LocalError {
  constructor(readonly residual: number, readonly reason: string) { super('local.process_stop_partial'); }
}

export interface StopTimings { graceMs: number; forceMs: number }
export const STOP_TIMINGS: StopTimings = { graceMs: 500, forceMs: 2000 };

// Keep the event loop alive until awaited descendant cleanup finishes, including standalone probes.
const sleep = (ms: number) => new Promise<void>((resolve) => { setTimeout(resolve, ms); });

/** POSIX owned process group plus accumulated descendants. Windows must use the Job Object backend. */
export async function runOwnedCommand(argv: string[], opts: { cwd: string; env: NodeJS.ProcessEnv; signal: AbortSignal; timeoutMs?: number; maxOutputBytes?: number; input?: string; onStdout?: (chunk: string) => void; limits?: CommandLimits; stopTimings?: StopTimings }): Promise<CommandResult> {
  opts.signal.throwIfAborted();
  // Windows argv must already be wrapped by our native AppContainer/Job broker.
  if (process.platform === 'win32' && !argv[0]?.endsWith('zhiban-local-sandbox.exe')) throw new LocalError('local.process_backend_unavailable');
  if (!argv[0]) throw new LocalError('local.invalid_command');
  const limits = opts.limits ?? COMMAND_LIMITS;
  const timings = opts.stopTimings ?? STOP_TIMINGS;
  const [command, ...args] = limitsPrelude(argv, { cpuSeconds: limits.cpuSeconds, nofile: 1024 });
  return new Promise((resolve, reject) => {
    const child = spawn(command!, args, { cwd: opts.cwd, env: opts.env, detached: process.platform !== 'win32', windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    const outputDecoder = new StringDecoder('utf8');
    const errorDecoder = new StringDecoder('utf8');
    let stdout = '';
    let stderr = '';
    let bytes = 0;
    let failure: LocalError | undefined;
    let reaping: Promise<number> | undefined;
    let stopping = false;
    // Every pid ever seen on this tree. A process that setsid()s away is unreachable through the
    // group and, after our parent exits, through ppid too — the accumulated set is the only handle.
    const observed = new Set<number>();

    const signalOne = (pid: number, signal: NodeJS.Signals) => {
      try { process.kill(pid, signal); }
      catch (err) { if ((err as NodeJS.ErrnoException).code !== 'ESRCH') failure ??= new LocalError('local.process_cleanup_failed'); }
    };
    const signalGroup = (signal: NodeJS.Signals) => {
      if (!child.pid) return;
      try { if (process.platform === 'win32') child.kill(); else process.kill(-child.pid, signal); }
      catch (err) { if ((err as NodeJS.ErrnoException).code !== 'ESRCH') failure ??= new LocalError('local.process_cleanup_failed'); }
    };
    /** Group signal first (cheap, covers the common case), then every accumulated descendant. */
    const signalTree = (signal: NodeJS.Signals) => {
      signalGroup(signal);
      if (process.platform === 'win32') return;
      for (const pid of observed) if (pid !== process.pid) signalOne(pid, signal);
    };

    const reap = async (): Promise<number> => {
      if (process.platform === 'win32') { signalGroup('SIGKILL'); return 0; }
      // Force one last sample: descendants spawned inside the previous sampling gap are still
      // reachable right now, before we signal anything.
      if (child.pid) { try { for (const pid of await sampleOwnedTree(child.pid)) observed.add(pid); } catch { /* fall back to what we already saw */ } }
      if (stopping) {
        // TERM can wake a waiting shell, run its trap, and continue after `;`.
        // Freeze before reaping and never grant a user-cancelled command a
        // graceful execution window. Include descendants found in this sample.
        signalTree('SIGSTOP');
        signalTree('SIGKILL');
        await sleep(timings.forceMs);
        try { return (await livePids(observed)).size; } catch { return Math.max(1, observed.size); }
      }
      signalTree('SIGTERM');
      await sleep(timings.graceMs);
      let alive: Set<number>;
      try { alive = await livePids(observed); } catch { return 0; }
      if (!alive.size) return 0;
      signalGroup('SIGKILL');
      for (const pid of alive) if (pid !== process.pid) signalOne(pid, 'SIGKILL');
      await sleep(timings.forceMs);
      try { return (await livePids(observed)).size; } catch { return 0; }
    };
    const startReap = () => (reaping ??= reap());

    const stop = (code: string) => {
      if (stopping) return;
      stopping = true;
      failure ??= new LocalError(code);
      if (process.platform !== 'win32') signalTree('SIGSTOP');
      void startReap();
    };
    const abort = () => stop('local.command_cancelled');
    const stopMonitor = child.pid && process.platform !== 'win32'
      ? watchOwnedTree(child.pid, stop, limits, (owned) => { for (const pid of owned) observed.add(pid); })
      : () => {};
    opts.signal.addEventListener('abort', abort, { once: true });
    // Close the race between the pre-spawn check and subscription.
    if (opts.signal.aborted) abort();
    const timeout = setTimeout(() => stop('local.command_timeout'), opts.timeoutMs ?? 60_000);
    const collect = (chunk: Buffer, target: 'stdout' | 'stderr') => {
      bytes += chunk.length;
      if (bytes > (opts.maxOutputBytes ?? 256_000)) { stop('local.command_output_limit'); return; }
      if (target === 'stdout') { const text = outputDecoder.write(chunk); stdout += text; try { opts.onStdout?.(text); } catch { stop('local.invalid_process_output'); } } else stderr += errorDecoder.write(chunk);
    };
    child.stdin.on('error', () => { /* broken stdin is reflected in process exit */ });
    child.stdin.end(opts.input ?? '');
    child.stdout.on('data', (data: Buffer) => collect(data, 'stdout'));
    child.stderr.on('data', (data: Buffer) => collect(data, 'stderr'));
    // Parent exit is not task completion if it left descendants holding our pipe FDs.
    child.on('exit', () => signalGroup('SIGKILL'));
    child.on('error', () => { failure ??= new LocalError('local.command_start_failed'); });
    child.on('close', (code) => {
      stopMonitor();
      clearTimeout(timeout);
      opts.signal.removeEventListener('abort', abort);
      // A plain, fast command that never left the group needs no verification round trip.
      const escaped = [...observed].some((pid) => pid !== child.pid);
      if (!failure && !escaped) {
        signalGroup('SIGKILL');
        resolve({ code: code ?? -1, stdout: stdout + outputDecoder.end(), stderr: stderr + errorDecoder.end() });
        return;
      }
      void startReap().then((residual) => {
        if (residual > 0) { reject(new PartialStopError(residual, failure?.code ?? 'local.command_completed')); return; }
        if (failure) { reject(failure); return; }
        resolve({ code: code ?? -1, stdout: stdout + outputDecoder.end(), stderr: stderr + errorDecoder.end() });
      }, () => {
        if (failure) reject(failure);
        else resolve({ code: code ?? -1, stdout: stdout + outputDecoder.end(), stderr: stderr + errorDecoder.end() });
      });
    });
  });
}
