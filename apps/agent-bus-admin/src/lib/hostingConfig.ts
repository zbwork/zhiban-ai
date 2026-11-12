// hostingConfig.ts: 平台 / 租户「智能体托管环境」共享的 HostingConfig helpers。
//
// 之所以单独成文件 (而不是写在 RuntimeHosting.tsx 里 export 出来) 是为了满足
// react-refresh/only-export-components — 该规则要求 .tsx 文件里只 export 组件。
//
// 来源: 原本住在 apps/agent-bus-admin/src/pages/RuntimeHosting.tsx; ADR-0022 v0.4
// 起 TenantRuntimeEnvironments.tsx 也要复用 K8s/PaaS 表单, 抽公共到此处。
// ADR-0025: 加 external_endpoint (平台 ZAP 自建接入) 分支 + primary_endpoint 根地址 normalize。

import type { HostingConfig } from './api'

export type HostingKind = 'clawmanager' | 'k8s_native' | 'external_endpoint'
export type HostingFormScope = 'platform' | 'tenant'

export const EMPTY_CFG: HostingConfig = {
  runtime_environment_id: 0,
  hosting_kind: 'clawmanager',
  framework: '',
  scope: 'platform',
  open_to_tenants: false,
  primary_endpoint: '',
  api_key_secret_ref: '',
  external_environment_id: '',
  workload_api_base_url: '',
  workload_api_token_secret_ref: '',
  k8s_api_server_url: '',
  k8s_token_secret_ref: '',
  k8s_insecure_skip_verify: false,
  k8s_ops_kubeconfig_secret_ref: '',
  image_repository: '',
  image_tag: 'latest',
  k8s_namespace: 'aigc',
  gateway_port: 18789,
  mount_path: '/workspace',
  storage_class: '',
  pvc_name: '',
  default_cpu_cores: 2,
  default_memory_gb: 4,
  default_disk_gb: 10,
  workload_env: {},
  // ADR-0021: 运行时参数 (可空, 留空走 bus.yaml / 全局默认)
  llm_default_model: '',
  http_proxy: '',
  https_proxy: '',
  no_proxy: '',
  enabled: false,
}

export function hostingKindLabel(kind?: string) {
  if (kind === 'clawmanager') return '工作负载服务'
  if (kind === 'k8s_native') return 'Kubernetes 集群'
  if (kind === 'external_endpoint') return '外部服务接入'
  return kind || '托管服务'
}

function isHttpURL(value: string): boolean {
  try {
    const u = new URL(value)
    return u.protocol === 'http:' || u.protocol === 'https:'
  } catch {
    return false
  }
}

// OpenClaw / Hermes 的 clawmanager 只创建、定位 Pod；agent / skill 文件仍需经
// per-environment Kubernetes API 写入。与后端 runtimehosting.requiresK8sWriteChannel 保持一致。
export function requiresK8sWriteChannel(framework?: string): boolean {
  return framework === 'openclaw' || framework === 'hermes'
}

// isZapWire: framework 是否走 ZAP 协议 (external_endpoint / runtime_card probe / /zap/v1/*)。
// 目前包含 'zap' (第三方自建) 与 'dsh' (ADR-0035 知办通用运行时；平台内置但线上协议同 ZAP)。
// 需要以「外部 HTTP endpoint 语义」判断时用此 helper, 不要直接 `=== 'zap'`。
export function isZapWire(framework?: string): boolean {
  return framework === 'zap' || framework === 'dsh'
}

// normalizeRuntimeRootEndpoint: ADR-0025 / Phase A 用户要求统一 external_endpoint 的 primary_endpoint
// 语义为「runtime 根地址，不带 /zap/v1 后缀」。后端 probe 会自己拼 /zap/v1/runtime_card。
//
// 兼容：
//   - 历史/手填 `https://x.cmb.com/zap/v1`     → `https://x.cmb.com`
//   - 历史/手填 `https://x.cmb.com/zap/v1/`    → `https://x.cmb.com`
//   - 历史/手填 `https://x.cmb.com/zap/v1/foo` → 保留 (不动；保护多 runtime 同 host 路径前缀场景)
//   - 末尾 `/` 一律去掉
//
// 仅在 hosting_kind=external_endpoint 调用；其它 hosting_kind 不动。
export function normalizeRuntimeRootEndpoint(raw: string): string {
  let v = (raw || '').trim().replace(/\s+/g, '')
  if (!v) return ''
  // 去末尾斜杠 (单层)
  v = v.replace(/\/+$/, '')
  // 仅当 path 严格等于 /zap/v1 时剥掉
  try {
    const u = new URL(v)
    const path = u.pathname.replace(/\/+$/, '')
    if (path === '/zap/v1') {
      u.pathname = ''
      // toString 会带回末尾 /, 二次 trim
      return u.toString().replace(/\/+$/, '')
    }
  } catch {
    // 非合法 URL 直接原样返回, 校验由 isHttpURL 兜底
  }
  return v
}

export function validateHostingConfig(cfg: HostingConfig): string {
  const missing = (label: string) => `请填写${label}。`
  const invalid = (label: string) => `请填写有效的${label}。`
  if (cfg.hosting_kind === 'external_endpoint') {
    // external_endpoint 仅展示服务地址 + 访问凭证 + framework；
    // 不渲染 image / k8s / 资源 / 运行时参数。
    const ep = (cfg.primary_endpoint || '').trim()
    if (!ep) return missing('服务地址')
    if (!isHttpURL(ep)) return invalid('服务地址')
    const ref = (cfg.api_key_secret_ref || '').trim()
    if (!ref) return missing('访问凭证')
    // 后台 UX 不暴露 secret-ref scheme; SecretValueField 会把用户填写内容包装为 value://。
    // 仍兼容历史 env:// 引用; vault:// 暂未接 resolver, 不在本期 UI 暴露。
    if (!/^(env|value):\/\//i.test(ref)) {
      return '请填写访问凭证。'
    }
    const externalID = (cfg.external_environment_id || '').trim()
    if (Array.from(externalID).length > 256) return '外部环境标识不能超过 256 个字符。'
    if (Array.from(externalID).some((char) => {
      const codePoint = char.codePointAt(0) || 0
      return codePoint < 32 || codePoint === 127
    })) return '外部环境标识必须是单行文本。'
    if (cfg.scope === 'platform') {
      if (!isZapWire(cfg.framework || 'zap')) {
        return '平台外部接入仅支持 ZAP 协议 / 知办通用运行时（dsh）。'
      }
    }
    return ''
  }
  if (cfg.hosting_kind === 'k8s_native') {
    if (!cfg.k8s_api_server_url.trim()) return missing('API Server 地址')
    if (!isHttpURL(cfg.k8s_api_server_url)) return invalid('API Server 地址')
    if (!cfg.k8s_token_secret_ref.trim()) return missing('访问令牌')
    if (!cfg.k8s_namespace.trim()) return missing('命名空间')
  } else {
    // clawmanager: workload API 创建/定位 Pod。
    if (!cfg.workload_api_base_url.trim()) return missing('服务地址')
    if (!isHttpURL(cfg.workload_api_base_url)) return invalid('服务地址')
    if (!cfg.workload_api_token_secret_ref.trim()) return missing('访问凭证')
    // doc-12 §11.8 + F02 §5.5.0: OpenClaw / Hermes + clawmanager 还必须配 Kubernetes
    // 写入通道（工作负载服务只定位 Pod，数字员工/技能文件经 K8S API 写入）。
    if (requiresK8sWriteChannel(cfg.framework)) {
      if (!cfg.k8s_api_server_url.trim()) return missing('Kubernetes 写入通道 API Server 地址')
      if (!isHttpURL(cfg.k8s_api_server_url)) return invalid('Kubernetes 写入通道 API Server 地址')
      if (!cfg.k8s_token_secret_ref.trim()) return missing('Kubernetes 写入通道访问令牌')
    }
  }
  if (!cfg.image_repository.trim()) return missing('镜像仓库')
  if (!cfg.image_tag.trim()) return missing('镜像版本')
  if (!cfg.mount_path.trim()) return missing('挂载路径')
  if (!cfg.mount_path.startsWith('/')) return '挂载路径必须以 / 开头。'
  if (!Number.isFinite(cfg.gateway_port) || cfg.gateway_port < 1 || cfg.gateway_port > 65535) return '网关端口必须在 1-65535 之间。'
  if (!Number.isFinite(cfg.default_cpu_cores) || cfg.default_cpu_cores < 1) return '默认 CPU 必须大于 0。'
  if (!Number.isFinite(cfg.default_memory_gb) || cfg.default_memory_gb < 1) return '默认内存必须大于 0。'
  if (!Number.isFinite(cfg.default_disk_gb) || cfg.default_disk_gb < 1) return '默认磁盘必须大于 0。'
  return ''
}

export type HostingConfigFieldErrorKey =
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
  | 'mount_path'

export type HostingConfigFieldErrors = Partial<Record<HostingConfigFieldErrorKey, string>>

export function fieldErrorsForHostingConfigValidation(
  cfg: HostingConfig,
  message: string
): HostingConfigFieldErrors {
  const msg = message.trim()
  if (!msg) return {}

  if (cfg.hosting_kind === 'external_endpoint') {
    if (msg.includes('服务地址')) return { primary_endpoint: msg }
    if (msg.includes('访问凭证')) return { api_key_secret_ref: msg }
    if (msg.includes('外部环境标识')) return { external_environment_id: msg }
    return {}
  }

  if (cfg.hosting_kind === 'k8s_native') {
    if (msg.includes('API Server 地址')) return { k8s_api_server_url: msg }
    if (msg.includes('访问令牌')) return { k8s_token_secret_ref: msg }
    if (msg.includes('命名空间')) return { k8s_namespace: msg }
    if (msg.includes('镜像仓库')) return { image_repository: msg }
    if (msg.includes('镜像版本')) return { image_tag: msg }
    if (msg.includes('挂载路径')) return { mount_path: msg }
    return {}
  }

  if (msg.includes('Kubernetes 写入通道 API Server 地址')) {
    return { k8s_api_server_url: msg }
  }
  if (msg.includes('Kubernetes 写入通道访问令牌')) {
    return { k8s_token_secret_ref: msg }
  }
  if (msg.includes('服务地址')) return { workload_api_base_url: msg }
  if (msg.includes('访问凭证')) return { workload_api_token_secret_ref: msg }
  if (msg.includes('镜像仓库')) return { image_repository: msg }
  if (msg.includes('镜像版本')) return { image_tag: msg }
  if (msg.includes('命名空间')) return { k8s_namespace: msg }
  if (msg.includes('挂载路径')) return { mount_path: msg }
  return {}
}

export function cfgWithKindDefaults(cfg: HostingConfig, hostingKind: HostingKind, framework: string): HostingConfig {
  if (hostingKind === 'external_endpoint') {
    // ADR-0025: 只保留 primary_endpoint / api_key_secret_ref / framework / open_to_tenants / enabled / scope;
    // 其它 K8s/PaaS 字段一律清回 EMPTY_CFG 默认 (避免 stale 数据被一起写库)。
    return {
      ...EMPTY_CFG,
      runtime_environment_id: cfg.runtime_environment_id,
      hosting_kind: 'external_endpoint',
      framework: framework || cfg.framework || 'zap',
      scope: cfg.scope,
      open_to_tenants: cfg.open_to_tenants,
      enabled: cfg.enabled,
      primary_endpoint: normalizeRuntimeRootEndpoint(cfg.primary_endpoint || ''),
      api_key_secret_ref: cfg.api_key_secret_ref || '',
      external_environment_id: cfg.external_environment_id || '',
      last_probed_at: cfg.last_probed_at,
      last_probe_status: cfg.last_probe_status,
      last_probe_message: cfg.last_probe_message,
      last_probe_latency_ms: cfg.last_probe_latency_ms,
      multi_tenant_isolation: cfg.multi_tenant_isolation,
    }
  }
  const isOpenClaw = framework === 'openclaw'
  const isHermes = framework === 'hermes'
  return {
    ...EMPTY_CFG,
    ...cfg,
    hosting_kind: hostingKind,
    workload_api_base_url: hostingKind === 'clawmanager' ? (cfg.workload_api_base_url || '') : '',
    workload_api_token_secret_ref: hostingKind === 'clawmanager' ? cfg.workload_api_token_secret_ref : '',
    // doc-12 §11.8 + F02 §5.5.0: K8S 写入通道字段对 k8s_native 与 clawmanager 都保留
    // (clawmanager + OpenClaw/Hermes 需用 K8S API 写 agent/skill 文件)；仅 k8s_native 给默认
    // API Server 占位。切到 external_endpoint 才清空（上面分支）。
    k8s_api_server_url:
      hostingKind === 'k8s_native'
        ? (cfg.k8s_api_server_url || '')
        : hostingKind === 'clawmanager'
          ? cfg.k8s_api_server_url
          : '',
    k8s_token_secret_ref:
      hostingKind === 'k8s_native' || hostingKind === 'clawmanager' ? cfg.k8s_token_secret_ref : '',
    image_repository: cfg.image_repository || (isOpenClaw ? '' : isHermes ? '' : ''),
    mount_path: cfg.mount_path || (isHermes ? '/opt/data' : '/workspace'),
    gateway_port: cfg.gateway_port || 18789,
  }
}
