import type { ZapFrame } from '../translate/sse.js';

/** Merge adjacent text deltas before durable sequencing; preserve tool/terminal order. */
export class LocalEventBuffer {
  private pending?: ZapFrame;
  private lastFlush = 0;
  constructor(private readonly emit: (frame: ZapFrame) => void, private readonly now = Date.now) {}
  push(frame: ZapFrame): void {
    const delta = frame.event === 'message.reasoning' || frame.event === 'message.block.delta';
    if (!delta) { this.flush(); this.emit(frame); return; }
    if (this.pending && (this.pending.event !== frame.event || this.pending.data['block_index'] !== frame.data['block_index'])) this.flush();
    if (!this.pending) this.pending = structuredClone(frame);
    else if (frame.event === 'message.reasoning') this.pending.data['reasoning'] = String(this.pending.data['reasoning'] ?? '') + String(frame.data['reasoning'] ?? '');
    else {
      const previous = this.pending.data['block_delta'] as Record<string, unknown>;
      const next = frame.data['block_delta'] as Record<string, unknown>;
      previous['text'] = String(previous['text'] ?? '') + String(next['text'] ?? '');
    }
    if (this.now() - this.lastFlush >= 200 || JSON.stringify(this.pending).length >= 16000) this.flush();
  }
  flush(): void {
    if (!this.pending) return;
    const frame = this.pending; this.pending = undefined; this.lastFlush = this.now(); this.emit(frame);
  }
}
