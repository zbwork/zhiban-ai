import { PageHeader } from '../components/ui'

export function Placeholder({ title, subtitle }: { title: string; subtitle?: string }) {
  return (
    <div>
      <PageHeader
        title={title}
        subtitle={subtitle || '该模块仍在开发中。菜单与权限已按目标 IA 就绪，业务页面后续增量补齐。'}
      />
      <div className="mt-2 bg-white rounded-lg card-shadow p-6 text-sm text-[var(--color-text-sub)]">
        <h3 className="text-base mb-2 font-serif">功能开发中</h3>
        <p>本页面为目标信息架构的预留实现，确保左侧菜单完整且不会点出 404。</p>
      </div>
    </div>
  )
}
