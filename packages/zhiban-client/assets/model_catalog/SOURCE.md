# 数据来源

`providers.json` / `models.json` 主体派生自 [CherryHQ/cherry-studio](https://github.com/CherryHQ/cherry-studio)
（AGPL-3.0）的 `packages/provider-registry/data/{providers,models,provider-models}.json`，
拉取于 2026-08-24，仅保留厂商 id/名称/endpoint 类型/baseUrl 和模型 id/名称/能力标签，
不含原始的定价（pricing）字段。

`beebridge` 是 2026-09-03 追加的知办默认预设，端点与模型发现口径来自
[BeeBridge API 文档](https://docs.beeaicloud.com/zh/docs/api) 和项目收到的
《Codex 与 Claude Code 接入蜂桥 AI 配置手册》v1.1。只预置官方 base URL 与
OpenAI-compatible 协议元数据，不复制示例模型，也不包含任何 API Key。

`../icons/providers/*.svg` 派生自同仓库 `packages/ui/src/components/icons/providers/{key}/light.tsx`
（React 组件源码，转成静态 SVG），厂商 id → icon key 的映射严格照抄
`packages/ui/src/components/icons/registry.ts` 里的 `PROVIDER_ID_ALIASES`
（别名优先于同名目录，例如 `dashscope` 必须映射到 `bailian` 而不是它自己
同名的 `dashscope` 目录）。`mimo`（Xiaomi MiMo）在 providers 目录下没有专属
图标，实际用的是 `packages/ui/src/components/icons/models/mimo/light.tsx`
——Cherry Studio 的 `resolveProviderIconRef` 本身就有 `providerRef(key) ??
modelRef(key)` 这层回退（厂商没有专属图标时，找同名的模型图标顶上），我们
这里手动照抄了这一条回退结果，不是通用机制。BeeBridge 图标来自其官方文档站
[`/assets/logo.svg`](https://docs.beeaicloud.com/assets/logo.svg)。当前 62/62 个
Provider 全部有图标。

注：早期版本误用了 `packages/ui/icons/providers/light/*.svg`（旧的静态快照，
156 个文件，部分缺失/命名对不上，如 `radeon-cloud`/`opencode`/`tencent-cloud-ti`
完全没有）；已改用上面的权威来源重新生成整批图标。

这份内容的授权状态未经法务复核，接入时是产品方明确知情并承担风险的决定，
不代表默认可以对其他项目重复这个做法。后续如需分发/开源本仓库，需要在此之前
单独评估这批数据/图标的授权方式。
