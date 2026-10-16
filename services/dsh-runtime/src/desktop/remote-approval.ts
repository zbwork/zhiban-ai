import { basename } from 'node:path';
import { z } from 'zod';
import { fingerprint, LocalError } from './ledger.js';
import type { ApprovalRequest, LocalPolicy } from './policy.js';

const decisionSchema = z.object({ id: z.string(), run: z.string(), fence: z.number().int(), revision: z.number().int(), intent_hash: z.string(), status: z.enum(['pending', 'approved', 'rejected', 'expired']), scope: z.enum(['once', 'task']) });

/** Only display metadata leaves the device. Tool bodies, command arguments and paths stay local. */
export function approvalDisplay(request: ApprovalRequest): { tool: string; operation: string; target: string } {
  const { tool, operation, args } = request.intent;
  let target = '当前任务';
  if (tool === 'search_files') target = args['scope'] === 'home' ? '用户主目录内的文件名与数量（只读检索）' : '当前工作目录内的文件名与数量';
  else if (typeof args['path'] === 'string' || typeof args['name'] === 'string') {
    target = [...basename(String(args['path'] ?? args['name']).replaceAll('\\', '/'))].map(c => c.codePointAt(0)! < 32 || c.codePointAt(0) === 127 ? '_' : c).join('').slice(0, 100);
  } else if (operation === 'shell') target = '员工工作目录中的命令（详细参数在电脑端查看）';
  else if (operation === 'browser' || operation === 'network') target = '本次浏览器或网络操作（详细参数在电脑端查看）';
  else if (operation === 'desktop') target = '本次桌面软件操作（详细参数在电脑端查看）';
  return { tool, operation, target };
}

export async function coordinateApproval(options: {
  request: ApprovalRequest; policy: LocalPolicy; fence: number; expiresAt: number; signal: AbortSignal;
  send(method: 'POST' | 'GET' | 'DELETE', suffix: string, body?: unknown): Promise<unknown>;
  intervalMs?: number;
}): Promise<void> {
  const { request, policy, signal } = options;
  const hash = fingerprint(request.intent);
  const suffix = `/${request.id}`;
  try {
    let raw = await options.send('POST', '', { id: request.id, revision: request.revision, intent_hash: hash, display: approvalDisplay(request), expires_at: new Date(Math.min(request.expiresAt, options.expiresAt)).toISOString() });
    while (!signal.aborted && policy.pendingApproval(request.id) && Date.now() < Math.min(request.expiresAt, options.expiresAt)) {
      const result = decisionSchema.parse(raw);
      if (result.id !== request.id || result.run !== request.run || result.fence !== options.fence || result.revision !== request.revision || result.intent_hash !== hash) throw new LocalError('local.approval_changed');
      if (result.status !== 'pending') {
        policy.approve(request.id, request.revision, result.status === 'approved', result.scope);
        return;
      }
      await new Promise<void>((resolve) => {
        const done = () => { clearTimeout(timer); signal.removeEventListener('abort', done); resolve(); };
        const timer = setTimeout(done, options.intervalMs ?? 500);
        signal.addEventListener('abort', done, { once: true });
        if (signal.aborted) done();
      });
      if (signal.aborted || !policy.pendingApproval(request.id)) break;
      raw = await options.send('GET', suffix);
    }
  } finally {
    // A timeout, revocation or failed sync cannot leave a local approval executable.
    if (policy.pendingApproval(request.id)) {
      try { policy.approve(request.id, request.revision, false); } catch { /* already expired/revoked */ }
    }
    await options.send('DELETE', suffix).catch(() => {});
  }
}
