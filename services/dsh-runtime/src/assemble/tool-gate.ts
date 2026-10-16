/**
 * 按员工的 `tools.allow` / `tools.deny` 决定装配里保留哪些工具插件。
 *
 * 背景（2026-08-25 实测）：admin 能配 tool_allow/tool_deny，Bus 随注册下发，runtime 也存进了 agent 卡片，
 * **但装配代码从不读它** —— 于是每个 dsh 员工都拿到固定工具集（bash + 文件读写 + 技能 + 平台工具），
 * 没法配出"只会聊天、不会执行命令"的员工。共享运行时下这点尤其要紧：bash 是最大的一片攻击面
 * （同 uid 可互发信号、可出网），能按员工关掉就少一大半暴露。
 *
 * 口径：对外用**逻辑工具名**，不暴露 dsh 内部插件 id —— 后者随上游版本会变，而 admin 里配的值要稳定。
 *   - `bash`     命令执行
 *   - `fs`       文件读写/搜索/编辑
 *   - `skill`    技能加载与调用
 *   - `platform` 平台工具桥（kb / memory / a2a / 图片）
 *
 * 语义（与常见 allow/deny 一致，deny 优先）：
 *   - allow 为空 → 给「全部 - 部署级默认关闭集」；allow 非空 → 只给列出的（**显式 allow 覆盖默认关闭**）
 *   - deny 命中 → 一律去掉，即便在 allow 里
 *   - 未知名字忽略（admin 侧新增的名字不该让整个装配失败）
 *
 * **部署级默认关闭集**（`DSH_RUNTIME_TOOL_DEFAULT_DENY`，生产缺省 `bash`）：
 * 用户 2026-08-25 拍板「客户可见的员工一律 deny bash」。只写进文档会烂掉——原语义是 allow 为空 = 全给，
 * 而员工卡片默认没有 `tools` 字段（节点实测），等于要靠每个建员工的人记得去 admin 勾一次，漏一个就破功。
 * 所以策略在部署层默认生效，需要 bash 的员工**显式** `allow` 点名。
 * 见 `docs/plans/dsh-sandbox-hardening-implementation.md` §6。
 */

export type LogicalTool = 'bash' | 'fs' | 'skill' | 'platform';

/**
 * 逻辑工具 → 基座装配里的插件 id。基座条目改名时同步这里。
 *
 * ⚠️ **只摘"模型可见的工具"，不摘服务提供者**（2026-08-25 实测踩过）：
 * `bash-sandbox` 不只是"bash 的沙箱"，它是 **`ctx.shell` 的提供者**，而 `permission-presets`
 * 明确 inject `shell`。一起摘掉的话 agent 进程 boot 直接 exit 1：
 *   `plugin tree failed to load: @deepseek-ai/dsh-permission-presets: pending (waiting for service: shell)`
 * → 每条消息 `zap.upstream_failure`，deny bash 的员工完全不可用。
 * 摘掉 `tool-bash` 就够了：模型侧没有 bash 工具，`ctx.shell` 留着给依赖它的服务解析。
 * 回归由 `test/pool/real-agent.test.ts` 的**真 bin 启动**用例守住——单测断言 yaml 里少了哪几行是不够的。
 */
const TOOL_PLUGIN_IDS: Record<LogicalTool, readonly string[]> = {
  bash: ['tool-bash'],
  fs: ['tool-fs', 'tool-fs-search', 'tool-str-replace-editor', 'fs-sandbox', 'fs-observation-policy', 'zhiban-office'],
  skill: ['skill', 'skill-filesystem', 'tool-skill'],
  platform: ['zhiban-tools'],
};

const ALL_TOOLS = Object.keys(TOOL_PLUGIN_IDS) as LogicalTool[];

function normalize(list: unknown): string[] {
  if (!Array.isArray(list)) return [];
  return list.filter((v): v is string => typeof v === 'string').map((v) => v.trim().toLowerCase()).filter((v) => v !== '');
}

/** 从 agent 卡片的 `tools` 字段解析出 allow / deny（形状不对时按"不限制"处理）。 */
export function parseToolPolicy(tools: unknown): { allow: string[]; deny: string[] } {
  if (tools === null || typeof tools !== 'object') return { allow: [], deny: [] };
  const t = tools as Record<string, unknown>;
  return { allow: normalize(t['allow']), deny: normalize(t['deny']) };
}

/**
 * 解析部署级默认关闭集。**区分「未设置」与「显式设空」**：
 * 未设置 → 用 fallback（生产缺省 `bash`）；显式设为空串 → 不默认关任何工具（回到旧语义，用于排障/回滚）。
 * 未知名字忽略，与 allow/deny 同口径。
 */
export function parseToolDefaultDeny(raw: string | undefined, fallback: readonly LogicalTool[] = ['bash']): LogicalTool[] {
  if (raw === undefined) return [...fallback];
  const names = raw.split(',').map((v) => v.trim().toLowerCase()).filter((v) => v !== '');
  return ALL_TOOLS.filter((t) => names.includes(t));
}

/** 计算该员工最终启用的逻辑工具集。`defaultDeny` = 部署级默认关闭集（员工未显式 allow 时生效）。 */
export function resolveEnabledTools(tools: unknown, defaultDeny: readonly LogicalTool[] = []): Set<LogicalTool> {
  const { allow, deny } = parseToolPolicy(tools);
  const base = allow.length > 0 ? ALL_TOOLS.filter((t) => allow.includes(t)) : ALL_TOOLS.filter((t) => !defaultDeny.includes(t));
  return new Set(base.filter((t) => !deny.includes(t)));
}

/**
 * 返回应当从装配中剔除的插件 id 集合。
 * 平台工具桥（zhiban-tools）由 shim 以 extraEntries 注入，这里一并按同一口径门控。
 */
export function disabledPluginIds(tools: unknown, defaultDeny: readonly LogicalTool[] = []): Set<string> {
  const enabled = resolveEnabledTools(tools, defaultDeny);
  const out = new Set<string>();
  for (const t of ALL_TOOLS) {
    if (enabled.has(t)) continue;
    for (const id of TOOL_PLUGIN_IDS[t]) out.add(id);
  }
  return out;
}
