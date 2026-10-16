import type { FastifyBaseLogger } from 'fastify';
import type { CordisCache } from '../assemble/cordis.js';
import type { BusClient } from '../backchannel/bus-client.js';
import type { RuntimeConfig } from '../config.js';
import type { IdentityRegistry } from '../identity/identity.js';
import type { RuntimeMetrics } from '../obs/metrics.js';
import type { HistoryStore } from '../history/history.js';
import type { ReadIsolation } from '../pool/read-isolation.js';
import type { IdempotencyCache, SkillCarrier } from '../skills/skills.js';
import type { ProcessPool } from '../pool/process-pool.js';
import type { SessionStore } from '../sessions/session-store.js';
import type { AgentStore } from '../store/agent-store.js';

/** 北侧路由可见的全部依赖；路由层不直接碰南侧 SDK。 */
export interface AppDeps {
  config: RuntimeConfig;
  store: AgentStore;
  cordis: CordisCache;
  pool: ProcessPool;
  sessions: SessionStore;
  identity: IdentityRegistry;
  metrics: RuntimeMetrics;
  isolation: ReadIsolation;
  history: HistoryStore;
  skills: SkillCarrier;
  idempotency: IdempotencyCache;
  /** 反向通道（配齐 DSH_RUNTIME_BUS_* 才有）；有则每会话装配插入 mcp-client 工具桥 */
  bus?: BusClient;
  /** 平台默认输出风格（assets/skills/zhiban-output-style），并入所有会话的系统提示 */
  outputStyle: string;
  log: FastifyBaseLogger;
}
