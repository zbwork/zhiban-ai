import type { ArtifactStore, ArtifactMeta } from './artifacts.js';
import { archiveLocalOutputs, type ArchiveTransport } from './archive.js';
import type { LocalIdentity, LocalLedger, LocalTask } from './ledger.js';

/** Durable delivery outbox: no model, tool, worker credential, or workspace scan. */
export class ResultRecovery {
  private busy = false;
  constructor(private readonly opts: {
    identity: LocalIdentity; ledger: LocalLedger; artifacts: ArtifactStore;
    save(task: LocalTask, artifacts: ArtifactMeta[], signal: AbortSignal): Promise<boolean>;
    transport(task: LocalTask): ArchiveTransport;
    onSaved?(task: LocalTask): void;
  }) {}

  async drain(signal: AbortSignal): Promise<void> {
    if (this.busy || signal.aborted) return;
    this.busy = true;
    try {
      for (const item of this.opts.ledger.pendingResults(this.opts.identity)) {
        if (signal.aborted) return;
        let complete = false;
        try {
          const canArchive = await this.opts.save(item.task, item.artifacts, signal);
          if (canArchive && item.artifacts.some((meta) => meta.archive_status !== 'synced')) {
            const controller = new AbortController();
            const abort = () => controller.abort(signal.reason);
            signal.addEventListener('abort', abort, { once: true });
            try {
              if (signal.aborted) abort();
              await archiveLocalOutputs({task: item.task, artifacts: item.artifacts, controller}, this.opts.artifacts, this.opts.transport(item.task));
            } finally { signal.removeEventListener('abort', abort); }
            await this.opts.save(item.task, item.artifacts, signal);
          }
          complete = !canArchive || item.artifacts.every((meta) => meta.archive_status === 'synced');
          this.opts.onSaved?.(item.task);
        } catch { /* bounded durable retry; never change execution status */ }
        this.opts.ledger.saveResultAttempt(item.task.run, item.artifacts, complete);
      }
    } finally { this.busy = false; }
  }
}
