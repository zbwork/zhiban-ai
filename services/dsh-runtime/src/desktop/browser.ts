import { desktopBrowser, desktopEnvironment } from './platform.js';
import { randomBytes } from 'node:crypto';
import { access, mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { createConnection } from '@playwright/mcp';
import { chromium, type BrowserServer, type BrowserContext } from 'playwright';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { z } from 'zod';
import type { DesktopTool } from './broker.js';
import type { ActiveLocalRun } from './supervisor.js';
import { fingerprint, LocalError } from './ledger.js';

const actions = ['browser_navigate', 'browser_navigate_back', 'browser_snapshot', 'browser_click', 'browser_type', 'browser_press_key', 'browser_select_option', 'browser_hover', 'browser_drag', 'browser_wait_for', 'browser_tabs'] as const;
const schema = z.object({ action: z.enum(actions), arguments: z.record(z.string(), z.unknown()).default({}) }).strict();
interface BrowserRun { client: Client; server: Awaited<ReturnType<typeof createConnection>>; process: BrowserServer; context: BrowserContext; root: string; removeAbort(): void }

/** Official MCP + official Playwright process ownership. No user profile, arbitrary JS or caller file paths. */
export class LocalBrowser {
  private readonly runs = new Map<string, Promise<BrowserRun>>();
  private readonly closing = new Map<string, Promise<void>>();
  constructor(private readonly opts: { root: string; executable?: string; headless?: boolean }) {}

  tool(): DesktopTool {
    return { name: 'browser', operation: 'browser', schema, inputSchema: z.toJSONSchema(schema) as Record<string, unknown>,
      description: '操作本任务独立浏览器。先 browser_navigate，再用 browser_snapshot 的 ref 点击或输入。action 使用官方 Playwright MCP 工具名，arguments 为该操作参数；不支持上传、任意代码或保存路径。可用操作参数通过 browser_actions 查询。',
      isError: (result) => (result as { isError?: boolean }).isError === true,
      call: async (run, args, signal) => {
        const action = args['action'] as typeof actions[number];
        const params = args['arguments'] as Record<string, unknown>;
        if (Object.keys(params).some((key) => /file|path|script|code/i.test(key))) throw new LocalError('local.browser_argument_denied');
        if (action === 'browser_navigate') {
          const url = new URL(String(params['url']));
          if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) throw new LocalError('local.browser_url_denied');
        }
        const browser = await this.ensure(run, signal);
        const close = () => { void this.close(run.task.run); };
        signal.addEventListener('abort', close, { once: true });
        try {
          signal.throwIfAborted();
          const result = await browser.client.callTool({ name: action, arguments: params }, undefined, { signal, timeout: 60_000 });
          // File/credential paths in driver diagnostics never become cloud chat metadata.
          const content = (Array.isArray(result.content) ? result.content : []).flatMap((item) => {
            if (typeof item !== 'object' || item === null || item.type !== 'text' || typeof item.text !== 'string') return [];
            return [{ type: 'text', text: item.text.split(browser.root).join('[本机浏览器]').slice(0, 32000) }];
          });
          return { content, isError: result.isError === true };
        } catch {
          if (signal.aborted) await this.close(run.task.run);
          throw new LocalError('local.browser_operation_failed');
        } finally { signal.removeEventListener('abort', close); }
      },
    };
  }

  actionsTool(): DesktopTool {
    const empty = z.object({}).strict();
    return { name: 'browser_actions', operation: 'read', schema: empty, inputSchema: z.toJSONSchema(empty) as Record<string, unknown>, description: '查询浏览器操作参数，不启动浏览器。',
      call: async () => {
        const server = await createConnection({ capabilities: ['core'], imageResponses: 'omit' });
        const client = new Client({ name: 'zhiban-local-browser-schema', version: '1' });
        const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
        try {
          await server.connect(serverTransport); await client.connect(clientTransport);
          const list = await client.listTools();
          return { tools: list.tools.filter((tool) => actions.includes(tool.name as typeof actions[number])).map(({ name, description, inputSchema }) => ({ name, description, inputSchema: { ...inputSchema, properties: Object.fromEntries(Object.entries(inputSchema.properties ?? {}).filter(([key]) => !/file|path|script|code/i.test(key))) } })) };
        } finally { await client.close(); await server.close(); }
      },
    };
  }

  private async ensure(run: ActiveLocalRun, signal: AbortSignal): Promise<BrowserRun> {
    await this.closing.get(run.task.run);
    signal.throwIfAborted();
    let pending = this.runs.get(run.task.run);
    if (!pending) {
      pending = this.start(run, signal).catch((error) => { this.runs.delete(run.task.run); throw error; });
      this.runs.set(run.task.run, pending);
    }
    return pending;
  }

  private async start(run: ActiveLocalRun, signal: AbortSignal): Promise<BrowserRun> {
    const executable = this.opts.executable ?? desktopBrowser();
    if (!executable) throw new LocalError('local.browser_component_unavailable');
    try { await access(executable); } catch { throw new LocalError('local.browser_component_unavailable'); }
    signal.throwIfAborted();
    const root = join(this.opts.root, fingerprint({ run: run.task.run, fence: run.task.fence }));
    await mkdir(root, { recursive: true, mode: 0o700 });
    const browserProcess = await chromium.launchServer({ executablePath: executable, headless: this.opts.headless ?? false,
      chromiumSandbox: true, host: '127.0.0.1', wsPath: randomBytes(32).toString('hex'), downloadsPath: root,
      env: desktopEnvironment(root), timeout: 20_000,
    });
    try {
      signal.throwIfAborted();
      const browser = await chromium.connect(browserProcess.wsEndpoint());
      const context = await browser.newContext({ acceptDownloads: false, serviceWorkers: 'block' });
      await context.route('**/*', async (route) => {
        const protocol = new URL(route.request().url()).protocol;
        if (protocol === 'https:' || protocol === 'http:') await route.continue(); else await route.abort();
      });
      const server = await createConnection({ capabilities: ['core'], outputDir: root, saveSession: false, imageResponses: 'omit',
        allowUnrestrictedFileAccess: false, snapshot: { mode: 'none' }, codegen: 'none', timeouts: { action: 10000, navigation: 30000 },
      }, async () => context);
      const client = new Client({ name: 'zhiban-local-browser', version: '1' });
      const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
      await server.connect(serverTransport); await client.connect(clientTransport);
      const abort = () => { void this.close(run.task.run); };
      run.controller.signal.addEventListener('abort', abort, { once: true });
      run.policy.signal.addEventListener('abort', abort, { once: true });
      const policySignal = run.policy.signal;
      signal.throwIfAborted();
      return { client, server, process: browserProcess, context, root, removeAbort: () => { run.controller.signal.removeEventListener('abort', abort); policySignal.removeEventListener('abort', abort); } };
    } catch { await browserProcess.kill(); await rm(root, { recursive: true, force: true }); throw new LocalError('local.browser_start_failed'); }
  }

  close(run: string): Promise<void> {
    const closing = this.closing.get(run); if (closing) return closing;
    const pending = this.runs.get(run); if (!pending) return Promise.resolve();
    this.runs.delete(run);
    const cleanup = (async () => {
      const browser = await pending.catch(() => undefined); if (!browser) return;
      browser.removeAbort();
      // Playwright's public BrowserServer.kill owns and terminates the entire browser process tree.
      try { await browser.process.kill(); } finally {
        await Promise.allSettled([browser.client.close(), browser.server.close()]);
        await rm(browser.root, { recursive: true, force: true });
      }
    })().finally(() => { this.closing.delete(run); });
    this.closing.set(run, cleanup);
    return cleanup;
  }
}
