import { homedir } from 'node:os';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { realpath } from 'node:fs/promises';
import { z } from 'zod';
import type { DesktopTool } from './broker.js';
import { validateRelativePath } from './artifacts.js';
import { confineDesktop } from './confinement.js';
import { desktopEnvironment } from './platform.js';
import { runOwnedCommand } from './process.js';
import { LocalError } from './ledger.js';

/** Source bytes never enter the unsandboxed host filesystem reader. */
export function visionTool(opts: {privateRoot:string;brokerPort:number;home?:string}): DesktopTool {
  const schema=z.object({scope:z.enum(['workspace','home']).default('workspace'),path:z.string().min(1).max(2048)}).strict();
  return {name:'view_local_image',description:'查看真实本地图片，返回模型可见的图像。path 是 workspace 或 home 下的相对路径；home 文件内容需要授权。支持 PNG/JPEG/WebP/GIF，最多 1.5 MB；大图先通过受控命令生成缩略图；小图自动返回放大预览及原始尺寸，不修改源文件。',operation:'read',schema,inputSchema:z.toJSONSchema(schema),
    content: result => { const {data,mimeType,...dimensions}=result as {data:string;mimeType:string;[key:string]:unknown}; return [{type:'text',text:JSON.stringify(dimensions)},{type:'image',data,mimeType}]; },
    call:async(run,args,signal)=>{
      const a=schema.parse(args); validateRelativePath(a.path);
      const base=await realpath(a.scope==='home' ? opts.home ?? homedir() : run.config.workspace);
      const packageRoot=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
      const dependencies: string[] = process.platform === 'win32'
        ? (createRequire(import.meta.url)(resolve(packageRoot,'assets/bridge/vision-dependencies.cjs')) as string[]).map(name => resolve(packageRoot,'node_modules',name))
        : [resolve(packageRoot,'node_modules')];
      const argv=confineDesktop([process.execPath,resolve(packageRoot,'assets/bridge/local-vision.cjs')],{readOnly:[base,resolve(packageRoot,'assets'),...dependencies],readWrite:[],deny:[opts.privateRoot],brokerPort:opts.brokerPort});
      const result=await runOwnedCommand(argv,{cwd:base,env:desktopEnvironment(base),input:JSON.stringify(a),signal,maxOutputBytes:2_010_000,timeoutMs:15_000,limits:{cpuSeconds:10,maxRssMb:512,maxProcesses:8,intervalMs:250}});
      if(result.code!==0)throw new LocalError('local.image_read_failed');
      return JSON.parse(result.stdout) as unknown;
    }};
}
