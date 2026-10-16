// backchannel.go — Batch 2C T2C.1.F: 预留接口, 让 Runtime 创建 / 启动 OpenClaw 容器时
// 能注入 ai-office-webhook 插件回推 Bus 所需的 URL + Bearer。
//
// **本批 2C 不实现接收路由** (`/api/agent-bus/v1/zap/backchannel/*`)。
// 仅提供配置载体 + env 读取, 供 T2C.1.A LocalRegistryResolver / 后续 K8s
// CreateWorkload 把这两个值灌进容器 env (与 legacy entrypoint.sh
// `AI_OFFICE_WEBHOOK_URL` / `AI_OFFICE_WEBHOOK_SECRET` 对齐)。
//
// M6 / M9 真正接 cron 回推 + fs.watch jobs.json 推送时, 不需要改本文件 ——
// 仅在 transport 层补 `/zap/backchannel/*` 路由 + 复用同一组 secret 校验。
package openclaw

// BackchannelConfig 是 OpenClaw 容器内 plugin (legacy: ai-office-webhook)
// 回推 Bus 所需的连接信息。
type BackchannelConfig struct {
	// URL Bus 接收 backchannel 请求的入口, 如 "http://host.docker.internal:8082/api/agent-bus/v1/zap/backchannel"
	URL string
	// Secret 共享密钥, 容器内 plugin POST 时带 "Authorization: Bearer <Secret>"
	// Bus 接收路由按此校验。**本批不实现接收路由**, 但容器 env 注入必须含此值,
	// 否则 M6 上线时改 entrypoint 会比直接复用麻烦。
	Secret string
}

// IsZero 当 URL 与 Secret 均空时返回 true。
func (b BackchannelConfig) IsZero() bool { return b.URL == "" && b.Secret == "" }

// EnvKey 容器内 plugin 读的 env 名 (与 legacy openclaw-deploy/entrypoint.sh 对齐)。
const (
	EnvBackchannelURL    = "AI_OFFICE_WEBHOOK_URL"
	EnvBackchannelSecret = "AI_OFFICE_WEBHOOK_SECRET"
)

// AsContainerEnv 把 BackchannelConfig 渲染成容器 env map (key 用 legacy 名)。
// 空 URL/Secret 跳过对应 key。
func (b BackchannelConfig) AsContainerEnv() map[string]string {
	out := map[string]string{}
	if b.URL != "" {
		out[EnvBackchannelURL] = b.URL
	}
	if b.Secret != "" {
		out[EnvBackchannelSecret] = b.Secret
	}
	return out
}
