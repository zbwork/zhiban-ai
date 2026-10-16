import { constants } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { lstat, mkdir, open, realpath, writeFile } from 'node:fs/promises';
import { basename, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { LocalError, type LocalIdentity } from './ledger.js';

export interface ArtifactOwner extends Pick<LocalIdentity, 'tenant' | 'account' | 'device'> { employee: string; conversation: string; run: string }
export interface ArtifactRef { artifact_id: string; device_id: string; sha256: string }
export interface ArtifactMeta { local_artifact: ArtifactRef; name: string; mime: string; size: number; archive_status?: 'synced' | 'failed'; drive_file_id?: string }
interface RecordFile { owner: ArtifactOwner; meta: ArtifactMeta; source?: { workspace: string; name: string } }

function contained(root: string, path: string): boolean {
  const rel = relative(root, path);
  return rel !== '' && rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
}

/** No symlinks, dot traversal, NTFS streams, device names or network paths in broker file names. */
export function validateRelativePath(path: string): void {
  if (!path || path.includes('\0') || path.includes('\\') || isAbsolute(path) || path.includes(':') || path.split('/').some((part) => !part || part === '.' || part === '..' || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part) || /[. ]$/.test(part))) throw new LocalError('local.invalid_path');
}

export async function authorizedPath(root: string, name: string): Promise<string> {
  validateRelativePath(name);
  const canonical = await realpath(root);
  const path = resolve(canonical, name);
  if (!contained(canonical, path)) throw new LocalError('local.path_outside_workspace');
  let current = canonical;
  for (const part of name.split('/')) {
    current = join(current, part);
    const info = await lstat(current);
    if (info.isSymbolicLink()) throw new LocalError('local.symlink_refused');
  }
  if (!contained(canonical, await realpath(path))) throw new LocalError('local.path_outside_workspace');
  return path;
}

export async function readRegularFile(path: string, maxBytes: number): Promise<Buffer> {
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const before = await handle.stat();
    if (!before.isFile() || before.nlink !== 1 || before.size > maxBytes) throw new LocalError('local.file_refused');
    // Bounded allocation/read also protects against concurrent file growth.
    const bytes = Buffer.alloc(before.size + 1);
    let offset = 0;
    while (offset < bytes.length) {
      const read = await handle.read(bytes, offset, bytes.length - offset, offset);
      if (read.bytesRead === 0) break;
      offset += read.bytesRead;
    }
    const after = await handle.stat();
    const named = await lstat(path);
    if (offset !== before.size || after.size !== before.size || after.mtimeMs !== before.mtimeMs || after.ctimeMs !== before.ctimeMs || named.isSymbolicLink() || named.ino !== after.ino || named.dev !== after.dev) throw new LocalError('local.file_changed');
    return bytes.subarray(0, offset);
  } finally { await handle.close(); }
}

/** Snapshots stay in App support storage. Published snapshots are archived separately; original paths remain in the private App index. */
export class ArtifactStore {
  constructor(private readonly root: string, private readonly maxBytes = 128 * 1024 * 1024) {}

  async publish(owner: ArtifactOwner, workspace: string, name: string, mime: string, capture?: (path: string, maxBytes: number) => Promise<Buffer>, candidates: ArtifactMeta[] = []): Promise<ArtifactMeta> {
    const canonical = await realpath(workspace);
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    const privateRoot = await realpath(this.root);
    if (canonical === privateRoot || contained(canonical, privateRoot) || contained(privateRoot, canonical)) throw new LocalError('local.artifact_storage_not_private');
    const path = await authorizedPath(canonical, name);
    const bytes = capture ? await capture(path, this.maxBytes) : await readRegularFile(path, this.maxBytes);
    if (bytes.length > this.maxBytes) throw new LocalError('local.file_refused');
    // Recheck ancestry after reading. OS execution isolation remains mandatory for arbitrary-code tools.
    await authorizedPath(canonical, name);
    const hash = createHash('sha256').update(bytes).digest('hex');
    for (const candidate of candidates) {
      if (candidate.local_artifact.sha256 !== hash || candidate.mime !== mime || candidate.name !== basename(name)) continue;
      await this.read(owner, candidate.local_artifact);
      const record = JSON.parse((await readRegularFile(await authorizedPath(this.root, `${candidate.local_artifact.artifact_id}/record.json`), 16_384)).toString('utf8')) as RecordFile;
      if (record.source?.workspace === canonical && record.source.name === name) return candidate;
    }
    const id = randomUUID();
    const meta: ArtifactMeta = { local_artifact: { artifact_id: id, device_id: owner.device, sha256: hash }, name: basename(name), mime, size: bytes.length };
    const dir = join(privateRoot, id);
    await mkdir(dir, { mode: 0o700 });
    await writeFile(join(dir, 'content'), bytes, { flag: 'wx', mode: 0o600 });
    await writeFile(join(dir, 'record.json'), JSON.stringify({ owner, meta, source: { workspace: canonical, name } } satisfies RecordFile), { flag: 'wx', mode: 0o600 });
    return meta;
  }

  async read(owner: ArtifactOwner, ref: ArtifactRef): Promise<{ meta: ArtifactMeta; bytes: Buffer }> {
    return this.readAuthorized(owner, ref);
  }

  /** Existing local snapshots remain readable after same-account re-login on this installation. */
  async readForConversation(owner: Pick<ArtifactOwner, 'tenant' | 'account' | 'conversation'>, ref: ArtifactRef): Promise<{ meta: ArtifactMeta; bytes: Buffer }> {
    return this.readAuthorized(owner, ref);
  }

  async originalForConversation(owner: Pick<ArtifactOwner, 'tenant' | 'account' | 'conversation'>, ref: ArtifactRef): Promise<string> {
    await this.readAuthorized(owner, ref);
    const record = JSON.parse((await readRegularFile(await authorizedPath(this.root, `${ref.artifact_id}/record.json`), 16_384)).toString('utf8')) as RecordFile;
    if (!record.source) throw new LocalError('local.artifact_original_unavailable');
    const path = await authorizedPath(record.source.workspace, record.source.name);
    const bytes = await readRegularFile(path, this.maxBytes);
    if (createHash('sha256').update(bytes).digest('hex') !== ref.sha256) throw new LocalError('local.artifact_changed');
    await authorizedPath(record.source.workspace, record.source.name);
    return path;
  }

  private async readAuthorized(owner: Partial<ArtifactOwner>, ref: ArtifactRef): Promise<{ meta: ArtifactMeta; bytes: Buffer }> {
    if (!/^[0-9a-f-]{36}$/.test(ref.artifact_id)) throw new LocalError('local.artifact_not_found');
    const recordPath = await authorizedPath(this.root, `${ref.artifact_id}/record.json`);
    const record = JSON.parse((await readRegularFile(recordPath, 16_384)).toString('utf8')) as RecordFile;
    if (Object.keys(owner).some((key) => record.owner[key as keyof ArtifactOwner] !== owner[key as keyof ArtifactOwner])) throw new LocalError('local.artifact_owner_mismatch');
    if (ref.device_id !== record.owner.device || record.meta.local_artifact.sha256 !== ref.sha256) throw new LocalError('local.artifact_version_mismatch');
    const contentPath = await authorizedPath(this.root, `${ref.artifact_id}/content`);
    const bytes = await readRegularFile(contentPath, this.maxBytes);
    if (bytes.length !== record.meta.size || createHash('sha256').update(bytes).digest('hex') !== ref.sha256) throw new LocalError('local.artifact_changed');
    return { meta: record.meta, bytes };
  }
}
