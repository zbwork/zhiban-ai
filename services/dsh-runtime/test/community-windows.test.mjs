import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
assert.equal(process.platform, 'win32', 'Run the native Windows acceptance on Windows');
const runtime = process.env.COMMUNITY_RUNTIME_TEST_ROOT;
const { confineDesktop } = await import(pathToFileURL(join(runtime, 'dist/desktop/confinement.js')));
const { desktopEnvironment } = await import(pathToFileURL(join(runtime, 'dist/desktop/platform.js')));

test('missing deny directories block creation and ancestor replacement, then clean up only owned empty directories', { timeout: 30000 }, async () => {
  const root = await mkdtemp(join(tmpdir(), 'community-future-deny-'));
  const workspace = join(root, 'workspace'); const retained = join(workspace, 'retained');
  const denied = join(retained, 'new-parent', 'PowerShell');
  await mkdir(retained, { recursive: true }); await writeFile(join(retained, 'user.txt'), 'keep');
  try {
    const script = `const fs=require('node:fs'),path=require('node:path'); const a=JSON.parse(process.argv[1]);
      for(const op of [()=>fs.writeFileSync(path.join(a.denied,'profile.ps1'),'bad'),()=>fs.renameSync(path.dirname(a.denied),path.join(a.workspace,'replaced'))]) {
        let blocked=false; try{op()}catch(e){if(!['EACCES','EPERM','EBUSY'].includes(e.code))throw e;blocked=true} if(!blocked)process.exit(17);
      }
      fs.writeFileSync(path.join(a.workspace,'allowed.txt'),'allowed');process.stdout.write('protected');`;
    const command = confineDesktop([process.execPath, '-e', script, JSON.stringify({ denied, workspace })], { readOnly: [], readWrite: [workspace], deny: [denied], brokerPort: 34567, network: true });
    const result = spawnSync(command[0], command.slice(1), { cwd: workspace, env: desktopEnvironment(workspace), encoding: 'utf8', timeout: 25000 });
    assert.equal(result.status, 0, result.stderr); assert.equal(result.stdout, 'protected');
    assert.equal(await readFile(join(workspace, 'allowed.txt'), 'utf8'), 'allowed');
    assert.equal(await readFile(join(retained, 'user.txt'), 'utf8'), 'keep');
    await assert.rejects(access(join(retained, 'new-parent')));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('missing deny outside writable roots fails closed without creating the target', { timeout: 30000 }, async () => {
  const root = await mkdtemp(join(tmpdir(), 'community-deny-scope-'));
  const workspace = join(root, 'workspace'); await mkdir(workspace);
  const denied = join(root, 'not-authorized');
  try {
    const command = confineDesktop([process.execPath, '-e', 'process.exit(99)'], { readOnly: [], readWrite: [workspace], deny: [denied], brokerPort: 34567 });
    const result = spawnSync(command[0], command.slice(1), { cwd: workspace, env: desktopEnvironment(workspace), encoding: 'utf8', timeout: 25000 });
    assert.equal(result.status, 1); await assert.rejects(access(denied));
  } finally { await rm(root, { recursive: true, force: true }); }
});
