import { useEffect, useState } from 'react'
import { MySessions, type MySession } from '../lib/api'
import { Monitor, ShieldCheck } from 'lucide-react'
import { PageHeader, RowActions } from '../components/ui'

export function MySessionsPage() {
  const [items, setItems] = useState<MySession[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [tick, setTick] = useState(0)
  const [revoking, setRevoking] = useState<string>('')

  useEffect(() => {
    MySessions.list()
      .then((r) => { setItems(r.items || []); setErr('') })
      .catch((e: Error) => setErr(e.message))
      .finally(() => setLoading(false))
  }, [tick])

  const onRevoke = async (uuid: string) => {
    if (!confirm('确认踢掉这台设备? 该设备上 admin 会立即被拒, 需要重新登录。')) return
    setRevoking(uuid)
    try {
      await MySessions.revoke(uuid)
      setTick((t) => t + 1)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setRevoking('')
    }
  }

  return (
    <div>
      <PageHeader
        title="我的会话 (多设备管理)"
        subtitle="列出当前账号所有活跃登录, 一键踢掉其他设备 (例如丢了手机 / 别人偷登)。撤销立即生效 (Redis 黑名单 + pg_notify 跨进程同步)。"
      />

      {err && <div className="mb-4 p-3 rounded-md bg-red-50 text-red-700 text-[13px]">{err}</div>}

      <div className="rounded-md ring-border bg-white overflow-hidden">
        <table className="w-full text-[13px]">
          <thead className="bg-[var(--color-bg-sub)] text-[13px] font-semibold text-[var(--color-text)]">
            <tr>
              <th className="text-left px-4 py-3">设备 / User Agent</th>
              <th className="text-left px-4 py-3">IP</th>
              <th className="text-left px-4 py-3">登录时间</th>
              <th className="text-left px-4 py-3">最近使用</th>
              <th className="text-left px-4 py-3">状态</th>
              <th className="text-left px-4 py-3">操作</th>
            </tr>
          </thead>
          <tbody>
            {loading && (
              <tr><td colSpan={6} className="px-4 py-8 text-center text-[var(--color-text-sub)]">加载中…</td></tr>
            )}
            {!loading && items.length === 0 && (
              <tr><td colSpan={6} className="px-4 py-12 text-center text-[var(--color-text-sub)]">
                <Monitor size={28} className="mx-auto mb-2 opacity-40" />
                没有活跃 session
              </td></tr>
            )}
            {items.map((s) => (
              <tr key={s.uuid} className="border-t border-[var(--color-border)]">
                <td className="px-4 py-3 max-w-[400px]">
                  <div className="text-[12px] truncate" title={s.userAgent}>{s.userAgent || '未知设备'}</div>
                  {s.actingAs && <div className="mt-1 text-[11px] text-red-600">代入模式 ({s.actingAs})</div>}
                </td>
                <td className="px-4 py-3 font-mono text-[12px]">{s.ip || '—'}</td>
                <td className="px-4 py-3 text-[var(--color-text-sub)]">{new Date(s.issuedAt).toLocaleString()}</td>
                <td className="px-4 py-3 text-[var(--color-text-sub)]">{new Date(s.lastUsedAt).toLocaleString()}</td>
                <td className="px-4 py-3">
                  {s.isCurrent ? (
                    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded bg-blue-100 text-blue-700 text-[11px]">
                      <ShieldCheck size={11} /> 当前会话
                    </span>
                  ) : (
                    <span className="px-2 py-0.5 rounded bg-green-100 text-green-700 text-[11px]">活跃</span>
                  )}
                </td>
                <td className="px-4 py-3">
                  {!s.isCurrent && (
                    <RowActions
                      deleteLabel="踢掉"
                      deleteDisabled={revoking === s.uuid}
                      onDelete={() => onRevoke(s.uuid)}
                    />
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
