import { homedir } from 'node:os';
import { realpath } from 'node:fs/promises';
import { isAbsolute, join, relative } from 'node:path';
import { z } from 'zod';
import type { DesktopTool } from './broker.js';
import { validateRelativePath } from './artifacts.js';
import { confineDesktop } from './confinement.js';
import { desktopEnvironment } from './platform.js';
import { runOwnedCommand } from './process.js';
import { LocalError } from './ledger.js';

// Static program inside the OS sandbox. No file contents are read, no symlinks followed.
export const searchProgram = String.raw`
const fs=require('node:fs'), path=require('node:path');
const a=JSON.parse(fs.readFileSync(0,'utf8'));
let ancestor=a.base;
for(const part of a.path.split(/[\\/]/).filter(Boolean)){
 ancestor=path.join(ancestor,part);
 if(fs.lstatSync(ancestor).isSymbolicLink())throw Error('symbolic link');
}
const excluded=['Library','node_modules','build','dist','vendor','__pycache__','venv'];
const images=new Set(['jpg','jpeg','png','gif','webp','heic','heif','avif','bmp','tif','tiff','svg','ico','raw','cr2','nef','dng']);
const started=Date.now(), stack=[{path:a.root,depth:0}], samples=[];
let count=0,scanned=0,skipped=0,unreadable=0,truncated=false;
while(stack.length && !truncated){
 const current=stack.pop(); let dir;
 try{if(fs.lstatSync(current.path).isSymbolicLink()){skipped++;continue;} dir=fs.opendirSync(current.path);}catch{unreadable++;continue;}
 try{let e;while((e=dir.readSync())!==null){
  if(++scanned>a.max_entries || Date.now()-started>40000){truncated=true;break;}
  if(e.name.startsWith('.')||e.isSymbolicLink()){skipped++;continue;}
  const p=path.join(current.path,e.name);
  if(e.isDirectory()){
   if(excluded.includes(e.name)||/\.(app|bundle|framework|photoslibrary)$/i.test(e.name)){skipped++;continue;}
   if(current.depth>=40){truncated=true;break;}
   stack.push({path:p,depth:current.depth+1});continue;
  }
  if(!e.isFile())continue;
  const ext=path.extname(e.name).slice(1).toLowerCase();
  if(a.kind==='image'&&!images.has(ext))continue;
  if(a.name&&a.name!=='*'&&!e.name.toLocaleLowerCase().includes(a.name.toLocaleLowerCase()))continue;
  count++;
  if(samples.length<a.sample_limit)samples.push(path.relative(a.base,p));
 }}catch{unreadable++;}finally{dir.closeSync();}
}
process.stdout.write(JSON.stringify({scope:a.scope,path:a.path||'.',name_filter:a.name==='*'?'':a.name,count,unit:'file_paths',
 complete_within_scope:!truncated&&unreadable===0,truncated,unreadable_directories:unreadable,
 scanned_entries:scanned,skipped_entries:skipped,excluded:['hidden','symlinks','*.app','*.bundle','*.framework','*.photoslibrary',...excluded],
 samples,samples_truncated:count>samples.length,matched_by:'filename_extension',
 note:'统计所选范围内可访问且未排除的文件路径；不包含照片图库内部、隐藏及系统目录，不代表整台电脑的全部图片。'}));`;

export function searchTool(opts: { privateRoot: string; brokerPort: number; home?: string }): DesktopTool {
  const schema = z.object({ scope: z.enum(['workspace', 'home']).default('workspace'),
    path: z.string().max(2048).default('').describe('所选 home/workspace 范围内相对路径或绝对路径；如 Documents/知办材料，不要重复用户名。空字符串为整个范围。'), kind: z.enum(['image', 'file']).default('image'),
    name: z.string().max(200).default('').describe('文件名子串；空字符串或单独 * 表示不过滤文件名。统计所有图片时留空。不支持其他通配符。'), sample_limit: z.number().int().min(0).max(50).default(0).describe('返回文件名样本的数量；仅统计总数时使用 0，与扫描总量无关。'),
    max_entries: z.number().int().min(1).max(1_000_000).default(500_000).describe('扫描文件和目录的总预算，不是结果数。统计图片总量使用 500000；若 truncated 则提高至 1000000 或分目录扫描。不要使用 1 来查询总数。'),
  }).strict();
  return { name: 'search_files', operation: 'read', schema, inputSchema: z.toJSONSchema(schema),
    description: `home 根目录为 ${opts.home ?? homedir()}。递归检索本机文件名或统计图片数量，只读元数据，不读文件内容。电脑上的图片用 scope=home（用户主目录，需要审批），当前任务文件用 workspace。path 为该范围内相对目录或绝对路径；默认仅返回计数，用户要求列表时才设置 sample_limit。统计总数时 max_entries 使用 500000；若因预算截断，增加预算或缩小到子目录继续检索。必须说明统计范围、排除项及是否完整，不得把部分计数当作总数。`,
    call: async (run, args, signal) => {
      const a = schema.parse(args);
      const base = await realpath(a.scope === 'home' ? opts.home ?? homedir() : run.config.workspace);
      if (isAbsolute(a.path)) a.path = relative(base, a.path);
      if (a.path) validateRelativePath(a.path);
      if (a.name !== '*' && /[?*]/.test(a.name)) throw new LocalError('local.invalid_tool_arguments');
      // Subdirectories remain lexical; the sandbox is authoritative against rename/symlink races.
      const argv = confineDesktop([process.execPath, '-e', searchProgram], {
        readOnly: [base], readWrite: [], deny: [opts.privateRoot], brokerPort: opts.brokerPort,
      });
      const result = await runOwnedCommand(argv, { cwd: base, env: desktopEnvironment(base), signal,
        timeoutMs: 50_000, input: JSON.stringify({ ...a, base, root: join(base, a.path) }),
      });
      if (result.code !== 0) throw new LocalError('local.search_failed');
      return JSON.parse(result.stdout) as unknown;
    },
  };
}
