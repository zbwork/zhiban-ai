import type { Department } from './api'

export function defaultRootDepartmentID(departments: Department[]): number | '' {
  const roots = departments
    .filter((department) => department.parent_id === null)
    .sort((a, b) => a.id - b.id)
  return roots[0]?.id ?? ''
}
