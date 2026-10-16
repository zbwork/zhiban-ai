// repo_notify.go — F03 v0.9.1 跨进程事件 PG NOTIFY 发射器。
//
// 详见 docs/features/F03-skills.md §2.5 / §4.6。复用同一 `config_change` 通道，与
// composer / contacts policy / emp block 共用 listener pool。payload 形如：
//
//	skills:<id>
//	agent_skill_bindings:<agent_id>
//	tenant_skill_preferences:<tenant_id>
//	tenant_skill_disables:<tenant_id>
//	user_agent_skill_overrides:<account_id>:<agent_id>
//	builtin_skill_keys:<id>
//
// 所有 payload 收 listener 端做无状态失效或转发；不携带详细内容（避免大 payload 阻塞 PG）。
package skill

import (
	"context"

	svccomposer "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/composer"
)

// NotifyConfigChange 复用 composer.ConfigChangeChannel；payload 由调用方拼好。
//
// 失败不阻塞主流程（仅日志）；调用方按业务需要选择 propagation 还是 swallow。
// 目前服务层选择 swallow — 写入已成功，缓存最坏 5min TTL 兜底。
func (r *Repo) NotifyConfigChange(ctx context.Context, payload string) error {
	_, err := r.pool.Exec(ctx, `SELECT pg_notify($1, $2)`,
		svccomposer.ConfigChangeChannel, payload)
	return err
}
