import net from 'node:net';
import { URL } from 'node:url';
import { clearTimeout, setTimeout } from 'node:timers';

/** Rust and this listener share the same AppContainer SID; the pipe has one fixed host destination. */
export async function startCodexBrokerRelay({ baseURL, pipe = process.env.LOCAL_AGENT_BROKER_PIPE, platform = process.platform }) {
  const base = new URL(baseURL);
  if (base.protocol !== 'http:' || base.hostname !== '127.0.0.1' || !base.port || base.pathname !== '/' || base.username || base.password) throw Error('invalid_broker');
  if (platform !== 'win32') return { url: base.origin, close() {} };
  const prefix = '\\\\.\\pipe\\LOCAL\\ZhiBan-';
  // StringFromGUID2 in the native launcher includes braces around the GUID.
  const suffix = pipe?.startsWith(prefix) ? pipe.slice(prefix.length) : '';
  if (!/^(?:[a-zA-Z0-9-]{1,100}|\{[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}\})$/.test(suffix)) throw Error('missing_broker_pipe');
  const connections = new Set();
  const server = net.createServer(downstream => {
    if (connections.size >= 32) { downstream.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'); return; }
    const connection = forwardCodexBrokerSocket(downstream, pipe, () => connections.delete(connection));
    connections.add(connection);
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const address = server.address();
  if (!address || typeof address === 'string' || address.port === Number(base.port)) { server.close(); throw Error('invalid_relay'); }
  return { url: `http://127.0.0.1:${address.port}`, close() { for (const connection of connections) connection.close(); connections.clear(); server.close(); } };
}

/** Fixed destination supplied by the validated launcher; exported for transport regression tests. */
export function forwardCodexBrokerSocket(downstream, pipe, onClose) {
  let upstream, retry, attempts = 0, closed = false;
  const close = () => {
    if (closed) return;
    closed = true; clearTimeout(firstByte); clearTimeout(retry);
    downstream.destroy(); upstream?.destroy(); onClose();
  };
  const firstByte = setTimeout(close, 10000); firstByte.unref();
  downstream.once('data', () => clearTimeout(firstByte));
  downstream.on('error', close); downstream.on('close', close);
  downstream.pause();
  const connect = () => {
    if (closed) return;
    upstream = net.connect({ path: pipe });
    let connected = false;
    upstream.on('connect', () => {
      connected = true;
      downstream.pipe(upstream); upstream.pipe(downstream); downstream.resume();
    });
    upstream.on('error', error => {
      if (!connected && error.code === 'EBUSY' && ++attempts < 5) { retry = setTimeout(connect, 100); return; }
      close();
    });
    upstream.on('close', () => {
      // pipe.end() has already queued downstream.end(). Preserve its buffered body.
      if (connected && !upstream.readableEnded) close();
    });
  };
  connect();
  return { close };
}
