import { lookup } from 'node:dns/promises';
import { addAbortListener } from 'node:events';
import { request as httpsRequest } from 'node:https';
import { request as httpRequest } from 'node:http';
import { isIP } from 'node:net';
import ipaddr from 'ipaddr.js';
import { LocalError } from './ledger.js';

export function publicAddress(address: string): boolean {
  try { return ipaddr.process(address).range() === 'unicast'; } catch { return false; }
}

/** Only task-provided signed resource URLs; never exposed as an arbitrary-URL worker tool. */
export async function downloadResource(raw: string, maxBytes: number, parent: AbortSignal, options: { allowHttpStorage?: boolean } = {}): Promise<Buffer> {
  const signal = AbortSignal.any([parent, AbortSignal.timeout(60_000)]);
  try {
    signal.throwIfAborted();
    const url = new URL(raw);
    const insecureDevStorage = options.allowHttpStorage === true && url.protocol === 'http:';
    const port = insecureDevStorage ? 80 : 443;
    if ((!insecureDevStorage && url.protocol !== 'https:') || url.username || url.password || url.hash || (url.port && url.port !== String(port))) throw new Error('url');
    const host = url.hostname.replace(/^\[|\]$/g, '');
    const addresses = isIP(host) ? [{ address: host, family: isIP(host) }] : await new Promise<Array<{ address: string; family: number }>>((resolve, reject) => {
      const listener = addAbortListener(signal, () => reject(new Error('cancelled')));
      void lookup(host, { all: true }).then(resolve, reject).finally(() => listener[Symbol.dispose]());
    });
    signal.throwIfAborted();
    if (!addresses.length || addresses.some(({ address }) => !publicAddress(address))) throw new Error('address');
    const target = addresses[0]!;
    // Connect to the checked IP while retaining the original TLS name and Host header.
    // agent:false prevents environment/global proxy configuration from changing the destination.
    return await new Promise<Buffer>((resolve, reject) => {
      const request = insecureDevStorage ? httpRequest : httpsRequest;
      const req = request({ protocol: url.protocol, hostname: target.address, family: target.family,
        servername: isIP(host) ? undefined : host, port, path: url.pathname + url.search,
        headers: { host: url.host, 'accept-encoding': 'identity' }, agent: false, signal,
      }, (response) => {
        if (response.statusCode !== 200 || Number(response.headers['content-length'] ?? 0) > maxBytes || (response.headers['content-encoding'] && response.headers['content-encoding'] !== 'identity')) {
          response.destroy(); reject(new Error('response')); return;
        }
        const chunks: Buffer[] = []; let size = 0;
        response.on('data', (chunk: Buffer) => {
          size += chunk.length;
          if (size > maxBytes) { response.destroy(new Error('limit')); return; }
          chunks.push(chunk);
        });
        response.once('end', () => resolve(Buffer.concat(chunks, size)));
        response.once('error', reject);
        response.once('aborted', () => reject(new Error('aborted')));
      });
      req.once('error', reject); req.end();
    });
  } catch { throw new LocalError(parent.aborted ? 'local.run_cancelled' : 'local.resource_download_failed'); }
}
