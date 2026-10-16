/**
 * 入站附件（ZAP-1.0 §4.4）：Bus 把用户消息里的 `file` / `image` block 换成**短期签名的绝对 URL**
 * （`zap_chat.go` 出站前 ResolveRuntimeURL），runtime 只管下载到会话工作区，让工具按路径读。
 *
 * 落点：<workspace>/.attachments/<message_id>/<安全文件名>；单文件限大小（边下边数，超限即断），URL 必须 http(s)，
 * 失败只记录（提示词里如实告诉模型"下载失败"），不让整条消息失败。不存 URL（签名短期）；
 * 历史库只记 name/mime/size/file_id。
 */
import { createWriteStream } from 'node:fs';
import { mkdir, rename, rm } from 'node:fs/promises';
import { basename, extname, join } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import type { ReadableStream as WebReadableStream } from 'node:stream/web';

export interface InboundAttachment {
  type: 'file' | 'image';
  name: string;
  mime: string;
  size?: number;
  file_id: string;
  url: string;
}

export interface SavedAttachment {
  type: 'file' | 'image';
  name: string;
  mime: string;
  size?: number;
  file_id: string;
  /** 相对工作区的路径（工具的 cwd = 工作区） */
  path?: string;
  error?: string;
}

type Obj = Record<string, unknown>;
const str = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');
// eslint-disable-next-line no-control-regex -- 刻意过滤控制字符，防止文件名里藏 \n / \x00
const UNSAFE_NAME_CHARS = /[\\/:*?"<>|\u0000-\u001f]/g;

/** 从 block 抽附件；不是 file/image 或没有可下载的 http(s) URL 的返回 undefined。 */
export function attachmentFromBlock(block: Obj): InboundAttachment | undefined {
  const type = str(block['type']).toLowerCase();
  if (type !== 'file' && type !== 'image') return undefined;
  const url =
    str(block['download_url']) || str(block['downloadUrl']) || str(block['url']) || str(block['preview_url']) || str(block['previewUrl']) || str(block['src']);
  if (!/^https?:\/\//i.test(url)) return undefined;
  let fromUrl = '';
  try {
    fromUrl = basename(new URL(url).pathname);
  } catch {
    fromUrl = '';
  }
  const name = str(block['name']) || str(block['file_name']) || str(block['filename']) || fromUrl || (type === 'image' ? 'image' : 'file');
  const sizeRaw = Number(block['size']);
  return {
    type,
    name,
    mime: str(block['mime']) || str(block['mime_type']) || str(block['content_type']),
    ...(Number.isFinite(sizeRaw) && sizeRaw >= 0 ? { size: sizeRaw } : {}),
    file_id: str(block['file_id']),
    url,
  };
}

/** 文件名只留安全字符、去掉前导点（不落隐藏文件）、限长但保留扩展名；空则回落。 */
export function safeFileName(name: string, fallback: string): string {
  const base = basename(name).replace(UNSAFE_NAME_CHARS, '_').replace(/\s+/g, '_').replace(/^\.+/, '').trim();
  const ext = extname(base);
  const trimmed = base.length > 120 ? base.slice(0, 120 - ext.length) + ext : base;
  return trimmed || fallback;
}

export interface SaveOptions {
  workspace: string;
  messageId: string;
  maxBytes: number;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

export const ATTACHMENTS_DIR = '.attachments';

/** 逐个下载；返回每个附件的结果（成功带相对路径，失败带 error），永不抛。 */
export async function saveAttachments(list: InboundAttachment[], opts: SaveOptions): Promise<SavedAttachment[]> {
  if (list.length === 0) return [];
  const dirRel = join(ATTACHMENTS_DIR, opts.messageId);
  const dir = join(opts.workspace, dirRel);
  await mkdir(dir, { recursive: true });
  const used = new Set<string>();
  const out: SavedAttachment[] = [];
  for (const [i, a] of list.entries()) {
    let name = safeFileName(a.name, a.file_id || `attachment-${i + 1}`);
    if (used.has(name)) name = `${i + 1}-${name}`;
    used.add(name);
    const meta = { type: a.type, name: a.name, mime: a.mime, ...(a.size !== undefined ? { size: a.size } : {}), file_id: a.file_id };
    try {
      if (a.size !== undefined && a.size > opts.maxBytes) throw new Error(`too large (${a.size} > ${opts.maxBytes})`);
      await download(a.url, join(dir, name), opts);
      out.push({ ...meta, path: join(dirRel, name) });
    } catch (err) {
      out.push({ ...meta, error: err instanceof Error ? err.message : String(err) });
    }
  }
  return out;
}

async function download(url: string, dest: string, opts: SaveOptions): Promise<void> {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const res = await fetchImpl(url, { signal: AbortSignal.timeout(opts.timeoutMs ?? 60_000), redirect: 'follow' });
  if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);
  const declared = Number(res.headers.get('content-length') ?? '0');
  if (declared > opts.maxBytes) throw new Error(`too large (${declared} > ${opts.maxBytes})`);
  const tmp = `${dest}.part`;
  let seen = 0;
  const limiter = new Transform({
    transform(chunk: Buffer, _enc, cb) {
      seen += chunk.length;
      if (seen > opts.maxBytes) {
        cb(new Error(`too large (> ${opts.maxBytes})`));
        return;
      }
      cb(null, chunk);
    },
  });
  try {
    await pipeline(Readable.fromWeb(res.body as WebReadableStream), limiter, createWriteStream(tmp));
    await rename(tmp, dest);
  } catch (err) {
    await rm(tmp, { force: true }).catch(() => undefined);
    throw err;
  }
}

/** 提示词里的附件说明（路径相对工作区，工具 cwd 即工作区）。 */
export function attachmentsPrefix(saved: SavedAttachment[]): string {
  if (saved.length === 0) return '';
  const ok = saved.filter((s) => s.path);
  const failed = saved.filter((s) => !s.path);
  const lines: string[] = [];
  if (ok.length > 0) {
    lines.push('[用户附件] 已保存到当前工作目录，按路径直接读取：');
    for (const s of ok) {
      const detail = [s.mime, s.size !== undefined ? formatSize(s.size) : ''].filter((x) => x).join(', ');
      lines.push(`- ${s.path}${detail ? `（${detail}）` : ''}`);
    }
  }
  if (failed.length > 0) {
    lines.push('[用户附件] 以下文件下载失败，请告知用户重新发送：');
    for (const s of failed) lines.push(`- ${s.name}${s.error ? `（${s.error}）` : ''}`);
  }
  return lines.join('\n') + '\n\n';
}

function formatSize(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}
