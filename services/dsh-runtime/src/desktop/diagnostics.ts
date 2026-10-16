import { createServer } from 'node:http';
import { desktopBrowser, desktopEnvironment } from './platform.js';
import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { probeCodex } from './codex-engine.js';
import { promisify } from 'node:util';
import { createRequire } from 'node:module';
import { confineDesktop } from './confinement.js';

/** No account, network request, user file, path, secret or raw error enters this report. */
export async function desktopComponentCheck(): Promise<{ node: string; checks: Record<string, boolean> }> {
  const checks: Record<string, boolean> = { node: Number(process.versions.node.split('.')[0]) >= 24, engine: false, office: false, browser: false, isolation: false };
  const require = createRequire(import.meta.url);
  try { require.resolve('@deepseek-ai/dsh-sdk-jsonrpc-demo/package.json'); require.resolve('@deepseek-ai/dsh-sdk-client'); checks.engine = true; } catch { /* missing */ }
  try { for (const dep of ['docx', 'exceljs', 'pptxgenjs', 'officeparser']) require.resolve(dep); checks.office = true; } catch { /* missing */ }
  checks.browser = !!desktopBrowser();
  if (process.platform === 'darwin' || process.platform === 'win32') {
    const root = await mkdtemp(join(tmpdir(), 'zhiban-component-check-'));
    const broker = createServer((_req, response) => response.end('broker-ok'));
    const denied = createServer((_req, response) => response.end('forbidden'));
    try {
      await new Promise<void>(resolve => broker.listen(0, '127.0.0.1', resolve));
      await new Promise<void>(resolve => denied.listen(0, '127.0.0.1', resolve));
      const port = (broker.address() as { port: number }).port;
      const deniedPort = (denied.address() as { port: number }).port;
      const workspace = join(root, 'workspace'), outside = join(root, 'outside'), deniedRoot = join(workspace, 'private');
      await mkdir(workspace); await mkdir(outside); await mkdir(deniedRoot); await writeFile(join(outside, 'probe'), 'private'); await writeFile(join(deniedRoot, 'probe'), 'private');
      const script = `const f=require('node:fs');f.writeFileSync(${JSON.stringify(join(workspace, 'probe'))},'ok');for(const p of ${JSON.stringify([join(outside, 'probe'), join(deniedRoot, 'probe')])}){try{f.readFileSync(p);process.exit(2)}catch(e){if(e.code!=='EPERM'&&e.code!=='EACCES')process.exit(3)}}; (async()=>{if(await(await fetch('http://127.0.0.1:${port}')).text()!=='broker-ok')process.exit(4);try{await fetch('http://127.0.0.1:${deniedPort}',{signal:AbortSignal.timeout(1200)});process.exit(5)}catch{}})().catch(()=>process.exit(6))`;
      const [bin, ...args] = confineDesktop([process.execPath, '-e', script], { readOnly: [], readWrite: [workspace], deny: [deniedRoot], brokerPort: port });
      await promisify(execFile)(bin!, args, { timeout: process.platform === 'win32' ? 60_000 : 8000, maxBuffer: 4096, env: desktopEnvironment(workspace) });
      checks.isolation = true;
    } catch { /* failed closed */ } finally { broker.closeAllConnections(); broker.close(); denied.closeAllConnections(); denied.close(); await rm(root, { recursive: true, force: true }); }
  }
  checks.codex = !!checks.isolation && await probeCodex(resolve(dirname(fileURLToPath(import.meta.url)), '../..'));
  return { node: process.versions.node, checks };
}
