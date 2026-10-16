/** Fixed Office operations inside the existing cloud Agent's confined process tree. */
import { spawn } from 'node:child_process';
import { lstat, realpath } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { officeCreate, officeCreateInput, officeRead } from '../desktop/office-schema.js';
import { validateRelativePath } from '../desktop/artifacts.js';

const worker = fileURLToPath(new URL('../../dist/desktop/office-worker.js', import.meta.url));

export async function callOffice(workspace: string, operation: 'create' | 'read', input: unknown, signal?: AbortSignal): Promise<unknown> {
  const args = operation === 'create' ? officeCreate.parse(input) : officeRead.parse(input);
  validateRelativePath(args.path);
  if (operation === 'create' && !args.path.startsWith('outbox/')) throw Error('office_output_requires_outbox');
  const root = await realpath(workspace);
  let current = root;
  for (const part of args.path.split('/')) {
    current = join(current, part);
    const info = await lstat(current).catch((error: NodeJS.ErrnoException) => {
      if (error.code === 'ENOENT' && operation === 'create') return null;
      throw error;
    });
    if (info?.isSymbolicLink()) throw Error('office_symlink_refused');
  }
  const body = JSON.stringify({ operation, args });
  if (Buffer.byteLength(body) > 4 * 1024 * 1024) throw Error('office_input_limit');
  if (signal?.aborted) throw Error('office_cancelled');
  return new Promise((resolveResult, reject) => {
    // No shell, arbitrary code, env supplied by the model, or additional privilege.
    const child = spawn(process.execPath, ['--max-old-space-size=256', worker], {
      cwd: root, env: process.env, stdio: ['pipe', 'pipe', 'ignore'],
    });
    const chunks: Buffer[] = [];
    let bytes = 0;
    let interrupted = false;
    const stop = () => { interrupted = true; child.kill('SIGKILL'); };
    const timer = setTimeout(stop, 60_000);
    signal?.addEventListener('abort', stop, { once: true });
    if (signal?.aborted) stop();
    child.stdout.on('data', (chunk: Buffer) => {
      bytes += chunk.length;
      if (bytes > 256_000) stop();
      else chunks.push(chunk);
    });
    child.stdin.on('error', () => { /* close/error below owns the result */ });
    child.on('error', reject);
    child.on('close', (code) => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', stop);
      if (interrupted || code !== 0) { reject(Error('office_operation_failed')); return; }
      try { resolveResult(JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown); }
      catch { reject(Error('office_result_invalid')); }
    });
    child.stdin.end(body);
  });
}

async function main(): Promise<void> {
  const workspace = process.argv[process.argv.indexOf('--workspace') + 1];
  if (!process.argv.includes('--workspace') || !workspace) throw Error('workspace_required');
  const server = new McpServer({ name: 'zhiban-office', version: '1.0.0' });
  const call = async (operation: 'create' | 'read', args: unknown, signal: AbortSignal) => {
    try {
      const result = await callOffice(workspace, operation, args, signal);
      return { content: [{ type: 'text' as const, text: JSON.stringify(result) }] };
    } catch {
      return { isError: true, content: [{ type: 'text' as const, text: 'Office 操作失败：请检查参数、文件是否存在及任务是否取消。仅支持工作区内路径，创建须写入 outbox/，不能覆盖已有文件。' }] };
    }
  };
  server.registerTool('office_create', {
    description: '创建可编辑 Word/Excel/PPT 并作为附件交付。使用固定 Office 组件，无需 bash。path 必须以 outbox/ 开头；docx 提供 title/paragraphs，xlsx 提供 sheets，pptx 提供 title/slides。不执行宏或公式，不覆盖已有文件。',
    inputSchema: officeCreateInput.shape,
  }, (args, extra) => call('create', args, extra.signal));
  server.registerTool('office_read', {
    description: '读取工作区内 Office/PDF 的正文，用于交付前检查内容；不执行宏，不含扫描件 OCR。',
    inputSchema: officeRead.shape,
  }, (args, extra) => call('read', args, extra.signal));
  await server.connect(new StdioServerTransport());
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  void main().catch(() => { process.stderr.write('office_mcp_start_failed\n'); process.exitCode = 1; });
}
