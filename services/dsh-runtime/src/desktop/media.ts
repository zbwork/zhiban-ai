import { realpath } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { z } from 'zod';
import type { DesktopTool } from './broker.js';
import { validateRelativePath } from './artifacts.js';
import { confineDesktop } from './confinement.js';
import { desktopEnvironment } from './platform.js';
import { PartialStopError, runOwnedCommand } from './process.js';
import { LocalError } from './ledger.js';

export function mediaTool(opts: { executable: string; privateRoot: string; brokerPort: number; home?: string }): DesktopTool {
  const schema = z.object({
    action: z.enum(['pdf-info', 'pdf-page', 'video-info', 'video-frame']),
    scope: z.enum(['workspace', 'home']).default('workspace'),
    path: z.string().min(1).max(2048),
    page: z.number().int().min(1).max(5000).optional(),
    seconds: z.number().min(0).max(86400).optional(),
    output: z.string().min(1).max(2048).optional(),
  }).strict();
  return { name: 'render_local_media', operation: 'shell', schema, inputSchema: z.toJSONSchema(schema),
    description: 'macOS 本地 PDF 页面与视频关键帧。先 pdf-info/video-info 查询页数或秒数，再 pdf-page（page 从 1 开始）或 video-frame（seconds）生成长边最多 1600 的 PNG。path 是 scope 下相对路径；output 必须是当前工作目录内新 PNG 的相对路径，父目录须已存在。返回实际页码/时间戳，随后用 view_local_image 查看。读取上限 512 MB，单次 30 秒。不支持 PPT 原生渲染或音频转录。沿用本轮文件与命令授权。',
    call: async (run, args, signal) => {
      const a = schema.parse(args); validateRelativePath(a.path);
      const workspace = await realpath(run.config.workspace);
      const base = a.scope === 'home' ? await realpath(opts.home ?? homedir()) : workspace;
      const render = a.action === 'pdf-page' || a.action === 'video-frame';
      const argv = [opts.executable, a.action, join(base, a.path)];
      if (render) {
        if (!a.output || !a.output.endsWith('.png') || (a.action === 'pdf-page' ? a.page === undefined : a.seconds === undefined)) throw new LocalError('local.invalid_tool_arguments');
        validateRelativePath(a.output);
        argv.push(String(a.action === 'pdf-page' ? a.page : a.seconds), join(workspace, a.output));
      }
      const command = confineDesktop(argv, { readOnly: [base, opts.executable], readWrite: render ? [workspace] : [], deny: [opts.privateRoot], brokerPort: opts.brokerPort, mediaDecode: a.action === 'video-frame' });
      const result = await runOwnedCommand(command, { cwd: workspace, env: desktopEnvironment(workspace), signal, timeoutMs: 30000, maxOutputBytes: 100000, limits: { cpuSeconds: 20, maxRssMb: 768, maxProcesses: 8, intervalMs: 250 } }).catch((error: unknown) => {
        if (error instanceof PartialStopError) run.stopResidual = (run.stopResidual ?? 0) + error.residual;
        throw error;
      });
      if (result.code !== 0) throw new LocalError('local.media_render_failed');
      try {
        return { ...JSON.parse(result.stdout) as Record<string, unknown>, ...(render ? { output: a.output } : {}) };
      } catch { throw new LocalError('local.media_render_failed'); }
    },
  };
}
