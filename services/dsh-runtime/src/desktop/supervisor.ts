import type { ModelFailure } from './model-error.js';
import { recoveryState, type RecoveryCandidate, type RecoveryState } from './model-recovery.js';
import { PartialStopError } from './process.js';
import { LocalEventBuffer } from './event-buffer.js';
import { randomBytes } from 'node:crypto';
import type { DshEvent } from '../translate/dsh-events.js';
import { TurnTranslator } from '../translate/translator.js';
import type { ZapFrame } from '../translate/sse.js';
import type { TurnOutcome } from '../pool/process-pool.js';
import type { ModelServiceEndpointType } from '../assemble/byok-route.js';
import { type LocalLedger, LocalError, sameIdentity, type LocalEvent, type LocalIdentity, type LocalTask, type StoredRun } from './ledger.js';
import { LocalPolicy, type ApprovalRequest } from './policy.js';
import type { DesktopTurn } from './engine.js';
import type { LocalContextInput } from './context.js';
import type { DeliverableRequirement } from './deliverables.js';
import type { ArtifactMeta } from './artifacts.js';

/** true = authorized, false = server revoked, 'offline' = unreachable (refuse the call, keep the run). */
export type LeaseState = boolean | 'offline';
export interface StopLock { run: string; residual: number; at: number }

export interface LocalRunConfig { modelRecovery?: RecoveryCandidate[]; context?: LocalContextInput; prompt?: string; skillsDir?: string; contextID?: string; workspace: string; persona: string; history: string; protocol: ModelServiceEndpointType; mode?: 'ask' | 'assist' | 'full' }
export interface LocalEngine { run(turn: DesktopTurn): Promise<TurnOutcome>; cancel(task: LocalTask): Promise<void>; stop(): Promise<void> }
export interface ActiveLocalRun {
  task: LocalTask;
  config: LocalRunConfig;
  policy: LocalPolicy;
  controller: AbortController;
  credential: string;
  executionClosed?: boolean;
  /** Descendants that survived SIGKILL during this run's stop; drives the workspace stop-lock. */
  stopResidual?: number;
  done: Promise<void>;
  artifacts: ArtifactMeta[];
  /** Host-only notification after a validated immutable snapshot is published. */
  artifactsChanged?: () => void;
  archiveProgress?: (completed: number, total: number) => void;
  attemptedFileDelivery?: boolean;
  attemptedOfficeCreation?: boolean;
  deliverables?: DeliverableRequirement[];
  recovery: RecoveryState;
  /** Latest unrecovered model failure for this run; set only by the authenticated broker. */
  modelFailure?: ModelFailure;
  modelRequestSequence?: number;
  modelResponseFailed?: boolean;
}
export interface SupervisorOptions {
  identity: LocalIdentity;
  ledger: LocalLedger;
  engine: LocalEngine;
  /**
   * Server authority, queried before acceptance AND each model/tool call.
   *
   * `true` authorizes the call. `false` means the server revoked it — the run dies. `'offline'` means
   * we could not ask: the call is still refused (fail closed), but the run and its engine survive so
   * a reconnect can finish it (product decision Q4, 2026-09-12). `task.expiresAt` remains the backstop.
   */
  validateLease(task: LocalTask): Promise<LeaseState>;
  /** Short bounded interval; each check must honor its own network timeout. */
  leaseCheckMs?: number;
  onEvent(event: LocalEvent): void;
  onApproval(request: ApprovalRequest): void;
  onFatalError?(code: string): void;
  /** Called after durable local acceptance; no engine side effect precedes server acknowledgement. */
  confirmAccepted?(task: LocalTask): Promise<void>;
  prepareContext?(run: ActiveLocalRun): Promise<void>;
  releaseContext?(run: ActiveLocalRun): Promise<void>;
  /** Removes invalid snapshots while retaining valid partial results; never uploads. */
  verifyDeliverables?(run: ActiveLocalRun): Promise<void>;
  archiveDeliverables?(run: ActiveLocalRun): Promise<void>;
  requireDeliveryDeclaration?: boolean;
}

export class LocalSupervisor {
  private readonly active = new Map<string, ActiveLocalRun>();
  private readonly stopLocks = new Map<string, StopLock>();
  private stopped = false;
  constructor(private readonly opts: SupervisorOptions) {}

  /** Workspaces whose last stop left unreaped descendants (product decision Q5, 2026-09-12). */
  stopLockList(): Array<StopLock & { workspace: string }> {
    return [...this.stopLocks].map(([workspace, lock]) => ({ workspace, ...lock }));
  }

  /** Only an explicit user confirmation clears the lock; the helper never assumes cleanup succeeded. */
  clearStopLock(workspace: string): void { this.stopLocks.delete(workspace); }

  async accept(task: LocalTask, config: LocalRunConfig): Promise<{ fresh: boolean; run: StoredRun }> {
    // A workspace whose previous stop could not be verified refuses new work until the user clears it.
    const lock = this.stopLocks.get(config.workspace);
    if (lock) throw new LocalError('local.workspace_stop_pending');
    if (this.stopped || !sameIdentity(task, this.opts.identity) || task.expiresAt <= Date.now() || (await this.opts.validateLease(task)) !== true) throw new LocalError('local.lease_invalid');
    if (this.stopped) throw new LocalError('local.supervisor_stopped');
    const result = this.opts.ledger.accept(task, this.opts.identity);
    if (!result.fresh) return result;
    const run: ActiveLocalRun = {
      task: structuredClone(task), config: structuredClone(config), policy: new LocalPolicy(task.run, this.opts.onApproval),
      credential: `sk-local-${randomBytes(32).toString('base64url')}`, controller: new AbortController(), done: Promise.resolve(), artifacts: [], recovery: recoveryState(),
    };
    if (config.mode === 'ask') run.policy.setMode('ask');
    // Config is supplied exclusively by authenticated App preferences after local confirmation.
    if (config.mode === 'full') { const proof = run.policy.requestFull(); run.policy.setMode('full', proof.id); }
    this.active.set(task.run, run);
    // Ledger accepted is already committed. Start work only after this promise yields to the caller.
    run.done = Promise.resolve().then(() => this.execute(run)).catch(() => {
      // Cleanup/storage failures cannot leave a helper advertising usable credentials.
      this.stopped = true;
      for (const active of this.active.values()) {
        active.policy.revoke();
        active.controller.abort(new LocalError('local.host_failed'));
      }
      try { this.opts.onFatalError?.('local.host_failed'); } catch { /* shutdown notification is best effort */ }
    });
    return result;
  }

  runs(): ActiveLocalRun[] { return [...this.active.values()]; }

  get(run: string): ActiveLocalRun | undefined { return this.active.get(run); }

  async authorize(credential: string): Promise<ActiveLocalRun> {
    // A settled run cannot lend execution authority to asynchronous cleanup.
    if (!credential) throw new LocalError('local.lease_invalid');
    const run = [...this.active.values()].find((candidate) => candidate.credential === credential);
    const executable = () => run && !run.executionClosed && ['accepted', 'running'].includes(this.opts.ledger.get(run.task.run)?.status ?? '');
    if (!run || !executable() || this.stopped || run.controller.signal.aborted || run.task.expiresAt <= Date.now()) throw new LocalError('local.lease_invalid');
    const state = await this.opts.validateLease(run.task);
    // Offline refuses the call without killing the run; only a server revocation tears it down.
    if (state === 'offline') throw new LocalError('local.lease_offline');
    if (!state) {
      run.policy.revoke(); run.controller.abort(new LocalError('local.lease_invalid'));
      throw new LocalError('local.lease_invalid');
    }
    if (!executable() || run.credential !== credential || run.controller.signal.aborted || this.active.get(run.task.run) !== run) throw new LocalError('local.lease_invalid');
    return run;
  }

  private emit(task: LocalTask, frame: ZapFrame): void {
    const event = this.opts.ledger.append(task.run, task.fence, frame);
    // Transport failure must not turn a committed terminal result into a second result.
    try { this.opts.onEvent(event); } catch { /* durable replay is the retry path */ }
  }

  /**
   * Reports one recovery step to the Bus. `text` stays human-readable for the chat
   * stage line; the structured fields are what the run record persists as
   * retry_index / retry_reason / fallback_chain. Only controlled enums travel here —
   * never upstream error text.
   */
  modelProgress(task: LocalTask, text: string): void {
    const active = this.active.get(task.run);
    if (!active || active.controller.signal.aborted) return;
    const recovery = active.recovery;
    this.emit(task, { event: 'message.block.delta', data: { message_id: task.messageId, block_index: 0, block_delta: {
      type: 'local_model_recovery', text,
      retry_index: recovery.extraAttempts,
      retry_reason: recovery.lastReason ?? '',
      fallback_chain: recovery.chain.map((step) => ({ slot: step.slot, reason: step.reason })),
    } } });
  }

  private async execute(run: ActiveLocalRun): Promise<void> {
    const tr = new TurnTranslator(run.task.messageId, { strictTerminal: true });
    let terminal: ZapFrame | undefined;
    let nativeText = '';
    let knownUsage: Record<string, unknown> | undefined;
    const pendingTools = new Map<string, string>();
    let deliveryVerified = false;
    let attemptedOfficeCreation = false;
    let attemptedFileDelivery = false;
    const buffer = new LocalEventBuffer((frame) => this.emit(run.task, frame));
    run.artifactsChanged = () => {
      buffer.flush();
      this.emit(run.task, { event: 'message.block.delta', data: {
        message_id: run.task.messageId, block_index: 1,
        block_delta: { type: 'local_artifacts', blocks: run.artifacts.map((meta) => ({
          type: meta.mime.startsWith('image/') ? 'image' : 'file', ...meta,
        })) },
      } });
    };
    run.archiveProgress = (completed, total) => {
      buffer.flush();
      this.emit(run.task, { event: 'message.block.delta', data: {
        message_id: run.task.messageId, block_index: 1,
        block_delta: { type: 'local_archive_progress', completed, total },
      } });
    };
    const write = (frames: ZapFrame[]) => {
      for (const frame of frames) {
        // Only the host can attest to local snapshots; ignore reserved model-origin deltas.
        if (frame.event === 'message.block.delta' && ['local_artifacts', 'local_archive_progress'].includes((frame.data['block_delta'] as {type?: string} | undefined)?.type ?? '')) continue;
        if (frame.event === 'message.block.delta' && run.task.engine === 'codex_app_server') { const delta = frame.data['block_delta'] as {text?: string} | undefined; nativeText += delta?.text ?? ''; }
        if (frame.event === 'message.tool_call') {
          const tool = frame.data['tool_name'];
          pendingTools.set(String(frame.data['tool_call_id']), String(tool));
          if (tool === 'mcp__local__office_create') attemptedOfficeCreation = true;
          if (['mcp__local__write_file', 'mcp__local__edit_file', 'mcp__local__local_shell', 'mcp__local__office_create', 'mcp__local__image_generate', 'mcp__local__publish_artifact'].includes(String(tool))) attemptedFileDelivery = true;
        }
        if (frame.event === 'message.tool_result') pendingTools.delete(String(frame.data['tool_call_id']));
        if (['message.completed', 'message.failed', 'message.cancelled'].includes(frame.event)) { buffer.flush(); terminal = frame; }
        else buffer.push(frame);
      }
    };
    const failed = (code: string, message: string): ZapFrame => ({ event: 'message.failed', data: { message_id: run.task.messageId, error_code: code, error_message: message } });
    const cancelled = (): ZapFrame => run.controller.signal.reason instanceof LocalError && run.controller.signal.reason.code === 'local.repeated_tool_failure'
      ? failed('zap.local_execution_failed', '同一工具操作连续失败且参数未修正，已停止重复尝试；已生成的有效文件仍可查看。')
      : { event: 'message.cancelled', data: { message_id: run.task.messageId } };
    let checking = false;
    const leaseTimer = setInterval(() => {
      if (checking || run.controller.signal.aborted) return;
      checking = true;
      void this.opts.validateLease(run.task).then((state) => {
        // 'offline' keeps the run alive on purpose: a transient disconnect must not destroy context
        // that a reconnect can still deliver. Execution stays gated because authorize() refuses too.
        if (state === false) { run.policy.revoke(); run.controller.abort(new LocalError('local.lease_invalid')); }
      }, () => {
        run.policy.revoke(); run.controller.abort(new LocalError('local.lease_invalid'));
      }).finally(() => { checking = false; });
    }, this.opts.leaseCheckMs ?? 5000);
    leaseTimer.unref();
    const timeout = setTimeout(() => run.controller.abort(new LocalError('local.lease_expired')), Math.max(1, run.task.expiresAt - Date.now()));
    try {
      await this.opts.confirmAccepted?.(run.task);
      run.controller.signal.throwIfAborted();
      this.opts.ledger.start(run.task.run);
      write(tr.created());
      await this.opts.prepareContext?.(run);
      run.controller.signal.throwIfAborted();
      const outcome = await this.opts.engine.run({
        task: run.task, ...run.config, credential: run.credential, signal: run.controller.signal,
        onEvent: (event: DshEvent) => write(tr.push(event)),
        onFrame: (frame: ZapFrame) => write([frame]),
        onUsage: (usage) => { knownUsage = usage; },
      });
      buffer.flush();
      if (run.controller.signal.aborted || outcome.kind === 'aborted') {
        if (!tr.end) write(tr.cancel());
        terminal = cancelled();
      } else if (!terminal) {
        write(tr.fail(outcome.kind === 'timeout' ? 'zap.turn_timeout' : 'zap.upstream_failure', '本机执行未完整结束，请检查已有结果后续跑。'));
      } else if (outcome.kind !== 'completed' && terminal?.event === 'message.completed') {
        terminal = failed('zap.upstream_failure', '本机执行器异常结束，结果未确认。');
      }
    } catch (err) {
      if (err instanceof PartialStopError) run.stopResidual = (run.stopResidual ?? 0) + err.residual;
      buffer.flush();
      if (!tr.end) write(run.controller.signal.aborted ? tr.cancel() : tr.fail('zap.local_execution_failed', err instanceof LocalError ? err.code : '本机执行失败，请检查运行环境。'));
      else if (run.controller.signal.aborted) terminal = cancelled();
      else if (terminal?.event === 'message.completed') terminal = failed('zap.local_execution_failed', '本机执行未完整结束，请检查已有结果。');
    } finally {
      for (const [id, name] of pendingTools) buffer.push({event:'message.tool_result',data:{message_id:run.task.messageId,tool_call_id:id,tool_name:name,tool_status:'failed',tool_result:'工具调用已中断，结果未确认。'}});
      buffer.flush();
      attemptedFileDelivery ||= !!run.attemptedFileDelivery;
      attemptedOfficeCreation ||= !!run.attemptedOfficeCreation;
      run.executionClosed = true;
      run.credential = '';
      run.policy.revoke();
      try {
        // Revalidate immutable snapshots even on failed/cancelled turns. This step never uploads.
        try {
          // Plain answers and read-only browser turns have no delivery contract.
          // Running artifact verification for them turns a normal response into
          // a misleading "部分文件未通过交付校验" failure.
          if (attemptedFileDelivery || run.deliverables !== undefined || run.artifacts.length > 0) {
            await this.opts.verifyDeliverables?.(run);
            deliveryVerified = this.opts.verifyDeliverables !== undefined;
          }
          if (terminal?.event === 'message.completed') {
            if (this.opts.requireDeliveryDeclaration && attemptedFileDelivery && run.deliverables === undefined) terminal = failed('zap.deliverable_verification_failed', '尚未确认本轮交付要求，不能确认任务完成。已验证的部分文件仍可查看。');
            else if (attemptedOfficeCreation && run.artifacts.length === 0) terminal = failed('zap.deliverable_verification_failed', '文档尚未生成，未收到可交付文件。请检查工具参数或审批状态后重试。');
          }
        } catch (err) {
          if (terminal?.event === 'message.completed') {
            const code = err instanceof LocalError ? err.code : '';
            terminal = code === 'local.deliverable_missing'
              ? failed('zap.deliverable_missing', '未生成全部要求的文件。已验证的文件仍可查看。')
              : code === 'local.deliverable_content_mismatch'
                ? failed('zap.deliverable_content_mismatch', '文件已生成，但内容或大小未满足交付要求。已验证的文件仍可查看。')
                : failed('zap.deliverable_verification_failed', '部分文件未通过交付校验。已验证的文件仍可查看。');
          }
        }
        // Publish the verified set before potentially slow archival (including removed invalid files).
        if (run.artifacts.length || attemptedFileDelivery) run.artifactsChanged();
        // Archive uses the same task/snapshot identities, never reruns model or file-writing tools.
        if (run.artifacts.length && terminal?.event !== 'message.cancelled' && !run.controller.signal.aborted
          && await this.opts.validateLease(run.task).catch(() => false) === true) {
          try { await this.opts.archiveDeliverables?.(run); }
          catch { for (const meta of run.artifacts) if (meta.archive_status !== 'synced') meta.archive_status = 'failed'; }
        }
        if (run.controller.signal.aborted) terminal = cancelled();
        if (terminal?.event === 'message.completed' && this.opts.archiveDeliverables
          && run.artifacts.some((meta) => meta.archive_status !== 'synced')) {
          const originalBlocks = terminal.data['blocks'];
          terminal = failed('zap.local_archive_failed', '文件已生成，但云盘保存未完成，可先查看本机文件。');
          terminal.data['blocks'] = originalBlocks;
        }
        if (terminal?.event === 'message.completed' && run.modelResponseFailed && run.modelFailure) {
          const blocks = terminal.data['blocks'];
          terminal = failed(run.modelFailure.code, run.modelFailure.message);
          terminal.data['blocks'] = blocks;
        }
        if (terminal?.event === 'message.failed' && run.modelFailure && !run.controller.signal.aborted) {
          // Keep partial blocks/files and the terminal identity. Cancellation and success win.
          terminal.data['error_code'] = run.modelFailure.code;
          terminal.data['error_message'] = run.modelFailure.message;
        }
        if (terminal) {
          if (knownUsage) terminal.data['usage'] = knownUsage;
          const blocks: Record<string, unknown>[] = Array.isArray(terminal.data['blocks'])
            ? terminal.data['blocks'].filter((block: unknown): block is Record<string, unknown> =>
              !!block && typeof block === 'object' && !Array.isArray(block)
              && !('local_artifact' in block) && (!('type' in block) || block.type !== 'local_delivery'))
            : [];
          if (terminal.event !== 'message.completed' && (tr.finalText() || nativeText) && !blocks.some((block) => block['type'] === 'markdown' && block['text'] === (tr.finalText() || nativeText))) blocks.push({ type: 'markdown', text: tr.finalText() || nativeText });
          if (['message.failed', 'message.cancelled'].includes(terminal.event) && run.artifacts.length > 0 && this.opts.verifyDeliverables) {
            blocks.push({ type: 'local_delivery', status: deliveryVerified && (run.deliverables?.length ?? 0) > 0 ? 'complete' : 'partial', verified_count: run.artifacts.length, required_count: run.deliverables?.length ?? 0 });
          }
          terminal.data['blocks'] = [...blocks, ...run.artifacts.map((meta) => ({ type: meta.mime.startsWith('image/') ? 'image' : 'file', ...meta }))];
          if (run.recovery.usedSlots.some((slot) => slot !== 0)) {
            const usage = terminal.data['usage'];
            if (usage && typeof usage === 'object') delete (usage as Record<string, unknown>)['model'];
            terminal.data['model_routes'] = run.recovery.usedSlots;
          }
          const status = this.opts.ledger.get(run.task.run)?.status;
          if (status === 'running' || status === 'accepted') this.emit(run.task, terminal);
        }
      } finally {
        clearTimeout(timeout);
        clearInterval(leaseTimer);
        run.policy.revoke();
        run.credential = '';
        run.controller.abort(new LocalError('local.run_settled'));
        // Stop could not be proven complete: hold the workspace until the user confirms (Q5).
        if (run.stopResidual) this.stopLocks.set(run.config.workspace, { run: run.task.run, residual: run.stopResidual, at: Date.now() });
        try { await this.opts.engine.cancel(run.task); } finally {
          try { await this.opts.releaseContext?.(run); } finally { this.active.delete(run.task.run); }
        }
      }
    }
  }

  async cancel(runID: string, fence: number): Promise<void> {
    const run = this.active.get(runID);
    const stored = this.opts.ledger.get(runID);
    if (!stored || stored.task.fence !== fence || !sameIdentity(stored.task, this.opts.identity)) throw new LocalError('local.fence_mismatch');
    if (!run) return;
    run.policy.revoke();
    run.controller.abort(new LocalError('local.run_cancelled'));
    await run.done;
  }

  async stop(): Promise<void> {
    this.stopped = true;
    const runs = [...this.active.values()];
    for (const run of runs) { run.policy.revoke(); run.controller.abort(new LocalError('local.supervisor_stopped')); }
    await Promise.allSettled(runs.map((run) => run.done));
    await this.opts.engine.stop();
  }
}
