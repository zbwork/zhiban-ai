/**
 * ZAP-1.1 北侧路由：runtime_card / agents CRUD / instances & tenants / sessions & messages(SSE) & cancel & delete。
 * 所有响应只讲 ZAP 词汇；错误经 app.ts 统一落 { ok:false, error:{ code:'zap.*', message } }。
 */
import type { FastifyInstance } from 'fastify';
import { newSessionToken, type SessionRecord } from '../sessions/session-store.js';
import { newBridgeKey } from '../backchannel/bridge.js';
import { applyPatch, parsePatch, parseSkillsNode, skillsFromSnapshot } from '../skills/skills.js';
import { validateAgentKey, validatePatch } from '../store/agent-store.js';
import { agentInfo, buildAgentCard, validateUiComponents } from './agent-card.js';
import { assertPathSegment, parseInbound, streamMessage } from './chat.js';
import type { AppDeps } from './deps.js';
import { ZapError, ZapErrorCode, zapErrors } from './errors.js';
import { buildRuntimeCard } from './runtime-card.js';

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Obj) : {});
const str = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');

export function registerZapRoutes(zap: FastifyInstance, deps: AppDeps): void {
  const { store, sessions, pool, identity, config, skills } = deps;
  const runtimeCard = buildRuntimeCard(config);

  /** 内存表没有就去历史库找回（shim 重启 / 另一副本接手）；找回时把技能重新落盘。 */
  const resolveSession = async (sid: string): Promise<SessionRecord | undefined> => {
    const inMemory = sessions.get(sid);
    if (inMemory) return inMemory;
    const found = await deps.history.findSession(sid);
    if (!found || !store.has(found.agent_key)) return undefined;
    const rec = sessions.rehydrate(found);
    if (rec === found && deps.bus && rec.agent_id) rec.bridgeKey = newBridgeKey();
    if (rec === found && rec.skills.agent.size > 0) {
      rec.skillsReady = skills.prepareSession(sid).then(() => skills.materializeAll(sid, rec.skills.agent.values())).then(() => undefined);
    }
    deps.log.info({ session_id: sid, agent_key: found.agent_key, conversation_id: found.conversation_id, skills: rec.skills.agent.size }, 'session rehydrated from history');
    return rec;
  };

  /** 技能文件操作排队：不打断进行中的轮次（§11.4 第 4 条），串在 skillsReady 链上。 */
  const scheduleSkillOps = (rec: SessionRecord, ops: () => Promise<unknown>): void => {
    const gate = rec.inflight && rec.inflightDone ? rec.inflightDone : Promise.resolve();
    rec.skillsReady = rec.skillsReady
      .then(() => gate)
      .then(ops)
      .then(() => undefined)
      .catch((err: unknown) => deps.log.warn({ session_id: rec.session_id, detail: String(err) }, 'skill file operation failed'));
  };

  zap.get('/runtime_card', async () => runtimeCard);

  // ---- agents（管理面 §2）----
  zap.get('/agents', async () => {
    const agents = store.list().map(agentInfo);
    return { ok: true, agents, total: agents.length };
  });

  zap.post('/agents', async (req, reply) => {
    const body = obj(req.body);
    const key = validateAgentKey(body['agent_key']);
    if (store.has(key)) throw zapErrors.agentKeyExists(key);
    const patch = validatePatch(body, { allowAgentKey: key });
    const bad = validateUiComponents(patch.ui_components);
    if (bad) throw new ZapError(ZapErrorCode.invalidRequest, 422, `ui_components not a subset of runtime_ui_components: ${bad}`);
    const rec = await store.create({ agent_key: key, ...patch });
    deps.log.info({ agent_key: key }, 'agent registered');
    void reply.status(201);
    return { ok: true, agent_key: rec.agent_key, message: 'created', agent_card: buildAgentCard(rec) };
  });

  zap.get('/agents/:agent_key/card', async (req) => {
    const key = validateAgentKey((req.params as Obj)['agent_key']);
    const rec = store.get(key);
    if (!rec) throw zapErrors.agentKeyNotFound(key);
    return { ok: true, agent: agentInfo(rec), agent_card: buildAgentCard(rec) };
  });

  zap.patch('/agents/:agent_key', async (req) => {
    const key = validateAgentKey((req.params as Obj)['agent_key']);
    if (!store.has(key)) throw zapErrors.agentKeyNotFound(key);
    const patch = validatePatch(req.body, { allowAgentKey: key });
    const bad = validateUiComponents(patch.ui_components);
    if (bad) throw new ZapError(ZapErrorCode.invalidRequest, 422, `ui_components not a subset of runtime_ui_components: ${bad}`);
    const rec = await store.update(key, patch);
    deps.log.info({ agent_key: key, revision: rec.revision }, 'agent updated');
    return { ok: true, agent_key: rec.agent_key, message: 'updated', agent_card: buildAgentCard(rec) };
  });

  zap.delete('/agents/:agent_key', async (req) => {
    const key = validateAgentKey((req.params as Obj)['agent_key']);
    const existed = await store.delete(key);
    deps.log.info({ agent_key: key, existed }, 'agent deleted');
    return { ok: true, agent_key: key, message: existed ? 'deleted' : 'already absent' };
  });

  // ---- identity（§10 最小实现）----
  const initializeInstance = async (body: unknown) => {
    const res = identity.initialize(obj(body));
    if (!res) throw new ZapError(ZapErrorCode.invalidRequest, 422, 'tenant.tenant_id and user.user_id are required');
    return { ok: true, runtime_identity: res.identity, mapping_status: 'matched', matched_by: 'platform_uuid' };
  };
  zap.post('/instances', async (req) => initializeInstance(req.body));
  zap.post('/identity/provision', async (req) => initializeInstance(req.body));
  const upsertTenant = async (params: unknown, body: unknown) => {
    const tenantId = str((params as Obj)['tenant_id']);
    if (!tenantId) throw zapErrors.invalidRequest('tenant_id is required');
    identity.upsertTenant(tenantId, obj(body));
    return { ok: true, runtime_identity: { tenant_id: tenantId }, status: 'active' };
  };
  zap.put('/tenants/:tenant_id', async (req) => upsertTenant(req.params, req.body));
  zap.put('/identity/tenants/:tenant_id', async (req) => upsertTenant(req.params, req.body));

  // §10.5 user upsert
  zap.put('/identity/users/:user_id', async (req) => {
    const userId = str((req.params as Obj)['user_id']);
    const body = obj(req.body);
    const tenantId = str(body['tenant_id']) || str(obj(body['tenant'])['tenant_id']);
    if (!tenantId || !userId) throw zapErrors.identityProfileInvalid('tenant_id and user_id are required');
    const bodyUserId = str(obj(body['user'])['user_id']);
    if (bodyUserId && bodyUserId !== userId) throw zapErrors.identityProfileInvalid('user.user_id must equal path user_id');
    const { identity: id, created } = identity.upsertUser(tenantId, userId, body);
    deps.log.info({ tenant_id: tenantId, user_id: userId, created }, 'identity user upserted');
    return { ok: true, runtime_identity: id, mapping_status: created ? 'created' : 'matched', matched_by: 'platform_uuid' };
  });

  // §10.6 user resolve
  zap.post('/identity/users/resolve', async (req) => {
    const body = obj(req.body);
    const tenantId = str(body['tenant_id']);
    if (!tenantId) throw zapErrors.identityProfileInvalid('tenant_id is required');
    const res = identity.resolveUser(tenantId, body);
    if (res === 'not_found') throw zapErrors.identityUserNotFound(str(body['user_id']) || str(body['provider_subject']) || str(body['email']) || '?');
    if (res === 'conflict') throw zapErrors.identityMappingConflict();
    return { ok: true, runtime_identity: res.identity, mapping_status: 'matched', matched_by: str(body['user_id']) ? 'platform_uuid' : 'runtime_policy' };
  });

  // §10.7 user status：suspended / deactivated → 拒开新会话 + 杀掉在跑的会话进程
  zap.patch('/identity/users/:user_id/status', async (req) => {
    const userId = str((req.params as Obj)['user_id']);
    const body = obj(req.body);
    const tenantId = str(body['tenant_id']);
    const status = str(body['status']);
    if (!tenantId || !userId) throw zapErrors.identityProfileInvalid('tenant_id and user_id are required');
    if (status !== 'active' && status !== 'suspended' && status !== 'deactivated') throw zapErrors.identityProfileInvalid('status must be active|suspended|deactivated');
    if (!identity.setUserStatus(tenantId, userId, status)) {
      // 没登记过也接受（Bus 可能只推状态）：按状态建一条最小记录
      identity.upsertUser(tenantId, userId, { user: { user_id: userId } });
      identity.setUserStatus(tenantId, userId, status);
    }
    let cancelled = 0;
    if (status !== 'active') {
      for (const rec of sessions.forUser(tenantId, userId)) {
        sessions.cancel(rec.session_id);
        if (await pool.kill(rec.session_id, 'user_' + status)) cancelled += 1;
        await deps.history.sessionCancelled(rec.session_id);
      }
    }
    deps.log.info({ tenant_id: tenantId, user_id: userId, status, reason: str(body['reason']), sessions_cancelled: cancelled }, 'identity user status patched');
    return { ok: true, runtime_identity: { tenant_id: tenantId, user_id: userId }, status };
  });

  // ---- sessions（数据面 §3）----
  zap.post('/sessions', async (req) => {
    const body = obj(req.body);
    const agentKey = str(body['agent_key']);
    if (!agentKey) throw zapErrors.invalidRequest('agent_key is required');
    if (!store.has(agentKey)) throw zapErrors.agentKeyNotFound(agentKey);
    const agentCtx = obj(body['agent']);
    if (str(agentCtx['agent_key']) && str(agentCtx['agent_key']) !== agentKey) throw zapErrors.agentContextMismatch();
    const user = obj(body['user']);
    const hint = obj(body['conversation_context_hint']);
    const sessionKind = str(body['session_kind']) || 'single';
    const isA2a = sessionKind === 'a2a';
    const tenantId = str(user['tenant_id']);
    const userId = str(user['user_id']);
    if (!tenantId) throw zapErrors.contextMissing('user.tenant_id is required');
    if (!isA2a) {
      if (!userId) throw zapErrors.contextMissing('user.user_id is required');
      if (!str(hint['tenant_id']) || !str(hint['user_id'])) throw zapErrors.contextMissing('conversation_context_hint.tenant_id and user_id are required');
      if (str(hint['user_id']) !== userId) throw zapErrors.accountMismatch();
    }
    if (str(hint['tenant_id']) && str(hint['tenant_id']) !== tenantId) throw zapErrors.tenantMismatch();
    assertPathSegment(tenantId, 'user.tenant_id');
    assertPathSegment(userId || 'a2a', 'user.user_id');
    if (userId) {
      const status = identity.userStatus(tenantId, userId);
      if (status !== 'active') throw zapErrors.userInactive(status);
    }
    const purpose = str(hint['purpose']) || 'production';
    // ZAP-1.1 §11.1：可选 skills 节（Bus 过滤后的该员工技能集）
    let skillsNode: ReturnType<typeof parseSkillsNode> | undefined;
    if (body['skills'] !== undefined) {
      skillsNode = parseSkillsNode(body['skills']);
      if (skillsNode.errors.length > 0) throw zapErrors.patchInvalid(skillsNode.errors);
    }
    const rec = sessions.create({
      agent_key: agentKey,
      tenant_id: tenantId,
      user_id: userId || 'a2a',
      conversation_id: str(hint['conversation_id']),
      purpose,
      session_kind: sessionKind,
      agent_id: str(agentCtx['agent_id']),
      metadata: obj(body['metadata']),
    });
    // 反向通道工具桥：需要数字员工 UUID（runtime_access 按 agent 绑定换发）
    if (deps.bus && rec.agent_id) rec.bridgeKey = newBridgeKey();
    if (skillsNode) {
      rec.skills = skillsFromSnapshot(skillsNode.snapshot, 0);
      const list = [...rec.skills.agent.values()];
      rec.skillsReady = skills.prepareSession(rec.session_id).then(() => skills.materializeAll(rec.session_id, list)).then(() => undefined);
    }
    await deps.history.sessionCreated(rec);
    deps.log.info(
      { session_id: rec.session_id, agent_key: agentKey, conversation_id: rec.conversation_id, purpose, session_kind: sessionKind, agent_skills: rec.skills.agent.size, builtin_skills: rec.skills.builtin.length },
      'session created',
    );
    return {
      ok: true,
      session_id: rec.session_id,
      session_token: newSessionToken(),
      expires_at: new Date(rec.expires_at).toISOString(),
      agent_key: agentKey,
      metadata: { purpose, session_kind: sessionKind, ...(purpose === 'debug' ? { is_debug: true } : {}) },
      ...(skillsNode ? { agent_state: 'ready', skill_packages_cached: skills.cachedList(rec.skills.agent.values()) } : {}),
    };
  });

  // ---- skills carrier（§11.2 / §11.3）----
  zap.patch('/sessions/:session_id/skills', async (req, reply) => {
    const sid = str((req.params as Obj)['session_id']);
    const idem = str(req.headers['idempotency-key']);
    const cacheKey = idem ? `${sid}:${idem}` : '';
    if (cacheKey) {
      const hit = deps.idempotency.get(cacheKey);
      if (hit) return reply.status(hit.status).send(hit.body);
    }
    const respond = (status: number, body: unknown) => {
      if (cacheKey) deps.idempotency.set(cacheKey, status, body);
      return reply.status(status).send(body);
    };
    try {
      const session = await resolveSession(sid);
      if (!session) throw zapErrors.skillsSessionNotFound(sid);
      const { patch, errors } = parsePatch(req.body);
      const headerSeq = str(req.headers['x-zap-patch-seq']);
      if (headerSeq && Number(headerSeq) !== patch.patch_seq) errors.push('X-ZAP-Patch-Seq header must equal body.patch_seq');
      if (errors.length > 0) throw zapErrors.patchInvalid(errors);
      const outcome = applyPatch(session.skills, patch);
      if (outcome.kind === 'outdated') throw zapErrors.patchSeqOutdated(outcome.current_seq);
      if (outcome.kind === 'gap') throw zapErrors.patchGap(outcome.current_seq, outcome.expected_seq, outcome.received_seq);
      const { materialize, remove } = outcome;
      scheduleSkillOps(session, async () => {
        await skills.prepareSession(sid);
        for (const r of remove) if (![...session.skills.agent.values()].some((s) => s.code === r.code)) await skills.remove(sid, r.code);
        await skills.materializeAll(sid, materialize);
      });
      await deps.history.sessionSkillsUpdated(session);
      deps.log.info({ session_id: sid, patch_seq: patch.patch_seq, added: patch.added.length, updated: patch.updated.length, removed: patch.removed.length }, 'skills patch applied');
      return respond(200, { applied: true, patch_seq_applied: patch.patch_seq, skill_packages_cached: skills.cachedList(session.skills.agent.values()) });
    } catch (err) {
      if (err instanceof ZapError) return respond(err.httpStatus, err.toBody());
      throw err;
    }
  });

  zap.post('/sessions/:session_id/skills/resync', async (req) => {
    const sid = str((req.params as Obj)['session_id']);
    const session = await resolveSession(sid);
    if (!session) throw zapErrors.skillsSessionNotFound(sid);
    const { snapshot, errors } = parseSkillsNode(obj(req.body)['skills']);
    if (errors.length > 0) throw zapErrors.patchInvalid(errors);
    session.skills = skillsFromSnapshot(snapshot, 0);
    const list = [...session.skills.agent.values()];
    scheduleSkillOps(session, () => skills.replaceAll(sid, list));
    await deps.history.sessionSkillsUpdated(session);
    deps.log.info({ session_id: sid, agent_skills: list.length, builtin_skills: session.skills.builtin.length }, 'skills resynced');
    return { applied: true, patch_seq_applied: 0, skill_packages_cached: skills.cachedList(list) };
  });

  zap.post('/sessions/:session_id/messages', async (req, reply) => {
    const sid = str((req.params as Obj)['session_id']);
    // 内存表没有 → 历史库找回（shim 重启 / 另一副本接手）；已取消/删除/过期的找不回 → 404，Bus 会带同一 conversation_id 重建
    const session = await resolveSession(sid);
    if (!session) throw zapErrors.sessionNotFound(sid);
    if (session.cancelled) throw zapErrors.sessionCancelled(sid);
    if (session.inflight) throw zapErrors.sessionBusy(sid);
    const { message, droppedBlocks } = parseInbound(req.body);
    if (droppedBlocks > 0) deps.log.warn({ session_id: sid, dropped_blocks: droppedBlocks }, 'non-text blocks ignored (not supported in this phase)');
    // 跨副本互斥（PG advisory lock）：另一副本正在跑这条会话 → 409，与单副本内存态口径一致
    const release = await deps.history.lockSession(sid);
    if (!release) throw zapErrors.sessionBusy(sid);
    await streamMessage(deps, session, message, req, reply, release);
  });

  zap.post('/sessions/:session_id/cancel', async (req) => {
    const sid = str((req.params as Obj)['session_id']);
    const session = sessions.cancel(sid);
    if (!session) throw zapErrors.sessionNotFound(sid);
    const killed = await pool.kill(sid, 'cancel');
    await deps.history.sessionCancelled(sid);
    deps.log.info({ session_id: sid, killed }, 'session cancelled');
    return { ok: true, session_id: sid, cancelled: true };
  });

  zap.delete('/sessions/:session_id', async (req) => {
    const sid = str((req.params as Obj)['session_id']);
    const rec = sessions.get(sid);
    const existed = sessions.delete(sid);
    await pool.kill(sid, 'delete');
    await deps.history.sessionDeleted(sid);
    await skills.removeSession(sid);
    if (rec) await deps.cordis.removeSession(rec.agent_key, { tenant: rec.tenant_id, user: rec.user_id, session: sid });
    if (!existed) throw zapErrors.sessionNotFound(sid);
    return { ok: true, session_id: sid, deleted: true };
  });
}
