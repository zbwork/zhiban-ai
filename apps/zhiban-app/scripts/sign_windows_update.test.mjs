import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

test('signs exact installer bytes and rejects a different public key', () => {
  const root = mkdtempSync(join(tmpdir(), 'zhiban-signature-'));
  try {
    const { privateKey, publicKey } = generateKeyPairSync('ed25519');
    const key = join(root, 'private.pem'), pub = join(root, 'public.txt'), artifact = join(root, 'package.exe');
    const bytes = Buffer.from('test installer bytes');
    writeFileSync(key, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
    writeFileSync(pub, publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64'));
    writeFileSync(artifact, bytes);
    const run = () => spawnSync(process.execPath, [fileURLToPath(new URL('./sign_windows_update.mjs', import.meta.url)), artifact, key, pub], { encoding: 'utf8' });
    const result = run();
    assert.equal(result.status, 0, result.stderr);
    const signature = Buffer.from(/edSignature="([^"]+)"/.exec(result.stdout)[1], 'base64');
    assert.equal(signature.length, 64);
    assert(verify(null, bytes, publicKey, signature));
    assert(!verify(null, Buffer.from('changed installer'), publicKey, signature));
    writeFileSync(pub, Buffer.alloc(32).toString('base64'));
    const rejected = run();
    assert.equal(rejected.status, 1);
    assert.equal(rejected.stdout, '');
    assert.match(rejected.stderr, /does not match/);
    assert(!rejected.stderr.includes('PRIVATE KEY'));
  } finally { rmSync(root, { recursive: true, force: true }); }
});
