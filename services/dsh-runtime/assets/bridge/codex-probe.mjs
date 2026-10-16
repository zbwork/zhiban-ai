import { openCodexTransport } from './codex-transport.mjs';
import { startCodexBrokerRelay } from './codex-broker-relay.mjs';

let relay, transport, ok = false;
try {
  relay = await startCodexBrokerRelay({ baseURL: process.argv[3] });
  if (await (await fetch(`${relay.url}/${process.argv[4]}`, { signal: AbortSignal.timeout(5000) })).text() !== process.argv[4]) throw new Error('broker_probe_failed');
  transport = await openCodexTransport(process.argv[2]);
  transport.events.on('invalid', () => transport.child.kill());
  transport.events.on('message', (message) => {
    if (message.id === 1) { ok = !!message.result?.userAgent; transport.close(); }
  });
  transport.child.once('exit', () => {
    relay.close(); process.stdout.write(ok ? 'ok' : 'failed'); process.exit(ok ? 0 : 2);
  });
  transport.send({ id: 1, method: 'initialize', params: { clientInfo: { name: 'zhiban_probe', version: '1' } } });
} catch { transport?.child.kill(); relay?.close(); process.exit(2); }
