import type { Department } from '../../lib/departmentApi'
import { Select } from '../ui'

export function MemberDepartmentSelect({
  departments,
  value,
  onChange,
  disabled = false,
}: {
  departments: Department[]
  value: number | ''
  onChange: (departmentID: number | '') => void
  disabled?: boolean
}) {
  return (
    <Select
      value={value}
      onChange={(event) => onChange(event.target.value === '' ? '' : Number(event.target.value))}
      disabled={disabled}
      required
    >
      <option value="" disabled>请选择部门</option>
      {departments.map((department) => (
        <option key={department.id} value={department.id}>
          {'　'.repeat(department.depth)}{department.name}
        </option>
      ))}
    </Select>
  )
}
