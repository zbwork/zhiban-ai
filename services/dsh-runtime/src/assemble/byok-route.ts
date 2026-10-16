/**
 * 员工自带模型服务（ADR-0037 dsh 消费端）：把 Bus 登记时带来的 metadata.model_service 渲染成
 * @deepseek-ai/dsh-llm-pi-ai 的一条手工声明路由 `byok`。
 *
 * - 装配文件按员工缓存、落盘、多会话共用 → baseURL 指向回环代理的 by-key 入口（不带 session_id），
 *   真实 base_url 与 key 都不进文件；子进程 env 里的 DEEPSEEK_API_KEY 仍是会话假 key，代理换真 key。
 * - models 只声明该员工的 model_id：pi-ai 对未声明模型直接 UNKNOWN_MODEL，等于"选了什么就只能用什么"。
 */
import type { CordisEntry } from './cordis.js';
import type { AgentRecord } from '../store/agent-store.js';

export const BYOK_PROVIDER = 'byok';
export const BYOK_ENTRY_ID = 'llm-byok';

export type ModelServiceEndpointType = 'openai-compatible' | 'anthropic-messages';
export interface ModelService {
  endpoint_type: ModelServiceEndpointType;
  base_url: string;
  model_id: string;
}

export class ModelServiceError extends Error {
  constructor(
    readonly reason: 'unsupported_endpoint_type',
    detail: string,
  ) {
    super(detail);
    this.name = 'ModelServiceError';
  }
}

const PROTOCOL_BY_ENDPOINT: Record<ModelServiceEndpointType, string> = {
  'openai-compatible': 'openai-completions',
  'anthropic-messages': 'anthropic-messages',
};

const str = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');

/** 登记 metadata 里的 model_service；缺失/不完整 = 不是 byok 员工。endpoint_type 非法则抛错（登记接受、spawn 拒绝）。 */
export function modelServiceOf(agent: Pick<AgentRecord, 'metadata'>): ModelService | undefined {
  const raw = agent.metadata?.['model_service'];
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return undefined;
  const r = raw as Record<string, unknown>;
  const endpointType = str(r['endpoint_type']);
  const baseUrl = str(r['base_url']);
  const modelId = str(r['model_id']);
  if (!baseUrl || !modelId) return undefined;
  if (!(endpointType in PROTOCOL_BY_ENDPOINT)) {
    throw new ModelServiceError('unsupported_endpoint_type', `model_service.endpoint_type ${endpointType || '(empty)'} is not supported`);
  }
  return { endpoint_type: endpointType as ModelServiceEndpointType, base_url: baseUrl, model_id: modelId };
}

export function byokRouteEntry(ms: ModelService, opts: { bridgeBaseUrl: string; compat: Record<string, unknown>; maxTokens: number; input?: Array<'text' | 'image'> }): CordisEntry {
  const api = PROTOCOL_BY_ENDPOINT[ms.endpoint_type];
  return {
    id: BYOK_ENTRY_ID,
    name: '@deepseek-ai/dsh-llm-pi-ai',
    config: {
      providers: {
        [BYOK_PROVIDER]: {
          displayName: 'Model service (BYOK)',
          apiKeyEnv: 'DEEPSEEK_API_KEY',
          api,
          baseURL: `${opts.bridgeBaseUrl.replace(/\/+$/, '')}/llmgw/v1/by-key`,
          ...(opts.input?.includes('image') ? { maxRequestImageBytes: 4_000_000 } : {}),
          ...(api === 'openai-completions' ? { compat: { ...opts.compat } } : {}),
          models: [{ id: ms.model_id, maxTokens: opts.maxTokens, ...(opts.input ? { input: opts.input } : {}) }],
        },
      },
    },
  };
}
