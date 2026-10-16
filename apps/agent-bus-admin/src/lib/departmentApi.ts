import { api } from './httpClient'
export type Department = {
  id: number
  uuid: string
  tenant_id: number
  parent_id: number | null
  path: string
  depth: number
  name: string
  sort_order: number
  metadata?: Record<string, unknown>
  member_count: number
}

export type CreateDeptInput = {
  name: string
  parent_id?: number | null
  sort_order?: number
  leader_id?: number | null
  metadata?: Record<string, unknown>
}
export type UpdateDeptInput = {
  name?: string
  parent_id?: number | null
  sort_order?: number
  leader_id?: number | null
  metadata?: Record<string, unknown>
}

export const Departments = {
  list: () => api<{ items: Department[]; total: number }>(`/api/admin/v1/tenant/departments`),
  create: (body: CreateDeptInput) =>
    api<Department>('/api/admin/v1/tenant/departments', { method: 'POST', body: JSON.stringify(body) }),
  update: (id: number, body: UpdateDeptInput) =>
    api<Department>(`/api/admin/v1/tenant/departments/${id}`, { method: 'PUT', body: JSON.stringify(body) }),
  remove: (id: number) =>
    api<{ ok: boolean }>(`/api/admin/v1/tenant/departments/${id}`, { method: 'DELETE' }),
}
