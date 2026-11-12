import { useCallback, useEffect, useState } from 'react'
import { PlatformRuntimeEnvs, type RuntimeEnv } from '../lib/api'
import { Server, Star, StarOff, Trash2 } from 'lucide-react'
import { useConfirmDialog } from '../components/useConfirmDialog'
import { PageHeader } from '../components/ui'

// M3 v1.1 Stage 8: 平台托管 Agent 平台环境 (产品化用语)。
// 后端 API: /api/admin/v1/platform/runtime-environments + /set-as-default + DELETE。
// 不引入新的后端 path; 列表只读 + 默认环境切换 + 删除前置校验。
export function PlatformRuntimeEnvironments() {
  const confirmDelete = useConfirmDialog()
  const [items, setItems] = useState<RuntimeEnv[]>([])
  const [err, setErr] = useState('')

  const reload = useCallback(() => {
    PlatformRuntimeEnvs.list(true)
      .then((r) => setItems(r.items || []))
      .catch((e: Error) => setErr(e.message))
  }, [])
  useEffect(() => { reload() }, [reload])

  const setDefault = async (uuid: string) => {
    try {
      await PlatformRuntimeEnvs.setDefault(uuid)
      reload()
    } catch (e) { setErr((e as Error).message) }
  }
  const remove = async (uuid: string, code: string) => {
    const ok = await confirmDelete.confirm({
      title: '删除平台环境',
      description: <>确认删除平台环境「<span className="font-medium text-[var(--color-text)]">{code}</span>」吗？必须无租户启用、无数字员工绑定、无活跃实例。</>,
      confirmLabel: '删除',
    })
    if (!ok) return
    try {
      await PlatformRuntimeEnvs.remove(uuid)
      reload()
    } catch (e) { setErr((e as Error).message) }
  }
  const hasDefault = items.some((r) => r.IsPlatformDefault && r.Status === 'active')

  return (
    <div>
      {confirmDelete.dialog}
      <PageHeader
        title="Agent 平台环境（平台托管）"
        subtitle={<>
          平台预置 / 第三方接入的 Agent 运行时类型；新租户开通时默认启用 <code className="font-mono text-xs">is_platform_default</code> 环境。
        </>}
      />

      {!hasDefault && (
        <div className="text-[13px] text-[var(--color-warn)] bg-[var(--color-warn-bg)] ring-border rounded-md p-3 mb-4">
          ⚠️ 当前未配置平台默认环境，新租户开通会失败。请点击 ⭐ 设置一个默认环境。
        </div>
      )}
      {err && <div className="text-[13px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] ring-border rounded-md p-3 mb-4">{err}</div>}

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {items.map((r) => (
          <div key={r.UUID} className="rounded-2xl border border-[var(--color-border)] bg-[var(--color-fill-bg)] p-4 flex flex-col gap-3">
            <div className="flex items-start justify-between">
              <div className="flex items-center gap-2">
                <Server size={16} className="text-[var(--color-ink-mute)]" />
                <div>
                  <div className="text-sm font-semibold">{r.Name || r.Code}</div>
                  <div className="text-[11px] text-[var(--color-ink-mute)] font-mono">{r.Code}</div>
                </div>
              </div>
              {r.IsPlatformDefault && (
                <span className="text-[10px] px-2 py-0.5 rounded bg-yellow-100 text-yellow-700">默认</span>
              )}
            </div>
            <div className="text-xs space-y-1 text-[var(--color-ink-sub)]">
              <div>框架: <span className="font-mono">{r.Framework || '—'}</span></div>
              <div>协议: <span className="font-mono">{r.ProtocolVersion || 'zap-1.1'}</span></div>
              <div>多 Agent: {r.SupportsMultiAgent ? '是' : '否'}</div>
              <div>状态: <span className={r.Status === 'active' ? 'text-emerald-600' : 'text-rose-600'}>{r.Status}</span></div>
              <div>绑定数字员工: {r.BoundAgents}</div>
            </div>
            <div className="flex items-center gap-2 mt-1">
              {r.IsPlatformDefault ? (
                <button disabled className="px-2 py-1.5 rounded-md text-xs ring-1 ring-[var(--color-border)] text-[var(--color-ink-mute)] flex items-center gap-1">
                  <StarOff size={12} /> 已是默认
                </button>
              ) : (
                <button
                  onClick={() => setDefault(r.UUID)}
                  disabled={r.Status !== 'active'}
                  className="px-2 py-1.5 rounded-md text-xs ring-1 ring-[var(--color-border)] hover:bg-[var(--color-fill-1)] disabled:opacity-50 flex items-center gap-1"
                ><Star size={12} /> 设为默认</button>
              )}
              <button
                onClick={() => remove(r.UUID, r.Code)}
                className="px-2 py-1.5 rounded-md text-xs ring-1 ring-rose-300 text-rose-600 hover:bg-rose-50 flex items-center gap-1"
              ><Trash2 size={12} /> 删除</button>
            </div>
          </div>
        ))}
        {!items.length && (
          <div className="col-span-full text-center py-12 text-[var(--color-ink-mute)] text-sm">未配置任何平台环境</div>
        )}
      </div>
    </div>
  )
}
