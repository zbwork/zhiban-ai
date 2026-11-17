import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.env.COMMUNITY_RUNTIME_TEST_ROOT;
assert.ok(root);
const { DesktopChannel } = await import(pathToFileURL(join(root, 'dist/desktop/channel.js')));
const skill = '582d21b6-4424-4cee-a386-f07be9480bb2';
const identity = { tenant: 'tenant', account: 'member', loginSession: 'session', device: 'device' };

test('skill package uses only the connected Bus and run capability, with bounded bytes and no redirect', async () => {
  let mode = 'ok'; let requests = 0;
  const server = createServer((req, res) => {
    requests++;
    assert.equal(req.url, `/api/agent-bus/v1/local-runtime/runs/run/skills/${skill}/package`);
    assert.equal(req.headers.authorization, 'Bearer run-only-capability');
    assert.equal(req.headers['x-local-fence'], '3');
    if (mode === 'redirect') { res.writeHead(302, {location:'/never'}); res.end(); return; }
    if (mode === 'revoke') channel.capabilities.clear();
    res.end(mode === 'large' ? 'oversized' : 'zip');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const channel = new DesktopChannel({baseURL:`http://127.0.0.1:${server.address().port}/api/agent-bus/v1`, identity});
  channel.connected = true; channel.capabilities.set('run', 'run-only-capability');
  const task = {...identity, run:'run', fence:3};
  const get = (input=task, id=skill) => channel.skillPackage(input, id, 3, new AbortController().signal);
  try {
    assert.equal((await get()).toString(), 'zip');
    const before = requests;
    await assert.rejects(get({...task, account:'other'}), /local.lease_invalid/);
    await assert.rejects(get(task, '../other'), /local.lease_invalid/);
    assert.equal(requests, before);
    mode = 'large'; await assert.rejects(get(), /local.resource_download_failed/);
    mode = 'redirect'; await assert.rejects(get()); assert.equal(requests, before + 2);
    mode = 'revoke'; await assert.rejects(get(), /local.lease_invalid/);
  } finally { await new Promise(resolve => server.close(resolve)); }
});
