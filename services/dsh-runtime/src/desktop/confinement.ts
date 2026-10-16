import { existsSync, realpathSync } from 'node:fs';
import { basename, dirname, isAbsolute, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LocalError } from './ledger.js';

export interface DesktopGrants {
  readOnly: string[];
  readWrite: string[];
  brokerPort: number;
  network?: boolean;
  /** Only the fixed media decoder child, never arbitrary shell/engine code. */
  mediaDecode?: boolean;
  deny?: string[];
  limits?: { maxRssMb: number; maxProcesses: number; cpuSeconds: number };
}

function assertSandboxPath(path: string): void {
  if (!isAbsolute(path) || path.includes('\0')) throw new LocalError('local.invalid_sandbox_path');
}

/**
 * Canonical form of a path that need not exist yet.
 *
 * Deny rules must survive the target being created later: `~/Library/LaunchAgents` frequently does
 * not exist, and dropping the rule because of that would let the worker `mkdir` it and write. So we
 * canonicalize the nearest existing ancestor (defeating symlinked prefixes) and re-append the tail
 * literally instead of failing on ENOENT.
 */
function canonicalPath(path: string): string {
  assertSandboxPath(path);
  const tail: string[] = [];
  let current = path;
  for (;;) {
    try { return resolve(realpathSync(current), ...tail.reverse()); }
    catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw new LocalError('local.invalid_sandbox_path');
      const parent = dirname(current);
      if (parent === current) throw new LocalError('local.invalid_sandbox_path');
      tail.push(basename(current));
      current = parent;
    }
  }
}

function literal(path: string): string {
  // JSON string escaping is also valid for these Scheme string literals; no shell is involved.
  return JSON.stringify(canonicalPath(path));
}

/** Development backend. Packaged builds must pass the same probes before enabling local execution. */
export function macProfile(grants: DesktopGrants): string {
  if (!Number.isInteger(grants.brokerPort) || grants.brokerPort < 1 || grants.brokerPort > 65535) throw new LocalError('local.invalid_broker_port');
  const read = [...new Set(['/System', '/usr/lib', '/usr/share', '/bin', '/usr/bin', '/private/etc', dirname(process.execPath), ...(process.arch === 'x64' ? ['/Library/Apple/usr/libexec/oah'] : []), ...grants.readOnly, ...grants.readWrite])].filter(existsSync);
  return [
    '(version 1)', '(deny default)',
    '(allow process-exec process-fork)', '(allow signal (target self))', '(allow sysctl-read)',
    // Runtime IPC services only. No blanket mach-lookup permits opening arbitrary application services.
    '(allow mach-lookup (global-name "com.apple.system.logger") (global-name "com.apple.system.opendirectoryd.libinfo") (global-name "com.apple.system.notification_center"))',
    ...(grants.mediaDecode ? ['(allow mach-lookup (xpc-service-name "com.apple.coremedia.videodecoder"))', '(allow iokit-open (iokit-user-client-class "IOSurfaceRootUserClient"))'] : []),
    '(allow file-read-metadata)',
    '(allow file-read-data (literal "/"))',
    ...read.map((path) => `(allow file-read* (subpath ${literal(path)}))`),
    ...grants.readWrite.map((path) => `(allow file-write* (subpath ${literal(path)}))`),
    '(allow file-read* (literal "/dev/urandom") (literal "/dev/random"))',
    '(allow file-read* file-write* (literal "/dev/null") (literal "/dev/tty"))',
    grants.network ? '(allow network-outbound)' : `(allow network-outbound (remote tcp "localhost:${grants.brokerPort}"))`,
    ...(grants.deny ?? []).map((path) => `(deny file-read-data file-write* (subpath ${literal(path)}))`),
  ].join('\n');
}

export function confineDesktop(argv: string[], grants: DesktopGrants, platform: NodeJS.Platform = process.platform): string[] {
  if (platform === 'win32') return confineWindows(argv, grants);
  if (platform !== 'darwin' || !existsSync('/usr/bin/sandbox-exec')) throw new LocalError('local.isolation_unavailable');
  if (argv.length === 0) throw new LocalError('local.invalid_command');
  return ['/usr/bin/sandbox-exec', '-p', macProfile(grants), ...argv];
}

export function confineWindows(argv: string[], grants: DesktopGrants): string[] {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const helper = resolve(root, 'native/zhiban-local-sandbox.exe');
  const preload = resolve(root, 'assets/bridge/windows-broker.cjs');
  if (!existsSync(helper) || !existsSync(preload)) throw new LocalError('local.isolation_unavailable');
  if (!argv.length || !Number.isInteger(grants.brokerPort) || grants.brokerPort < 1 || grants.brokerPort > 65535) throw new LocalError('local.invalid_command');
  const args = [helper, '--broker-port', String(grants.brokerPort)];
  for (const [flag, paths] of [['--read', [dirname(process.execPath), dirname(preload), dirname(helper), ...grants.readOnly]], ['--write', grants.readWrite], ['--deny', grants.deny ?? []]] as const) {
    for (const path of new Set(paths)) {
      // Deny entries must keep working for targets that do not exist yet; see canonicalPath.
      args.push(flag, canonicalPath(path));
    }
  }
  const limits = grants.limits ?? { maxRssMb: 1024, maxProcesses: 32, cpuSeconds: 60 };
  args.push('--memory-mb', String(limits.maxRssMb), '--processes', String(limits.maxProcesses), '--cpu-seconds', String(limits.cpuSeconds));
  if (grants.network) args.push('--network');
  // Grants are canonicalized by the host. Avoid Node's loader lstat-ing every
  // ancestor (including an unmodifiable volume root) inside AppContainer.
  // Filesystem access remains enforced by the kernel for all resolved targets.
  const command = argv[0] === process.execPath
    ? [argv[0], '--preserve-symlinks', '--preserve-symlinks-main', '--require', preload, ...argv.slice(1)] : argv;
  return [...args, '--', ...command];
}
