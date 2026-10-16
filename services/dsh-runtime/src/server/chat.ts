/**
 * 一条消息的全链路：受理 → SSE 首帧 → pool.ensure（spawn/复用）→ prompt → 翻译器逐帧回推 → 终态帧。
 * 取消语义：Bus 调 /cancel 或客户端断连 → 杀进程（wire 无 cancel）→ message.cancelled。
 * 进程重建（崩溃/回收后再来消息）：新 wire 会话 id + transcript 前缀注入（ADR §4.8 "由 shim 重建上下文"）。
 */
import { knowledgeContextPrefix, skillPrefix } from '../context/prompt.js';
export { knowledgeContextPrefix, skillPrefix } from '../context/prompt.js';
import { randomBytes } from 'node:crypto';
import { mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { resolve as resolvePath } from 'node:path';
import type { AssemblyScope, CordisEntry } from '../assemble/cordis.js';
import { packageRoot } from '../config.js';
import { attachmentFromBlock, attachmentsPrefix, saveAttachments, type InboundAttachment } from '../files/attachments.js';
import { publishOutbox, stripOutboxLinks } from '../files/outbox.js';
import { CapacityError, RuntimeStartError, type SessionProcess, type SpawnSpec } from '../pool/process-pool.js';
import { BYOK_PROVIDER, ModelServiceError, byokRouteEntry, modelServiceOf, type ModelService } from '../assemble/byok-route.js';
import { quotaRoots } from '../pool/process-limits.js';
import type { HistoryEvent } from '../history/history.js';
import type { SessionRecord, ConversationModelBinding } from '../sessions/session-store.js';
import { TRANSCRIPT_MAX_CHARS, TRANSCRIPT_MAX_ENTRIES, newMessageId } from '../sessions/session-store.js';
import type { AgentRecord } from '../store/agent-store.js';
import { encodeSse, type ZapFrame } from '../translate/sse.js';
import { TurnTranslator } from '../translate/translator.js';
import type { AppDeps } from './deps.js';
import { ZapErrorCode, zapErrors } from './errors.js';

const SAFE_SEGMENT = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

export function assertPathSegment(value: string, field: string): string {
  if (!SAFE_SEGMENT.test(value) || value.includes('..')) throw zapErrors.invalidRequest(`${field} must be a safe identifier`);
  return value;
}

export interface InboundMessage {
  modelService?: ConversationModelBinding;
  text: string;
  metadata: Record<string, unknown>;
  /** file / image block（Bus 已换成短期签名绝对 URL） */
  attachments: InboundAttachment[];
}

/**
 * Bus 出站三形态（text / blocks / raw typed blocks）→ 纯文本。
 *
 * **防正文翻倍（zhiban-zap-debugging 坑#3）**：知办 Bus 会把同一句话同时塞进顶层 `text`
 * 和 `blocks[].text`。因此**有文本 block 就以 block 为准，仅在没有任何文本 block 时才回落顶层 text**，
 * 绝不把两者拼接（拼接 = "你好" → "你好\n你好"）。
 * file / image block 抽成附件（下载到工作区，见 files/attachments.ts）；其它 typed block 忽略并计数。
 * 附件可以没有文本：纯附件消息的文本回落为「（用户发送了附件）」。
 */
export function parseInbound(body: unknown): { message: InboundMessage; droppedBlocks: number } {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) throw zapErrors.invalidRequest('body must be a JSON object');
  const b = body as Record<string, unknown>;
  const blockPieces: string[] = [];
  const attachments: InboundAttachment[] = [];
  let dropped = 0;
  if (b['blocks'] !== undefined) {
    if (!Array.isArray(b['blocks'])) throw zapErrors.invalidRequest('blocks must be an array');
    for (const blk of b['blocks']) {
      if (typeof blk !== 'object' || blk === null) continue;
      const rec = blk as Record<string, unknown>;
      const type = typeof rec['type'] === 'string' ? rec['type'] : '';
      if ((type === 'markdown' || type === 'plain' || type === 'text' || type === '') && typeof rec['text'] === 'string') {
        const t = rec['text'].trim();
        if (t) blockPieces.push(t);
        continue;
      }
      const att = attachmentFromBlock(rec);
      if (att) attachments.push(att);
      else dropped += 1;
    }
  }
  const topText = typeof b['text'] === 'string' ? b['text'].trim() : '';
  // 文本 block 优先；没有文本 block 才用顶层 text，二者不拼接。
  const text = blockPieces.length > 0 ? blockPieces.join('\n').trim() : topText;
  if (!text && attachments.length === 0) throw zapErrors.emptyUserMessage();
  const metadata = typeof b['metadata'] === 'object' && b['metadata'] !== null ? (b['metadata'] as Record<string, unknown>) : {};
  const modelService = parseModelBinding(b['model_service_override']);
  return { message: { text: text || '（用户发送了附件）', metadata, attachments, ...(modelService ? {modelService} : {}) }, droppedBlocks: dropped };
}

export function parseModelBinding(value: unknown): ConversationModelBinding | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw zapErrors.invalidRequest('invalid model platform');
  const b = value as Record<string, unknown>;
  if (typeof b['model'] !== 'string' || !b['model'].trim() || b['model'].length > 256 ||
      !['openai-compatible','anthropic-messages'].includes(String(b['protocol'])) ||
      typeof b['api_key'] !== 'string' || !b['api_key'].startsWith('ms1.') || b['api_key'].length > 4096 || typeof b['base_url'] !== 'string') throw zapErrors.invalidRequest('invalid model platform');
  let u: URL;
  try { u = new URL(b['base_url']); } catch { throw zapErrors.invalidRequest('invalid model platform'); }
  if (!['http:','https:'].includes(u.protocol) || u.username || u.password || u.search || u.hash || !u.pathname.endsWith('/api/agent-bus/v1/runtime-model-proxy/v1')) throw zapErrors.invalidRequest('invalid model platform');
  return {model:b['model'], protocol:b['protocol'] as ConversationModelBinding['protocol'], base_url:u.toString().replace(/\/$/, ''), api_key:b['api_key']};
}
function selectedService(session?: SessionRecord): ModelService | undefined {
  const b = session?.conversationModelBinding;
  return b ? {endpoint_type:b.protocol, base_url:b.base_url, model_id:b.model} : undefined;
}

/**
 * 新进程首轮：把此前对话注入为上下文前缀。transcript 来源优先 PG（按 conversation 跨会话、跨重启重放），
 * PG 未配/读失败/为空时回落内存 transcript。
 */
export function composePrompt(transcript: SessionRecord['transcript'], proc: SessionProcess, userText: string): string {
  if (proc.turns > 0 || transcript.length === 0) return userText;
  const lines = transcript.map((e) => `${e.role === 'user' ? '用户' : '助手'}：${e.text}`);
  return `[会话上下文恢复] 以下是你与用户在本会话中此前的对话记录，请在此基础上自然地继续，不要复述这段记录：\n${lines.join('\n')}\n[记录结束]\n\n${userText}`;
}

async function transcriptFor(deps: AppDeps, session: SessionRecord, proc: SessionProcess): Promise<SessionRecord['transcript']> {
  if (proc.turns > 0) return [];
  if (deps.history.kind === 'pg' && session.conversation_id) {
    const fromPg = await deps.history.loadTranscript(
      { tenant_id: session.tenant_id, agent_key: session.agent_key, conversation_id: session.conversation_id },
      { maxEntries: TRANSCRIPT_MAX_ENTRIES, maxChars: TRANSCRIPT_MAX_CHARS },
    );
    if (fromPg.length > 0) return fromPg;
  }
  return session.transcript;
}

/**
 * Bus 预检回来的 KB 片段（ZAP-1.1 opaque `metadata.knowledge_context`）→ OpenClaw 同款
 * `[Authorized Knowledge Context]…[/Authorized Knowledge Context]\n\n[User Message]…[/User Message]` 包裹用户文本。
 * 目的：把知识注入的口径从 Bus 平移到 runtime（同一提示词模板，模型行为不变）。
 *
 * 纪律：
 * - 只读；片段 **绝不进日志/历史/SSE**（历史仍只存 `inbound.text` 原文，见 streamMessage 里的 userPayload）。
 * - 防御性：`items` 必须是非空数组；单条至少要有 `content` 才计入；items 上限 20，content 上限 4000 字。
 * - `score<=0` 时省略 score 行；其它元信息不下传给模型。
 * - `suggest_tool_follow_up=true` 时在 `[User Message]` 前追加一行 kb_search 提示（模型可再检索）。
 */

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export const BRIDGE_SCRIPT = resolvePath(packageRoot, 'assets/bridge/zhiban-mcp.mjs');

/** 平台工具使用纪律（与 OpenClaw zhiban-kb-search skill 同口径），只在工具桥启用时追加到系统提示。 */
export const PLATFORM_TOOLS_GUIDANCE = [
  '【平台工具】你可以使用知办平台工具（mcp__zhiban__*）：kb_search 检索本数字员工已授权的知识库；memory_recall / memory_write 读写用户长期记忆；a2a_discover / a2a_invoke 发现并调用其他数字员工；a2a_get_edge 查询已派出任务的状态/结果；a2a_cancel_edge 取消尚未完成的协作任务；image_generate 生成图片（落在 outbox/images/，自动作为附件发给用户）。',
  '规则：需要企业资料、制度、产品知识时先 kb_search，只依据检索结果作答，检索不到就如实说明，不得编造；用户问"有哪些同事/数字员工可以帮忙"必须用 a2a_discover，只用返回的候选作答；派发任务时 user_text 只写清晰的业务任务，不写路由话术；工具参数里绝不传租户/账号/会话/令牌/地址等任何标识；不要向用户透露工具内部字段与标识。',
  '【交付文件】要交给用户的文件（报表、文档、图片等）请写到当前工作目录的 outbox/ 下，本轮结束后平台会自动把 outbox/ 里本轮新增的文件作为附件发给用户。正文里只用文件名提及即可，不要写文件路径、不要写指向文件的链接，也不要把文件内容整段贴在回复里。',
].join('\n');

/** spawn 前拒绝（byok 凭据/登记问题），由 streamMessage 映射成 message.failed，不 spawn。 */
export class SpawnRefusedError extends Error {
  constructor(
    readonly code: string,
    readonly userMessage: string,
  ) {
    super(code);
    this.name = 'SpawnRefusedError';
  }
}

/** BeeBridge member credentials use the existing OpenAI-compatible pi-ai route.
 * Its descriptor is transient; neither the upstream address nor key enters Cordis.
 */
function memberModelService(deps: AppDeps, agent: AgentRecord, session: SessionRecord): ModelService | undefined {
  const creds = deps.identity.credentialsFor(session.tenant_id, session.user_id);
  if (creds?.source !== 'beebridge_gateway') return undefined;
  const model = agent.model?.primary?.trim();
  if (!model || !creds.base_url || !creds.api_key || !deps.config.llmGatewayNormalize) {
    throw new SpawnRefusedError(ZapErrorCode.modelServiceCredentialsMissing, '蜂桥模型服务配置不完整，请检查模型和成员凭证');
  }
  return { endpoint_type: 'openai-compatible', base_url: creds.base_url, model_id: model };
}

/** byok 员工：在装配里加一条 pi-ai `byok` 路由（登记非法时这里不抛，交给 spawnSpecFor 统一拒绝）。 */
export function byokEntryFor(deps: AppDeps, agent: AgentRecord, session?: SessionRecord): CordisEntry | undefined {
  let ms: ModelService | undefined;
  try {
    ms = selectedService(session) ?? modelServiceOf(agent) ?? (session ? memberModelService(deps, agent, session) : undefined);
  } catch {
    return undefined;
  }
  return ms ? byokRouteEntry(ms, { bridgeBaseUrl: deps.config.bridgeBaseUrl, compat: deps.config.byokCompat, maxTokens: deps.config.byokMaxTokens }) : undefined;
}

/** 每会话的工具桥装配：dsh mcp-client(stdio) → assets/bridge/zhiban-mcp.mjs → 本 runtime 回环桥。 */
export function bridgeScope(deps: AppDeps, session: SessionRecord): Pick<AssemblyScope, 'extraEntries' | 'personaSuffix'> {
  const style = deps.outputStyle ? [deps.outputStyle] : [];
  const office = {
    id: 'zhiban-office',
    name: '@deepseek-ai/dsh-mcp-client',
    config: {
      transport: 'stdio', serverName: 'zhiban-office', command: process.execPath,
      args: [resolvePath(packageRoot, 'dist/office/mcp.js'), '--workspace', resolvePath(deps.config.tenantsDir, assertPathSegment(session.tenant_id, 'tenant_id'), assertPathSegment(session.user_id, 'user_id'))],
      toolCallTimeoutMs: 70_000,
    },
  };
  if (!deps.bus || !session.bridgeKey) return { extraEntries: [office], ...(style.length > 0 ? { personaSuffix: style.join('\n\n') } : {}) };
  return {
    extraEntries: [
      office,
      {
        id: 'zhiban-tools',
        name: '@deepseek-ai/dsh-mcp-client',
        config: {
          transport: 'stdio',
          serverName: 'zhiban',
          command: process.execPath,
          args: [BRIDGE_SCRIPT, '--endpoint', `${deps.config.bridgeBaseUrl.replace(/\/+$/, '')}/bridge/v1/${session.session_id}`, '--key', session.bridgeKey],
          // 图片生成类工具可能跑几分钟；dsh 侧单次工具调用超时放宽到 7 分钟（MCP 服务自己按工具再细分）
          toolCallTimeoutMs: 420_000,
        },
      },
    ],
    personaSuffix: [...style, PLATFORM_TOOLS_GUIDANCE].join('\n\n'),
  };
}

/** 进历史库的北侧事件子集（不含 block.delta / reasoning）。 */
const PERSISTED_EVENTS = new Set(['message.created', 'message.tool_call', 'message.tool_result', 'message.completed', 'message.failed', 'message.cancelled']);

/** 模型名守卫：deepseek-official 只接受 deepseek* 模型；空/不匹配回落默认。 */
export function resolveModel(primary: string | undefined, provider: string, fallback: string): string {
  const m = (primary ?? '').trim();
  if (!m) return fallback;
  // 只挡"明显不是 deepseek 系"的模型（dsh 走 DeepSeek 方言，openai/* 这类路由会直接 INVALID_REQUEST）。
  // 匹配整串而非前缀：公司 LLM 网关的命名是 <厂商>/<模型>（如 localai/deepseek-v4-flash），
  // 用 ^deepseek 会把所有网关模型名一律打掉、静默回落默认值，等于每员工选模型彻底失效
  // （2026-08-25 测试环境实测）。
  if (provider === 'deepseek-official' && !/deepseek/i.test(m)) return fallback;
  return m;
}

/** 租户合计配额的计量根：该租户全部用户的工作区 / DSH_HOME / 会话持久化根 */
function tenantRootsFor(deps: AppDeps, tenant: string): string[] {
  return [resolvePath(deps.config.tenantsDir, tenant), resolvePath(deps.config.cacheDir, 'dsh-home', tenant), resolvePath(deps.config.sessionsRoot, tenant)];
}

/** 磁盘配额口径（与池看门狗 quotaRoots 一致）：工作区 + 按租户/账号分的 DSH_HOME + 会话持久化根 */
function quotaRootsFor(deps: AppDeps, session: SessionRecord): string[] {
  const tenant = assertPathSegment(session.tenant_id, 'tenant_id');
  const user = assertPathSegment(session.user_id, 'user_id');
  return quotaRoots(
    { workspace: resolvePath(deps.config.tenantsDir, tenant, user), dshHome: resolvePath(deps.config.cacheDir, 'dsh-home', tenant, user), readWrite: [deps.cordis.sessionsRootFor({ tenant, user })] },
    deps.pool.defaultDshHome,
  );
}

/** 容量类失败的用户文案：按租户/用户配额 vs 全局容量区分，避免把"你自己开太多会话"说成"系统忙"。 */
function capacityMessage(err: CapacityError, deps: AppDeps): string {
  switch (err.reason) {
    case 'user_limit':
      return `您同时进行的会话已达上限（${deps.config.maxProcessesPerUser} 个），请先结束其它会话或稍后重试`;
    case 'user_queue_full':
      return `您已有 ${deps.config.maxQueuePerUser} 条消息在排队，请等它们完成后再发`;
    case 'tenant_limit':
      return `当前组织同时进行的会话已达上限（${deps.config.maxProcessesPerTenant} 个），请稍后重试`;
    case 'queue_timeout':
      return `runtime is at capacity (waited ${Math.round(err.waitedMs / 1000)}s), retry later`;
    default:
      return 'runtime is at capacity, retry later';
  }
}

export function spawnSpecFor(deps: AppDeps, session: SessionRecord, agent: AgentRecord, cordisPath: string): SpawnSpec {
  const tenant = assertPathSegment(session.tenant_id, 'tenant_id');
  const user = assertPathSegment(session.user_id, 'user_id');
  const scope = { tenant, user };
  // ADR-0037 dsh 消费端：登记带 metadata.model_service 的 byok 员工走 pi-ai `byok` 路由，模型原样透传，不经 deepseek 守卫。
  let modelService: ModelService | undefined;
  try {
    modelService = selectedService(session) ?? modelServiceOf(agent);
  } catch (err) {
    if (err instanceof ModelServiceError) {
      throw new SpawnRefusedError(ZapErrorCode.modelServiceEndpointUnsupported, '该员工配置的模型服务协议不受支持，请在「模型服务」里换用 OpenAI 兼容或 Anthropic 协议的服务');
    }
    throw err;
  }
  const isBYOK = Boolean(modelService) && !session.conversationModelBinding;
  modelService ??= memberModelService(deps, agent, session);
  const provider = modelService ? BYOK_PROVIDER : typeof agent.metadata?.['provider'] === 'string' ? (agent.metadata['provider'] as string) : deps.config.defaultProvider;
  // BeeBridge/BYOK use the selected model verbatim via pi-ai. The legacy
  // DeepSeek name guard applies only to deployments without these credentials.
  const model = modelService ? modelService.model_id : resolveModel(agent.model?.primary, provider, deps.config.defaultModel);
  // 模型凭据注入（ADR-0021 / ADR-0037）：先员工级（byok），再账号级；没有则回落服务级 env（DEEPSEEK_API_KEY）。凭据不进 labels/日志。
  const memberOnly = Boolean(modelService) && !isBYOK;
  const creds = session.conversationModelBinding ?? deps.identity.credentialsFor(session.tenant_id, session.user_id, memberOnly ? undefined : agent.agent_key);
  // The broker must use the same scope; an old employee BYOK credential must
  // not override the account credential after switching to BeeBridge.
  session.llmMemberKeyOnly = memberOnly;
  // byok 员工必须拿到员工级凭据（source=byok）；账号级/服务级都不是它的 key，宁可拒绝也不静默换身份。
  if (isBYOK && (!creds || !('source' in creds) || creds.source !== 'byok')) {
    throw new SpawnRefusedError(ZapErrorCode.modelServiceCredentialsMissing, '该员工配置的模型服务不可用（未获取到它的 API Key），请在「模型服务」里检查后重新发布');
  }
  const env: Record<string, string> = {};
  if (creds) {
    // P1-c：真凭据不下发给子进程。走回环代理时只给**会话级假 key**，代理校验后换成真 key 转发；
    // 直连上游（关了归一化开关）时无处可换，只能原样下发——这条路径下 agent 能把账号 key 发出去。
    const brokered = Boolean(creds.base_url) && deps.config.llmGatewayNormalize;
    if (brokered) {
      // 每会话**只铸一次**：本函数每条消息都会被调用（见 pool.ensure 调用点），而子进程的 env 只在
      // spawn 那一刻固化。每次都重铸的话，进程被复用时子进程手里还是旧 key、代理却按新 key 校验
      // → 从第二轮起必然 `bad session key`（2026-08-25 测试环境实锤：首条正常、之后全挂）。
      // 进程被回收后重新 spawn 会拿到同一把会话级 key，与代理侧一致。
      session.llmKey ??= `sk-sess-${randomBytes(24).toString('base64url')}`;
      env.DEEPSEEK_API_KEY = session.llmKey;
    } else {
      env.DEEPSEEK_API_KEY = creds.api_key;
    }
    if (creds.base_url) {
      // 走回环归一化代理: 公司网关的流式 tool_calls 增量帧把 id/name 显式写成 null, 而 DeepSeek SDK
      // 用 `!== undefined` 累积 → 首帧的名字被覆盖 → 所有工具报 unknown tool ""（src/llmgw/normalize.ts）。
      // 代理只做协议归一化, 凭据仍由子进程自带、原样转发。关掉开关即直连上游。
      env.DEEPSEEK_BASE_URL = deps.config.llmGatewayNormalize
        ? `${deps.config.bridgeBaseUrl.replace(/\/+$/, '')}/llmgw/v1/${session.session_id}`
        : creds.base_url;
    }
  }
  return {
    sessionId: session.session_id,
    wireSessionId: `${session.session_id}--g${randomBytes(4).toString('hex')}`,
    cordisPath,
    processCwd: dirname(cordisPath),
    workspace: resolve(deps.config.tenantsDir, tenant, user),
    tenant,
    user,
    provider,
    model,
    // 登记 revision 作为配置指纹：员工换模型/模型服务后同一会话的下一条消息即重开进程（pool.ensure）
    configRevision: String(agent.revision),
    ...(creds ? { env } : {}),
    // 读隔离授权面（pool/read-isolation.ts）：可写=工作区 + 按租户/账号分的 DSH_HOME 与会话持久化根 + 会话私有 TMPDIR；
    // 只读=本员工配置目录（P3 skills）+ 装配目录（池自动加）。租户根与 /tmp、/proc 不授。
    dshHome: resolve(deps.config.cacheDir, 'dsh-home', tenant, user),
    // TMPDIR / HOME 放进工作区：dsh 内层沙箱只许写工作区，Chrome/bun/mktemp 的临时与缓存写入才不被拒
    tmpDir: resolve(deps.config.tenantsDir, tenant, user, '.tmp', session.session_id),
    homeDir: resolve(deps.config.tenantsDir, tenant, user, '.home'),
    readOnly: [resolve(deps.config.agentsConfigDir, agent.agent_key), deps.skills.sessionDir(session.session_id)],
    readWrite: [deps.cordis.sessionsRootFor(scope)],
    tenantRoots: tenantRootsFor(deps, tenant),
    labels: {
      agent_key: agent.agent_key,
      conversation_id: session.conversation_id,
      tenant_id: session.tenant_id,
      user_id: session.user_id,
      llm_credential: isBYOK ? 'agent_byok' : creds ? 'per_account' : 'service_default',
    },
  };
}

/** 接管响应写 SSE。调用前 session 校验已通过（存在、未取消、无在途消息）。 */
export async function streamMessage(deps: AppDeps, session: SessionRecord, inbound: InboundMessage, req: FastifyRequest, reply: FastifyReply, release?: () => Promise<void>): Promise<void> {
  const messageId = newMessageId();
  const log = deps.log.child({ session_id: session.session_id, message_id: messageId, agent_key: session.agent_key, conversation_id: session.conversation_id });
  const translator = new TurnTranslator(messageId);
  const t0 = Date.now();
  let firstDeltaAt: number | undefined;
  let frameCount = 0;
  let done = false;
  let proc: SessionProcess | undefined;
  let procFresh = false;
  let failCode: string | undefined;
  const userPayload: Record<string, unknown> = { text: inbound.text, ...(Object.keys(inbound.metadata).length > 0 ? { metadata: inbound.metadata } : {}) };
  const history: HistoryEvent[] = [{ event: 'user.message', message_id: messageId, payload: userPayload }];

  reply.hijack();
  const raw = reply.raw;
  raw.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-cache',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
  });
  // 输出文件回传：completed 帧先扣住，等 outbox 登记完再把 file block 追加进去发出（保持 completed 末帧不变量）
  let heldCompleted: ZapFrame | undefined;
  const write = (fs: ZapFrame[]) => {
    for (const f of fs) {
      if (f.event === 'message.completed' && deps.bus && session.bridgeKey && proc) {
        heldCompleted = f;
        continue;
      }
      frameCount += 1;
      if (f.event === 'message.block.delta' && firstDeltaAt === undefined) firstDeltaAt = Date.now();
      if (f.event === 'message.failed' && typeof f.data['error_code'] === 'string') failCode = f.data['error_code'];
      if (PERSISTED_EVENTS.has(f.event)) history.push({ event: f.event, message_id: messageId, payload: f.data });
      raw.write(encodeSse(f));
    }
  };
  const flushCompleted = async () => {
    if (!heldCompleted) return;
    const frame = heldCompleted;
    heldCompleted = undefined;
    if (deps.bus && session.bridgeKey && proc) {
      const { blocks, failedCount } = await publishOutbox({
        workspace: proc.spec.workspace,
        since: t0,
        messageId,
        maxBytes: deps.config.attachmentMaxBytes,
        bus: deps.bus,
        scope: { tenant_id: session.tenant_id, agent_id: session.agent_id, ...(session.session_kind !== 'a2a' && session.user_id !== 'a2a' ? { account_id: session.user_id } : {}) },
        logger: log,
        seen: (session.outboxSeen ??= new Map()),
        retry: (session.outboxRetry ??= new Set()),
      }).catch(() => ({ blocks: [], failedCount: 1 }));
      // 正文里的 outbox/ 链接改成纯文本（客户端会把它渲染成打不开的下载卡），再把真正的 file block 追加进去。
      const bodyBlocks = stripOutboxLinks((frame.data['blocks'] as unknown[]) ?? [], blocks.map((b) => b.name));
      const warning = failedCount > 0 ? [{ type: 'markdown', text: `\n\n有 ${failedCount} 个文件未能传回，当前交付尚未完成。文件已保留在工作区，可稍后重试交付；无需重新生成。` }] : [];
      frame.data = { ...frame.data, blocks: [...bodyBlocks, ...blocks, ...warning] };
    }
    frameCount += 1;
    if (PERSISTED_EVENTS.has(frame.event)) history.push({ event: frame.event, message_id: messageId, payload: frame.data });
    raw.write(encodeSse(frame));
  };
  const ac = new AbortController();
  req.raw.on('close', () => {
    if (!done) ac.abort();
  });

  session.inflight = true;
  let markInflightDone: () => void = () => {};
  session.inflightDone = new Promise<void>((r) => (markInflightDone = r));
  write(translator.created());
  try {
    let agent = deps.store.get(session.agent_key);
    if (!agent) {
      write(translator.fail(ZapErrorCode.agentKeyNotFound, `agent_key ${session.agent_key} is not registered`));
      return;
    }
    // Bus authenticates/authorizes this opaque override. Apply to a transient copy only;
    // a changed model causes pool.ensure to rebuild the process and replay persisted history.
    session.conversationModelBinding = inbound.modelService;
    if (inbound.modelService) {
      if (!deps.config.llmGatewayNormalize) { write(translator.fail(ZapErrorCode.modelServiceCredentialsMissing, '模型平台执行需要启用凭据代理')); return; }
      agent = {...agent, model:{...agent.model, primary:inbound.modelService.model}};
    }
    const selected = inbound.modelService ? undefined : inbound.metadata['conversation_model'];
    if (selected !== undefined) {
      if (typeof selected !== 'string' || !selected.trim() || selected.length > 256) {
        write(translator.fail(ZapErrorCode.modelServiceCredentialsMissing, '所选模型无效')); return;
      }
      const byok = modelServiceOf(agent);
      const member = deps.identity.credentialsFor(session.tenant_id, session.user_id);
      if (byok ? byok.model_id !== selected : member?.source !== 'beebridge_gateway') {
        write(translator.fail(ZapErrorCode.modelServiceCredentialsMissing, '所选模型的凭据不可用')); return;
      }
      agent = { ...agent, model: { ...agent.model, primary: selected } };
    }
    // 账号级凭据策略（fail-closed）：DSH_RUNTIME_REQUIRE_ACCOUNT_LLM_KEY=1 时 (租户,账号) 必须已由 /instances 下发 llm 凭据，
    // 否则 message.failed(zap.llm_credential_missing) 且**不 spawn**、不触碰服务级 DEEPSEEK_API_KEY。
    // byok 员工的员工级凭据（scope=agent）同样满足本门（Bus 对 byok 员工只下发员工级，不再下发账号级）。
    if (deps.config.requireAccountLlmKey && !session.conversationModelBinding && !deps.identity.credentialsFor(session.tenant_id, session.user_id, session.agent_key)) {
      write(translator.fail(ZapErrorCode.llmCredentialMissing, '未获取到该用户的模型凭据，请联系管理员检查模型网关配置'));
      return;
    }
    // 磁盘三道闸（都在 spawn 前）：① 数据卷剩余空间 → zap.disk_full（运维项）；② 租户合计软配额；③ 用户可写根软配额（工作区 + DSH_HOME + 会话持久化根）。
    // 本轮内超限由池看门狗杀进程。
    {
      const disk = deps.pool.diskFull(deps.config.tenantsDir);
      if (disk.full) {
        log.warn({ free_mb: disk.freeMb, min_free_mb: disk.minFreeMb }, 'data volume nearly full; refusing new turns');
        write(translator.fail(ZapErrorCode.diskFull, '运行时存储空间不足，已暂停新任务；请联系管理员扩容或清理'));
        return;
      }
      const tenant = assertPathSegment(session.tenant_id, 'tenant_id');
      const tq = await deps.pool.tenantOverQuota(`t:${session.tenant_id}`, tenantRootsFor(deps, tenant));
      if (tq.over) {
        write(translator.fail(ZapErrorCode.workspaceQuotaExceeded, `组织存储配额已用满（${tq.usedMb}MB / ${tq.quotaMb}MB），请联系管理员清理成员工作区后重试`));
        return;
      }
      const quota = await deps.pool.workspaceOverQuota(quotaRootsFor(deps, session));
      if (quota.over) {
        write(translator.fail(ZapErrorCode.workspaceQuotaExceeded, `工作区已使用 ${quota.usedMb}MB，超出配额 ${quota.quotaMb}MB；请清理 outbox/ 或删除大文件后重试`));
        return;
      }
    }
    try {
      // 技能落盘有界等待（§11.4 异步下载；超时不阻塞，watcher 稍后补上）
      if (session.skills.agent.size > 0) await Promise.race([session.skillsReady, sleep(deps.config.skillsReadyTimeoutMs)]);
      const bridge = bridgeScope(deps, session);
      const byokEntry = byokEntryFor(deps, agent, session);
      const cordisPath = await deps.cordis.ensure(agent, {
        tenant: assertPathSegment(session.tenant_id, 'tenant_id'),
        user: assertPathSegment(session.user_id, 'user_id'),
        session: session.session_id,
        extraSkillDirs: [deps.skills.sessionDir(session.session_id)],
        ...bridge,
        ...(byokEntry ? { extraEntries: [...(bridge.extraEntries ?? []), byokEntry] } : {}),
      });
      proc = await deps.pool.ensure(spawnSpecFor(deps, session, agent, cordisPath), { signal: ac.signal });
      procFresh = proc.turns === 0;
    } catch (err) {
      if (err instanceof CapacityError) {
        // 排队中客户端断连 = 取消，不算容量失败
        if (err.reason === 'aborted' || ac.signal.aborted) {
          write(translator.cancel());
          return;
        }
        write(translator.fail(ZapErrorCode.capacityExhausted, capacityMessage(err, deps)));
        return;
      }
      if (err instanceof SpawnRefusedError) {
        write(translator.fail(err.code, err.userMessage));
        return;
      }
      if (err instanceof RuntimeStartError) {
        write(translator.fail(ZapErrorCode.runtimeStartFailed, 'agent process failed to start'));
        return;
      }
      throw err;
    }
    if (ac.signal.aborted) {
      await deps.pool.kill(session.session_id, 'client_abort_before_prompt');
      write(translator.cancel());
      return;
    }
    // 交付目录：系统提示让模型把交付物写到 outbox/，这里先建好（反向通道启用时才回传）
    if (deps.bus && session.bridgeKey) await mkdir(resolvePath(proc.spec.workspace, 'outbox'), { recursive: true }).catch(() => undefined);
    // 入站附件落工作区（进程已起、工作区已建）；失败只写进提示词，不中断消息
    let attachmentNote = '';
    if (inbound.attachments.length > 0) {
      const saved = await saveAttachments(inbound.attachments, { workspace: proc.spec.workspace, messageId, maxBytes: deps.config.attachmentMaxBytes });
      attachmentNote = attachmentsPrefix(saved);
      userPayload['attachments'] = saved.map(({ type, name, mime, size, file_id, path, error }) => ({ type, name, mime, ...(size !== undefined ? { size } : {}), file_id, ...(path ? { path } : {}), ...(error ? { error } : {}) }));
      log.info({ attachments: saved.length, failed: saved.filter((s) => !s.path).length }, 'attachments saved to workspace');
    }
    // KB 片段来自 Bus 预检（metadata.knowledge_context），只包裹用户原文，不吞掉 attachmentNote/skillPrefix
    const userWithKB = knowledgeContextPrefix(inbound.text, inbound.metadata);
    const prompt = composePrompt(await transcriptFor(deps, session, proc), proc, attachmentNote + skillPrefix(session, inbound.metadata) + userWithKB);
    const outcome = await proc.runTurn([{ type: 'text', text: prompt }], (ev) => write(translator.push(ev)), {
      timeoutMs: deps.config.turnTimeoutMs,
      signal: ac.signal,
    });
    switch (outcome.kind) {
      case 'completed':
        if (!translator.end) write(translator.push({ type: 'turn/end', data: { reason: { kind: 'completed' } } }));
        if (translator.end?.kind === 'completed') deps.sessions.recordTurn(session, inbound.text, translator.finalText());
        await flushCompleted();
        break;
      case 'timeout':
        write(translator.fail(ZapErrorCode.turnTimeout, 'turn timed out'));
        break;
      case 'aborted':
        write(translator.cancel());
        break;
      case 'died':
        if (session.cancelled) write(translator.cancel());
        else if (outcome.reason === 'rss_limit') write(translator.fail(ZapErrorCode.resourceLimitExceeded, `会话进程内存超过上限（${deps.config.processMaxRssMb}MB），已终止；请拆分任务或减少一次处理的数据量`));
        else if (outcome.reason === 'cpu_limit') write(translator.fail(ZapErrorCode.resourceLimitExceeded, `会话累计 CPU 时间超过上限（${deps.config.processCpuSeconds}s），已终止；请拆分任务后重试`));
        else if (outcome.reason === 'proc_limit') write(translator.fail(ZapErrorCode.resourceLimitExceeded, `会话同时运行的进程数超过上限（${deps.config.processMaxProcs}），已终止；请不要并行启动大量子进程`));
        else if (outcome.reason === 'disk_quota') write(translator.fail(ZapErrorCode.workspaceQuotaExceeded, `工作区超出磁盘配额（${deps.config.workspaceQuotaMb}MB），本轮已终止；请清理 outbox/ 或删除大文件后重试`));
        else write(translator.fail(ZapErrorCode.upstreamFailure, 'agent process exited unexpectedly'));
        log.warn({ detail: outcome.detail, reason: outcome.reason }, 'agent process died mid-turn');
        break;
    }
  } catch (err) {
    log.error({ err }, 'message stream failed');
    write(translator.fail(ZapErrorCode['internal'], 'internal runtime error'));
  } finally {
    await flushCompleted().catch(() => undefined);
    session.conversationModelBinding = undefined;
    done = true;
    session.inflight = false;
    markInflightDone();
    if (release) await release().catch(() => undefined);
    raw.end();
    deps.history.appendEvents(
      session,
      history.map((e) => ({ ...e, seq: session.event_seq++ })),
    );
    const outcome = translator.end?.kind ?? 'unknown';
    const { toolCalls, toolErrors, usage } = translator.stats();
    const totalMs = Date.now() - t0;
    const ttftMs = firstDeltaAt === undefined ? undefined : firstDeltaAt - t0;
    deps.metrics.observeMessage({
      outcome,
      ...(failCode ? { errorCode: failCode } : {}),
      ...(ttftMs === undefined ? {} : { ttftMs }),
      totalMs,
      toolCalls,
      toolErrors,
      ...(usage ? { inputTokens: usage.input_tokens, outputTokens: usage.output_tokens } : {}),
    });
    // 一条消息一行汇总，字段对齐 F24 run 口径（outcome/耗时/TTFT/工具数/失败数/token/model），
    // 加上运行时独有的进程维度（复用还是新拉、排队与 spawn 耗时）。正文与凭据一律不进日志。
    log.info(
      {
        outcome,
        error_code: failCode ?? null,
        frames: frameCount,
        ttft_ms: ttftMs ?? null,
        total_ms: totalMs,
        process: proc ? (procFresh ? 'spawned' : 'reused') : null,
        queued_ms: proc && procFresh ? proc.queuedMs : null,
        spawn_ms: proc && procFresh ? proc.spawnMs : null,
        tool_calls: toolCalls,
        tool_errors: toolErrors,
        input_tokens: usage?.input_tokens ?? null,
        output_tokens: usage?.output_tokens ?? null,
        model: usage?.model ?? null,
        pool: deps.pool.stats(),
      },
      'message stream finished',
    );
  }
}
