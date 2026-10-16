import { desktopEnvironment } from './platform.js';
import { realpath } from 'node:fs/promises';
import { validateRelativePath } from './artifacts.js';
import { confineDesktop } from './confinement.js';
import { LocalError } from './ledger.js';
import { runOwnedCommand } from './process.js';

/** Parent directories are user-controlled: only the confined child opens/writes the destination. */
export async function writeWorkspaceBytes(workspace: string, path: string, bytes: Buffer, opts: { privateRoot: string; brokerPort: number }, signal: AbortSignal, recoverIdentical = false): Promise<void> {
  validateRelativePath(path);
  if (bytes.length > 32 * 1024 * 1024) throw new LocalError('local.file_size_limit');
  const root = await realpath(workspace);
  const script = "const fs=require('node:fs'),path=require('node:path'); const a=JSON.parse(fs.readFileSync(0,'utf8')); fs.mkdirSync(path.dirname(a.path),{recursive:true});const data=Buffer.from(a.data,'base64'); try{fs.writeFileSync(a.path,data,{flag:'wx'});}catch(e){if(e.code!=='EEXIST'||!a.recover)throw e;const fd=fs.openSync(a.path,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);try{const st=fs.fstatSync(fd);if(!st.isFile()||st.nlink!==1||st.size!==data.length||!fs.readFileSync(fd).equals(data))throw Error('conflict');}finally{fs.closeSync(fd);}}";
  const argv = confineDesktop([process.execPath, '-e', script], { readOnly: [], readWrite: [root], brokerPort: opts.brokerPort, deny: [opts.privateRoot] });
  const result = await runOwnedCommand(argv, { cwd: root, env: desktopEnvironment(root), signal, input: JSON.stringify({ path, data: bytes.toString('base64'), recover: recoverIdentical }) });
  if (result.code !== 0) throw new LocalError('local.file_operation_failed');
}
