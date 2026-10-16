import { constants } from 'node:fs';
import { validateRelativePath } from './artifacts.js';
import { access, stat, mkdir, readFile, realpath, rename, writeFile } from 'node:fs/promises';
import { isAbsolute, join, relative, sep } from 'node:path';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { LocalError, type LocalIdentity } from './ledger.js';

const selection = z.object({ employee: z.string().regex(/^[a-zA-Z0-9_-]{1,128}$/), conversation: z.string().regex(/^[a-zA-Z0-9_-]{1,128}$/), workspace: z.string(), mode: z.enum(['ask', 'assist', 'full']).default('assist') });
const preferences = z.object({ version: z.literal(1), choices: z.array(selection), recent: z.array(z.tuple([selection.shape.employee, z.array(z.string()).max(8)])) });
export type WorkspaceSelection = z.infer<typeof selection>;

/** App-only preferences. Paths never enter the task envelope or the model credential store. */
export class LocalWorkspaces {
  private readonly choices = new Map<string, WorkspaceSelection>();
  private readonly recent = new Map<string, string[]>();
  private readonly confirmations = new Map<string, { conversation: string; expires: number }>();
  private readonly fullConversations = new Set<string>();
  private pendingWrite: Promise<void> = Promise.resolve();

  constructor(private readonly opts: { stateRoot: string; documentsRoot: string; identity: LocalIdentity }) {}

  async load(): Promise<void> {
    try {
      const raw: unknown = JSON.parse(await readFile(join(this.opts.stateRoot, 'workspaces.json'), 'utf8'));
      const stored = Array.isArray(raw) ? { choices: z.array(selection).parse(raw), recent: undefined } : preferences.parse(raw);
      // Broad permission never survives helper restart, logout or sleep.
      for (const value of stored.choices) this.remember({ ...value, mode: value.mode === 'full' ? 'assist' : value.mode });
      if (stored.recent) for (const [employee, paths] of stored.recent) this.recent.set(employee, [...new Set(paths)]);
    } catch (err) { if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw new LocalError('local.workspace_preferences_invalid'); }
  }

  private remember(value: WorkspaceSelection): void {
    this.choices.set(value.conversation, value);
    this.recent.set(value.employee, [value.workspace, ...(this.recent.get(value.employee) ?? []).filter((path) => path !== value.workspace)].slice(0, 8));
  }

  private persist(): Promise<void> {
    const snapshot = JSON.stringify({ version: 1, choices: [...this.choices.values()].map((choice) => ({ ...choice, mode: choice.mode === 'full' ? 'assist' : choice.mode })), recent: [...this.recent] });
    const write = this.pendingWrite.catch(() => {}).then(async () => {
      await mkdir(this.opts.stateRoot, { recursive: true, mode: 0o700 });
      const temporary = join(this.opts.stateRoot, `workspaces-${randomUUID()}.tmp`);
      await writeFile(temporary, snapshot, { flag: 'wx', mode: 0o600 });
      await rename(temporary, join(this.opts.stateRoot, 'workspaces.json'));
    });
    this.pendingWrite = write;
    return write;
  }

  confirmFull(conversation: string): { id: string; expiresAt: number } {
    const id = randomUUID(); const expiresAt = Date.now() + 60_000;
    this.confirmations.set(id, { conversation, expires: expiresAt });
    return { id, expiresAt };
  }

  async create(parent: string, name: string): Promise<string> {
    validateRelativePath(name);
    if (name.includes('/') || ([...name].some((c) => c.codePointAt(0)! < 32 || c.codePointAt(0) === 127) || /[*?"<>|]/.test(name)) || name.length > 120) throw new LocalError('local.invalid_path');
    const root = await this.validateDirectory(parent);
    const path = join(root, name);
    try { await mkdir(path); }
    catch (err) { if ((err as NodeJS.ErrnoException).code === 'EEXIST') throw new LocalError('local.directory_exists'); throw err; }
    return path;
  }

  private async validateDirectory(path: string): Promise<string> {
    if (!isAbsolute(path)) throw new LocalError('local.invalid_workspace');
    const workspace = await realpath(path);
    if (!(await stat(workspace)).isDirectory()) throw new LocalError('local.invalid_workspace');
    await access(workspace, constants.W_OK | constants.R_OK);
    const state = await realpath(this.opts.stateRoot);
    const inside = (a: string, b: string) => { const path = relative(a, b); return path === '' || (path !== '..' && !path.startsWith(`..${sep}`) && !isAbsolute(path)); };
    if (inside(workspace, state) || inside(state, workspace)) throw new LocalError('local.workspace_overlaps_private_state');
    return workspace;
  }

  async select(value: WorkspaceSelection, confirmation?: string): Promise<WorkspaceSelection> {
    value = selection.parse(value);
    const workspace = await this.validateDirectory(value.workspace);
    if (value.mode === 'full' && !this.fullConversations.has(value.conversation)) {
      const proof = confirmation ? this.confirmations.get(confirmation) : undefined;
      if (confirmation) this.confirmations.delete(confirmation);
      if (!proof || proof.conversation !== value.conversation || proof.expires < Date.now()) throw new LocalError('local.full_confirmation_required');
      this.fullConversations.add(value.conversation);
    }
    if (value.mode !== 'full') this.fullConversations.delete(value.conversation);
    this.remember({ ...value, workspace }); await this.persist();
    return this.choices.get(value.conversation)!;
  }

  async defaults(employee: string, conversation: string, name: string): Promise<{ selection: WorkspaceSelection; recent: string[]; defaultWorkspace: string }> {
    selection.parse({ employee, conversation, workspace: '/' });
    const safeName = [...name].map((c) => c.codePointAt(0)! < 32 ? '_' : c).join('').replace(/[\\/:*?"<>|]/g, '_').replace(/[. ]+$/, '').slice(0, 60) || '数字员工';
    const identity = this.opts.identity;
    const workspace = join(this.opts.documentsRoot, '知办AI', identity.tenant, identity.account, `${[...safeName].slice(0, 20).join('')}-${employee}`);
    const old = this.choices.get(conversation);
    if (old && old.employee !== employee) throw new LocalError('local.workspace_identity_mismatch');
    // A saved custom directory must not depend on creating an unused default.
    if (!old || old.workspace === workspace) {
      try { await mkdir(workspace, { recursive: true }); }
      catch (error) {
        const code = (error as NodeJS.ErrnoException).code;
        throw new LocalError(code === 'EEXIST' || code === 'ENOTDIR' ? 'local.workspace_path_conflict'
          : ['EACCES', 'EPERM', 'EROFS'].includes(code ?? '') ? 'local.workspace_permission_denied'
          : 'local.workspace_io_failed');
      }
    }
    const selected = old ?? await this.select({ employee, conversation, workspace, mode: 'assist' });
    return { selection: selected, recent: this.recent.get(employee) ?? [], defaultWorkspace: workspace };
  }

  forTurn(employee: string, conversation: string): WorkspaceSelection {
    const selected = this.choices.get(conversation);
    if (!selected || selected.employee !== employee) throw new LocalError('local.workspace_required');
    return { ...selected };
  }
}
