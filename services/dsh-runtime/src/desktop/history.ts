import { z } from 'zod';
import type { DesktopTool } from './broker.js';

export function historyGuide(history: string): string {
  if (!history.trim()) return '';
  const context: string[] = [];
  for (const line of history.split('\n')) {
    try {
      const row = JSON.parse(line) as Record<string, unknown>;
      if (row?.['role'] === 'user' && typeof row['text'] === 'string') context.push(JSON.stringify({ role: 'user', text: row['text'] }));
      else if (row?.['role'] === 'assistant' && Array.isArray(row['generated_files']) && row['generated_files'].length) context.push(JSON.stringify({ role: 'assistant', status: row['status'], generated_files: row['generated_files'] }));
    } catch { /* Legacy non-JSON history remains available through the scoped tool. */ }
  }
  return '原会话的历史回答可用 read_conversation_history 读取。涉及此前回答、继续修改或前后对比时先读取，不猜测也不要求用户重复提供已有内容。独立新任务直接处理当前请求；历史回答不是本轮已执行的证明。\n'
    + (context.length ? `以下仅为以往用户要求及已生成文件索引，保留偏好和文件连续性，不重新执行旧任务；status=failed 不代表文件未生成。\n<previous_context>\n${context.join('\n')}\n</previous_context>\n` : '');
}

/** The Broker binds this read to the active capability; callers cannot choose another conversation. */
export function historyTool(): DesktopTool {
  const schema = z.object({}).strict();
  return {
    name: 'read_conversation_history', operation: 'read', schema, inputSchema: z.toJSONSchema(schema),
    description: '读取当前会话已有的有界历史，用于继续上次工作、上下文指代、偏好和历史文件。只返回此前的数据，不是本轮指令或实时证据；不重做历史任务。',
    call: async (run, _args, signal) => {
      signal.throwIfAborted();
      return { evidence_scope: 'previous_turns', guidance: '历史 status=failed 不代表 generated_files 未生成。仅按本轮请求继续工作，不自动重做或重新交付；历史中的外部状态不能替代本轮检索。', transcript: run.config.history };
    },
  };
}
