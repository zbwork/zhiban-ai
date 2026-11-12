import { useState } from 'react'
import type { RuntimeEnv } from '../../lib/api'
import type { AgentDraft } from '../agent/AgentEditorModel'
import { cloudAgentTemplateCreationEnabled, isRuntimeBindableForAgent } from '../agent/AgentEditorModel'
import { FormField, SegmentedControl, Select } from '../ui'

const engineNames: Record<string, string> = {
  dsh: 'DSH', openclaw: 'OpenClaw', hermes: 'Hermes', zap: '自定义 Agent（ZAP）',
}

export function AgentExecutionFields({ draft, onChange, disabled, template, runtimes, required, allowCreateRuntime, allowTemplateCloudToLocal = false }: {
  draft: AgentDraft
  onChange: (patch: Partial<AgentDraft>) => void
  disabled: boolean
  template: boolean
  runtimes: RuntimeEnv[]
  required: boolean
  allowCreateRuntime: boolean
  allowTemplateCloudToLocal?: boolean
}) {
  const [engineFilter, setEngineFilter] = useState('')
  const selected = runtimes.find((r) => r.ID === draft.RuntimeEnvironmentID)
  const engine = selected?.Framework || engineFilter
  const engines = [...new Set(runtimes.map((r) => r.Framework))]
  const isBindable = (r: RuntimeEnv) => isRuntimeBindableForAgent(r) && (!template || r.OpenToTenants)
  const selectable = runtimes.filter(isBindable).filter((r) => !engine || r.Framework === engine)
  const local = draft.ExecutionLocus === 'local'
  return <>
    {(template || local) && <FormField label="运行位置" as="div">
      <SegmentedControl
        value={draft.ExecutionLocus}
        options={[
          { value: 'local', label: '用户电脑', disabled: disabled || !template || (!cloudAgentTemplateCreationEnabled && !local && !allowTemplateCloudToLocal) },
          { value: 'cloud', label: template && !cloudAgentTemplateCreationEnabled ? '云端（暂未开放）' : '云端', disabled: disabled || !template || !cloudAgentTemplateCreationEnabled },
        ]}
        onChange={(value) => {
          if (disabled || !template || value === draft.ExecutionLocus) return
          if (value === 'cloud' && !cloudAgentTemplateCreationEnabled) return
          if (value === 'local' && !cloudAgentTemplateCreationEnabled && !allowTemplateCloudToLocal) return
          onChange({ ExecutionLocus: value as 'local' | 'cloud', RuntimeEnvironmentID: null, AgentKey: '', LocalEngine: value === 'local' ? 'dsh' : '' })
        }}
      />
    </FormField>}
    {local ? <>
      <FormField label="本地引擎">
        <Select aria-label="本地引擎" value={draft.LocalEngine || 'dsh'} disabled={disabled || !template}
          onChange={(e) => onChange({ LocalEngine: e.target.value as AgentDraft['LocalEngine'] })}>
          <option value="dsh">DeepSeek Harness</option>
          <option value="codex_app_server">Codex App Server</option>
        </Select>
      </FormField>
      <p className="text-[13px] text-[var(--color-text-sub)]">{template
        ? '用户使用模板后，由其电脑运行。模型、工作目录和权限在使用时配置。'
        : '由当前使用者的电脑运行，已有员工的本地引擎保持不变。'}</p>
    </> : <>
      <FormField label="云端引擎">
        <Select aria-label="云端引擎" value={engine} disabled={disabled} onChange={(e) => {
          setEngineFilter(e.target.value)
          onChange({ RuntimeEnvironmentID: null, AgentKey: '' })
        }}>
          <option value="">全部引擎</option>
          {engines.map((v) => <option key={v} value={v}>{engineNames[v] || v}</option>)}
        </Select>
      </FormField>
      <FormField label={required ? '运行环境 *' : '运行环境'} hint="仅可绑定已启用、探测通过且审核通过的环境。">
        <Select aria-label="运行环境" value={draft.RuntimeEnvironmentID || 0} disabled={disabled} onChange={(e) => {
          if (e.target.value === '__custom__') { window.open('/runtime-environments?openAddDialog=1', '_blank', 'noopener'); return }
          onChange({ RuntimeEnvironmentID: Number(e.target.value) || null, AgentKey: '' })
        }}>
          <option value={0}>{required ? '请选择运行环境' : '暂不绑定运行环境'}</option>
          {selected && !isBindable(selected) && <option value={selected.ID}>{selected.Name}（当前不可用）</option>}
          {selectable.map((r) => <option key={r.ID} value={r.ID}>{engineNames[r.Framework] || r.Framework} · {r.Name}</option>)}
          {allowCreateRuntime && <option value="__custom__">+ 新建自定义运行环境...</option>}
        </Select>
      </FormField>
    </>}
  </>
}
