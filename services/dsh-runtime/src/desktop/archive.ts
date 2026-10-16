import { setTimeout as delay } from 'node:timers/promises';
import type { ArtifactStore } from './artifacts.js';
import type { ActiveLocalRun } from './supervisor.js';
import { LocalError } from './ledger.js';

export interface OutputRequest { artifact_id: string; sha256: string; file_name: string; file_size: number; mime_type: string }
export interface ArchiveTransport {
  /** Only the explicit loopback Bus development configuration may use HTTP object storage. */
  allowHttpStorage?: boolean;
  sign(body: OutputRequest, signal: AbortSignal): Promise<{ upload_url?: string; upload_headers?: Record<string, string>; uploaded?: boolean }>;
  confirm(body: OutputRequest, signal: AbortSignal): Promise<{ id: string }>;
}

/** Archive only this turn's published immutable snapshots. No workspace scan or UI-triggered upload. */
export async function archiveLocalOutputs(run: Pick<ActiveLocalRun, 'task' | 'controller' | 'artifacts' | 'archiveProgress'>, store: ArtifactStore, transport: ArchiveTransport): Promise<void> {
  const signal = run.controller.signal;
  const owner = { tenant: run.task.tenant, account: run.task.account, device: run.task.device, employee: run.task.employee, conversation: run.task.conversation, run: run.task.run };
  let completed = 0;
  run.archiveProgress?.(completed, run.artifacts.length);
  for (const meta of run.artifacts) {
    signal.throwIfAborted();
    if (meta.archive_status === 'synced') { run.archiveProgress?.(++completed, run.artifacts.length); continue; }
    const request = { artifact_id: meta.local_artifact.artifact_id, sha256: meta.local_artifact.sha256, file_name: meta.name, file_size: meta.size, mime_type: meta.mime };
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const { bytes } = await store.read(owner, meta.local_artifact);
        const signed = await transport.sign(request, signal);
        signal.throwIfAborted();
        if (!signed.uploaded) {
          const url = new URL(signed.upload_url ?? '');
          if (url.username || url.password || (url.protocol !== 'https:' && !(url.protocol === 'http:' && (url.hostname === '127.0.0.1' || transport.allowHttpStorage)))) throw new LocalError('local.invalid_upload_url');
          // Never forward Bus credentials to object storage or follow redirects.
          const headers = new Headers(signed.upload_headers);
          if ([...headers.keys()].some((key) => ['authorization', 'cookie', 'proxy-authorization'].includes(key.toLowerCase()))) throw new LocalError('local.invalid_upload_headers');
          if (!headers.has('content-type')) headers.set('content-type', meta.mime);
          const response = await fetch(url, { method: 'PUT', redirect: 'error', headers, body: new Uint8Array(bytes), signal: AbortSignal.any([signal, AbortSignal.timeout(120_000)]) });
          await response.body?.cancel();
          if (!response.ok) throw new LocalError('local.archive_upload_failed');
        }
        const result = await transport.confirm(request, signal);
        if (!/^[0-9a-f-]{36}$/i.test(result.id)) throw new LocalError('local.archive_unconfirmed');
        meta.drive_file_id = result.id;
        meta.archive_status = 'synced';
        break;
      } catch {
        signal.throwIfAborted();
        meta.archive_status = 'failed';
        if (attempt < 2) await delay(300 * (attempt + 1), undefined, { signal });
      }
    }
    run.archiveProgress?.(++completed, run.artifacts.length);
  }
}
