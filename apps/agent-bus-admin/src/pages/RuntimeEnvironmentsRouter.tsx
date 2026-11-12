// 按 actScope 分发到 Platform / Tenant 视图。
import { useOutletContext } from 'react-router-dom'
import { PlatformRuntimeEnvironments } from './PlatformRuntimeEnvironments'
import { TenantRuntimeEnvironments } from './TenantRuntimeEnvironments'
import type { ScopeOption } from '../lib/api'

type Ctx = { actScope?: ScopeOption | null }

export function RuntimeEnvironmentsRouter() {
  const ctx = useOutletContext<Ctx>() || {}
  const scope = ctx.actScope?.kind
  if (scope === 'platform') return <PlatformRuntimeEnvironments />
  // 默认走 tenant 视图; act_scope=tenant/workspace 都走这里。
  return <TenantRuntimeEnvironments />
}
