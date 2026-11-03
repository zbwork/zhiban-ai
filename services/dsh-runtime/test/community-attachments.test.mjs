import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, realpath, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
const root = process.env.COMMUNITY_RUNTIME_TEST_ROOT;
const { importCommunityAttachments } = await import(pathToFileURL(join(root, 'dist/desktop/community-attachments.js')));

test('imports exact selected binary snapshot; rejects cross employee, changed bytes and links', async () => {
  const temp = await realpath(await mkdtemp(join(tmpdir(), 'community-import-')));
  try {
    const state = join(temp, 'community-runtime', 'employee');
    const files = join(temp, 'community_attachments', 'employee');
    const workspace = join(temp, 'workspace');
    for (const dir of [state, files, workspace]) await mkdir(dir, { recursive: true });
    const bytes = Buffer.from([80, 75, 0, 255, 1, 2]);
    const path = join(files, 'original.docx');
    await writeFile(path, bytes);
    const file = { name: '报告.docx', path, size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
    const guide = await importCommunityAttachments(state, 'employee', workspace, [file]);
    const index = JSON.parse(guide.slice(guide.indexOf('['), guide.indexOf(']') + 1));
    assert.deepEqual(await readFile(join(workspace, index[0].path)), bytes);
    assert.deepEqual(await readFile(path), bytes);
    await assert.rejects(importCommunityAttachments(state, 'other', workspace, [file]));
    await assert.rejects(importCommunityAttachments(state, 'employee', workspace, [{ ...file, sha256: '0'.repeat(64) }]));
    const link = join(files, 'link.docx');
    await symlink(path, link);
    await assert.rejects(importCommunityAttachments(state, 'employee', workspace, [{ ...file, path: link }]));
  } finally { await rm(temp, { recursive: true, force: true }); }
});
