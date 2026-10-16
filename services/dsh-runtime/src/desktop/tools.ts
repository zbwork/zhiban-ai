import { desktopEnvironment, desktopShell, persistenceDenyPaths } from './platform.js';
import { declareDeliverables, deliveryDeclaration, existingDeliveryIssues, inspectArtifact } from './deliverables.js';
import { homedir } from 'node:os';
import { join, relative } from 'node:path';
import { open, realpath } from 'node:fs/promises';
import { constants } from 'node:fs';
import { z } from 'zod';
import { type ArtifactStore, type ArtifactOwner, validateRelativePath } from './artifacts.js';
import type { DesktopTool } from './broker.js';
import { confineDesktop } from './confinement.js';
import { PartialStopError, runOwnedCommand } from './process.js';
import type { ActiveLocalRun } from './supervisor.js';
import { LocalError } from './ledger.js';
import { writeWorkspaceBytes } from './workspace-files.js';

export interface LocalToolOptions { privateRoot: string; artifacts: ArtifactStore; brokerPort: number; runtimeReadRoots?: string[]; moduleRoot?: string }

// Include snapshot validation and registration in the lock, including Office's publisher.
const publications = new WeakMap<ActiveLocalRun, Promise<unknown>>();
async function publishSerially<T>(run: ActiveLocalRun, publish: () => Promise<T>): Promise<T> {
  const pending = (publications.get(run) ?? Promise.resolve()).catch(() => {}).then(publish);
  publications.set(run, pending);
  try { return await pending; } finally { if (publications.get(run) === pending) publications.delete(run); }
}

/** File operations execute inside the same OS boundary as shell, preventing symlink-race escapes from host I/O. */
export function localTools(opts: LocalToolOptions): DesktopTool[] {
  const schemaFor = (schema: z.ZodType) => z.toJSONSchema(schema) as Record<string, unknown>;
  const file = z.object({ path: z.string().min(1).max(2048) }).strict();
  const skillFile = z.object({ skill_code: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/), path: z.string().min(1).max(2048).default('SKILL.md') }).strict();
  const write = file.extend({ text: z.string().max(2_000_000) });
  const edit = write.extend({ expected_sha256: z.string().regex(/^[0-9a-f]{64}$/) });
  async function execute(run: ActiveLocalRun, script: string, args: Record<string, unknown>, signal: AbortSignal, writable: boolean) {
    const workspace = await realpath(run.config.workspace);
    const argv = confineDesktop([process.execPath, '-e', script], {
      // These fixed scripts use only Node built-ins. On Windows, granting the
      // dependency tree propagates ACLs through every package on each file call.
      readOnly: [workspace, ...(process.platform === 'win32' ? [] : opts.runtimeReadRoots ?? [])], readWrite: writable ? [workspace] : [], brokerPort: opts.brokerPort,
      deny: [opts.privateRoot],
    });
    const result = await runOwnedCommand(argv, { cwd: workspace, env: desktopEnvironment(workspace), signal, input: JSON.stringify(args) });
    if (result.code !== 0) throw new LocalError('local.file_operation_failed');
    return JSON.parse(result.stdout) as unknown;
  }
  // All interpolated code below is static; caller parameters travel as a separate argv value.
  const prelude = "const fs=require('node:fs'); const crypto=require('node:crypto'); const path=require('node:path'); const a=JSON.parse(process.argv[1]??fs.readFileSync(0,'utf8')); const out=v=>process.stdout.write(JSON.stringify(v));";
  return [
    {
      name: 'declare_deliverables', description: '生成多文件前声明本轮完整清单（只填文件名，不填目录）。后一次非空清单替换旧清单，修正另存时更新完整清单，仍列出用户要求的全部结果。纯问答无需调用，已有非空清单不能改为空。Office/生图工具自动发布，不必重复 publish_artifact；其他文件完成后再发布。text_contains 是必须实际写入可读正文的内容要求；已有文件不满足时返回 delivery_issues，先修正再结束，不用于排版或公式验收。', operation: 'read',
      schema: deliveryDeclaration, inputSchema: schemaFor(deliveryDeclaration),
      call: async (run, args, signal) => {
        signal.throwIfAborted();
        declareDeliverables(run, deliveryDeclaration.parse(args).files);
        const delivery_issues = await existingDeliveryIssues(run, opts.artifacts);
        return { files: run.deliverables, delivery_issues, ...(delivery_issues.length ? { next_step: '已有文件未满足清单要求，请补齐 missing_text 或大小要求后另存新版本，并更新完整交付清单；不要降低要求或直接结束。' } : {}) };
      },
      isError: result => Array.isArray((result as Record<string, unknown>)['delivery_issues']) && ((result as Record<string, unknown>)['delivery_issues'] as unknown[]).length > 0,
    },
    {
      name: 'read_skill_file', description: '读取本轮已加载关联技能的 SKILL.md 或参考文本，最多 256 KB。skill_code 使用可用关联技能清单中的 code；path 为包内相对路径，默认 SKILL.md。无需切换工作目录，不使用市场 code 猜原生 skill 名称。', operation: 'read',
      schema: skillFile, inputSchema: schemaFor(skillFile),
      call: async (run, args, signal) => {
        signal.throwIfAborted();
        if (!run.config.skillsDir) throw new LocalError('local.skill_unavailable');
        const input = skillFile.parse(args);
        validateRelativePath(input.skill_code); validateRelativePath(input.path);
        const root = await realpath(join(run.config.skillsDir, input.skill_code)).catch((error: NodeJS.ErrnoException) => {
          if (error.code === 'ENOENT') throw new LocalError('local.skill_unavailable');
          throw error;
        });
        validateRelativePath(relative(await realpath(run.config.skillsDir), root));
        const source = await realpath(join(root, input.path));
        validateRelativePath(relative(root, source));
        const fd = await open(source, constants.O_RDONLY | constants.O_NOFOLLOW);
        try {
          const st = await fd.stat();
          if (!st.isFile() || st.nlink !== 1 || st.size > 256000) throw new LocalError('local.file_size_limit');
          const bytes = await fd.readFile();
          signal.throwIfAborted();
          if (bytes.length !== st.size) throw new LocalError('local.file_changed');
          return { skill_code: input.skill_code, path: input.path, text: bytes.toString('utf8') };
        } finally { await fd.close(); }
      },
    },
    {
      name: 'copy_skill_file', description: '把已加载技能包中的脚本或模板复制到工作目录后使用。目标必须是新文件；执行脚本另经 local_shell 审批。', operation: 'write',
      schema: z.object({ skill_code: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/), path: z.string().min(1).max(2048), destination: z.string().min(1).max(2048) }).strict(),
      inputSchema: { type: 'object', properties: { skill_code: { type: 'string' }, path: { type: 'string' }, destination: { type: 'string' } }, required: ['skill_code', 'path', 'destination'] },
      call: async (run, args, signal) => {
        if (!run.config.skillsDir) throw new LocalError('local.skill_unavailable');
        validateRelativePath(String(args['path'])); validateRelativePath(String(args['skill_code']));
        // This tree is created by the host ZIP extractor; workers only have a read-only grant.
        const fd = await open(join(run.config.skillsDir, String(args['skill_code']), String(args['path'])), constants.O_RDONLY | constants.O_NOFOLLOW);
        try {
          const st = await fd.stat();
          if (!st.isFile() || st.size > 16 * 1024 * 1024) throw new LocalError('local.file_size_limit');
          const bytes = await fd.readFile();
          if (bytes.length !== st.size) throw new LocalError('local.file_changed');
          await writeWorkspaceBytes(run.config.workspace, String(args['destination']), bytes, opts, signal);
          return { path: args['destination'], size: bytes.length };
        } finally { await fd.close(); }
      },
    },
    {
      name: 'read_file', description: '读取已授权工作目录内的文本文件，最多 256 KB；返回内容及 SHA-256。', operation: 'read', schema: file, inputSchema: schemaFor(file),
      call: async (run, args, signal) => {
        validateRelativePath(String(args['path']));
        return execute(run, prelude + `const fd=fs.openSync(a.path,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW); try { const st=fs.fstatSync(fd); if(!st.isFile()||st.nlink!==1||st.size>256000) throw Error('limit'); const b=Buffer.alloc(st.size+1); const n=fs.readSync(fd,b,0,b.length,0); if(n!==st.size) throw Error('changed'); const bytes=b.subarray(0,n); out({text:bytes.toString('utf8'),sha256:crypto.createHash('sha256').update(bytes).digest('hex')}); } finally{fs.closeSync(fd);}`, args, signal, false);
      },
    },
    {
      name: 'list_files', description: '列出授权工作目录的一个子目录。空路径表示当前工作目录，不跟随符号链接。', operation: 'read', schema: z.object({ path: z.string().max(2048).default('') }).strict(),
      inputSchema: { type: 'object', properties: { path: { type: 'string' } } },
      call: async (run, args, signal) => {
        if (args['path']) validateRelativePath(String(args['path']));
        return execute(run, prelude + "const entries=fs.readdirSync(a.path||'.',{withFileTypes:true}); out({entries:entries.slice(0,500).map(e=>({name:e.name,type:e.isSymbolicLink()?'link':e.isDirectory()?'directory':'file'})),truncated:entries.length>500});", args, signal, false);
      },
    },
    {
      name: 'write_file', description: '在工作目录创建新文本文件，拒绝覆盖已有文件；修改已有文件使用 edit_file。', operation: 'write', schema: write, inputSchema: schemaFor(write),
      call: async (run, args, signal) => {
        validateRelativePath(String(args['path']));
        return execute(run, prelude + "fs.mkdirSync(path.dirname(a.path),{recursive:true}); fs.writeFileSync(a.path,a.text,{flag:'wx'}); out({ok:true,path:a.path});", args, signal, true);
      },
    },
    {
      name: 'edit_file', description: '按读取时的 SHA-256 修改已有文本文件；内容已变化则拒绝覆盖。ask/assist 需要批准。', operation: 'overwrite', schema: edit, inputSchema: schemaFor(edit),
      call: async (run, args, signal) => {
        validateRelativePath(String(args['path']));
        return execute(run, prelude + "const fd=fs.openSync(a.path,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW); let old; try{const st=fs.fstatSync(fd);if(!st.isFile()||st.nlink!==1||st.size>2000000)throw Error('limit');old=fs.readFileSync(fd);}finally{fs.closeSync(fd);} if(crypto.createHash('sha256').update(old).digest('hex')!==a.expected_sha256)throw Error('conflict'); const temp=a.path+'.'+crypto.randomUUID()+'.tmp'; fs.writeFileSync(temp,a.text,{flag:'wx'}); try{if(crypto.createHash('sha256').update(fs.readFileSync(a.path)).digest('hex')!==a.expected_sha256)throw Error('conflict');fs.renameSync(temp,a.path);out({ok:true,path:a.path});}finally{try{fs.unlinkSync(temp);}catch{}}", args, signal, true);
      },
    },
    {
      name: 'local_shell', description: '在已授权工作目录执行命令；可用 node 执行代码，并通过 require 加载随包 docx、exceljs、pptxgenjs、officeparser 库处理或修改文件。ask/assist 逐次批准且禁止直接联网与工作目录外访问；full 按本机确认范围执行。', operation: 'shell',
      isError: (result) => (result as { code: number }).code !== 0,
      schema: z.object({ command: z.string().min(1).max(32_000), timeout_ms: z.number().int().min(100).max(300_000).default(60_000) }).strict(),
      inputSchema: { type: 'object', properties: { command: { type: 'string' }, timeout_ms: { type: 'integer', minimum: 100, maximum: 300000 } }, required: ['command'] },
      call: async (run, args, signal) => {
        const workspace = await realpath(run.config.workspace);
        const full = run.policy.mode === 'full';
        const home = full ? await realpath(homedir()) : undefined;
        const roots = home ? [workspace, home] : [workspace];
        // Full widens reads/writes to the home directory, but never to paths that would outlive the
        // session that granted it (Q1: denied outright, no per-task approval path).
        const argv = confineDesktop(desktopShell(String(args['command'])), {
          readOnly: [...roots, ...(opts.runtimeReadRoots ?? [])], readWrite: roots,
          brokerPort: opts.brokerPort, network: full,
          deny: [opts.privateRoot, ...(home ? persistenceDenyPaths(home) : [])],
        });
        try {
          return await runOwnedCommand(argv, { cwd: workspace, env: { ...desktopEnvironment(workspace), ...(opts.moduleRoot ? { NODE_PATH: opts.moduleRoot } : {}) }, timeoutMs: Number(args['timeout_ms']), signal });
        } catch (err) {
          // Unreaped descendants are recorded on the run so settling can lock this workspace (Q5).
          if (err instanceof PartialStopError) run.stopResidual = (run.stopResidual ?? 0) + err.residual;
          throw err;
        }
      },
    },
    {
      name: 'publish_artifact', description: '发布已完成的结果文件：保留本机文件卡片，并自动归档到该员工的云盘结果文件目录。仅发布需交付的结果，不发布临时文件。', operation: 'read',
      schema: file.extend({ mime: z.string().regex(/^[a-z0-9.+-]+\/[a-z0-9.+-]+$/i) }),
      inputSchema: { type: 'object', properties: { path: { type: 'string' }, mime: { type: 'string' } }, required: ['path', 'mime'] },
      call: (run, args, signal) => publishSerially(run, async () => {
        signal.throwIfAborted();
        const owner: ArtifactOwner = { tenant: run.task.tenant, account: run.task.account, device: run.task.device, employee: run.task.employee, conversation: run.task.conversation, run: run.task.run };
        const artifact = await opts.artifacts.publish(owner, run.config.workspace, String(args['path']), String(args['mime']), async (path, limit) => {
          // Host never opens the user-controlled source file: OS confinement seals parent-directory races.
          const workspace = await realpath(run.config.workspace);
          const script = prelude + `const fd=fs.openSync(a.path,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);try{const st=fs.fstatSync(fd);if(!st.isFile()||st.nlink!==1||st.size>a.limit)throw Error('limit');const b=Buffer.alloc(st.size+1);let n=0;while(n<b.length){const r=fs.readSync(fd,b,n,b.length-n,n);if(!r)break;n+=r;}const end=fs.fstatSync(fd);if(n!==st.size||end.size!==st.size||end.mtimeMs!==st.mtimeMs||end.ctimeMs!==st.ctimeMs)throw Error('changed');process.stdout.write(b.subarray(0,n).toString('base64'));}finally{fs.closeSync(fd);}`;
          const argv = confineDesktop([process.execPath, '-e', script, JSON.stringify({ path, limit })], { readOnly: [workspace], readWrite: [], brokerPort: opts.brokerPort, deny: [opts.privateRoot] });
          const captured = await runOwnedCommand(argv, { cwd: workspace, env: desktopEnvironment(workspace), signal, maxOutputBytes: Math.ceil(limit / 3) * 4 + 4096 });
          if (captured.code !== 0) throw new LocalError('local.file_refused');
          return Buffer.from(captured.stdout, 'base64');
        }, run.artifacts);
        const snapshot = await opts.artifacts.read(owner, artifact.local_artifact);
        try { inspectArtifact(artifact, snapshot.bytes); } catch { throw new LocalError('local.deliverable_invalid'); }
        if (!run.artifacts.some(item => item.local_artifact.artifact_id === artifact.local_artifact.artifact_id)) {
          run.artifacts.push(artifact);
          run.artifactsChanged?.();
        }
        signal.throwIfAborted();
        return artifact;
      }),
    },
  ];
}
