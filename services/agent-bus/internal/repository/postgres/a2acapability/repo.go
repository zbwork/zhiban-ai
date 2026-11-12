// Package a2acapability 实现 svc/a2a.CapabilityRepo 接口.
//
// 仅一个查询: HasA2AInvokeCapability(agentID) — 看 agent_capability_bindings 表里
// 该 Agent 是否有 a2a_invoke **哨兵行**.
//
// A2A v1b 语义拍板 (boundaries §3.4 / database-design §5.3): a2a_invoke 是**非版本化
// 运行时开关**, 唯一合法形态 = (agent_version_id IS NULL, capability_uuid=uuid_nil 哨兵,
// source='borrow')。本查询**只认哨兵行** —— versioned 行 (历史 PublishVersion 复制产生的
// 脏数据) 不算 enabled, 保证 Admin 关闭开关后不会被残留 versioned 行"复活"发起权限。
//
// migration 000001 squashed 000125 已把 'a2a_invoke' 加入 CHECK 取值合法集.
package a2acapability

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
)

// hasA2AInvokeSentinelSQL 只认哨兵行 (三条件齐: version NULL + uuid_nil + source='borrow',
// 与 boundaries §3.4 文档定义一致; 异常 source 的行不算 enabled)。
// 提为常量供单测断言谓词 (仓库无 live-DB 测试基建)。
const hasA2AInvokeSentinelSQL = `
	SELECT EXISTS(
		SELECT 1 FROM agent_capability_bindings
		WHERE digital_employee_id = $1
		  AND capability_kind = 'a2a_invoke'
		  AND agent_version_id IS NULL
		  AND capability_uuid = $2::uuid
		  AND source = 'borrow'
	)`

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

// HasA2AInvokeCapability 判断指定 Agent 是否启用 a2a_invoke 运行时开关 (哨兵行存在)。
func (r *Repo) HasA2AInvokeCapability(ctx context.Context, agentID int64) (bool, error) {
	var exists bool
	err := r.pool.QueryRow(ctx, hasA2AInvokeSentinelSQL, agentID, domagent.A2AInvokeSentinelUUID).Scan(&exists)
	return exists, err
}
