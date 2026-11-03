import { constants } from 'node:fs';
import { open, realpath, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { dirname, join, basename } from 'node:path';
import { createHash } from 'node:crypto';
import { LocalError } from './ledger.js';

export interface CommunityAttachment { name: string; path: string; size: number; sha256: string }

/** Parent-selected snapshots only; never grant the worker access to private state. */
export async function importCommunityAttachments(stateRoot: string, employee: string, workspace: string, files: CommunityAttachment[]): Promise<string> {
  if (!files.length) return '';
  const sourceRoot = await realpath(join(dirname(dirname(stateRoot)), 'community_attachments', employee));
  const destination = await mkdtemp(join(await realpath(workspace), 'attachments-'));
  try {
    const index: { name: string; path: string }[] = [];
    for (const [i, file] of files.entries()) {
      const source = await realpath(file.path);
      if (source !== file.path || dirname(source) !== sourceRoot) throw new LocalError('local.invalid_attachment');
      const fd = await open(source, constants.O_RDONLY | constants.O_NOFOLLOW);
      let bytes: Buffer;
      try {
        const st = await fd.stat();
        if (!st.isFile() || st.nlink !== 1 || st.size !== file.size || st.size > 10 * 1024 * 1024) throw new LocalError('local.invalid_attachment');
        bytes = Buffer.alloc(st.size + 1);
        let count = 0;
        while (count < bytes.length) {
          const read = await fd.read(bytes, count, bytes.length - count, count);
          if (!read.bytesRead) break;
          count += read.bytesRead;
        }
        if (count !== st.size) throw new LocalError('local.invalid_attachment');
        bytes = bytes.subarray(0, count);
        if (createHash('sha256').update(bytes).digest('hex') !== file.sha256) throw new LocalError('local.invalid_attachment');
      } finally { await fd.close(); }
      const safeName = file.name.replace(/[^\p{L}\p{N}._-]/gu, '_').slice(-120) || 'file';
      const name = `${i + 1}-${safeName}`;
      await writeFile(join(destination, name), bytes, { flag: 'wx', mode: 0o600 });
      index.push({ name: file.name, path: `${basename(destination)}/${name}` });
    }
    return `用户附件已复制到授权工作目录，仅本轮用户选择的文件：${JSON.stringify(index)}。用相对路径读取和修改，保留源文件，修改结果另存并发布。`;
  } catch (error) {
    await rm(destination, { recursive: true, force: true });
    throw error;
  }
}
