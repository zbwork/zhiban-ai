/** Product delivery checks; DSH remains responsible for its model/tool loop. */
import { extname } from 'node:path';
import { unzipSync } from 'fflate';
import { z } from 'zod';
import { extractOfficeText } from './office-text.js';
import { LocalError } from './ledger.js';
import type { ArtifactMeta, ArtifactStore } from './artifacts.js';
import type { ActiveLocalRun } from './supervisor.js';

const name = z.string().min(1).max(255).refine((s) => Buffer.byteLength(s) <= 255 && !/[\\/:]/.test(s) && ![...s].some((char) => char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127) && s !== '.' && s !== '..');
const mime = z.string().regex(/^[a-z0-9.+-]+\/[a-z0-9.+-]+$/);
export const deliveryDeclaration = z.object({ files: z.array(z.object({
  name, mime, min_bytes: z.number().int().min(1).max(128 * 1024 * 1024).default(1),
  text_contains: z.array(z.string().min(1).max(1000)).max(20).default([]),
}).strict()).max(32) }).strict();
export type DeliverableRequirement = z.infer<typeof deliveryDeclaration>['files'][number];

/** Recover explicitly declared root outputs; never scan a workspace or rerun writes. */
export async function captureDeclaredDeliverables(run: ActiveLocalRun, capture: (file: DeliverableRequirement) => Promise<unknown>): Promise<void> {
  for (const file of run.deliverables ?? []) {
    if (run.controller.signal.aborted) return;
    if (run.artifacts.some((meta) => meta.name === file.name && meta.mime === file.mime)) continue;
    // Declarations have safe basenames only. Nested paths are deliberately not guessed.
    try { name.parse(file.name); await capture(file); }
    catch { /* Missing/invalid outputs are classified by verifyLocalDeliverables. */ }
  }
}

/** Each nonempty declaration describes the complete current output plan, including renamed retries. */
export function declareDeliverables(run: ActiveLocalRun, files: DeliverableRequirement[]): void {
  const previousFiles = new Map((run.deliverables ?? []).map((f) => [f.name, f]));
  if (files.length === 0 && previousFiles.size > 0) throw new LocalError('local.deliverable_declaration_conflict');
  const merged = new Map<string, DeliverableRequirement>();
  for (const item of files) {
    const previous = merged.get(item.name) ?? previousFiles.get(item.name);
    if (previous && previous.mime !== item.mime) throw new LocalError('local.deliverable_declaration_conflict');
    const text = [...new Set([...(previous?.text_contains ?? []), ...item.text_contains])];
    if (text.length > 20) throw new LocalError('local.deliverable_declaration_limit');
    merged.set(item.name, { ...item, min_bytes: Math.max(previous?.min_bytes ?? 1, item.min_bytes), text_contains: text });
  }
  if (merged.size > 32) throw new LocalError('local.deliverable_declaration_limit');
  run.deliverables = [...merged.values()];
}

const officeMime: Record<string, string> = {
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
};

/** Bounded structure/body-text checks, not Office rendering, recalculation, OCR or semantic quality. */
export function inspectArtifact(meta: Pick<ArtifactMeta, 'name' | 'mime' | 'size'>, bytes: Buffer): string | undefined {
  if (bytes.length !== meta.size || !bytes.length) throw new LocalError('local.deliverable_invalid');
  name.parse(meta.name); mime.parse(meta.mime);
  const ext = extname(meta.name).toLowerCase();
  const expectedOffice = officeMime[ext];
  if (expectedOffice || Object.values(officeMime).includes(meta.mime)) {
    if (meta.mime !== expectedOffice || bytes.length > 32 * 1024 * 1024) throw new LocalError('local.deliverable_invalid');
    let expanded = 0, entries = 0;
    const files = unzipSync(bytes, { filter: (entry) => {
      expanded += entry.originalSize;
      if (++entries > 4096 || expanded > 32 * 1024 * 1024) throw new LocalError('local.deliverable_size_limit');
      return true;
    } });
    const xml = (path: string) => files[path] ? new TextDecoder('utf-8', { fatal: true }).decode(files[path]) : '';
    if (!xml('[Content_Types].xml').includes('<Types') || !xml('_rels/.rels').includes('<Relationships')) throw new LocalError('local.deliverable_invalid');
    const root = ext === '.docx' ? 'word/document.xml' : ext === '.xlsx' ? 'xl/workbook.xml' : 'ppt/presentation.xml';
    const tag = ext === '.docx' ? 'w:document' : ext === '.xlsx' ? 'workbook' : 'p:presentation';
    if (!new RegExp(`<${tag}(?:\\s|>)`).test(xml(root)) || !xml(root).includes(`</${tag}>`)) throw new LocalError('local.deliverable_invalid');
    if (ext === '.xlsx' && !Object.keys(files).some((path) => /^xl\/worksheets\/sheet\d+\.xml$/.test(path))) throw new LocalError('local.deliverable_invalid');
    if (ext === '.pptx' && !Object.keys(files).some((path) => /^ppt\/slides\/slide\d+\.xml$/.test(path))) throw new LocalError('local.deliverable_invalid');
    return extractOfficeText(ext, files);
  }
  if (meta.mime.startsWith('text/') || ['.txt', '.md', '.csv', '.json'].includes(ext) || meta.mime === 'application/json') {
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    if (!text.trim() || text.includes('\0')) throw new LocalError('local.deliverable_invalid');
    if (ext === '.json' || meta.mime === 'application/json') JSON.parse(text);
    return text;
  }
  // Other formats retain immutable-file identity checks; their dedicated decoders belong to D-04/D-05.
  return undefined;
}

export async function verifyLocalDeliverables(run: ActiveLocalRun, store: ArtifactStore): Promise<void> {
  const owner = { tenant: run.task.tenant, account: run.task.account, device: run.task.device, employee: run.task.employee, conversation: run.task.conversation, run: run.task.run };
  const valid: ArtifactMeta[] = [];
  const satisfied = new Set<string>();
  let invalid = false;
  for (const meta of run.artifacts) {
    try {
      const snapshot = await store.read(owner, meta.local_artifact);
      if (snapshot.meta.name !== meta.name || snapshot.meta.mime !== meta.mime || snapshot.meta.size !== meta.size) throw new LocalError('local.deliverable_invalid');
      const text = inspectArtifact(meta, snapshot.bytes);
      valid.push(meta);
      for (const requirement of run.deliverables ?? []) {
        // text_contains is meaningful only for formats whose body we can safely
        // extract (plain text and OOXML). Binary/image formats still require
        // identity, MIME, size and hash validation, but must not fail because a
        // model supplied a textual hint that cannot be inspected.
        const contentMatches = text === undefined || requirement.text_contains.every((part) => text.includes(part));
        if (meta.name === requirement.name && meta.mime === requirement.mime && meta.size >= requirement.min_bytes && contentMatches) satisfied.add(requirement.name);
      }
    } catch { invalid = true; }
  }
  // Preserve valid partial results even if another snapshot or requirement fails.
  run.artifacts = valid;
  if (invalid) throw new LocalError('local.deliverable_invalid');
  for (const requirement of run.deliverables ?? []) {
    if (!satisfied.has(requirement.name)) {
      const exists = valid.some((meta) => meta.name === requirement.name && meta.mime === requirement.mime);
      throw new LocalError(exists ? 'local.deliverable_content_mismatch' : 'local.deliverable_missing');
    }
  }
}

/** Feedback while the model can still correct an output; uncreated files are not errors yet. */
export async function existingDeliveryIssues(run: ActiveLocalRun, store: ArtifactStore, filename?: string): Promise<Record<string, unknown>[]> {
  const owner = { tenant: run.task.tenant, account: run.task.account, device: run.task.device, employee: run.task.employee, conversation: run.task.conversation, run: run.task.run };
  const issues: Record<string, unknown>[] = [];
  for (const requirement of run.deliverables ?? []) {
    if (filename !== undefined && requirement.name !== filename) continue;
    const matches = run.artifacts.filter(meta => meta.name === requirement.name && meta.mime === requirement.mime);
    if (!matches.length) continue;
    let issue: Record<string, unknown> = { name: requirement.name, reason: 'invalid_file' };
    let satisfied = false;
    for (const meta of matches) {
      try {
        const snapshot = await store.read(owner, meta.local_artifact);
        const text = inspectArtifact(snapshot.meta, snapshot.bytes);
        const missing = text === undefined ? [] : requirement.text_contains.filter(part => !text.includes(part));
        if (snapshot.meta.size >= requirement.min_bytes && !missing.length) { satisfied = true; break; }
        issue = { name: requirement.name, missing_text: missing, size: snapshot.meta.size, min_bytes: requirement.min_bytes };
      } catch { /* Report only a safe category, never filesystem/decoder exceptions. */ }
    }
    if (!satisfied) issues.push(issue);
  }
  return issues;
}
