import { basename } from 'node:path';
import { z } from 'zod';
import { type DesktopTool } from './broker.js';
import { LocalError, fingerprint, type LocalLedger, type LocalTask } from './ledger.js';
import { validateRelativePath } from './artifacts.js';
import { declareDeliverables } from './deliverables.js';
import { localTools, type LocalToolOptions } from './tools.js';
import { writeWorkspaceBytes } from './workspace-files.js';

export const imageInput = z.object({
  prompt: z.string().trim().min(1).max(4000),
  path: z.string().min(1).max(2048).refine((path) => { try { validateRelativePath(path); return path.toLowerCase().endsWith('.png'); } catch { return false; } }, '必须是工作目录内的相对 PNG 路径'),
  model: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/).default('gpt-image-2'),
  size: z.enum(['1024x1024', '1536x1024', '1024x1536']).default('1024x1024'),
}).strict();
interface ImageOptions extends LocalToolOptions {
  ledger: LocalLedger;
  generate(task: LocalTask, body: Record<string, unknown>, signal: AbortSignal): Promise<Buffer>;
}
export function imageTools(opts: ImageOptions): DesktopTool[] {
  const publish = localTools(opts).find((tool) => tool.name === 'publish_artifact')!;
  return [{ name: 'image_generate', operation: 'write',
    description: '通过当前任务模型平台真实生成并交付一张图片。必填 prompt（图片描述）和 path（新 PNG 相对路径）；默认图片模型 gpt-image-2，推理模型保持不变，未指定图片模型时省略 model 字段即可。自动保存、校验并发布图片卡片。仅传生图描述，不读取密钥或上传本机文件；失败须说明原因，不用代码绘图/目录搜索代替，不更换参数盲目重试付费操作。',
    schema: imageInput, inputSchema: z.toJSONSchema(imageInput) as Record<string, unknown>,
    call: async (run, args, signal) => {
      const input = imageInput.parse(args);
      const request = { model: input.model, prompt: input.prompt, size: input.size };
      const operation = fingerprint({ run: run.task.run, ...request });
      signal.throwIfAborted();
      const state = opts.ledger.prepareMedia(operation, run.task.run, request);
      if (state === 'prepared') opts.ledger.beginMedia(operation);
      if (state === 'failed') throw new LocalError('local.image_unavailable');
      // All repeated calls use the same durable Bus operation, even after local state loss.
      let bytes: Buffer;
      try {
        bytes = await opts.generate(run.task, { ...request, operation_id: operation }, signal);
        signal.throwIfAborted();
        if (bytes.length < 33 || bytes.length > 12 * 1024 * 1024 || bytes.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a') throw new LocalError('local.image_invalid');
      } catch (err) {
        if (state !== 'completed') opts.ledger.settleMedia(operation, 'unknown');
        throw err;
      }
      // Matching content can recover an interrupted write; different content is never overwritten.
      await writeWorkspaceBytes(run.config.workspace, input.path, bytes, opts, signal, true);
      const artifact = await publish.call(run, { path: input.path, mime: 'image/png' }, signal);
      // Only successful publication is an automatic deliverable declaration.
      declareDeliverables(run, [...(run.deliverables ?? []), { name: basename(input.path), mime: 'image/png', min_bytes: 1, text_contains: [] }]);
      if (state !== 'completed') opts.ledger.settleMedia(operation, 'completed');
      return { model: input.model, size: input.size, path: input.path, artifact };
    },
  }];
}
