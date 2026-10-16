// Package agenttrigger 持久化 IM group webhook 触发 Agent 的去重 + 审计日志。
//
// 幂等键 (migration 000028 起): UNIQUE(tenant_id, room_id, substrate, openim_client_msg_id)。
// openim_client_msg_id 是历史列名;当前 WuKong 路径写 webhook message_id。
package agenttrigger

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

// Decision 枚举。
const (
	DecisionTriggered = "triggered"
	DecisionSkipped   = "skipped"
	DecisionRejected  = "rejected"
)

// SubstrateOpenIM / SubstrateWuKong · IM 底座枚举 (agent_trigger_log.substrate)。
// OpenIM 仅用于历史行兼容;当前 runtime 默认使用 WuKong。
const (
	SubstrateOpenIM = "openim"
	SubstrateWuKong = "wukong"
)

// Entry · 一行 agent_trigger_log。
type Entry struct {
	ID       int64
	UUID     string
	TenantID int64
	RoomID   int64
	// Substrate IM 底座;空 → 默认 wukong。
	Substrate       string
	SenderAccountID *int64
	AgentID         *int64
	IMMessageID     string // 对应历史列 openim_client_msg_id;当前 WuKong 路径写 webhook message_id
	Decision        string
	RejectReason    string
	AgentRunID      *int64
}

// ErrDuplicate 表示同 (tenant, room, substrate, clientMsgID) 已被记录；调用方视为幂等命中并 audit dedup。
var ErrDuplicate = errors.New("agenttrigger: duplicate (tenant, room, substrate, client_msg_id)")

// defaultSubstrate 空值兼容为 wukong。
func defaultSubstrate(s string) string {
	if s == "" {
		return SubstrateWuKong
	}
	return s
}

// Insert 尝试落一条日志。UNIQUE 冲突时返 ErrDuplicate。
func (r *Repo) Insert(ctx context.Context, e Entry) (*Entry, error) {
	substrate := defaultSubstrate(e.Substrate)
	const q = `INSERT INTO agent_trigger_log (tenant_id, room_id, substrate, sender_account_id, agent_id, openim_client_msg_id, decision, reject_reason, agent_run_id)
	    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
	    RETURNING id, uuid, tenant_id, room_id, substrate, sender_account_id, agent_id, openim_client_msg_id, decision, COALESCE(reject_reason,''), agent_run_id`
	row := r.pool.QueryRow(ctx, q,
		e.TenantID, e.RoomID, substrate, e.SenderAccountID, e.AgentID,
		e.IMMessageID, e.Decision, nullable(e.RejectReason), e.AgentRunID,
	)
	out, err := scan(row)
	if err == nil {
		return out, nil
	}
	if isUniqueViolation(err) {
		return nil, ErrDuplicate
	}
	return nil, fmt.Errorf("agenttrigger.Insert: %w", err)
}

// LookupByDedup · webhook 重放检查 + audit 反查。substrate 空值兼容为 wukong;
// 与 (tenant, room, substrate, client_msg_id) 精确匹配。
func (r *Repo) LookupByDedup(ctx context.Context, tenantID, roomID int64, substrate, clientMsgID string) (*Entry, error) {
	substrate = defaultSubstrate(substrate)
	const q = `SELECT id, uuid, tenant_id, room_id, substrate, sender_account_id, agent_id, openim_client_msg_id, decision, COALESCE(reject_reason,''), agent_run_id
	    FROM agent_trigger_log WHERE tenant_id=$1 AND room_id=$2 AND substrate=$3 AND openim_client_msg_id=$4 LIMIT 1`
	row := r.pool.QueryRow(ctx, q, tenantID, roomID, substrate, clientMsgID)
	return scan(row)
}

func scan(row pgx.Row) (*Entry, error) {
	var e Entry
	var senderAcc, agentID, agentRunID *int64
	var reject string
	if err := row.Scan(&e.ID, &e.UUID, &e.TenantID, &e.RoomID, &e.Substrate, &senderAcc, &agentID, &e.IMMessageID, &e.Decision, &reject, &agentRunID); err != nil {
		return nil, err
	}
	e.SenderAccountID = senderAcc
	e.AgentID = agentID
	e.RejectReason = reject
	e.AgentRunID = agentRunID
	return &e, nil
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// isUniqueViolation 检测 UNIQUE 约束冲突。
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	type sqlStater interface{ SQLState() string }
	var s sqlStater
	if errors.As(err, &s) {
		return s.SQLState() == "23505"
	}
	return false
}

// ErrNotFound 反映 pgx.ErrNoRows。
var ErrNotFound = pgx.ErrNoRows
