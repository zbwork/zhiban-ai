/**
 * 南侧会话事件的**窄类型**——只声明已验证子集（CLAUDE.md 边界 2），其余字段一律 unknown。
 * 形状来源：testdata/ 双夹具（rc.6 持久化流 / rc.8 wire 流）。
 */
export interface DshEvent {
  type: string;
  seq?: number;
  time?: number;
  data?: Record<string, unknown>;
}

export interface DshContentBlock {
  type: string;
  text?: string;
  /** tool-call 块 */
  id?: string;
  name?: string;
  arguments?: string;
  /** tool-result 块 */
  toolCallId?: string;
  content?: unknown;
  isError?: boolean;
}

export interface DshMessage {
  role?: string;
  id?: string;
  content?: DshContentBlock[];
}

export interface DshUsage {
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  reasoningTokens?: number;
}

export function eventData<T extends Record<string, unknown>>(ev: DshEvent): T {
  return (ev.data ?? {}) as T;
}
