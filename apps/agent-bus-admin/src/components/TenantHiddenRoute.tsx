import { useOutletContext, Navigate } from 'react-router-dom'
import type { ReactNode } from 'react'
import type { LayoutOutletContext } from './Layout'

/**
 * Batch 2B T2B.4 — Vertical Slice 路由收口
 *
 * 这一批 tenant scope 不做 Agent / Skill / 通讯录策略 / 角色 tree UI，
 * 这些路由对应的页面是半成品。直接挂半成品组件违反"不展示空页面"的硬约束。
 *
 * 但同样的路由在 platform scope 下是平台运营工具（如 platform admin 配 platform 角色），
 * 整体把组件删掉会把 platform 的能力也砍掉。
 *
 * 该组件按当前 act_scope 决定：
 *   - actScope **尚未加载**（Layout useEffect 还在 fetch /me） → return null（loading 预留）
 *     **关键修复 (Batch 2B closeout #6)**：之前在 scope undefined 时会落入"透传 children"分支，
 *     可能短暂渲染 AgentList 半成品 UI 后才跳走。改为返回 null，渲染 nothing 直到 Layout 注入 scope。
 *   - tenant / workspace 视角 → 重定向 /dashboard（避免渲染半成品）
 *   - platform 视角 → 透传 children（保留 platform 工具）
 *
 * Batch 2C / 2D / 2E 启动对应模块时，请把该 wrapper 从对应 route 移除。
 */
export function TenantHiddenRoute({ children }: { children: ReactNode }) {
  const ctx = useOutletContext<LayoutOutletContext>()
  const scope = ctx?.actScope?.kind

  // 未加载完成：渲染空，避免半成品组件被瞬时挂载并触发 effect / 请求
  if (!scope) {
    return null
  }
  // 受限 scope → 立即 redirect
  if (scope === 'tenant' || scope === 'workspace') {
    return <Navigate to="/dashboard" replace />
  }
  // platform scope → 明确透传
  if (scope === 'platform') {
    return <>{children}</>
  }
  // 未来出现的未知 scope → 安全侧 redirect，不渲染半成品
  return <Navigate to="/dashboard" replace />
}

export function TenantOnlyRoute({ children }: { children: ReactNode }) {
  const ctx = useOutletContext<LayoutOutletContext>()
  const scope = ctx?.actScope?.kind

  if (!scope) {
    return null
  }
  if (scope === 'tenant' || scope === 'workspace') {
    return <>{children}</>
  }
  return <Navigate to="/dashboard" replace />
}
