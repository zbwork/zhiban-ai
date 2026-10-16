/**
 * 子进程环境：**白名单**构造，不继承 shim 的完整环境。
 *
 * 为什么不是黑名单：agent 进程跑的是租户任务（多租户读隔离 P2 才补），shim 的配置、
 * 其它服务的凭据一概不该出现在它的 env 里。只放：基础定位变量、代理、CA、模型凭据。
 *
 * 另两条硬规定（实测 app-boot 行为）：
 * - 进程 cwd 下的 .env 会被 agent bin 自动加载（不覆盖已设变量）。因此进程 cwd 必须是
 *   shim 自己的目录（装配目录），租户工作区只通过 initialize.cwd 传入；且 DEEPSEEK_BASE_URL
 *   必须显式设置，杜绝被工作区 .env 注入改道。
 * - DSH_CORDIS_CONFIG 优先于 argv，绝不能出现在子进程 env 里。
 */
const PASSTHROUGH = [
  'PATH',
  'SystemRoot',
  'WINDIR',
  'LANG',
  'LC_ALL',
  'LC_CTYPE',
  'TZ',
  'TMPDIR',
  'USER',
  'LOGNAME',
  'SHELL',
  'HTTP_PROXY',
  'HTTPS_PROXY',
  'NO_PROXY',
  'http_proxy',
  'https_proxy',
  'no_proxy',
  'NODE_EXTRA_CA_CERTS',
  'SSL_CERT_FILE',
  'DEEPSEEK_API_KEY',
  'DEEPSEEK_BASE_URL',
] as const;

export const DEFAULT_DEEPSEEK_BASE_URL = 'https://api.deepseek.com';

export interface ChildEnvInputs {
  parent: NodeJS.ProcessEnv;
  /** 子进程专属 DSH_HOME（缓存目录下），避免碰宿主 ~/.dsh */
  dshHome: string;
  /**
   * 子进程 HOME。默认 = dshHome；给工作区内目录（如 <workspace>/.home）时，bash/Chrome/bun 等工具在
   * dsh 内层沙箱（只许写工作区）下也能写 ~/.cache、~/.config。
   */
  home?: string;
  /** 会话级注入（P2：per-account 凭据、归因标签）；键名须已在白名单或以 DSH_RUNTIME_SESSION_ 开头 */
  extra?: Record<string, string>;
}

export function buildChildEnv({ parent, dshHome, home, extra }: ChildEnvInputs): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const k of PASSTHROUGH) {
    const v = parent[k];
    if (v !== undefined && v !== '') env[k] = v;
  }
  env.DEEPSEEK_BASE_URL ??= DEFAULT_DEEPSEEK_BASE_URL;
  env.DSH_HOME = dshHome;
  // HOME 不透传宿主的（读隔离下 /home/<user> 不授权）：默认指向会话 DSH_HOME，生产里指向工作区内的 .home，
  // 这样 bash 找 ~/.bashrc、Chrome/bun 写 ~/.cache 都落在按租户/账号分且内层沙箱可写的目录。
  env.HOME = home ?? dshHome;
  if (process.platform === 'win32') {
    env.USERPROFILE = env.HOME; env.LOCALAPPDATA = env.HOME; env.APPDATA = env.HOME;
    env.TEMP = extra?.['TMPDIR'] ?? env.HOME; env.TMP = env.TEMP;
  }
  for (const [k, v] of Object.entries(extra ?? {})) {
    if (k === 'DSH_CORDIS_CONFIG' || k.startsWith('DSH_RUNTIME_')) throw new Error(`refusing to pass ${k} to agent process`);
    env[k] = v;
  }
  delete env.DSH_CORDIS_CONFIG;
  return env;
}
