/**
 * Fastify 装配：北侧唯一出口。所有 /zap/v1/* 路由挂 Bearer 守卫；
 * 根 /healthz 免鉴权供编排探活。错误统一落 zap.* 词表。
 */
import Fastify, { type FastifyInstance } from 'fastify';
import { SessionCgroups } from '../pool/cgroup.js';
import { CordisCache } from '../assemble/cordis.js';
import { loadOutputStyle } from '../assemble/style.js';
import { registerBridgeRoutes } from '../backchannel/bridge.js';
import { registerLlmGatewayRoutes } from '../llmgw/proxy.js';
import { BusClient } from '../backchannel/bus-client.js';
import { packageRoot, type RuntimeConfig } from '../config.js';
import { MemoryHistory, PgHistory, type HistoryStore } from '../history/history.js';
import { IdentityRegistry } from '../identity/identity.js';
import { RuntimeMetrics } from '../obs/metrics.js';
import { ProcessPool } from '../pool/process-pool.js';
import { ReadIsolation, SYSTEM_READ_ONLY } from '../pool/read-isolation.js';
import { SessionStore } from '../sessions/session-store.js';
import { IdempotencyCache, SkillCarrier, SkillPackages } from '../skills/skills.js';
import { AgentStore } from '../store/agent-store.js';
import { makeBearerGuard } from './auth.js';
import type { AppDeps } from './deps.js';
import { ZapError, zapErrors } from './errors.js';
import { CONSOLE_HTML } from './console-page.js';
import { registerZapRoutes } from './routes.js';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

export type { AppDeps } from './deps.js';

/** 组装全部依赖（生产与测试同一条路径；测试只换 config）。 */
export async function buildApp(config: RuntimeConfig): Promise<FastifyInstance> {
  const app = Fastify({ logger: { level: config.logLevel }, bodyLimit: 4 * 1024 * 1024 });
  // Bus 的 cancel / delete 带 `Content-Type: application/json` 但不带 body；Fastify 默认对此返 400。
  // 空 body 一律当 {}，其余按 JSON 解析（解析失败仍走 400 zap.invalid_request）。
  app.removeContentTypeParser('application/json');
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (_req, body, done) => {
    const text = typeof body === 'string' ? body : body.toString('utf8');
    if (text.trim() === '') {
      done(null, {});
      return;
    }
    try {
      done(null, JSON.parse(text));
    } catch {
      const err = new Error('invalid JSON body') as Error & { statusCode?: number };
      err.statusCode = 400;
      done(err, undefined);
    }
  });
  const store = new AgentStore(config.agentsConfigDir);
  const loaded = await store.load();
  if (loaded.skipped.length > 0) app.log.warn({ skipped: loaded.skipped }, 'agent configs skipped (unreadable)');
  const cordis = new CordisCache(
    {
      baseCordisPath: config.baseCordisPath,
      cordisDir: config.cordisDir,
      sessionsRoot: config.sessionsRoot,
      packageNodeModules: resolve(packageRoot, 'node_modules'),
      ...(existsSync(config.platformSkillsDir) ? { platformSkillsDir: config.platformSkillsDir } : {}),
      toolDefaultDeny: config.toolDefaultDeny,
    },
    store,
  );
  // 部署级默认关闭集是安全策略，必须可见：默认关掉了什么、以及怎么给单个员工放开。
  if (config.toolDefaultDeny.length > 0) {
    app.log.info(
      { default_deny: config.toolDefaultDeny },
      'tool default-deny active — agents without an explicit tools.allow do NOT get these tools (set DSH_RUNTIME_TOOL_DEFAULT_DENY= to disable)',
    );
  } else {
    app.log.warn({}, 'tool default-deny is EMPTY — every agent gets bash unless it sets tools.deny; not recommended for customer-facing deployments');
  }
  if (!existsSync(config.platformSkillsDir)) app.log.warn({ dir: config.platformSkillsDir }, 'platform skills dir missing — run scripts/port-openclaw-skills.sh');
  await cordis.init();
  const metrics = new RuntimeMetrics();
  // 读隔离（P2 门禁）：required 时探针不过直接抛错 → 进程不起（fail-closed）。
  const isolation = await ReadIsolation.init({
    mode: config.readIsolation,
    readOnly: [
      ...SYSTEM_READ_ONLY,
      process.execPath,
      resolve(packageRoot, 'node_modules'),
      resolve(packageRoot, 'dist'),
      resolve(packageRoot, 'assets'),
      resolve(packageRoot, 'package.json'),
      config.agentBin,
      config.baseCordisPath,
    ],
    probeDir: resolve(config.cacheDir, 'isolation-probe'),
    // durable 卷（共享存储时通常是 NFS/NAS）也要过探针：租户工作区就在这上面
    probeDirs: [resolve(config.tenantsDir, '.isolation-probe')],
    logger: app.log,
  });
  // 每会话 cgroup 硬闸：内核实时执行，越界 OOM 只落在该会话（看门狗是 2 秒采样的软闸，拦不住突发分配）。
  // fail-open：委派不可用只 warn 并退回看门狗，不阻止启动（与读隔离的 fail-closed 刻意不同，见 pool/cgroup.ts）。
  const cgroups = config.cgroupRoot === '' ? SessionCgroups.disabled(app.log) : await SessionCgroups.init({ root: config.cgroupRoot, logger: app.log });
  const pool = new ProcessPool({
    agentBin: config.agentBin,
    idleTimeoutMs: config.idleTimeoutMs,
    maxProcesses: config.maxProcesses,
    maxQueue: config.maxQueue,
    queueTimeoutMs: config.queueTimeoutMs,
    maxPerTenant: config.maxProcessesPerTenant,
    maxPerUser: config.maxProcessesPerUser,
    maxQueuePerUser: config.maxQueuePerUser,
    limits: {
      cpuSeconds: config.processCpuSeconds,
      nofile: config.processNofile,
      maxRssMb: config.processMaxRssMb,
      maxProcesses: config.processMaxProcs,
      workspaceQuotaMb: config.workspaceQuotaMb,
      tenantQuotaMb: config.tenantQuotaMb,
      minFreeMb: config.minFreeMb,
      checkIntervalMs: config.limitCheckIntervalMs,
    },
    spawnTimeoutMs: config.spawnTimeoutMs,
    dshHome: resolve(config.cacheDir, 'dsh-home'),
    logger: app.log,
    metrics,
    confine: (argv, grants) => isolation.confine(argv, grants),
    cgroups,
    cpuPercent: config.processCpuPercent,
  });
  const sessions = new SessionStore(config.sessionTtlSeconds);
  const identity = new IdentityRegistry();
  metrics.bindPool(() => pool.stats());
  metrics.bindSessions(() => sessions.size());
  // 会话历史：配了 DSN 就双写 PG（连不上启动即失败），否则仅内存 transcript（重启即失，日志 warn）。
  let history: HistoryStore;
  if (config.pgDsn) {
    const pgHistory = new PgHistory(config.pgDsn, app.log, metrics);
    await pgHistory.init();
    history = pgHistory;
  } else {
    app.log.warn('DSH_RUNTIME_PG_DSN not set — session history is in-memory only (lost on restart, no cross-replica recovery)');
    history = new MemoryHistory();
  }
  const skills = new SkillCarrier({
    sessionsDir: config.skillsDir,
    packages: new SkillPackages({ dir: config.skillPackagesDir, maxBytes: config.skillPackageMaxBytes, logger: app.log, metrics }),
    logger: app.log,
  });
  const idempotency = new IdempotencyCache();
  let bus: BusClient | undefined;
  if (config.busBaseUrl && config.busClientId && config.busClientSecret) {
    bus = new BusClient({ baseUrl: config.busBaseUrl, clientId: config.busClientId, clientSecret: config.busClientSecret, logger: app.log });
    app.log.info({ bus_base_url: config.busBaseUrl, bridge_base_url: config.bridgeBaseUrl }, 'backchannel enabled (runtime_access) — platform tools bridged into agent sessions');
  } else {
    app.log.warn('DSH_RUNTIME_BUS_BASE_URL / CLIENT_ID / CLIENT_SECRET not all set — platform tools (kb/memory/a2a) NOT available to agents');
  }
  const outputStyle = loadOutputStyle(config.platformSkillsDir);
  const deps: AppDeps = { config, store, cordis, pool, sessions, identity, metrics, isolation, history, skills, idempotency, outputStyle, ...(bus ? { bus } : {}), log: app.log };
  // LLM 网关归一化代理（回环）：抹平公司网关与 DeepSeek SDK 之间的两处协议差异（src/llmgw/normalize.ts）
  if (config.llmGatewayNormalize) {
    registerLlmGatewayRoutes(app, {
      // 凭据经纪（P1-c）：子进程只拿会话级假 key，真凭据在这里换上，从不出 shim 进程。
      brokerFor: (sid: string) => {
        const rec = sessions.get(sid);
        if (!rec) return undefined;
        const creds = rec.conversationModelBinding ?? identity.credentialsFor(rec.tenant_id, rec.user_id, rec.llmMemberKeyOnly ? undefined : rec.agent_key);
        if (!creds?.base_url) return undefined;
        return { upstream: creds.base_url, ...(rec.llmKey ? { sessionKey: rec.llmKey, apiKey: creds.api_key } : {}) };
      },
      // by-key：员工自带模型服务的 pi-ai 路由（装配按员工缓存，baseURL 不能带 session_id），按假 key 反查会话
      brokerForKey: (key: string) => {
        const rec = sessions.findByLlmKey(key);
        if (!rec?.llmKey) return undefined;
        const creds = rec.conversationModelBinding ?? identity.credentialsFor(rec.tenant_id, rec.user_id, rec.llmMemberKeyOnly ? undefined : rec.agent_key);
        if (!creds?.base_url) return undefined;
        return { sessionId: rec.session_id, upstream: creds.base_url, sessionKey: rec.llmKey, apiKey: creds.api_key };
      },
      log: app.log,
      timeoutMs: config.turnTimeoutMs,
    });
  } else {
    // 直连上游 = 代理不在链路上 = 无处把假 key 换成真 key，只能把账号级凭据原样塞进 agent 进程 env。
    // agent 能出网 ⇒ 它能把这个 key 发出去。生产不要关这个开关。
    app.log.warn(
      {},
      'DSH_RUNTIME_LLM_GATEWAY_NORMALIZE=0 — agent processes receive the REAL per-account LLM key in their env (no broker in the path); they can exfiltrate it since egress is allowed',
    );
  }
  // 会话工具桥（回环 + 每会话 key；不走 Bus Bearer）
  if (bus) {
    registerBridgeRoutes(app, {
      bus,
      sessions,
      log: app.log,
      imageModel: config.imageModel,
      imageTimeoutMs: config.imageTimeoutMs,
      // Only scoped credentials from /instances; never fall back to a shared key.
      imageCredentials: (rec) => {
        const acct = identity.credentialsFor(rec.tenant_id, rec.user_id, rec.llmMemberKeyOnly ? undefined : rec.agent_key);
        if (acct?.base_url && acct.api_key) return { base_url: acct.base_url, api_key: acct.api_key };
        return undefined;
      },
      workspaceFor: (rec) => resolve(config.tenantsDir, rec.tenant_id, rec.user_id),
    });
  }

  const sweeper = setInterval(() => {
    for (const rec of sessions.sweep()) {
      void pool.kill(rec.session_id, 'session_expired');
      void skills.removeSession(rec.session_id);
      void cordis.removeSession(rec.agent_key, { tenant: rec.tenant_id, user: rec.user_id, session: rec.session_id });
    }
  }, 60_000);
  sweeper.unref();
  app.addHook('onClose', async () => {
    clearInterval(sweeper);
    await pool.shutdown();
    await history.close();
  });

  app.setErrorHandler((err, req, reply) => {
    if (err instanceof ZapError) {
      void reply.status(err.httpStatus).send(err.toBody());
      return;
    }
    const fe = err as { validation?: unknown; statusCode?: number; message?: string };
    if (fe.validation || fe.statusCode === 400 || fe.statusCode === 413 || fe.statusCode === 415) {
      void reply.status(fe.statusCode ?? 400).send(zapErrors.invalidRequest(fe.message ?? 'invalid request').toBody());
      return;
    }
    req.log.error({ err }, 'unhandled error');
    void reply.status(500).send(zapErrors.internal().toBody());
  });
  app.setNotFoundHandler((_req, reply) => {
    void reply.status(404).send(zapErrors.notFound().toBody());
  });

  app.get('/healthz', async () => ({
    status: 'ok',
    version: config.version,
    agents: store.list().length,
    sessions: sessions.size(),
    pool: pool.stats(),
    read_isolation: isolation.status(),
    // 运维要能一眼看出资源硬闸在不在（不 armed 时崩塌半径 = 整个容器，见方案 §3）
    cgroups: { armed: cgroups.available, detail: cgroups.detail },
    history: history.kind,
    llm_credential_policy: config.requireAccountLlmKey ? 'account_required' : 'service_fallback',
  }));
  // Prometheus 抓取口：只有池/链路聚合指标，无租户/员工标签，无正文；与 /healthz 同属编排面，免鉴权。
  app.get('/metrics', async (_req, reply) => reply.type('text/plain; version=0.0.4; charset=utf-8').send(metrics.render()));

  if (config.devConsole) {
    app.get('/', async (_req, reply) => reply.type('text/html; charset=utf-8').send(CONSOLE_HTML));
    app.log.warn('dev console enabled at GET / (DSH_RUNTIME_DEV_CONSOLE=1) — do not enable in production');
  }

  await app.register(
    async (zap) => {
      zap.addHook('preHandler', makeBearerGuard(config.apiKey));
      zap.get('/healthz', async () => ({ status: 'ok', protocol_version: 'zap-1.1', version: config.version, agents: store.list().map((a) => a.agent_key) }));
      registerZapRoutes(zap, deps);
    },
    { prefix: '/zap/v1' },
  );
  return app;
}
