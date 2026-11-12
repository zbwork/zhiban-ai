// PlatformTypes.tsx
//
// 4 层 Agent 平台模型 L1: Agent 平台类型 (只读列表)
//
// 这里展示 agent-bus 后端**代码层面**支持的协议家族 (openclaw / hermes / eap)。
// 平台 admin 无法在 UI 增删 —— 新增类型必须先有后端 adapter 代码。
//
// 设计文档: docs/design/agent-bus-admin-and-runtime-capabilities-design.md §2.3 L1
import { useEffect, useState } from 'react'
import { Server, Cpu, Plug, Loader2 } from 'lucide-react'
import { PlatformTypes as PlatformTypesAPI, type PlatformType } from '../lib/api'

const ICON_BY_CODE: Record<string, React.ComponentType<{ className?: string }>> = {
  openclaw: Cpu,
  hermes: Server,
  zap: Plug,
  // ADR-0035: 知办通用运行时 (dsh) 线上协议同 ZAP, 图标复用 Plug。
  dsh: Plug,
}

export default function PlatformTypes() {
  const [items, setItems] = useState<PlatformType[] | null>(null)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    PlatformTypesAPI.list()
      .then((r) => setItems(r.items))
      .catch((e) => setErr(String((e as Error)?.message || e)))
  }, [])

  return (
    <div className="space-y-5">
      <header>
        <h1 className="text-[30px] font-semibold tracking-tight text-[var(--color-text)] leading-none">Agent 平台类型</h1>
        <p className="mt-3 text-[13px] leading-relaxed text-[var(--color-text-sub)]">
          查看当前平台支持的 Agent 平台类型。每种类型对应不同的部署模式（平台托管 / 外部接入）。
        </p>
      </header>

      {err && (
        <div className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">{err}</div>
      )}

      {!items && !err && (
        <div className="flex items-center gap-2 text-sm text-slate-500">
          <Loader2 className="h-4 w-4 animate-spin" /> 加载中…
        </div>
      )}

      {items && (
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {items.map((t) => {
            const Icon = ICON_BY_CODE[t.code] || Server
            return (
              <article
                key={t.code}
                className="rounded-lg ring-1 ring-[var(--color-line)] bg-white p-4 shadow-[0_1px_0_rgba(23,23,23,0.02)]"
              >
                <div className="flex items-start justify-between">
                  <div className="flex items-center gap-2">
                    <div className="h-9 w-9 rounded-md bg-[var(--color-line-soft)] ring-1 ring-[var(--color-line)] grid place-items-center">
                      <Icon className="h-4 w-4 text-[var(--color-text-sub)]" />
                    </div>
                    <div>
                      <h2 className="text-base font-semibold">{platformTypeName(t)}</h2>
                      <div className="text-xs text-slate-500">{platformTypeTag(t)}</div>
                    </div>
                  </div>
                  <span className="rounded bg-slate-100 px-2 py-0.5 text-xs text-slate-600">只读</span>
                </div>
                <p className="mt-3 text-sm text-slate-700">{platformTypeDescription(t)}</p>
                <div className="mt-3">
                  <div className="text-xs font-medium text-slate-500">支持的部署方式</div>
                  <div className="mt-1 flex flex-wrap gap-1.5">
                    {t.hosting_kinds.map((k) => (
                      <span
                        key={k}
                        className="rounded border border-slate-200 bg-slate-50 px-2 py-0.5 text-xs text-slate-700"
                      >
                        {hostingKindLabel(k)}
                      </span>
                    ))}
                  </div>
                </div>
              </article>
            )
          })}
        </div>
      )}
    </div>
  )
}

function platformTypeName(t: PlatformType) {
  if (t.code === 'zap') return '自定义智能体平台（ZAP 协议）'
  if (t.code === 'dsh') return '知办通用运行时（dsh）'
  if (t.code === 'openclaw') return 'OpenClaw'
  if (t.code === 'hermes') return 'Hermes'
  return t.display_name || t.code
}

function platformTypeTag(t: PlatformType) {
  if (t.code === 'zap') return '适合外部智能体'
  if (t.code === 'dsh') return '平台内置'
  if (t.code === 'openclaw') return '平台托管'
  if (t.code === 'hermes') return '平台托管'
  return '平台支持'
}

function platformTypeDescription(t: PlatformType) {
  if (t.code === 'zap') return '适用于符合知办AI接入规范的第三方或自托管智能体。'
  if (t.code === 'dsh') return '知办AI 内置的通用运行时（ADR-0035）；线上协议与 ZAP 兼容，由平台自建 endpoint 提供。'
  if (t.code === 'openclaw') return '适用于由平台统一托管和调度的 OpenClaw 智能体。'
  if (t.code === 'hermes') return '适用于由平台统一托管和调度的 Hermes 智能体。'
  return t.description || '平台已支持的 Agent 平台类型。'
}

function hostingKindLabel(kind: string) {
  if (kind === 'clawmanager') return '工作负载服务'
  if (kind === 'k8s_native') return 'Kubernetes 集群'
  if (kind === 'external_endpoint') return '外部服务接入'
  return kind
}
