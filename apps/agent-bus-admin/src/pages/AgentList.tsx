import { useCallback, useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Bot, PieChart, Sparkles } from 'lucide-react'
import { AgentsAdmin, TenantRuntimeEnvs, type AgentCreatorDistributionItem, type AgentFull, type RuntimeEnv, type TenantAgentTemplate } from '../lib/api'
import { Button, DrawerShell, EmptyState, PageHeader, Pagination, Panel, PrimaryButton, SearchInput, Tabs, Toolbar } from '../components/ui'
import { notifyOk } from '../lib/toast'
import { useConfirmDialog } from '../components/useConfirmDialog'
import { AgentCard } from '../components/agent/AgentCard'
import { TenantAgentTemplatePicker } from '../components/agent/TenantAgentTemplatePicker'

export function AgentList() {
  const nav = useNavigate()
  const confirmAction = useConfirmDialog()
  const [items, setItems] = useState<AgentFull[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [err, setErr] = useState('')
  const [source, setSource] = useState<'platform' | 'enterprise' | 'personal'>('platform')
  const [showExamples, setShowExamples] = useState(false)
  const [creatorID, setCreatorID] = useState('')
  const [distributionOpen, setDistributionOpen] = useState(false)
  const [runtimeMap, setRuntimeMap] = useState<Map<number, RuntimeEnv>>(() => new Map())

  const reload = useCallback(() => {
    AgentsAdmin.list(pageSize, (page - 1) * pageSize, { source, creator_id: creatorID || undefined })
      .then((r) => {
        setItems(r.items || [])
        setTotal(r.total)
        setErr('')
      })
      .catch((e: Error) => setErr(e.message))
  }, [creatorID, page, pageSize, source])

  useEffect(() => { reload() }, [reload])

  useEffect(() => {
    let cancelled = false
    TenantRuntimeEnvs.list(200, 0)
      .then((r) => {
        if (cancelled) return
        const runtimes = [...(r.platform_enabled || []), ...(r.tenant_custom || [])]
        setRuntimeMap(new Map(runtimes.map((it) => [it.ID, it])))
      })
      .catch(() => {})
    return () => { cancelled = true }
  }, [])

  const deleteAgent = useCallback(async (agent: AgentFull) => {
    const ok = await confirmAction.confirm({
      title: '删除数字员工',
      description: <>确认删除「<span className="font-medium text-[var(--color-text)]">{agent.Name}</span>」？删除后将从管理列表移除。</>,
      confirmLabel: '删除',
      tone: 'danger',
    })
    if (!ok) return
    try {
      await AgentsAdmin.remove(agent.UUID)
      if (items.length === 1 && page > 1) setPage(page - 1)
      else reload()
    } catch (e) {
      setErr((e as Error).message)
    }
  }, [confirmAction, items.length, page, reload])

  const publishAgent = useCallback(async (agent: AgentFull) => {
    const isRepublish = agent.Status === 'archived'
    const ok = await confirmAction.confirm({
      title: isRepublish ? '上架数字员工' : '发布数字员工',
      description: isRepublish
        ? <>确认上架「<span className="font-medium text-[var(--color-text)]">{agent.Name}</span>」？上架后客户端将重新可见并可使用。</>
        : <>确认发布「<span className="font-medium text-[var(--color-text)]">{agent.Name}</span>」？发布后客户端将可见并可使用。</>,
      confirmLabel: isRepublish ? '上架' : '发布',
      tone: 'info',
    })
    if (!ok) return
    try {
      await AgentsAdmin.publish(agent.UUID)
      notifyOk(`「${agent.Name}」已${isRepublish ? '上架' : '发布'}。`)
      reload()
    } catch (e) {
      setErr((e as Error).message)
    }
  }, [confirmAction, reload])

  const unpublishAgent = useCallback(async (agent: AgentFull) => {
    const ok = await confirmAction.confirm({
      title: '下架数字员工',
      description: <>确认下架「<span className="font-medium text-[var(--color-text)]">{agent.Name}</span>」？下架后客户端将不再可用，配置和历史记录会保留。</>,
      confirmLabel: '下架',
      tone: 'warn',
    })
    if (!ok) return
    try {
      await AgentsAdmin.unpublish(agent.UUID)
      notifyOk(`「${agent.Name}」已下架。`)
      reload()
    } catch (e) {
      setErr((e as Error).message)
    }
  }, [confirmAction, reload])

  const openFromTemplate = useCallback((t: TenantAgentTemplate) => {
    setShowExamples(false)
    // doc-15：携带平台模板 uuid 跳新建页，由新建页调 /tenant/agent-templates 取该模板预填。
    nav('/agents/new', { state: { templateUuid: t.uuid } })
  }, [nav])

  return (
    <Panel className="p-6 md:p-8">
      {confirmAction.dialog}
      <PageHeader title="数字员工" subtitle="创建、发布和管理本租户可用的数字员工。" className="mb-10" />

      <Tabs
        className="mb-6"
        value={source}
        onChange={(value) => { setSource(value); setPage(1); setCreatorID('') }}
        items={[
          { value: 'platform', label: '平台创建' },
          { value: 'enterprise', label: '租户创建' },
          { value: 'personal', label: '个人创建' },
        ]}
      />

      <Toolbar
        className="mb-6"
        search={
          <SearchInput
            value={creatorID}
            onChange={(v) => { setCreatorID(v.replace(/[^\d]/g, '')); setPage(1) }}
            placeholder="按创建人 ID 筛选"
          />
        }
        actions={source === 'enterprise' ? (
          <>
            <Button variant="secondary" onClick={() => setDistributionOpen(true)}>
              <PieChart size={14} /> 创建人分布
            </Button>
            <Button variant="secondary" onClick={() => setShowExamples(true)}>
              <Sparkles size={14} /> 从模板创建
            </Button>
            <PrimaryButton onClick={() => nav('/agents/new')}>新建数字员工</PrimaryButton>
          </>
        ) : undefined}
      />

      {err && <div className="text-[13px] text-[var(--color-danger)] bg-[var(--color-danger-bg)] ring-border rounded-md p-3 mb-4">{err}</div>}

      {items.length > 0 ? (
        <div className="grid grid-cols-1 gap-5 md:grid-cols-2 xl:grid-cols-3">
          {items.map((a) => (
            <AgentCard
              key={a.ID}
              agent={a}
              runtimeEnv={a.RuntimeEnvironmentID ? runtimeMap.get(a.RuntimeEnvironmentID) : null}
              onEdit={source === 'enterprise' ? () => nav(`/agents/${a.UUID}`) : undefined}
              onPublish={source === 'enterprise' ? () => publishAgent(a) : undefined}
              onUnpublish={source === 'enterprise' ? () => unpublishAgent(a) : undefined}
              onDelete={source === 'enterprise' ? () => deleteAgent(a) : undefined}
              allowArchivedPublish
            />
          ))}
        </div>
      ) : (
        <EmptyState
          icon={<Bot size={22} />}
          title={source === 'platform' ? '暂无平台创建的数字员工' : source === 'enterprise' ? '暂无租户创建的数字员工' : '暂无个人创建的数字员工'}
          description={source === 'platform' ? '平台发布数字员工后会直接显示在这里，并始终使用平台的最新配置。' : source === 'enterprise' ? '可从平台模板创建独立副本，或从空白新建数字员工。' : '个人创建的数字员工会在这里只读展示。'}
          action={source === 'enterprise' ? (
            <Button variant="secondary" onClick={() => setShowExamples(true)}>
              <Sparkles size={14} /> 从模板创建
            </Button>
          ) : undefined}
        />
      )}
      <Pagination
        total={total}
        page={page}
        pageSize={pageSize}
        onPageChange={setPage}
        onPageSizeChange={(size) => { setPageSize(size); setPage(1) }}
      />

      {showExamples && (
        <TenantAgentTemplatePicker
          onClose={() => setShowExamples(false)}
          onPick={openFromTemplate}
        />
      )}
      {distributionOpen && (
        <CreatorDistributionDrawer onClose={() => setDistributionOpen(false)} />
      )}

    </Panel>
  )
}

function CreatorDistributionDrawer({ onClose }: { onClose: () => void }) {
  const [items, setItems] = useState<AgentCreatorDistributionItem[]>([])
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    try {
      const res = await AgentsAdmin.creatorDistribution()
      setItems(res.items || [])
      setErr('')
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => scheduleCreatorDistributionLoad(load), [load])

  return (
    <DrawerShell
      title="数字员工创建人分布"
      subtitle="按数字员工数据行统计，不按运行时实例统计；租户初始化种子不计入。"
      icon={<PieChart className="h-4 w-4" />}
      width="sm"
      onClose={onClose}
    >
      {err && <div className="mb-3 text-[13px] text-[var(--color-danger)]">{err}</div>}
      {loading ? (
        <div className="py-8 text-center text-[13px] text-[var(--color-text-mute)]">加载中...</div>
      ) : items.length === 0 ? (
        <EmptyState title="暂无数字员工" />
      ) : (
        <div className="divide-y divide-[var(--color-line)] rounded-lg border border-[var(--color-line)] bg-white">
          {items.map((item) => {
            const displayName = item.creator_name || (item.creator_id > 0 ? `创建人 #${item.creator_id}` : '未记录创建人')
            return (
              <div key={item.creator_id} className="flex items-center justify-between px-4 py-3">
                <div>
                  <div className="text-[13px] font-medium text-[var(--color-text)]">
                    {displayName}
                  </div>
                  <div className="text-[12px] text-[var(--color-text-mute)]">
                    {item.creator_id > 0 ? `ID ${item.creator_id} · 租户自定义数字员工` : '租户自定义数字员工'}
                  </div>
                </div>
                <div className="text-[18px] font-semibold tabular-nums text-[var(--color-brand)]">{item.count}</div>
              </div>
            )
          })}
        </div>
      )}
    </DrawerShell>
  )
}

function scheduleCreatorDistributionLoad(load: () => Promise<void>) {
  const timer = window.setTimeout(() => { void load() }, 0)
  return () => window.clearTimeout(timer)
}
