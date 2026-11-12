// capabilities.ts · S5e control-plane「接口能力」共享目录 + 校验 helper (doc-12 §4)。
// 抽成独立模块 (非组件文件), 既给 RuntimeHostingForm 渲染用, 也给页面保存前校验用,
// 避免在组件文件里导出非组件成员 (react-refresh/only-export-components)。
//
// 阶段 1 展示 agent.*、用户实例初始化、skill.install/uninstall/list;
// skill.create/update/delete 为预留, 不展示。
// agent.instance_initialize 是 Admin Web 展示用 key, 来源于 runtime_card.agent_instance_initialization,
// 不写入后端 control_plane_capabilities 白名单。

export type CapItem = { key: string; label: string; hint: string }

export const CAP_GROUPS: { title: string; items: CapItem[] }[] = [
  {
    title: '数字员工',
    items: [
      { key: 'agent.read', label: '查看', hint: '读取目标 runtime 上的数字员工信息。' },
      { key: 'agent.create', label: '创建', hint: '把数字员工注册到目标 runtime。未启用时系统不会调用其创建接口。' },
      { key: 'agent.update', label: '编辑', hint: '更新目标 runtime 上数字员工的配置。' },
      { key: 'agent.delete', label: '删除', hint: '从目标 runtime 移除数字员工。' },
      { key: 'agent.list', label: '列表', hint: '列出目标 runtime 上的数字员工。' },
      { key: 'agent.instance_initialize', label: '实例初始化', hint: '登录预热时调用 /zap/v1/instances，把租户、用户、数字员工和 LLM 凭证推给 runtime。' },
    ],
  },
  {
    title: '技能',
    items: [
      { key: 'skill.install', label: '安装', hint: '把技能安装到数字员工工作空间（需运行端支持 exec）。' },
      { key: 'skill.uninstall', label: '卸载', hint: '从工作空间卸载技能。' },
      { key: 'skill.list', label: '列表', hint: '列出已安装技能。' },
    ],
  },
]

// 内置 runtime adapter 真实能力（前端只读展示，doc-12 §11.8.2）。
// OpenClaw/Hermes 均通过 K8S exec 写入 agent/skill；是否实际执行仍由后端 adapter wiring、
// 对象存储 package fetcher 与 per-env K8S 写入通道共同 fail-closed 判定。
export const BUILTIN_RUNTIME_CAPS: Record<string, Record<string, boolean>> = {
  openclaw: {
    'agent.create': true,
    'skill.install': true,
    'skill.uninstall': true,
  },
  hermes: {
    'agent.create': true,
    'skill.install': true,
    'skill.uninstall': true,
  },
}

const KNOWN_CAPS = new Set(CAP_GROUPS.flatMap((group) => group.items.map((item) => item.key)))

export function controlPlaneCapsFromRuntimeCard(card?: Record<string, unknown> | null): Record<string, boolean> | undefined {
  if (!card) return undefined
  const raw = card?.control_plane_capabilities
  const out: Record<string, boolean> = {}
  if (Array.isArray(raw)) {
    raw.forEach((item) => {
      const key = String(item || '')
      if (KNOWN_CAPS.has(key)) out[key] = true
    })
  } else if (typeof raw === 'object' && raw !== null) {
    Object.entries(raw as Record<string, unknown>).forEach(([key, value]) => {
      if (KNOWN_CAPS.has(key) && value === true) out[key] = true
    })
  }
  const agentManagement = card.agent_management
  if (agentManagement && typeof agentManagement === 'object') {
    const m = agentManagement as Record<string, unknown>
    if (m.supports_read === true || m.supports_get === true) out['agent.read'] = true
    if (m.supports_create === true) out['agent.create'] = true
    if (m.supports_update === true) out['agent.update'] = true
    if (m.supports_delete === true) out['agent.delete'] = true
    if (m.supports_list === true) out['agent.list'] = true
  }
  const agentInstance = card.agent_instance_initialization
  if (
    agentInstance &&
    typeof agentInstance === 'object' &&
    (agentInstance as Record<string, unknown>).supports_initialize === true
  ) {
    out['agent.instance_initialize'] = true
  }
  return Object.keys(out).length > 0 ? out : undefined
}

export function mergeRuntimeDisplayCaps(
  controlPlaneCaps?: Record<string, boolean>,
  agentInstanceInitializeSupported?: boolean,
): Record<string, boolean> | undefined {
  const out: Record<string, boolean> = { ...(controlPlaneCaps || {}) }
  if (agentInstanceInitializeSupported) {
    out['agent.instance_initialize'] = true
  }
  return Object.keys(out).length > 0 ? out : undefined
}
