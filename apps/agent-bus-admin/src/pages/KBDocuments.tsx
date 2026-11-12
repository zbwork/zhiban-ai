import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { CheckCircle2, FileText, FolderOpen, RefreshCw, RotateCcw, Search } from 'lucide-react'
import {
  KBDocumentOps,
  type KBDocumentItem,
  TenantKB,
  type TenantKBItem,
} from '../lib/api'
import { Button, DataTable, EmptyState, InlineAlert, Input, PageHeader, Pagination, Select } from '../components/ui'

type DocStatusFilter = 'all' | 'ready' | 'processing' | 'failed'

function isFailedDoc(doc: KBDocumentItem) {
  return doc.status === 'failed' || doc.status === 'error' || !!doc.error_message
}

function isReadyDoc(doc: KBDocumentItem) {
  return doc.status === 'ready' || doc.status === 'active' || doc.status === 'completed'
}

function statusLabel(doc: KBDocumentItem) {
  if (isFailedDoc(doc)) return '异常'
  if (isReadyDoc(doc)) return '完成'
  return doc.status || '处理中'
}

function statusClass(doc: KBDocumentItem) {
  if (isFailedDoc(doc)) return 'bg-[var(--color-danger-bg)] text-[var(--color-danger)]'
  if (isReadyDoc(doc)) return 'bg-[var(--color-success-bg)] text-[var(--color-success)]'
  return 'bg-[var(--color-warn-bg)] text-[var(--color-warn)]'
}

function formatSize(n: number) {
  if (!n) return '-'
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / 1024 / 1024).toFixed(2)} MB`
}

function formatDate(value?: string) {
  if (!value) return '-'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString()
}

export function KBDocumentsPage() {
  const [kbs, setKbs] = useState<TenantKBItem[]>([])
  const [activeKB, setActiveKB] = useState('')
  const [docs, setDocs] = useState<KBDocumentItem[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(50)
  const [query, setQuery] = useState('')
  const [status, setStatus] = useState<DocStatusFilter>('all')
  const [err, setErr] = useState('')
  const [loadingKBs, setLoadingKBs] = useState(true)
  const [loadingDocs, setLoadingDocs] = useState(false)
  const [retrying, setRetrying] = useState<Record<string, boolean>>({})
  const [docsTick, setDocsTick] = useState(0)

  const loadKBs = useCallback(async () => {
    setLoadingKBs(true)
    setErr('')
    try {
      const r = await TenantKB.list()
      const items = r.items || []
      setKbs(items)
      setActiveKB((current) => current || items[0]?.uuid || '')
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setLoadingKBs(false)
    }
  }, [])

  useEffect(() => {
    let cancelled = false
    TenantKB.list()
      .then((r) => {
        if (cancelled) return
        const items = r.items || []
        setKbs(items)
        const firstKB = items[0]?.uuid || ''
        setActiveKB(firstKB)
        if (firstKB) setLoadingDocs(true)
      })
      .catch((e: Error) => {
        if (!cancelled) setErr(e.message)
      })
      .finally(() => {
        if (!cancelled) setLoadingKBs(false)
      })
    return () => { cancelled = true }
  }, [])

  useEffect(() => {
    if (!activeKB) {
      return
    }
    let cancelled = false
    KBDocumentOps.list(activeKB, { limit: pageSize, offset: (page - 1) * pageSize })
      .then((r) => {
        if (cancelled) return
        setDocs(r.items || [])
        setTotal(r.total ?? 0)
      })
      .catch((e: Error) => {
        if (cancelled) return
        setErr(e.message)
        setDocs([])
        setTotal(0)
      })
      .finally(() => {
        if (!cancelled) setLoadingDocs(false)
      })
    return () => { cancelled = true }
  }, [activeKB, docsTick, page, pageSize])

  const activeKBObj = useMemo(() => kbs.find((k) => k.uuid === activeKB), [activeKB, kbs])

  const filteredDocs = useMemo(() => {
    const q = query.trim().toLowerCase()
    return docs.filter((doc) => {
      if (status === 'ready' && !isReadyDoc(doc)) return false
      if (status === 'failed' && !isFailedDoc(doc)) return false
      if (status === 'processing' && (isReadyDoc(doc) || isFailedDoc(doc))) return false
      if (!q) return true
      return [doc.title, doc.uuid, doc.mime_type, doc.error_message].some((v) => (v || '').toLowerCase().includes(q))
    })
  }, [docs, query, status])

  const pageStats = useMemo(() => ({
    failed: docs.filter(isFailedDoc).length,
    chunks: docs.reduce((sum, doc) => sum + (doc.chunk_count || 0), 0),
  }), [docs])

  const doRetry = async (docUUID: string) => {
    setRetrying((s) => ({ ...s, [docUUID]: true }))
    setErr('')
    try {
      await KBDocumentOps.retry(activeKB, docUUID)
      setDocsTick((t) => t + 1)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setRetrying((s) => {
        const next = { ...s }
        delete next[docUUID]
        return next
      })
    }
  }

  return (
    <div>
      <PageHeader
        title="文档管理"
        subtitle="按知识库查看文档导入结果、分片数量和失败重试。"
        actions={
          <Button
            variant="secondary"
            onClick={() => {
              if (activeKB) {
                setLoadingDocs(true)
                setDocsTick((t) => t + 1)
              } else {
                void loadKBs()
              }
            }}
            disabled={loadingKBs || loadingDocs}
          >
            <RefreshCw size={14} className={(loadingKBs || loadingDocs) ? 'animate-spin' : ''} />
            刷新
          </Button>
        }
      />

      {err && <div className="mb-4"><InlineAlert>{err}</InlineAlert></div>}

      <div className="mb-4 rounded-lg border border-[var(--color-line)] bg-white p-4">
        <div className="grid grid-cols-1 gap-3 lg:grid-cols-[minmax(260px,1fr)_160px_auto]">
          <div>
            <div className="mb-1.5 text-[13px] font-medium text-[var(--color-text)]">知识库</div>
            <Select
              value={activeKB}
              disabled={loadingKBs || kbs.length === 0}
              onChange={(e) => {
                setActiveKB(e.target.value)
                setPage(1)
                setQuery('')
                setStatus('all')
                setLoadingDocs(true)
              }}
            >
              {kbs.length === 0 && <option value="">暂无知识库</option>}
              {kbs.map((kb) => (
                <option key={kb.uuid} value={kb.uuid}>{kb.name || kb.uuid}</option>
              ))}
            </Select>
          </div>
          <div>
            <div className="mb-1.5 text-[13px] font-medium text-[var(--color-text)]">状态</div>
            <Select value={status} onChange={(e) => setStatus(e.target.value as DocStatusFilter)} disabled={!activeKB}>
              <option value="all">全部状态</option>
              <option value="ready">完成</option>
              <option value="processing">处理中</option>
              <option value="failed">异常</option>
            </Select>
          </div>
          <div className="flex items-end">
            {activeKB && (
              <Link to={`/kb/${encodeURIComponent(activeKB)}`}>
                <Button variant="secondary">
                  <FolderOpen size={14} />
                  进入详情
                </Button>
              </Link>
            )}
          </div>
        </div>
        <div className="mt-3 grid grid-cols-1 gap-2 text-[12px] text-[var(--color-text-sub)] md:grid-cols-4">
          <span>当前 KB：<strong className="text-[var(--color-text)]">{activeKBObj?.name || '-'}</strong></span>
          <span>文档总数：<strong className="tabular-nums text-[var(--color-text)]">{total}</strong></span>
          <span>本页 chunks：<strong className="tabular-nums text-[var(--color-text)]">{pageStats.chunks}</strong></span>
          <span>本页异常：<strong className={pageStats.failed > 0 ? 'text-[var(--color-danger)]' : 'text-[var(--color-text)]'}>{pageStats.failed}</strong></span>
        </div>
      </div>

      {activeKB && (
        <div className="mb-3 relative">
          <Search size={15} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-[var(--color-text-mute)]" />
          <Input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="搜索文档标题、UUID、类型或错误信息"
            className="pl-9"
          />
        </div>
      )}

      <DataTable
        headers={['文档', '类型', '大小', 'Chunks', '状态', '错误', '创建时间', '操作']}
        loading={(loadingKBs || loadingDocs) ? <EmptyState title="正在加载文档" description="正在读取当前知识库的文档列表。" /> : undefined}
        empty={!loadingKBs && !loadingDocs && (!activeKB || filteredDocs.length === 0) ? (
          <EmptyState
            icon={<FileText size={22} />}
            title={!activeKB ? '本租户暂无可选知识库' : docs.length === 0 ? '当前知识库暂无文档' : '没有匹配的文档'}
            description={!activeKB ? '用户在客户端创建知识库后，可在这里查看文档导入和解析状态。' : docs.length === 0 ? '客户端上传文档后，这里会展示导入状态、chunks 和错误信息。' : '调整搜索词或状态筛选后再试。'}
          />
        ) : undefined}
      >
        {!loadingKBs && !loadingDocs && filteredDocs.map((doc) => {
          const failed = isFailedDoc(doc)
          return (
            <tr key={doc.uuid} className="transition hover:bg-[var(--color-bg-sub)]">
              <td className="px-4 py-3">
                <div className="min-w-0">
                  <div className="max-w-[320px] truncate font-medium text-[var(--color-text)]" title={doc.title}>{doc.title || '-'}</div>
                  <div className="truncate font-mono text-[11px] text-[var(--color-text-mute)]">{doc.uuid}</div>
                </div>
              </td>
              <td className="px-4 py-3 max-w-[160px] truncate text-[12px] text-[var(--color-text-sub)]" title={doc.mime_type || ''}>{doc.mime_type || '-'}</td>
              <td className="px-4 py-3 text-[12px] tabular-nums text-[var(--color-text-sub)]">{formatSize(doc.file_size)}</td>
              <td className="px-4 py-3 text-[12px] tabular-nums text-[var(--color-text-sub)]">{doc.chunk_count ?? 0}</td>
              <td className="px-4 py-3">
                <span className={`inline-flex h-6 items-center rounded px-2 text-[12px] font-medium ${statusClass(doc)}`}>
                  {statusLabel(doc)}
                </span>
              </td>
              <td className="px-4 py-3 max-w-[280px] truncate text-[12px] text-[var(--color-danger)]" title={doc.error_message || ''}>
                {doc.error_message || '-'}
              </td>
              <td className="px-4 py-3 text-[12px] text-[var(--color-text-sub)]">{formatDate(doc.created_at)}</td>
              <td className="px-4 py-3 text-right">
                {failed ? (
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={() => doRetry(doc.uuid)}
                    disabled={!!retrying[doc.uuid]}
                    title="重新触发解析"
                  >
                    <RotateCcw size={12} />
                    {retrying[doc.uuid] ? '重试中' : '重试'}
                  </Button>
                ) : (
                  <Button
                    size="sm"
                    variant="ghost"
                    disabled
                    title="文档已解析完成；只有异常文档需要重试"
                  >
                    <CheckCircle2 size={12} />
                    已完成
                  </Button>
                )}
              </td>
            </tr>
          )
        })}
      </DataTable>

      {activeKB && !loadingDocs && (
        <Pagination
          total={total}
          page={page}
          pageSize={pageSize}
          pageSizeOptions={[20, 50, 100]}
          onPageChange={(nextPage) => {
            setPage(nextPage)
            setLoadingDocs(true)
          }}
          onPageSizeChange={(size) => {
            setPageSize(size)
            setPage(1)
            setLoadingDocs(true)
          }}
        />
      )}
    </div>
  )
}
