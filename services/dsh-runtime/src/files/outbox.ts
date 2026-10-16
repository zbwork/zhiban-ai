/**
 * 输出文件回传（ZAP-1.0 §4.4 / §6 files.sign）：agent 把要交付的文件放进工作区 `outbox/`，
 * 本轮结束后 shim 把本轮新增/修改的文件经反向通道登记为 Agent 输出文件，再以 `file` block 追加到 `message.completed`。
 *
 * 链路：files/sign {file_name,file_size,mime_type,message_id} → PUT upload_url(+upload_headers) 文件体
 *   → files/confirm {presign_ticket,file_name,file_size,mime_type,message_id} → drive 文件 DTO(id)
 *   → files/sign-download {file_id} → 短期下载 URL → block {type:'file', name, mime, size, file_id, download_url}
 *
 * 纪律：只处理 outbox/ 下、本轮 mtime 之后、不超上限的普通文件；单个失败保留成功附件并向调用方报告；
 * 不把文件内容/URL 写进日志；需要反向通道（st_），未启用时整段跳过。
 */
import { readFile, readdir, stat } from 'node:fs/promises';
import { extname, join, relative } from 'node:path';
import type { BusClient, TokenScope } from '../backchannel/bus-client.js';

export const OUTBOX_DIR = 'outbox';

export interface OutboxOptions {
  workspace: string;
  /** 本轮开始时间（ms）；只回传 mtime ≥ since 的文件 */
  since: number;
  messageId: string;
  maxBytes: number;
  maxFiles?: number;
  bus: BusClient;
  scope: TokenScope;
  fetchImpl?: typeof fetch;
  logger: { info(obj: Record<string, unknown>, msg: string): void; warn(obj: Record<string, unknown>, msg: string): void };
  /** 会话级已回传记录（path → mtime:size）：同一文件未改动不重复回传（mtime 容差 1s 会把上一轮刚写的文件再扫进来） */
  seen?: Map<string, string>;
  retry?: Set<string>;
}

export interface OutboxBlock {
  type: 'file' | 'image';
  name: string;
  mime: string;
  size: number;
  file_id: string;
  download_url: string;
}

const MIME: Record<string, string> = {
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.csv': 'text/csv',
  '.json': 'application/json',
  '.html': 'text/html',
  '.htm': 'text/html',
  '.pdf': 'application/pdf',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.xls': 'application/vnd.ms-excel',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.doc': 'application/msword',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.zip': 'application/zip',
  '.xml': 'application/xml',
  '.yaml': 'application/yaml',
  '.yml': 'application/yaml',
  '.py': 'text/x-python',
  '.js': 'text/javascript',
  '.ts': 'text/typescript',
};

export function mimeOf(name: string): string {
  return MIME[extname(name).toLowerCase()] ?? 'application/octet-stream';
}

/** 列出 outbox/ 下本轮产出的普通文件（递归一层内，按名字排序，封顶 maxFiles）。 */
export async function collectOutbox(workspace: string, since: number, maxBytes: number, maxFiles = 20, retry?: ReadonlySet<string>): Promise<Array<{ path: string; name: string; size: number; mtimeMs: number }>> {
  const root = join(workspace, OUTBOX_DIR);
  const out: Array<{ path: string; name: string; size: number; mtimeMs: number }> = [];
  const walk = async (dir: string, depth: number): Promise<void> => {
    let entries: string[] = [];
    try {
      entries = await readdir(dir);
    } catch {
      return;
    }
    for (const name of entries.sort()) {
      if (name.startsWith('.')) continue;
      const full = join(dir, name);
      let st;
      try {
        st = await stat(full);
      } catch {
        continue;
      }
      if (st.isDirectory()) {
        if (depth < 2) await walk(full, depth + 1);
        continue;
      }
      if (!st.isFile() || (!retry?.has(full) && st.mtimeMs < since - 1000) || st.size === 0 || st.size > maxBytes) continue;
      out.push({ path: full, name: relative(root, full).split('/').join('__'), size: st.size, mtimeMs: st.mtimeMs });
      if (out.length >= maxFiles) return;
    }
  };
  await walk(root, 0);
  return out;
}

/**
 * 正文里指向 outbox/ 的 markdown 链接改成纯文本（2026-09-02 生产实测）：模型习惯写
 * `[📄 x.csv](<outbox/x.csv>)`，客户端把带文档后缀的链接渲染成"点击下载"卡片，点开是工作区相对路径，
 * 永远打不开；真正可下载的是本函数之后追加的 file block（附件区）。这里只动 markdown/plain 文本块，
 * 链接改成 `label`，命中本轮已回传文件时补"（见附件）"；http(s) 链接与其它块原样保留。
 * Bus 以 completed 帧 blocks 为权威终态，所以在 completed 帧上改写即落库生效；流式 delta 不动。
 */
const OUTBOX_LINK_RE = /!?\[([^\]]*)\]\(\s*<?\s*((?:\.\/)?outbox\/[^)>\s]+|\/[^)>\s]*\/outbox\/[^)>\s]+)\s*>?\s*\)/g;

export function stripOutboxLinks(blocks: unknown[], publishedNames: readonly string[] = []): unknown[] {
  const published = new Set(publishedNames);
  return blocks.map((b) => {
    if (!b || typeof b !== 'object') return b;
    const block = b as Record<string, unknown>;
    if ((block['type'] !== 'markdown' && block['type'] !== 'plain') || typeof block['text'] !== 'string') return b;
    const text = (block['text'] as string).replace(OUTBOX_LINK_RE, (_m, label: string, target: string) => {
      const rel = target.replace(/^.*?\/?outbox\//, '');
      const name = rel.split('/').join('__');
      const plain = label.trim() || rel.split('/').pop() || rel;
      return published.has(name) ? `${plain}（见附件）` : plain;
    });
    return text === block['text'] ? b : { ...block, text };
  });
}

/** 把本轮 outbox 文件登记为 Agent 输出文件；返回可直接进 message.completed 的 file blocks。 */
export async function publishOutbox(opts: OutboxOptions): Promise<{ blocks: OutboxBlock[]; failedCount: number }> {
  const files = await collectOutbox(opts.workspace, opts.since, opts.maxBytes, opts.maxFiles, opts.retry);
  const blocks: OutboxBlock[] = [];
  let failedCount = 0;
  const fetchImpl = opts.fetchImpl ?? fetch;
  for (const f of files) {
    const signature = `${Math.floor(f.mtimeMs)}:${f.size}`;
    if (opts.seen?.get(f.path) === signature) continue;
    const mime = mimeOf(f.name);
    try {
      const sign = asObj(await opts.bus.call(opts.scope, '/zap/v1/internal/files/sign', { file_name: f.name, file_size: f.size, mime_type: mime, message_id: opts.messageId }));
      const uploadUrl = str(sign['upload_url']);
      const ticket = str(sign['presign_ticket']);
      if (!uploadUrl || !ticket) throw new Error('sign returned no upload_url/presign_ticket');
      // 预签名 URL 把 upload_headers 里的头（通常含 Content-Type）算进了签名：原样发、不重复、不多加；
      // 本机实测多加一个小写 content-type 就 403（重复头破坏 SigV4）。content-length 交给 fetch。
      const headers: Record<string, string> = {};
      for (const [k, v] of Object.entries(asObj(sign['upload_headers']))) if (typeof v === 'string') headers[k] = v;
      if (!Object.keys(headers).some((k) => k.toLowerCase() === 'content-type')) headers['Content-Type'] = mime;
      const put = await fetchImpl(uploadUrl, { method: 'PUT', headers, body: new Uint8Array(await readFile(f.path)), signal: AbortSignal.timeout(120_000) });
      if (!put.ok) throw new Error(`upload failed: HTTP ${put.status}`);
      const dto = asObj(await opts.bus.call(opts.scope, '/zap/v1/internal/files/confirm', { presign_ticket: ticket, file_name: f.name, file_size: f.size, mime_type: mime, message_id: opts.messageId }));
      const fileId = str(dto['id']) || str(dto['file_id']) || ticket;
      const dl = asObj(await opts.bus.call(opts.scope, '/zap/v1/internal/files/sign-download', { file_id: fileId }));
      const url = str(dl['url']);
      if (!url) throw new Error('sign-download returned no url');
      blocks.push({ type: mime.startsWith('image/') ? 'image' : 'file', name: f.name, mime, size: f.size, file_id: fileId, download_url: url });
      opts.seen?.set(f.path, signature);
      opts.retry?.delete(f.path);
      opts.logger.info({ message_id: opts.messageId, name: f.name, size: f.size, mime }, 'outbox file published');
    } catch (err) {
      failedCount++;
      opts.retry?.add(f.path);
      opts.logger.warn({ message_id: opts.messageId, name: f.name, detail: err instanceof Error ? err.message : String(err) }, 'outbox file not published (skipped)');
    }
  }
  return { blocks, failedCount };
}

const str = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');
const asObj = (v: unknown): Record<string, unknown> => (typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
