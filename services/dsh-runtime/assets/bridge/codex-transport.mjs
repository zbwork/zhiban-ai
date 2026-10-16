/** Official JSON-RPC transports; the caller confines this entire process tree. */
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { createServer } from 'node:net';
import { randomBytes, createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import WebSocket from 'ws';

export async function openCodexTransport(binary, options = {}) {
  const events = new EventEmitter();
  const args = ['app-server', '--listen'];
  const config = options.config ?? [];
  const receive = (bytes) => {
    try {
      if (bytes.length > 4_000_000) throw new Error('app_server_frame_too_large');
      events.emit('message', JSON.parse(bytes.toString()));
    } catch { events.emit('invalid'); }
  };
  if ((options.platform ?? process.platform) !== 'win32') {
    const child = spawn(binary, [...args, 'stdio://', ...config], {
      cwd: options.cwd, env: process.env, stdio: ['pipe', 'pipe', 'pipe'],
    });
    child.stderr.resume();
    createInterface({ input: child.stdout, crlfDelay: Infinity }).on('line', receive);
    child.on('error', () => events.emit('invalid'));
    return { events, child, send: (message) => child.stdin.write(JSON.stringify(message) + '\n'), close: () => child.stdin.end() };
  }

  // Same-AppContainer loopback only. No network capability or host exemption.
  // Reserve an ephemeral port inside the fresh per-task container. Authentication
  // gates clients; the cleartext capability never appears in the command line.
  const reservation = createServer();
  await new Promise((resolve, reject) => {
    reservation.once('error', reject);
    reservation.listen(0, '127.0.0.1', resolve);
  });
  const address = `ws://127.0.0.1:${reservation.address().port}`;
  await new Promise((resolve) => reservation.close(resolve));
  const token = randomBytes(32).toString('hex');
  // Reqwest also discovers Windows system proxies. The fixed in-container relay
  // must stay direct; a host proxy is intentionally unreachable from this SID.
  const env = { ...process.env, NO_PROXY: '127.0.0.1,localhost,::1', no_proxy: '127.0.0.1,localhost,::1' };
  const child = spawn(binary, [...args, address, '--ws-auth', 'capability-token',
    '--ws-token-sha256', createHash('sha256').update(token).digest('hex'), ...config], {
    cwd: options.cwd, env, stdio: [0, 2, 2], windowsHide: true,
  });
  let exited = false;
  child.once('exit', () => { exited = true; });
  child.once('error', () => { exited = true; });
  let socket;
  try {
    const deadline = Date.now() + 20_000;
    while (!exited && Date.now() < deadline) {
      try {
        socket = await new Promise((resolve, reject) => {
          const candidate = new WebSocket(address, {
            headers: { Authorization: `Bearer ${token}` }, handshakeTimeout: 500,
            maxPayload: 4_000_000, perMessageDeflate: false,
          });
          candidate.once('open', () => resolve(candidate));
          candidate.once('error', reject);
        });
        break;
      } catch { await new Promise((resolve) => setTimeout(resolve, 100)); }
    }
    if (!socket || exited) { socket?.terminate(); throw new Error('app_server_startup_failed'); }
    socket.on('message', receive);
    socket.on('error', () => events.emit('invalid'));
    socket.on('close', () => { if (!exited) child.kill(); });
    child.once('exit', () => socket.terminate());
    return {
      events, child,
      send: (message) => socket.send(JSON.stringify(message)),
      close: () => { socket.close(); child.kill(); },
    };
  } catch (error) { child.kill(); throw error; }
}
