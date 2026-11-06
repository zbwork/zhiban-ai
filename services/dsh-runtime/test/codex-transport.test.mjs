import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { pathToFileURL } from 'node:url';
const { openCodexTransport } = await import(pathToFileURL(join(process.env.COMMUNITY_RUNTIME_TEST_ROOT, 'assets/bridge/codex-transport.mjs')));

test('stdio transport confines config discovery while preserving caller options and EOF', { timeout: 10000 }, async () => {
  const root = await mkdtemp(join(tmpdir(), 'community-codex-stdio-'));
  let transport;
  try {
    await writeFile(join(root, 'app-server'), `
      const readline = require('node:readline');
      readline.createInterface({input:process.stdin}).on('line',line=>{
        const request=JSON.parse(line);
        process.stdout.write(JSON.stringify({id:request.id,args:process.argv.slice(2)})+'\\n');
      });
    `);
    const config = ['-c', 'project_root_markers=[".git"]'];
    transport = await openCodexTransport(process.execPath, { cwd: root, platform: 'darwin', config });
    const message = once(transport.events, 'message');
    transport.send({ id: 1, method: 'initialize' });
    assert.deepEqual(await message, [{ id: 1, args: ['--listen', 'stdio://', ...config, '-c', 'project_root_markers=[]'] }]);
    assert.deepEqual(config, ['-c', 'project_root_markers=[".git"]']);
    const exited = once(transport.child, 'exit');
    transport.close();
    assert.deepEqual(await exited, [0, null]);
  } finally { transport?.child.kill(); await rm(root, { recursive: true, force: true }); }
});
