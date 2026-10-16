// F09 Phase C (PR12 / C1-03): room_direct_pairs_with_agent 反查方法.
//
// 给 C2C webhook handler 使用: 拿到 (sender_account_id, recv_agent_id) 后反查 room_id,
// 然后走与 group 类似的 AgentTrigger 链路.

package room

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// DirectWithAgentPair · 反查结果 (PR12 webhook 只用到 RoomID + UUID; 完整字段留扩展).
type DirectWithAgentPair struct {
	ID        int64
	UUID      string
	TenantID  int64
	RoomID    int64
	AccountID int64
	AgentID   int64
}

// LookupDirectWithAgentByAccountAgent · 按 (tenant, account, agent) 反查 active pair.
//   - 找到 → 返该 row;
//   - 没找到 → apperr.ErrNotFound;
//   - 其它错 → 透传.
//
// 用 partial UNIQUE 索引 uq_rdpwa_tenant_account_agent_active (000131 migration) 加速.
func (r *Repo) LookupDirectWithAgentByAccountAgent(ctx context.Context, tenantID, accountID, agentID int64) (*DirectWithAgentPair, error) {
	var p DirectWithAgentPair
	err := r.pool.QueryRow(ctx, `
		SELECT id, uuid::text, tenant_id, room_id, account_id, agent_id
		  FROM room_direct_pairs_with_agent
		 WHERE tenant_id=$1 AND account_id=$2 AND agent_id=$3 AND is_deleted=false`,
		tenantID, accountID, agentID,
	).Scan(&p.ID, &p.UUID, &p.TenantID, &p.RoomID, &p.AccountID, &p.AgentID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return &p, nil
}
