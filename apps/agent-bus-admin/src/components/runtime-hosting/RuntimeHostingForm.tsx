// RuntimeHostingForm.tsx · 平台 / 租户「智能体托管环境」共享表单组件 (ADR-0025 §2.5 Phase A)。
//
// 抽象边界:
//   - 本组件 **只** 负责"按 hosting_kind 渲染对应字段"的 sections, 包括:
//       * external_endpoint (平台 ZAP 自建接入) — primary_endpoint + 访问凭证;
//         不渲染 image / k8s / 资源 / 运行时参数。
//       * clawmanager — workload api base + token ref + 工作负载默认参数 + 运行时参数。
//       * k8s_native  — k8s api server + token ref + 跳过 TLS + 工作负载默认参数 + 运行时参数。
//   - **不** 负责 page 级 footer / drawer / probe 调用 / save 调用 — 由 caller (CreateHostingConfigPanel
//     / HostingConfigPanel / TenantRuntimeEnvironments 自定义抽屉) 自己持有。
//   - 校验、敏感字段 normalize 全部走 lib/hostingConfig.ts; 本组件保持纯渲染。
//
// 这样既复用 UI, 又保留各 page 自己的 lifecycle (新建 vs 编辑、不同 API 端点) 灵活性。

import { useRef, useState } from 'react'
import clsx from 'clsx'
import { Trash2, UploadCloud } from 'lucide-react'
import type { HostingConfig } from '../../lib/api'
import { requiresK8sWriteChannel, type HostingFormScope, type HostingKind } from '../../lib/hostingConfig'
import { HelpLabel, InlineAlert, Tabs } from '../ui'
import { SecretValueField } from '../form/SecretValueField'
import { BUILTIN_RUNTIME_CAPS, CAP_GROUPS } from './capabilities'

// ---------------------------------------------------------------------------
// 内部小组件: 这些 helper 与 RuntimeHosting.tsx 内的 Field/Grid2/SelectField/NumberField
// 视觉一致, 但本文件独立维护一份, 避免破坏既有 page 的单元测试 / 视觉 token。
// ---------------------------------------------------------------------------

function Section({ title, desc, children }: { title: string; desc?: string; children: React.ReactNode }) {
  return (
    <section className="rounded-lg ring-1 ring-[var(--color-line)] bg-white p-4">
      <div className="text-[14px] font-semibold text-[var(--color-text)] mb-2">{title}</div>
      {desc && <p className="text-[11.5px] text-[var(--color-text-sub)] mb-2 leading-relaxed">{desc}</p>}
      {children}
    </section>
  )
}
function Grid2({ children }: { children: React.ReactNode }) {
  return <div className="grid grid-cols-1 md:grid-cols-2 gap-3">{children}</div>
}
export type RuntimeHostingFormFieldErrors = Partial<Record<
  | 'primary_endpoint'
  | 'api_key_secret_ref'
  | 'external_environment_id'
  | 'workload_api_base_url'
  | 'workload_api_token_secret_ref'
  | 'k8s_api_server_url'
  | 'k8s_token_secret_ref'
  | 'k8s_namespace'
  | 'image_repository'
  | 'image_tag'
  | 'mount_path',
  string
>>

function Field({ label, help, value, onChange, placeholder, mono, error, maxLength }: {
  label: string
  help?: string
  value: string
  onChange: (v: string) => void
  placeholder?: string
  mono?: boolean
  error?: string
  maxLength?: number
}) {
  return (
    <div>
      <HelpLabel label={label} hint={help} />
      <input
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        maxLength={maxLength}
        aria-invalid={!!error}
        className={clsx(
          'w-full h-10 px-3 text-[13px] rounded-md ring-1 ring-[var(--color-line)] focus:ring-2 focus:ring-[var(--color-text)]/20 focus:outline-none bg-white',
          mono && 'font-mono text-[12px]',
          error && 'ring-[var(--color-danger)] focus:ring-[var(--color-danger)]/20'
        )}
      />
      {error && (
        <p className="mt-1 text-[11.5px] leading-relaxed text-[var(--color-danger)]">
          {error}
        </p>
      )}
    </div>
  )
}
function NumberField({ label, value, onChange }: { label: string; value: number; onChange: (v: number) => void }) {
  return (
    <div>
      <label className="text-[13px] font-medium text-[var(--color-text)] mb-1.5 block">{label}</label>
      <input
        type="number"
        value={value}
        onChange={(e) => onChange(Number(e.target.value) || 0)}
        className="w-full h-10 px-3 text-[13px] rounded-md ring-1 ring-[var(--color-text)]/20 focus:outline-none ring-1 ring-[var(--color-line)] bg-white tabular-nums"
      />
    </div>
  )
}

function KubeconfigUploadField({
  valueRef,
  onChangeRef,
}: {
  valueRef?: string
  onChangeRef: (v: string) => void
}) {
  const inputRef = useRef<HTMLInputElement | null>(null)
  const [err, setErr] = useState('')
  const configured = !!(valueRef || '').trim()

  async function pick(file?: File) {
    setErr('')
    if (!file) return
    if (file.size > 1024 * 1024) {
      setErr('kubeconfig 文件不能超过 1MB。')
      return
    }
    const text = await file.text()
    if (!/apiVersion:\s*v1/.test(text) || !/clusters:\s*/.test(text) || !/users:\s*/.test(text)) {
      setErr('请选择有效的 kubeconfig 文件。')
      return
    }
    onChangeRef(`value://${text}`)
  }

  return (
    <div className="rounded-md border border-dashed border-[var(--color-line)] bg-[var(--color-bg-sub)] p-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="min-w-0">
          <HelpLabel
            label="Kubernetes 操作 kubeconfig"
            hint="与 API Server + 访问令牌二选一作为 k8s_native 监控操作凭证；仅用于重启和删除，不参与 ClawManager 生命周期、实例创建、数字员工注册或技能文件写入。"
          />
          <p className="mt-1 text-[11.5px] leading-relaxed text-[var(--color-text-sub)]">
            {configured ? '已配置 kubeconfig。重新上传会覆盖原配置。' : '上传后监控抽屉里的重启 / 删除会优先使用 kubeconfig。'}
          </p>
          {err && <p className="mt-1 text-[11.5px] text-[var(--color-danger)]">{err}</p>}
        </div>
        <div className="flex items-center gap-2">
          <input
            ref={inputRef}
            type="file"
            accept=".yaml,.yml,.conf,.config,text/yaml,text/plain"
            className="hidden"
            onChange={(e) => {
              void pick(e.target.files?.[0])
              e.currentTarget.value = ''
            }}
          />
          {configured && (
            <button
              type="button"
              onClick={() => onChangeRef('')}
              className="inline-flex h-8 items-center gap-1.5 rounded-md border border-[var(--color-line)] bg-white px-2.5 text-[12px] text-[var(--color-text-sub)] hover:bg-[var(--color-line-soft)]"
            >
              <Trash2 size={14} /> 清除
            </button>
          )}
          <button
            type="button"
            onClick={() => inputRef.current?.click()}
            className="inline-flex h-8 items-center gap-1.5 rounded-md bg-[var(--color-brand)] px-2.5 text-[12px] font-medium text-white hover:bg-[var(--color-brand-hover)]"
          >
            <UploadCloud size={14} /> 上传 kubeconfig
          </button>
        </div>
      </div>
    </div>
  )
}

type K8sOpsCredentialMode = 'api_token' | 'kubeconfig'

function K8sOpsCredentialTabs({
  mode,
  onModeChange,
  kubeconfigRef,
  onChangeKubeconfigRef,
}: {
  mode: K8sOpsCredentialMode
  onModeChange: (mode: K8sOpsCredentialMode) => void
  kubeconfigRef?: string
  onChangeKubeconfigRef: (v: string) => void
}) {
  return (
    <div className="mt-3 rounded-md border border-[var(--color-line)] bg-white p-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <HelpLabel
            label="Kubernetes 操作凭证"
            hint="仅用于监控抽屉里的重启和删除；实例创建、健康检查、OpenClaw 文件写入仍按上方 API Server + 访问令牌执行。"
          />
          <p className="mt-1 text-[11.5px] leading-relaxed text-[var(--color-text-sub)]">
            选择 kubeconfig 后，重启 / 删除优先使用上传的 kubeconfig；切回 API Server + Token 会清除 kubeconfig。
          </p>
        </div>
        <Tabs<K8sOpsCredentialMode>
          value={mode}
          onChange={onModeChange}
          items={[
            { value: 'api_token', label: 'API Server + Token' },
            { value: 'kubeconfig', label: 'kubeconfig' },
          ]}
        />
      </div>

      <div className="mt-3">
        {mode === 'api_token' ? (
          <InlineAlert tone="info">
            当前会复用上方 API Server 地址、访问令牌和 TLS 设置执行监控重启 / 删除。
          </InlineAlert>
        ) : (
          <KubeconfigUploadField
            valueRef={kubeconfigRef}
            onChangeRef={onChangeKubeconfigRef}
          />
        )}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// 公共组件主体
// ---------------------------------------------------------------------------

export type RuntimeHostingFormProps = {
  /** 平台 vs 租户 scope; external_endpoint 凭证策略二轨核心。 */
  scope: HostingFormScope
  /** 当前 hosting_kind, 由 caller 控制 (toggle / radio); 本组件按 kind 切换字段渲染。 */
  hostingKind: HostingKind
  /** L1 framework (zap / openclaw / hermes). external_endpoint 时必须 zap. */
  framework: string
  /** 全表单数据 (partial controlled). */
  cfg: HostingConfig
  /** patch 变更 (浅 merge). */
  onPatch: (p: Partial<HostingConfig>) => void
  /** 保留给旧 caller；当前表单不再展示额外的凭证方案选择。 */
  credRefKind: 'vault' | 'env'
  setCredRefKind: (v: 'vault' | 'env') => void
  /** 字段级校验错误；caller 仍持有全局错误与 probe/save 生命周期。 */
  fieldErrors?: RuntimeHostingFormFieldErrors
  /**
   * S5e: 最近一次「测试连通」的 runtime_card 能力探测结果 (仅 ZAP/custom 有意义)。
   * supportedCaps 可以包含 Admin Web 展示用能力, 如 agent.instance_initialize;
   * 表单保存仍只提交 cfg.control_plane_capabilities。
   * done=true 且 supportedCaps 非空时, 展示「已声明支持 / 未声明」并对"已勾但未声明"给出告警。
   * 不传 = 未测试连通; 仅展示勾选, 不展示探测对比。
   */
  probe?: { done: boolean; supportedCaps?: Record<string, boolean> }
}

// CapabilitySection S5e: control-plane「接口能力」声明 + probe 对比展示。
function CapabilitySection({ framework, caps, probe }: {
  framework: string
  caps: Record<string, boolean>
  probe?: { done: boolean; supportedCaps?: Record<string, boolean> }
}) {
  const isHermes = framework === 'hermes'
  const isOpenClaw = framework === 'openclaw'
  const isBuiltin = isHermes || isOpenClaw
  // ZAP / custom (含 'zap' 及任何非 openclaw/hermes 的 framework): 走 runtime_card probe 对比。
  const isZapLike = !isBuiltin
  const hasProbe = isZapLike && probe?.done === true
  const supported = probe?.supportedCaps || {}
  const hasSupportedInfo = hasProbe && Object.keys(supported).length > 0
  return (
    <Section
      title="接口能力"
      desc={isZapLike
        ? '外部 ZAP runtime 的接口能力以 runtime_card 声明为准；测试连通后展示探测结果，系统按声明自动调用。'
        : '内置运行框架的接口能力由系统按适配器和运行环境配置自动推导。'}
    >
      {isBuiltin && (
        <div className="mb-3">
          <InlineAlert tone="info">
            {framework === 'hermes' ? 'Hermes' : 'OpenClaw'} 为内置运行框架，接口能力由系统自动推导，**无需也不支持人工勾选**。是否真正生成数字员工注册 / 技能安装任务，取决于「Kubernetes 写入通道」是否配齐并通过健康检查（缺配置则不可用）。
          </InlineAlert>
        </div>
      )}
      {isZapLike && !hasProbe && (
        <div className="mb-3">
          <InlineAlert tone="info">
            先「测试连通性」读取 runtime_card；未声明的能力，Bus 不会调用对应接口。
          </InlineAlert>
        </div>
      )}
      <div className="space-y-4">
        {CAP_GROUPS.map((group) => (
          <div key={group.title}>
            <div className="text-[12.5px] font-medium text-[var(--color-text-sub)] mb-2">{group.title}</div>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-x-6 gap-y-2.5">
              {group.items.map((it) => {
                const builtinHint = isBuiltin && BUILTIN_RUNTIME_CAPS[framework]?.[it.key]
                return (
                  <div key={it.key} className="flex items-center justify-between gap-3">
                    <div className="min-w-0">
                      <HelpLabel label={it.label} hint={it.hint} />
                    </div>
                    <div className="flex items-center gap-2 shrink-0">
                      {isBuiltin ? (
                        // doc-12 §11.8.2: OpenClaw/Hermes 内置能力系统推导，只读展示，不给人工勾选。
                        builtinHint
                          ? <span className="text-[11px] text-[var(--color-success)]">系统内置</span>
                          : <span className="text-[11px] text-[var(--color-text-mute)]">不支持</span>
                      ) : isZapLike ? (
                        supported[it.key]
                          ? <span className="text-[11px] text-[var(--color-success)]">已声明支持</span>
                          : hasSupportedInfo
                            ? <span className="text-[11px] text-[var(--color-warn)]">未声明</span>
                            : <span className="text-[11px] text-[var(--color-text-mute)]">待探测</span>
                      ) : (
                        caps[it.key]
                          ? <span className="text-[11px] text-[var(--color-success)]">已启用</span>
                          : <span className="text-[11px] text-[var(--color-text-mute)]">不支持</span>
                      )}
                    </div>
                  </div>
                )
              })}
            </div>
          </div>
        ))}
      </div>
    </Section>
  )
}

export function RuntimeHostingForm(props: RuntimeHostingFormProps) {
  const { scope, hostingKind, framework, cfg, onPatch, probe } = props
  const fieldErrors = props.fieldErrors || {}
  const isExternal = hostingKind === 'external_endpoint'
  const caps = cfg.control_plane_capabilities || {}
  const k8sOpsStateKey = `${cfg.runtime_environment_id || 0}:${hostingKind}`
  const [k8sOpsModeOverride, setK8sOpsModeOverride] = useState<{ key: string; mode: K8sOpsCredentialMode } | null>(null)
  const k8sOpsMode: K8sOpsCredentialMode =
    k8sOpsModeOverride?.key === k8sOpsStateKey
      ? k8sOpsModeOverride.mode
      : (cfg.k8s_ops_kubeconfig_secret_ref ? 'kubeconfig' : 'api_token')
  const changeK8sOpsMode = (mode: K8sOpsCredentialMode) => {
    setK8sOpsModeOverride({ key: k8sOpsStateKey, mode })
    if (mode === 'api_token') {
      onPatch({ k8s_ops_kubeconfig_secret_ref: '' })
    }
  }

  return (
    <div className="space-y-5">
      {/* ADR-0025: 平台 ZAP 自建接入 — 仅展示 服务地址 + 访问凭证. */}
      {isExternal && (
        <Section
          title="ZAP 服务接入"
          desc={scope === 'platform'
            ? '平台外部 ZAP runtime 必须实现 multi_tenant_isolation；连通性测试会强校验。服务地址填 runtime 根地址，不带 /zap/v1 后缀。'
            : '外部 ZAP runtime 必须可被本租户访问。服务地址填 runtime 根地址，不带 /zap/v1 后缀；后端会自动拼 /zap/v1/runtime_card。'}
        >
          <Grid2>
            <Field
              label="服务地址（primary_endpoint）"
              help="runtime 根地址；后端会自动拼 /zap/v1/runtime_card 做连通性测试。"
              value={cfg.primary_endpoint || ''}
              onChange={(v) => onPatch({ primary_endpoint: v })}
              placeholder="https://my-zap-runtime.example.com"
              mono
              error={fieldErrors.primary_endpoint}
            />
            <SecretValueField
              label="访问凭证"
              hint={scope === 'platform'
                ? '直接填写平台外部 ZAP runtime 的访问凭证；系统会自动保存为内部凭证，并用同一凭证完成连通性测试。'
                : '直接填写外部智能体 Bearer Token；系统会自动保存为内部凭证，并用同一凭证完成连通性测试。'}
              valueRef={cfg.api_key_secret_ref || ''}
              onChangeRef={(v) => onPatch({ api_key_secret_ref: v })}
              placeholder={scope === 'platform' ? '粘贴平台 ZAP runtime 访问凭证' : '粘贴外部智能体访问凭证'}
              error={fieldErrors.api_key_secret_ref}
            />
            <div className="md:col-span-2">
              <Field
                label="外部环境标识"
                help="由 ZAP 接入方提供，用于在对方系统识别当前托管运行环境。创建实例和会话时原样传递，请勿填写密钥或个人敏感信息。"
                value={cfg.external_environment_id || ''}
                onChange={(v) => onPatch({ external_environment_id: v })}
                placeholder="例如：chuangye-prod"
                mono
                maxLength={256}
                error={fieldErrors.external_environment_id}
              />
            </div>
          </Grid2>
        </Section>
      )}

      {hostingKind === 'clawmanager' && (
        <Section title="工作负载服务" desc="负责创建运行实例 Pod 并查询其位置（命名空间 / Deployment / Pod IP）；不负责写入文件。">
          <Grid2>
            <Field label="服务地址" value={cfg.workload_api_base_url} onChange={(v) => onPatch({ workload_api_base_url: v })} placeholder="https://runtime.example.com/api/v1" error={fieldErrors.workload_api_base_url} />
            <SecretValueField
              label="访问凭证"
              hint="直接填写工作负载服务的长期凭证；系统会自动保存为内部凭证。"
              valueRef={cfg.workload_api_token_secret_ref}
              onChangeRef={(v) => onPatch({ workload_api_token_secret_ref: v })}
              placeholder="粘贴服务访问凭证"
              error={fieldErrors.workload_api_token_secret_ref}
            />
          </Grid2>
        </Section>
      )}

      {hostingKind === 'clawmanager' && requiresK8sWriteChannel(framework) && (
        <Section
          title="Kubernetes 写入通道"
          desc="工作负载服务只创建/定位 Pod；数字员工与技能文件通过 Kubernetes API 写入目标 Pod，必须额外配置集群 API 与令牌。令牌需具备目标命名空间下 pods 的 list/get、pods/exec 的 create、deployments 的 get 权限。"
        >
          <Grid2>
            <Field label="API Server 地址" value={cfg.k8s_api_server_url} onChange={(v) => onPatch({ k8s_api_server_url: v })} placeholder="https://kubernetes.example.com:6443" mono error={fieldErrors.k8s_api_server_url} />
            <SecretValueField
              label="访问令牌"
              hint="直接填写具备最小权限的 Kubernetes ServiceAccount token；系统会自动保存为内部凭证。"
              valueRef={cfg.k8s_token_secret_ref}
              onChangeRef={(v) => onPatch({ k8s_token_secret_ref: v })}
              placeholder="粘贴 Kubernetes API token"
              error={fieldErrors.k8s_token_secret_ref}
            />
          </Grid2>
          <div className="mt-2 flex items-center gap-1.5 text-[12px]">
            <input id="hf-workload-k8s-insecure" type="checkbox" checked={cfg.k8s_insecure_skip_verify}
              onChange={(e) => onPatch({ k8s_insecure_skip_verify: e.target.checked })} />
            <label htmlFor="hf-workload-k8s-insecure" className="text-rose-700">
              跳过 TLS 校验（仅测试环境）
            </label>
          </div>
        </Section>
      )}

      {hostingKind === 'k8s_native' && (
        <Section title="Kubernetes 集群" desc="生产环境必须保持 TLS 校验；仅测试环境可临时跳过。">
          <Grid2>
            <Field label="API Server 地址" value={cfg.k8s_api_server_url} onChange={(v) => onPatch({ k8s_api_server_url: v })} placeholder="https://kubernetes.example.com:6443" mono error={fieldErrors.k8s_api_server_url} />
            <SecretValueField
              label="访问令牌"
              hint="直接填写具备最小权限的 Kubernetes ServiceAccount token；系统会自动保存为内部凭证。"
              valueRef={cfg.k8s_token_secret_ref}
              onChangeRef={(v) => onPatch({ k8s_token_secret_ref: v })}
              placeholder="粘贴 Kubernetes API token"
              error={fieldErrors.k8s_token_secret_ref}
            />
          </Grid2>
          <div className="mt-2 flex items-center gap-1.5 text-[12px]">
            <input id="hf-k8s-insecure" type="checkbox" checked={cfg.k8s_insecure_skip_verify}
              onChange={(e) => onPatch({ k8s_insecure_skip_verify: e.target.checked })} />
            <label htmlFor="hf-k8s-insecure" className="text-rose-700">
              跳过 TLS 校验（仅测试环境）
            </label>
          </div>
          <K8sOpsCredentialTabs
            mode={k8sOpsMode}
            onModeChange={changeK8sOpsMode}
            kubeconfigRef={cfg.k8s_ops_kubeconfig_secret_ref}
            onChangeKubeconfigRef={(v) => onPatch({ k8s_ops_kubeconfig_secret_ref: v })}
          />
        </Section>
      )}

      {/* ADR-0025 §2.5: external_endpoint 不渲染部署 / 资源 / 运行时参数. */}
      {!isExternal && (
        <Section title="工作负载默认参数">
          <Grid2>
            <Field label="镜像仓库" value={cfg.image_repository} onChange={(v) => onPatch({ image_repository: v })} placeholder={framework === 'openclaw' ? 'registry.example.com/openclaw' : 'registry.example.com/runtime'} mono error={fieldErrors.image_repository} />
            <Field label="镜像版本" value={cfg.image_tag} onChange={(v) => onPatch({ image_tag: v })} placeholder="latest" mono error={fieldErrors.image_tag} />
            <Field label="命名空间" value={cfg.k8s_namespace} onChange={(v) => onPatch({ k8s_namespace: v })} mono error={fieldErrors.k8s_namespace} />
            <NumberField label="网关端口" value={cfg.gateway_port} onChange={(v) => onPatch({ gateway_port: v })} />
            <Field label="挂载路径" value={cfg.mount_path} onChange={(v) => onPatch({ mount_path: v })} mono error={fieldErrors.mount_path} />
            <Field label="存储类型" value={cfg.storage_class} onChange={(v) => onPatch({ storage_class: v })} placeholder="可空" mono />
            <Field label="数据卷名称" value={cfg.pvc_name} onChange={(v) => onPatch({ pvc_name: v })} placeholder="可空" mono />
            <NumberField label="默认 CPU" value={cfg.default_cpu_cores} onChange={(v) => onPatch({ default_cpu_cores: v })} />
            <NumberField label="默认内存" value={cfg.default_memory_gb} onChange={(v) => onPatch({ default_memory_gb: v })} />
            <NumberField label="默认磁盘" value={cfg.default_disk_gb} onChange={(v) => onPatch({ default_disk_gb: v })} />
          </Grid2>
        </Section>
      )}

      {!isExternal && (
        <Section title="运行时参数" desc="留空 = 使用平台默认。LLM 网关与 backchannel 由后端 bus.yaml 全局管理，不在此处配置。">
          <Grid2>
            <Field
              label="默认模型"
              help="覆盖平台默认；留空则使用 bus.yaml 中的 aigc.default_model。"
              value={cfg.llm_default_model || ''}
              onChange={(v) => onPatch({ llm_default_model: v })}
              placeholder="例如 qwen3.5-max-coder（留空 = 平台默认）"
              mono
            />
            <Field
              label="HTTP 代理"
              help="留空 = pod 直连。"
              value={cfg.http_proxy || ''}
              onChange={(v) => onPatch({ http_proxy: v })}
              placeholder="http://proxy.example:7890"
              mono
            />
            <Field
              label="HTTPS 代理"
              value={cfg.https_proxy || ''}
              onChange={(v) => onPatch({ https_proxy: v })}
              placeholder="http://proxy.example:7890"
              mono
            />
            <div>
              <HelpLabel label="no_proxy 白名单" hint="一行一条或逗号分隔；如 127.0.0.1、.example.com、127.0.0.0/8。" />
              <textarea
                rows={3}
                value={cfg.no_proxy || ''}
                onChange={(e) => onPatch({ no_proxy: e.target.value })}
                placeholder="127.0.0.1&#10;localhost&#10;.example.com"
                className="w-full px-3 py-2 text-[12px] font-mono rounded-md ring-1 ring-[var(--color-line)] focus:ring-[var(--color-text)] bg-white"
              />
            </div>
          </Grid2>
        </Section>
      )}

      {/* control-plane 接口能力: 内置 runtime 系统推导; 外部 ZAP 以 runtime_card 探测结果为准, 不做人为开关。 */}
      <CapabilitySection framework={framework} caps={caps} probe={probe} />
    </div>
  )
}
