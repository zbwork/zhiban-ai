/**
 * 服务配置：全部来自环境变量（容器友好），集中在此解析一次。
 *
 * 命名前缀 DSH_RUNTIME_* 只属于本 shim；spawn 子进程时这些变量**不会**下传
 * （见 pool/child-env.ts），避免 shim 配置泄进 agent 进程。
 */
import { existsSync } from 'node:fs';
import { parseToolDefaultDeny, type LogicalTool } from './assemble/tool-gate.js';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export interface RuntimeConfig {
  host: string;
  port: number;
  /** Bus → runtime 的 Bearer（runtime API key）。必填。 */
  apiKey: string;
  logLevel: string;
  /** 数据根目录：config/agents、tenants/<t>/<u> 工作区、cache/（可丢弃） */
  dataDir: string;
  /** dsh-jsonrpc-agent 可执行入口（node 脚本） */
  agentBin: string;
  /** 最小装配模板（assets/agent.cordis.yml） */
  baseCordisPath: string;
  /** 平台内置技能根（assets/skills，从 OpenClaw 平移；空目录/不存在则不挂） */
  platformSkillsDir: string;
  defaultProvider: string;
  defaultModel: string;
  /** 会话进程空闲回收（ms） */
  idleTimeoutMs: number;
  /** 同时存活的会话进程上限 */
  maxProcesses: number;
  /** 满员且无可驱逐进程时允许 FIFO 排队的请求数；0 = 不排队立即拒绝 */
  maxQueue: number;
  /** 排队等待名额上限（ms），超时 → zap.capacity_exhausted */
  queueTimeoutMs: number;
  /** 按租户 / 按用户的并发进程上限（0=不限）；超限只排队或驱逐自己的空闲进程，不挤占别人 */
  maxProcessesPerTenant: number;
  maxProcessesPerUser: number;
  /** 单用户最多占用的队列名额（0=不限） */
  maxQueuePerUser: number;
  /** 每进程树 RSS 上限 MB（看门狗 kill，reason=rss_limit；0=不限） */
  processMaxRssMb: number;
  /** 每进程树累计 CPU 秒上限（看门狗 kill；RLIMIT_CPU 兜底 2 倍；0=不限） */
  processCpuSeconds: number;
  /** 每进程树进程数上限（fork 炸弹 / 线程风暴；0=不限） */
  processMaxProcs: number;
  /** 每进程 RLIMIT_NOFILE（0=不设） */
  processNofile: number;
  /**
   * 每会话 cgroup 硬闸的委派子树（见 pool/cgroup.ts）。空串 = 关闭（只留看门狗软闸）。
   * Linux 缺省 `/sys/fs/cgroup/agents`；非 Linux 恒为空。探测不过 fail-open：只 warn 不阻止启动。
   */
  cgroupRoot: string;
  /** cgroup cpu.max 配额，占单核百分比（100=一个核；0=不限）。与看门狗的 cpuSeconds（累计量）语义不同 */
  processCpuPercent: number;
  /**
   * 部署级默认关闭的逻辑工具（员工未在 tools.allow 里显式点名时生效）。
   * `DSH_RUNTIME_TOOL_DEFAULT_DENY`，缺省 `bash`（用户 2026-08-25 拍板：客户可见员工一律 deny bash）。
   * 显式设为空串 = 不默认关任何工具（回滚用）。
   */
  toolDefaultDeny: LogicalTool[];
  /** 用户工作区磁盘软配额 MB（超出：本轮 kill + 新消息 spawn 前拒绝；0=不限） */
  workspaceQuotaMb: number;
  /** 租户合计磁盘软配额 MB（该租户全部用户可写根之和；0=不限） */
  tenantQuotaMb: number;
  /** 数据卷剩余空间下限 MB（低于此拒开新轮 zap.disk_full；0=不查） */
  minFreeMb: number;
  /** 资源看门狗采样间隔 ms */
  limitCheckIntervalMs: number;
  /** spawn + initialize 握手上限（ms） */
  spawnTimeoutMs: number;
  /** 单轮（一次 session/prompt 到 turn/end）上限（ms）；与 Bus DefaultChatTimeout 对齐 */
  turnTimeoutMs: number;
  /** 会话记录 TTL（秒） */
  sessionTtlSeconds: number;
  /** 服务版本（runtime_card.version） */
  version: string;
  /** 开发测试台（GET / 返回一个网页控制台）。仅本地/联调开，生产关。 */
  devConsole: boolean;
  /**
   * 多租户读隔离（Landlock 进程级 allow-list，见 pool/read-isolation.ts）。
   * `required`（Linux 默认）：启动时探针不过即拒绝启动；`off`（macOS 默认）：仅开发，日志 warn。
   */
  readIsolation: 'required' | 'off';
  /**
   * 会话历史 PG DSN（权威历史，双写；空 = 仅内存 transcript，重启即失）。独立库/schema，禁止指向 agent_bus。
   */
  pgDsn: string;
  /**
   * 持久根（多副本必须是共享 RWX 卷）：员工配置 + 用户工作区。丢了 = 员工不认识 / 用户文件没了。
   * DSH_RUNTIME_DURABLE_DIR，缺省 = dataDir。
   */
  durableDir: string;
  /** 员工配置库根：<durable>/config/agents/<agent_key>/{agent.yml,skills/} */
  agentsConfigDir: string;
  /** 租户工作区根：<durable>/tenants/<tenant>/<user>（spawn cwd；读隔离探针在此卷上跑） */
  tenantsDir: string;
  /**
   * 可丢弃缓存根（每副本本地盘即可，不要放 NFS：会话 jsonl / 技能落盘 / 包缓存 / DSH_HOME 都能从 PG 与 Bus 重建）。
   * DSH_RUNTIME_CACHE_DIR，缺省 = <dataDir>/cache。
   */
  cacheDir: string;
  /** 会话持久化根（dsh 会话 jsonl 落点；按 cwd 自动分目录） */
  sessionsRoot: string;
  /** 会话技能落盘根：<cache>/skills/<session_id>/<code>/SKILL.md（ZAP §11） */
  skillsDir: string;
  /** 技能包缓存：<cache>/skill-packages/<sha256>.zip */
  skillPackagesDir: string;
  /** 单个技能包上限（F03：≤ 50MB） */
  skillPackageMaxBytes: number;
  /** 首条消息等待技能落盘的上限；超时不阻塞（watcher 稍后补上） */
  skillsReadyTimeoutMs: number;
  /** 单个入站附件上限（下载到工作区 .attachments/） */
  attachmentMaxBytes: number;
  /**
   * 反向通道（ZAP §6）：Bus 根地址 + 本 runtime 的 runtime_access 凭据（ADR-0030）。三者齐备才启用工具桥；
   * 凭据只在 shim 进程里，绝不下传 agent 进程。
   */
  busBaseUrl: string;
  busClientId: string;
  busClientSecret: string;
  /** 回环桥对外地址（agent 进程里的 MCP 服务调用）；默认 http://127.0.0.1:<port> */
  bridgeBaseUrl: string;
  /**
   * 图片生成（平移 OpenClaw aigc-llm-image）：公司 LLM 网关 OpenAI 兼容 `POST {base}/images/generations`。
   * 只使用 /instances 下发的成员凭据，无服务级图片凭据回退。
   */
  imageModel: string;
  imageTimeoutMs: number;
  /**
   * per-agent 渲染后的装配文件目录。**必须**能向上找到 node_modules/@deepseek-ai/*：
   * 装配里的裸包名按配置文件所在目录解析（app-boot ctx.baseUrl = dirname(config)）。
   * 默认 <packageRoot>/var/cordis；assemble 会在该目录补 node_modules 软链兜底。
   */
  cordisDir: string;
  /**
   * 账号级模型凭据强制策略（fail-closed）。
   * `true`：spawn 前必须已通过 `/instances` 下发该 (租户,账号) 的 llm 凭据；缺失 → `zap.llm_credential_missing`，不 spawn，不使用服务级 fallback。
   * 默认 true；仅隔离测试可显式置 false 使用测试凭据。
   */
  requireAccountLlmKey: boolean;
  /**
   * 走回环 LLM 网关归一化代理（默认开）。公司 AIGC 网关的流式 tool_calls 增量帧把 id/name 显式写成
   * null, 而 DeepSeek SDK 用 `!== undefined` 累积 → 名字被冲掉 → 所有工具不可用；另测试环境网关不发
   * `[DONE]` → STREAM_CLOSED。两处都在 src/llmgw/normalize.ts 抹平。上游 SDK 修好后可置 0 直连。
   */
  llmGatewayNormalize: boolean;
  /** 员工自带模型服务（byok）走 pi-ai openai-completions 路由时的请求兼容开关（pi-ai compat），JSON 对象 */
  byokCompat: Record<string, unknown>;
  /** byok 路由单次输出上限（pi-ai models[].maxTokens）；中转站/私有网关对 32768 的默认值常直接拒绝 */
  byokMaxTokens: number;
}

const here = dirname(fileURLToPath(import.meta.url));
/** 包根：src/ 或 dist/ 的上一级 */
export const packageRoot = resolve(here, '..');

function intEnv(env: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) throw new Error(`${name} must be a non-negative number, got ${JSON.stringify(raw)}`);
  return n;
}

function strEnv(env: NodeJS.ProcessEnv, name: string, fallback: string): string {
  const raw = env[name];
  return raw === undefined || raw === '' ? fallback : raw;
}

function jsonObjectEnv(env: NodeJS.ProcessEnv, name: string, fallback: Record<string, unknown>): Record<string, unknown> {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  const parsed: unknown = JSON.parse(raw); // 配错就启动失败，不静默回落
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) throw new Error(`${name} must be a JSON object`);
  return parsed as Record<string, unknown>;
}

function boolEnv(env: NodeJS.ProcessEnv, name: string, fallback: boolean): boolean {
  const raw = (env[name] ?? '').trim().toLowerCase();
  if (raw === '') return fallback;
  if (['1', 'true', 'yes', 'on'].includes(raw)) return true;
  if (['0', 'false', 'no', 'off'].includes(raw)) return false;
  throw new Error(`${name} must be a boolean (1/0/true/false), got ${JSON.stringify(env[name])}`);
}

function isolationEnv(env: NodeJS.ProcessEnv): 'required' | 'off' {
  const raw = strEnv(env, 'DSH_RUNTIME_READ_ISOLATION', process.platform === 'linux' ? 'required' : 'off');
  if (raw !== 'required' && raw !== 'off') throw new Error(`DSH_RUNTIME_READ_ISOLATION must be required|off, got ${JSON.stringify(raw)}`);
  return raw;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): RuntimeConfig {
  const apiKey = strEnv(env, 'DSH_RUNTIME_API_KEY', '');
  if (!apiKey) throw new Error('DSH_RUNTIME_API_KEY is required (runtime API key Bus uses as Bearer)');
  const dataDir = resolve(strEnv(env, 'DSH_RUNTIME_DATA_DIR', resolve(packageRoot, 'var/data')));
  // 多副本部署：durable（员工配置 + 工作区）挂共享卷，cache（可重建）留本地盘；单副本两者同在 dataDir 下
  const durableDir = resolve(strEnv(env, 'DSH_RUNTIME_DURABLE_DIR', dataDir));
  const cacheDir = resolve(strEnv(env, 'DSH_RUNTIME_CACHE_DIR', resolve(dataDir, 'cache')));
  const agentBin = resolve(
    strEnv(env, 'DSH_RUNTIME_AGENT_BIN', resolve(packageRoot, 'node_modules/@deepseek-ai/dsh-sdk-jsonrpc-demo/lib/bin.js')),
  );
  const baseCordisPath = resolve(strEnv(env, 'DSH_RUNTIME_BASE_CORDIS', resolve(packageRoot, 'assets/agent.cordis.yml')));
  if (!existsSync(baseCordisPath)) throw new Error(`base assembly not found: ${baseCordisPath}`);
  return {
    host: strEnv(env, 'DSH_RUNTIME_HOST', '0.0.0.0'),
    port: intEnv(env, 'DSH_RUNTIME_PORT', 8400),
    apiKey,
    logLevel: strEnv(env, 'LOG_LEVEL', 'info'),
    dataDir,
    agentBin,
    baseCordisPath,
    platformSkillsDir: resolve(strEnv(env, 'DSH_RUNTIME_PLATFORM_SKILLS_DIR', resolve(packageRoot, 'assets/skills'))),
    defaultProvider: strEnv(env, 'DSH_RUNTIME_DEFAULT_PROVIDER', 'deepseek-official'),
    defaultModel: strEnv(env, 'DSH_RUNTIME_DEFAULT_MODEL', 'deepseek-v4-flash'),
    idleTimeoutMs: intEnv(env, 'DSH_RUNTIME_IDLE_TIMEOUT_MS', 10 * 60_000),
    maxProcesses: intEnv(env, 'DSH_RUNTIME_MAX_PROCESSES', 32),
    maxQueue: intEnv(env, 'DSH_RUNTIME_MAX_QUEUE', 64),
    queueTimeoutMs: intEnv(env, 'DSH_RUNTIME_QUEUE_TIMEOUT_MS', 30_000),
    maxProcessesPerTenant: intEnv(env, 'DSH_RUNTIME_MAX_PROCESSES_PER_TENANT', 8),
    maxProcessesPerUser: intEnv(env, 'DSH_RUNTIME_MAX_PROCESSES_PER_USER', 3),
    maxQueuePerUser: intEnv(env, 'DSH_RUNTIME_MAX_QUEUE_PER_USER', 2),
    processMaxRssMb: intEnv(env, 'DSH_RUNTIME_PROCESS_MAX_RSS_MB', 2048),
    processCpuSeconds: intEnv(env, 'DSH_RUNTIME_PROCESS_CPU_SECONDS', 1800),
    processMaxProcs: intEnv(env, 'DSH_RUNTIME_PROCESS_MAX_PROCS', 64),
    processNofile: intEnv(env, 'DSH_RUNTIME_PROCESS_NOFILE', 4096),
    cgroupRoot: strEnv(env, 'DSH_RUNTIME_CGROUP_ROOT', process.platform === 'linux' ? '/sys/fs/cgroup/agents' : ''),
    processCpuPercent: intEnv(env, 'DSH_RUNTIME_PROCESS_CPU_PERCENT', 0),
    toolDefaultDeny: parseToolDefaultDeny(env['DSH_RUNTIME_TOOL_DEFAULT_DENY']),
    workspaceQuotaMb: intEnv(env, 'DSH_RUNTIME_WORKSPACE_QUOTA_MB', 2048),
    tenantQuotaMb: intEnv(env, 'DSH_RUNTIME_TENANT_QUOTA_MB', 20480),
    minFreeMb: intEnv(env, 'DSH_RUNTIME_MIN_FREE_MB', 2048),
    limitCheckIntervalMs: intEnv(env, 'DSH_RUNTIME_LIMIT_CHECK_INTERVAL_MS', 2_000),
    spawnTimeoutMs: intEnv(env, 'DSH_RUNTIME_SPAWN_TIMEOUT_MS', 30_000),
    turnTimeoutMs: intEnv(env, 'DSH_RUNTIME_TURN_TIMEOUT_MS', 10 * 60_000),
    sessionTtlSeconds: intEnv(env, 'DSH_RUNTIME_SESSION_TTL_SECONDS', 24 * 3600),
    version: strEnv(env, 'DSH_RUNTIME_VERSION', '0.1.0'),
    devConsole: strEnv(env, 'DSH_RUNTIME_DEV_CONSOLE', '') === '1',
    readIsolation: isolationEnv(env),
    pgDsn: strEnv(env, 'DSH_RUNTIME_PG_DSN', ''),
    durableDir,
    agentsConfigDir: resolve(durableDir, 'config/agents'),
    tenantsDir: resolve(durableDir, 'tenants'),
    cacheDir,
    sessionsRoot: resolve(cacheDir, 'sessions'),
    skillsDir: resolve(cacheDir, 'skills'),
    skillPackagesDir: resolve(cacheDir, 'skill-packages'),
    skillPackageMaxBytes: intEnv(env, 'DSH_RUNTIME_SKILL_PACKAGE_MAX_BYTES', 50 * 1024 * 1024),
    skillsReadyTimeoutMs: intEnv(env, 'DSH_RUNTIME_SKILLS_READY_TIMEOUT_MS', 20_000),
    attachmentMaxBytes: intEnv(env, 'DSH_RUNTIME_ATTACHMENT_MAX_BYTES', 50 * 1024 * 1024),
    busBaseUrl: strEnv(env, 'DSH_RUNTIME_BUS_BASE_URL', ''),
    busClientId: strEnv(env, 'DSH_RUNTIME_BUS_CLIENT_ID', ''),
    busClientSecret: strEnv(env, 'DSH_RUNTIME_BUS_CLIENT_SECRET', ''),
    bridgeBaseUrl: strEnv(env, 'DSH_RUNTIME_BRIDGE_BASE_URL', `http://127.0.0.1:${intEnv(env, 'DSH_RUNTIME_PORT', 8400)}`),
    imageModel: strEnv(env, 'DSH_RUNTIME_IMAGE_MODEL', 'doubao-seedream-4-0-250828'),
    imageTimeoutMs: intEnv(env, 'DSH_RUNTIME_IMAGE_TIMEOUT_MS', 360_000),
    cordisDir: resolve(strEnv(env, 'DSH_RUNTIME_CORDIS_DIR', resolve(packageRoot, 'var/cordis'))),
    requireAccountLlmKey: boolEnv(env, 'DSH_RUNTIME_REQUIRE_ACCOUNT_LLM_KEY', true),
    llmGatewayNormalize: boolEnv(env, 'DSH_RUNTIME_LLM_GATEWAY_NORMALIZE', true),
    byokCompat: jsonObjectEnv(env, 'DSH_RUNTIME_BYOK_COMPAT_JSON', { supportsDeveloperRole: false, maxTokensField: 'max_tokens' }),
    byokMaxTokens: intEnv(env, 'DSH_RUNTIME_BYOK_MAX_TOKENS', 8192),
  };
}
