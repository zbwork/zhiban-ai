// 服务商与定价（F24 v2-W2 壳 → 2026-07-30 扩展）：代账定价矩阵编辑 +
// 注册交接供应商分单（城市→供应商→邮箱，契约 §2.8）。均经 admin Go 代理写
// baigong 配置，operator 服务端注入并落双侧审计。
import { useCallback, useEffect, useState } from 'react'
import { Plus, RefreshCw, Save } from 'lucide-react'

import {
  StartupAgentCases,
  type BookkeepingPricing,
  type CityPricingRow,
  type HandoffRoutes,
} from '../lib/api'
import { notifyOk } from '../lib/toast'
import { Button, EmptyState, InlineAlert, Input, PageHeader, Select } from '../components/ui'

function newSupplierId(): string {
  return `s-${crypto.randomUUID().slice(0, 8)}`
}

type CityRow = { city: string; supplier: string }

export function ProviderPricingPage() {
  const [pricing, setPricing] = useState<BookkeepingPricing | null>(null)
  const [draft, setDraft] = useState<Record<string, Record<string, [number, number]>>>({})
  const [routes, setRoutes] = useState<HandoffRoutes | null>(null)
  const [cityPricing, setCityPricing] = useState<CityPricingRow[] | null>(null)
  const [savingCityPricing, setSavingCityPricing] = useState(false)
  const [cityPricingError, setCityPricingError] = useState('')
  const [cityRows, setCityRows] = useState<CityRow[]>([])
  const [loading, setLoading] = useState(true)
  const [savingPricing, setSavingPricing] = useState(false)
  const [savingRoutes, setSavingRoutes] = useState(false)
  const [error, setError] = useState('')
  const [routesError, setRoutesError] = useState('')

  const [tick, setTick] = useState(0)

  useEffect(() => {
    let cancelled = false
    Promise.all([StartupAgentCases.getPricing(), StartupAgentCases.getHandoffRoutes(),
      StartupAgentCases.getCityPricing()])
      .then(([pricingRes, routesRes, cityRes]) => {
        if (cancelled) return
        setPricing(pricingRes)
        setDraft(JSON.parse(JSON.stringify(pricingRes.matrix)))
        setRoutes(routesRes)
        setCityPricing(JSON.parse(JSON.stringify(cityRes.cities ?? [])))
        setCityRows(Object.entries(routesRes.city_routes).map(([city, supplier]) => ({ city, supplier })))
        setError('')
        setRoutesError('')
      })
      .catch((e: Error) => { if (!cancelled) setError(e.message) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [tick])

  const load = useCallback(() => {
    setLoading(true)
    setTick((v) => v + 1)
  }, [])

  // ---------------------------------------------------------- 定价矩阵

  const setCell = (row: string, band: string, idx: 0 | 1, raw: string) => {
    const v = Number(raw)
    setDraft((prev) => {
      const next = { ...prev, [row]: { ...prev[row] } }
      const cell: [number, number] = [...(next[row][band] ?? [0, 0])] as [number, number]
      cell[idx] = Number.isFinite(v) ? v : 0
      next[row][band] = cell
      return next
    })
  }

  const savePricing = async () => {
    for (const [row, cells] of Object.entries(draft)) {
      for (const [band, [lo, hi]] of Object.entries(cells)) {
        if (lo < 0 || hi < lo) {
          setError(`「${row} × ${band}」区间不合法（需 0 ≤ 低 ≤ 高）`)
          return
        }
      }
    }
    setSavingPricing(true)
    setError('')
    try {
      await StartupAgentCases.putPricing(draft)
      notifyOk('定价矩阵已保存（已记录审计）')
      load()
    } catch (e) {
      setError(e instanceof Error ? e.message : '保存失败')
    } finally {
      setSavingPricing(false)
    }
  }

  // ---------------------------------------------------------- 供应商分单

  const patchSupplier = (id: string, field: 'name' | 'email' | 'note', value: string) => {
    setRoutes((prev) => prev && ({
      ...prev,
      suppliers: prev.suppliers.map((s) => (s.id === id ? { ...s, [field]: value } : s)),
    }))
  }

  const addSupplier = () => {
    setRoutes((prev) => prev && ({
      ...prev,
      suppliers: [...prev.suppliers, { id: newSupplierId(), name: '', email: '', note: '' }],
    }))
  }

  const removeSupplier = (id: string) => {
    if (!routes) return
    if (routes.default_supplier === id || cityRows.some((r) => r.supplier === id)) {
      setRoutesError('该供应商仍被城市分单或默认设置引用，请先解除引用再移除')
      return
    }
    setRoutesError('')
    setRoutes({ ...routes, suppliers: routes.suppliers.filter((s) => s.id !== id) })
  }

  const saveRoutes = async () => {
    if (!routes) return
    for (const s of routes.suppliers) {
      if (!s.name.trim() || !s.email.trim()) {
        setRoutesError('供应商的名称与收件邮箱均不能为空')
        return
      }
      if (!s.email.includes('@')) {
        setRoutesError(`邮箱「${s.email}」格式不合法`)
        return
      }
    }
    const cityMap: Record<string, string> = {}
    for (const r of cityRows) {
      const city = r.city.trim()
      if (!city) {
        setRoutesError('城市名不能为空')
        return
      }
      if (!r.supplier) {
        setRoutesError(`城市「${city}」还没有选择供应商`)
        return
      }
      if (cityMap[city]) {
        setRoutesError(`城市「${city}」重复配置`)
        return
      }
      cityMap[city] = r.supplier
    }
    setSavingRoutes(true)
    setRoutesError('')
    try {
      await StartupAgentCases.putHandoffRoutes({ ...routes, city_routes: cityMap })
      notifyOk('供应商分单已保存（已记录审计）')
      load()
    } catch (e) {
      setRoutesError(e instanceof Error ? e.message : '保存失败')
    } finally {
      setSavingRoutes(false)
    }
  }

  // ---------------------------------------------------------- 城市地址价目

  const setSell = (city: string, field: 'reg_fee' | 'addr_fee_year' | 'note', raw: string) => {
    setCityPricing((prev) => {
      if (!prev) return prev
      return prev.map((row) => {
        if (row.city !== city) return row
        const sell = { ...row.sell }
        if (field === 'note') sell.note = raw
        else sell[field] = raw.trim() === '' ? null : Number(raw)
        return { ...row, sell }
      })
    })
  }

  // 主供 = 地址年费成本最低（报价缺失的不参与），派生不落库
  const primaryOf = (row: CityPricingRow) => {
    const priced = row.suppliers.filter((sp) => typeof sp.addr_cost_year === 'number')
    if (priced.length === 0) return null
    return priced.reduce((a, b) => ((a.addr_cost_year ?? 0) <= (b.addr_cost_year ?? 0) ? a : b))
  }

  const saveCityPricing = async () => {
    if (!cityPricing) return
    for (const row of cityPricing) {
      const { reg_fee, addr_fee_year } = row.sell
      if ((reg_fee !== null && (!Number.isFinite(reg_fee) || reg_fee < 0))
        || (addr_fee_year !== null && (!Number.isFinite(addr_fee_year) || addr_fee_year < 0))) {
        setCityPricingError(`「${row.city}」的售价必须是非负数字（留空=该城不报价）`)
        return
      }
    }
    setSavingCityPricing(true)
    setCityPricingError('')
    try {
      await StartupAgentCases.putCityPricing(cityPricing)
      notifyOk('城市价目已保存（已记录审计）')
      load()
    } catch (e) {
      setCityPricingError(e instanceof Error ? e.message : '保存失败')
    } finally {
      setSavingCityPricing(false)
    }
  }

  const supplierName = (id: string) =>
    routes?.suppliers.find((s) => s.id === id)?.name || id

  return (
    <div>
      <PageHeader
        title="服务商与定价"
        subtitle="注册交接的供应商分单（按城市把资料包发给对应供应商）与代理记账定价矩阵；保存即时生效并记录审计。"
        actions={<Button variant="secondary" onClick={load}><RefreshCw size={14} /> 刷新</Button>}
      />
      {loading ? (
        <EmptyState title="加载中…" />
      ) : (
        <div className="space-y-8">
          {routes && (
            <section>
              <div className="mb-3 flex items-end justify-between gap-4">
                <div>
                  <h2 className="text-[15px] font-semibold">注册交接供应商分单</h2>
                  <p className="mt-0.5 text-[12.5px] text-[var(--color-text-mute)]">
                    注册资料包与取消通知按注册城市发给对应供应商；未命中城市发默认供应商；未设默认时转内部邮箱人工分配。
                  </p>
                </div>
                <Button disabled={savingRoutes} onClick={() => void saveRoutes()}>
                  <Save size={14} /> {savingRoutes ? '保存中…' : '保存分单（记录审计）'}
                </Button>
              </div>
              {routesError && <div className="mb-3"><InlineAlert tone="danger">{routesError}</InlineAlert></div>}

              <div className="mb-2 flex items-center justify-between">
                <span className="text-[13px] font-medium">供应商（{routes.suppliers.length}）</span>
                <Button variant="secondary" onClick={addSupplier}><Plus size={14} /> 添加供应商</Button>
              </div>
              <section className="overflow-x-auto rounded-lg border border-[var(--color-line)] bg-white">
                {routes.suppliers.length === 0 ? (
                  <EmptyState title="暂无供应商" description="未配置供应商时，所有注册资料包发内部邮箱人工分配。" />
                ) : (
                  <table className="w-full text-[13px]">
                    <thead className="border-b border-[var(--color-line)] bg-[var(--color-bg-sub)]">
                      <tr>
                        <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">名称</th>
                        <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">收件邮箱</th>
                        <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">备注</th>
                        <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap w-[80px]">操作</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-[var(--color-line-soft)]">
                      {routes.suppliers.map((s) => (
                        <tr key={s.id}>
                          <td className="px-4 py-2">
                            <Input value={s.name} placeholder="如：供应商A" className="w-[180px]"
                                   onChange={(e) => patchSupplier(s.id, 'name', e.target.value)} />
                          </td>
                          <td className="px-4 py-2">
                            <Input value={s.email} placeholder="handoff@example.com" className="w-[240px]"
                                   onChange={(e) => patchSupplier(s.id, 'email', e.target.value)} />
                          </td>
                          <td className="px-4 py-2">
                            <Input value={s.note} placeholder="选填" className="w-full min-w-[160px]"
                                   onChange={(e) => patchSupplier(s.id, 'note', e.target.value)} />
                          </td>
                          <td className="px-4 py-2">
                            <Button variant="ghost" size="sm" onClick={() => removeSupplier(s.id)}>移除</Button>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </section>

              <div className="mt-4 flex items-center gap-2 text-[13px]">
                <span className="font-medium whitespace-nowrap">未命中城市兜底</span>
                <Select value={routes.default_supplier} className="w-[260px]"
                        onChange={(e) => setRoutes({ ...routes, default_supplier: e.target.value })}>
                  <option value="">无默认供应商（转内部邮箱人工分配）</option>
                  {routes.suppliers.map((s) => (
                    <option key={s.id} value={s.id}>{s.name || '（未命名供应商）'}</option>
                  ))}
                </Select>
              </div>

              <div className="mt-4 mb-2 flex items-center justify-between">
                <span className="text-[13px] font-medium">城市分单（{cityRows.length}）</span>
                <Button variant="secondary"
                        onClick={() => setCityRows((rows) => [...rows, { city: '', supplier: '' }])}>
                  <Plus size={14} /> 添加城市
                </Button>
              </div>
              <section className="overflow-x-auto rounded-lg border border-[var(--color-line)] bg-white">
                {cityRows.length === 0 ? (
                  <EmptyState title="暂无城市分单" description="全部城市都会走默认供应商或内部邮箱。" />
                ) : (
                  <table className="w-full text-[13px]">
                    <thead className="border-b border-[var(--color-line)] bg-[var(--color-bg-sub)]">
                      <tr>
                        <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">注册城市</th>
                        <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">供应商</th>
                        <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap w-[80px]">操作</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-[var(--color-line-soft)]">
                      {cityRows.map((row, i) => (
                        <tr key={i}>
                          <td className="px-4 py-2">
                            <Input value={row.city} placeholder="如：哈尔滨（自动忽略结尾的「市」）" className="w-[260px]"
                                   onChange={(e) => setCityRows((rows) =>
                                     rows.map((r, j) => (j === i ? { ...r, city: e.target.value } : r)))} />
                          </td>
                          <td className="px-4 py-2">
                            <Select value={row.supplier} className="w-[220px]"
                                    onChange={(e) => setCityRows((rows) =>
                                      rows.map((r, j) => (j === i ? { ...r, supplier: e.target.value } : r)))}>
                              <option value="">请选择供应商</option>
                              {routes.suppliers.map((s) => (
                                <option key={s.id} value={s.id}>{supplierName(s.id)}</option>
                              ))}
                            </Select>
                          </td>
                          <td className="px-4 py-2">
                            <Button variant="ghost" size="sm"
                                    onClick={() => setCityRows((rows) => rows.filter((_, j) => j !== i))}>
                              移除
                            </Button>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </section>
              <p className="mt-2 text-[12.5px] text-[var(--color-text-mute)]">
                已发出资料包的工单会锁定首次命中的供应商，改配置不影响在办工单；供应商停止合作请先改城市分单再移除。
              </p>
            </section>
          )}

          {cityPricing && cityPricing.length > 0 && (
            <section>
              <div className="mb-3 flex items-end justify-between gap-4">
                <div>
                  <h2 className="text-[15px] font-semibold">城市地址价目</h2>
                  <p className="mt-0.5 text-[12.5px] text-[var(--color-text-mute)]">
                    各家为供应商成本价，仅后台可见；主供＝地址成本最低自动选定。对外售价由运营手动填写，留空＝该城不报价（用户侧转顾问确认）。
                  </p>
                </div>
                <Button disabled={savingCityPricing} onClick={() => void saveCityPricing()}>
                  <Save size={14} /> {savingCityPricing ? '保存中…' : '保存价目（记录审计）'}
                </Button>
              </div>
              {cityPricingError && (
                <div className="mb-3"><InlineAlert tone="danger">{cityPricingError}</InlineAlert></div>
              )}
              <section className="overflow-x-auto rounded-lg border border-[var(--color-line)] bg-white">
                <table className="w-full text-[13px]">
                  <thead className="border-b border-[var(--color-line)] bg-[var(--color-bg-sub)]">
                    <tr>
                      <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">城市</th>
                      <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">各家成本（地址元/年；打包为一口价）</th>
                      <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">主供</th>
                      <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">售价·注册服务费</th>
                      <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">售价·地址年费</th>
                      <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">对外备注</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-[var(--color-line-soft)]">
                    {cityPricing.map((row) => {
                      const primary = primaryOf(row)
                      const belowCost = row.sell.addr_fee_year !== null && primary
                        && row.sell.addr_fee_year < (primary.addr_cost_year ?? 0)
                      return (
                        <tr key={row.city}>
                          <td className="px-4 py-2.5 font-medium whitespace-nowrap">{row.city}</td>
                          <td className="px-4 py-2.5 whitespace-nowrap text-[var(--color-text-sub)]">
                            {row.suppliers.map((sp) => {
                              if (sp.addr_cost_year !== null) return `${sp.code} ${sp.addr_cost_year}`
                              // 打包供应商（如 A 家）：无单列地址成本，展示一口价与所含地址期限
                              if (sp.reg_cost !== null) {
                                const term = sp.term.includes('长期') ? '含长期地址' : '含一年地址'
                                return `${sp.code} 打包${sp.reg_cost}·${term}`
                              }
                              return `${sp.code} —`
                            }).join(' · ')}
                          </td>
                          <td className="px-4 py-2.5 whitespace-nowrap">
                            {primary ? `${primary.code}（${primary.addr_cost_year}）` : '—'}
                          </td>
                          <td className="px-4 py-2">
                            <Input value={row.sell.reg_fee ?? ''} placeholder="留空=不报价"
                                   className="w-[110px]" inputMode="numeric"
                                   onChange={(e) => setSell(row.city, 'reg_fee', e.target.value)} />
                          </td>
                          <td className="px-4 py-2">
                            <Input value={row.sell.addr_fee_year ?? ''} placeholder="留空=不报价"
                                   className={`w-[110px] ${belowCost ? 'border-[var(--color-danger)]' : ''}`}
                                   inputMode="numeric"
                                   onChange={(e) => setSell(row.city, 'addr_fee_year', e.target.value)} />
                          </td>
                          <td className="px-4 py-2">
                            <Input value={row.sell.note} placeholder="选填，用户可见"
                                   className="w-full min-w-[150px]"
                                   onChange={(e) => setSell(row.city, 'note', e.target.value)} />
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </section>
              <p className="mt-2 text-[12.5px] text-[var(--color-text-mute)]">
                地址售价低于主供成本时输入框标红提醒（不拦截保存）；成本与供应商信息不会出现在用户侧。
              </p>
            </section>
          )}

          {pricing && (
            <section>
              <div className="mb-3 flex items-end justify-between gap-4">
                <div>
                  <h2 className="text-[15px] font-semibold">代理记账定价矩阵</h2>
                  <p className="mt-0.5 text-[12.5px] text-[var(--color-text-mute)]">
                    元/月区间；用户端费用评估按此查表报价。
                  </p>
                </div>
                <Button disabled={savingPricing} onClick={() => void savePricing()}>
                  <Save size={14} /> {savingPricing ? '保存中…' : '保存定价（记录审计）'}
                </Button>
              </div>
              {error && <div className="mb-3"><InlineAlert tone="danger">{error}</InlineAlert></div>}
              <section className="overflow-x-auto rounded-lg border border-[var(--color-line)] bg-white">
                <table className="w-full text-[13px]">
                  <thead className="border-b border-[var(--color-line)] bg-[var(--color-bg-sub)]">
                    <tr>
                      <th className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">纳税人类型 \ 月票据档</th>
                      {pricing.bands.map((band) => (
                        <th key={band} className="px-4 py-2.5 text-left font-semibold whitespace-nowrap">{band}</th>
                      ))}
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-[var(--color-line-soft)]">
                    {Object.entries(draft).map(([row, cells]) => (
                      <tr key={row}>
                        <td className="px-4 py-2.5 font-medium whitespace-nowrap">{row}</td>
                        {pricing.bands.map((band) => {
                          const cell = cells[band] ?? [0, 0]
                          return (
                            <td key={band} className="px-4 py-2">
                              <div className="flex items-center gap-1.5">
                                <Input value={String(cell[0])} inputMode="numeric" className="w-[76px]"
                                       onChange={(e) => setCell(row, band, 0, e.target.value)} />
                                <span className="text-[var(--color-text-mute)]">–</span>
                                <Input value={String(cell[1])} inputMode="numeric" className="w-[76px]"
                                       onChange={(e) => setCell(row, band, 1, e.target.value)} />
                              </div>
                            </td>
                          )
                        })}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </section>
              <p className="mt-3 text-[12.5px] text-[var(--color-text-mute)]">
                档位口径与用户端评估表单一致（月票据张数）；「不确定」纳税人类型不出价，由顾问人工报价。
              </p>
            </section>
          )}
        </div>
      )}
    </div>
  )
}
