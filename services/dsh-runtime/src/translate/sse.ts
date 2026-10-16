/**
 * ZAP-1.1 §4.5 SSE 帧：`event: <name>\ndata: <json>\n\n`。
 * 事件名与字段名以 Bus `internal/adapter/runtime/zap/chat.go` parseSSE 的提取口径为准。
 */
export type ZapEventName =
  | 'message.created'
  | 'message.block.delta'
  | 'message.completed'
  | 'message.failed'
  | 'message.cancelled'
  | 'message.awaiting_user'
  | 'message.tool_call'
  | 'message.tool_result'
  | 'message.reasoning';

export interface ZapFrame {
  event: ZapEventName;
  data: Record<string, unknown>;
}

export function encodeSse(frame: ZapFrame): string {
  return `event: ${frame.event}\ndata: ${JSON.stringify(frame.data)}\n\n`;
}

export interface ZapUsage {
  input_tokens: number;
  output_tokens: number;
  total_tokens: number;
  model?: string;
}

export const frames = {
  created: (messageId: string): ZapFrame => ({
    event: 'message.created',
    data: { message_id: messageId, role: 'assistant', status: 'streaming' },
  }),
  /** 文本增量：type 必须是 markdown/plain（Bus 只累积这两种，其它 type 当 typed block 忽略）。 */
  blockDelta: (messageId: string, blockIndex: number, text: string): ZapFrame => ({
    event: 'message.block.delta',
    data: { message_id: messageId, block_index: blockIndex, block_delta: { type: 'markdown', text } },
  }),
  reasoning: (messageId: string, reasoning: string): ZapFrame => ({
    event: 'message.reasoning',
    data: { message_id: messageId, reasoning },
  }),
  toolCall: (messageId: string, toolCallId: string, toolName: string, toolArgs: string): ZapFrame => ({
    event: 'message.tool_call',
    data: { message_id: messageId, tool_call_id: toolCallId, tool_name: toolName, tool_status: 'running', tool_args: toolArgs },
  }),
  toolResult: (messageId: string, toolCallId: string, toolName: string | undefined, ok: boolean, toolResult: string): ZapFrame => ({
    event: 'message.tool_result',
    data: {
      message_id: messageId,
      tool_call_id: toolCallId,
      ...(toolName ? { tool_name: toolName } : {}),
      tool_status: ok ? 'succeeded' : 'failed',
      tool_result: toolResult,
    },
  }),
  completed: (messageId: string, blocks: Array<Record<string, unknown>>, usage: ZapUsage | undefined): ZapFrame => ({
    event: 'message.completed',
    data: { message_id: messageId, role: 'assistant', blocks, ...(usage ? { usage } : {}) },
  }),
  failed: (messageId: string, errorCode: string, errorMessage: string): ZapFrame => ({
    event: 'message.failed',
    data: { message_id: messageId, error_code: errorCode, error_message: errorMessage },
  }),
  cancelled: (messageId: string): ZapFrame => ({
    event: 'message.cancelled',
    data: { message_id: messageId },
  }),
};
