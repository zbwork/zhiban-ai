// StorageConfigForm — 平台 storage-default / 租户 storage-override 共用的字段集合.
//
// 暴露字段: kind (仅 platform) / name (仅 platform) / region / endpoint / read_endpoint /
//          bucket / access_key_secret_ref / secret_key_secret_ref。
// 仅平台 create/edit 才校验必填 (name/kind/bucket); 租户 override 全字段可空 (空=继承平台默认).
//
// 2026-05-26 已砍 UI: prefix_tpl / lifecycle_rules / force_path_style 不再在前端暴露:
//   - prefix_tpl       : 后端 upload.go::buildFinalKey 硬编码, 没读这个字段 → UI 暴露纯属误导
//   - lifecycle_rules  : 后端没调 PutBucketLifecycle, JSON 只存 DB 不推 S3 → 同上
//   - force_path_style : 真有用 (传给 S3 SDK), 但 admin 90% 用不到; 留 schema 在 DB, 由后端 / 直接 SQL
//                        改; 新建行如果是 MinIO 类型, 后端可后续加 auto-set
// 后端 DB schema 未动 (这三列仍存在), PATCH 只发送 UI 出现的字段, 现有行的 path_style 保留。
//
// === 密钥 UX (2026-05-26 简化; 2026-05-31 修正) ===
// admin web 不暴露内部凭证引用协议，用户视野就是"填 Access Key / Secret Key"。
// 直填凭证保存时由 SecretValueField 包装成内部 value ref；历史引用不在 UI 展示内部格式。

import { FormField, Input, Select } from '../../../components/ui'
import { KeyRound, Settings2 } from 'lucide-react'
import { SecretValueField } from '../../../components/form/SecretValueField'

export type StorageFormValue = {
  kind?: 'oss' | 's3' | 'minio'
  name?: string
  region?: string
  endpoint?: string
  read_endpoint?: string
  bucket?: string
  access_key_secret_ref?: string
  secret_key_secret_ref?: string
}

export type StorageFormMode = 'platform' | 'tenant-override'

// 卡片容器: 给"基本/连接/密钥" 3 段用, 视觉上能清晰分组。
function SectionCard({
  icon,
  title,
  description,
  children,
}: {
  icon?: React.ReactNode
  title: string
  description?: string
  children: React.ReactNode
}) {
  return (
    <section className="rounded-lg border border-[var(--color-line)] bg-white p-5 shadow-[0_1px_2px_rgba(15,23,42,0.04)]">
      <header className="mb-4 flex items-start gap-3">
        {icon && (
          <div className="grid h-8 w-8 shrink-0 place-items-center rounded-md bg-[var(--color-line-soft)] text-[var(--color-text-sub)] ring-1 ring-[var(--color-line)]">
            {icon}
          </div>
        )}
        <div className="min-w-0">
          <div className="text-[14px] font-semibold text-[var(--color-text)]">{title}</div>
          {description && (
            <p className="mt-1 text-[12px] leading-relaxed text-[var(--color-text-sub)]">{description}</p>
          )}
        </div>
      </header>
      <div className="space-y-3">{children}</div>
    </section>
  )
}

export function StorageConfigForm({
  mode,
  value,
  onChange,
}: {
  mode: StorageFormMode
  value: StorageFormValue
  onChange: (v: StorageFormValue) => void
}) {
  const set = (patch: Partial<StorageFormValue>) => onChange({ ...value, ...patch })
  const isPlatform = mode === 'platform'
  const inheritHint = mode === 'tenant-override' ? '留空时继承平台默认' : undefined

  return (
    <div className="space-y-5">
      {isPlatform && (
        <SectionCard icon={<Settings2 size={16} />} title="基本信息">
          <FormField label="存储类型">
            <Select
              value={value.kind || 'oss'}
              onChange={(e) => set({ kind: e.target.value as StorageFormValue['kind'] })}
            >
              <option value="oss">阿里云 OSS</option>
              <option value="s3">AWS S3 / 自建 S3 兼容</option>
              <option value="minio">MinIO</option>
            </Select>
          </FormField>
          <FormField label="名称" hint="平台默认列表展示用, 例 oss-prod-hangzhou">
            <Input
              value={value.name || ''}
              onChange={(e) => set({ name: e.target.value })}
              placeholder="oss-prod-hangzhou"
            />
          </FormField>
        </SectionCard>
      )}

      <SectionCard
        title="连接信息"
        description={mode === 'tenant-override' ? '只填写本租户要覆盖的字段, 其它继承平台默认' : undefined}
      >
        <FormField label="区域" hint={inheritHint || '例 cn-hangzhou / us-east-1; 自建 S3 可填 default'}>
          <Input
            value={value.region || ''}
            onChange={(e) => set({ region: e.target.value })}
            placeholder="cn-hangzhou"
          />
        </FormField>
        <FormField label="写入地址" hint={inheritHint || '服务端 PutObject 走的 endpoint (通常是内网)'}>
          <Input
            value={value.endpoint || ''}
            onChange={(e) => set({ endpoint: e.target.value })}
            placeholder="https://oss-cn-hangzhou.aliyuncs.com"
          />
        </FormField>
        <FormField label="读取地址" hint={inheritHint || '客户端预签名 URL 走的 endpoint (通常是公网); 留空时与写入地址相同'}>
          <Input
            value={value.read_endpoint || ''}
            onChange={(e) => set({ read_endpoint: e.target.value })}
            placeholder="留空 = 与写入地址相同"
          />
        </FormField>
        <FormField label="存储桶" hint={inheritHint}>
          <Input
            value={value.bucket || ''}
            onChange={(e) => set({ bucket: e.target.value })}
            placeholder="zhiban-drive"
          />
        </FormField>
      </SectionCard>

      <SectionCard
        icon={<KeyRound size={16} />}
        title="密钥"
        description="访问存储桶的 Access Key / Secret Key。密钥会保存到平台数据库, 请确保数据库备份/快照妥善加密。"
      >
        <SecretValueField
          label="Access Key"
          valueRef={value.access_key_secret_ref}
          onChangeRef={(ref) => set({ access_key_secret_ref: ref })}
          placeholder="LTAI5tXXXXXXXXXXX"
          hint={inheritHint}
        />
        <SecretValueField
          label="Secret Key"
          valueRef={value.secret_key_secret_ref}
          onChangeRef={(ref) => set({ secret_key_secret_ref: ref })}
          placeholder="••••••••"
          hint={inheritHint}
        />
      </SectionCard>
    </div>
  )
}
