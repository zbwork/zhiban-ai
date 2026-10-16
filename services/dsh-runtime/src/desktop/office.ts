import { desktopEnvironment } from './platform.js';
import { declareDeliverables, existingDeliveryIssues } from './deliverables.js';
import { basename, join } from 'node:path';
import { realpath } from 'node:fs/promises';
import { z } from 'zod';
import type { DesktopTool } from './broker.js';
import type { ActiveLocalRun } from './supervisor.js';
import { officeCreate, officeCreateInput, officeRead } from './office-schema.js';
import { confineDesktop } from './confinement.js';
import { fingerprint, LocalError } from './ledger.js';
import type { ArtifactMeta, ArtifactOwner } from './artifacts.js';
import { runOwnedCommand } from './process.js';
import { localTools, type LocalToolOptions } from './tools.js';

const mime = { docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation' };
export function officeTools(opts: LocalToolOptions & { packageRoot: string }): DesktopTool[] {
  const creations = new WeakMap<ActiveLocalRun, Map<string, Promise<Record<string, unknown>>>>();
  const invoke = async (run: ActiveLocalRun, operation: 'read' | 'create', args: Record<string, unknown>, signal: AbortSignal) => {
    const workspace = await realpath(run.config.workspace);
    const input = JSON.stringify({ operation, args });
    if (input.length > 4 * 1024 * 1024) throw new LocalError('local.office_input_limit');
    const argv = confineDesktop([process.execPath, '--max-old-space-size=256', join(opts.packageRoot, 'dist/desktop/office-worker.js')], {
      readOnly: [workspace, join(opts.packageRoot, 'dist'), join(opts.packageRoot, 'node_modules')], readWrite: operation === 'create' ? [workspace] : [], brokerPort: opts.brokerPort, deny: [opts.privateRoot],
    });
    const result = await runOwnedCommand(argv, { cwd: workspace, env: desktopEnvironment(workspace), signal, input, timeoutMs: 60000, maxOutputBytes: 256000 });
    if (result.code !== 0) {
      const safe = result.stderr.trim().split('\n').at(-1) ?? '';
      throw new LocalError(['local.office_file_exists', 'local.office_file_missing', 'local.office_access_denied', 'local.office_invalid_format'].includes(safe) ? safe : 'local.office_operation_failed');
    }
    return JSON.parse(result.stdout) as Record<string, unknown>;
  };
  const publish = localTools(opts).find((tool) => tool.name === 'publish_artifact')!;
  const feedback = async (run: ActiveLocalRun, result: Record<string, unknown>) => {
    const delivery_issues = await existingDeliveryIssues(run, opts.artifacts, (result['artifact'] as ArtifactMeta).name);
    return { ...result, delivery_issues, next_step: delivery_issues.length
      ? '文件已创建，但缺少声明的内容或大小要求。请补齐 missing_text 后另存新版本，并更新完整交付清单；不要降低要求或直接结束。'
      : '文件已创建、基本结构检查通过并已发布。无需重复创建或读取相同内容；若已满足用户要求，请直接给出简短交付回复。结构检查不等同于视觉排版验收。' };
  };
  return [
    { name: 'office_read', description: '读取工作目录内 Word、Excel、PPT、PDF、RTF/ODF 文本及表格。支持 offset 分页；不执行宏，不包含扫描件 OCR。', operation: 'read', schema: officeRead, inputSchema: z.toJSONSchema(officeRead) as Record<string, unknown>, call: (run, args, signal) => invoke(run, 'read', args, signal) },
    { name: 'office_create', description: '生成并交付可编辑 Word/Excel/PPT 文件，不能传空参数。Word 必传 kind="docx", path="报告.docx", title="报告", paragraphs=["正文段落"]；Excel 传 kind="xlsx", path, sheets；PPT 传 kind="pptx", path, title, slides。请求批准模式由宿主等待用户批准后写入。拒绝覆盖已有文件；表格不声称执行了公式。', operation: 'write', schema: officeCreate, inputSchema: z.toJSONSchema(officeCreateInput) as Record<string, unknown>,
      call: async (run, args, signal) => {
        signal.throwIfAborted();
        const cache = creations.get(run) ?? new Map<string, Promise<Record<string, unknown>>>();
        creations.set(run, cache);
        const key = fingerprint(args);
        const existing = cache.get(key);
        if (existing) {
          const result = await existing;
          const owner: ArtifactOwner = { tenant: run.task.tenant, account: run.task.account, device: run.task.device, employee: run.task.employee, conversation: run.task.conversation, run: run.task.run };
          await opts.artifacts.read(owner, (result['artifact'] as ArtifactMeta).local_artifact);
          signal.throwIfAborted();
          return feedback(run, result);
        }
        const pending = (async () => {
          const result = await invoke(run, 'create', args, signal);
          const artifact = await publish.call(run, { path: args['path'], mime: mime[args['kind'] as keyof typeof mime] }, signal);
          // A failed attempt must not leave a dangling required deliverable.
          declareDeliverables(run, [...(run.deliverables ?? []), { name: basename(String(args['path'])), mime: mime[args['kind'] as keyof typeof mime], min_bytes: 1, text_contains: [] }]);
          return { ...result, artifact, structure_verified: true };
        })();
        cache.set(key, pending);
        try { return await feedback(run, await pending); } catch (error) { cache.delete(key); throw error; }
      },
      isError: result => ((result as { delivery_issues: unknown[] }).delivery_issues).length > 0,
    },
  ];
}
