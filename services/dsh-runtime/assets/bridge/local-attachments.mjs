// Keep official raster validation/replay. Only the trusted host fsyncs ancestor
// directories; workers retain their existing private-home filesystem sandbox.
import { URL } from 'node:url';
import { Buffer } from 'node:buffer';
import { LocalAttachmentStore } from '@deepseek-ai/dsh-attachment-local';

export default class DesktopAttachmentStore extends LocalAttachmentStore {
  async saveImage(input) {
    const endpoint = new URL(process.env.LOCAL_AGENT_BROKER_URL ?? 'http://invalid');
    const key = process.env.LOCAL_AGENT_BROKER_KEY;
    if (endpoint.protocol !== 'http:' || endpoint.hostname !== '127.0.0.1' || !endpoint.port || !key) {
      throw new Error('local attachment broker unavailable');
    }
    const response = await fetch(new URL('/worker/attachments/image', endpoint), {
      method: 'POST', headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
      body: JSON.stringify({ mediaType: input.mediaType, data: Buffer.from(input.data).toString('base64'),
        ...(input.name ? { name: input.name.slice(0, 200) } : {}) }),
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error('local image storage failed');
    return response.json();
  }
}
