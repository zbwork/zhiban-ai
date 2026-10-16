package conversation

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const baseCols = `id, uuid, tenant_id, account_id, digital_employee_id, room_id,
    COALESCE(title,''), COALESCE(source,''), last_message_at, unread_count, metadata, created_at, updated_at`

const conversationHumanDisplayNameSQL = `COALESCE(
	NULLIF(BTRIM(tm.nickname), ''),
	CASE
		WHEN NULLIF(BTRIM(a.display_name), '') IS NULL THEN ''
		WHEN BTRIM(a.display_name) LIKE '%的组织 管理员%' THEN ''
		WHEN BTRIM(a.display_name) LIKE '预热优化%' THEN ''
		ELSE NULLIF(BTRIM(a.display_name), '')
	END,
	''
)`

func scan(row pgx.Row) (*dom.Conversation, error) {
	var c dom.Conversation
	var meta []byte
	if err := row.Scan(&c.ID, &c.UUID, &c.TenantID, &c.AccountID, &c.DigitalEmployeeID, &c.RoomID,
		&c.Title, &c.Source, &c.LastMessageAt, &c.UnreadCount, &meta, &c.CreatedAt, &c.UpdatedAt); err != nil {
		return nil, err
	}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &c.Metadata)
	}
	return &c, nil
}

func (r *Repo) GetByID(ctx context.Context, id int64) (*dom.Conversation, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseCols+` FROM conversations WHERE id=$1 AND deleted_at IS NULL`, id)
	c, err := scan(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return c, nil
}

func (r *Repo) GetByUUID(ctx context.Context, uuid string) (*dom.Conversation, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+baseCols+` FROM conversations WHERE uuid=$1 AND deleted_at IS NULL`, uuid)
	c, err := scan(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return c, nil
}

func (r *Repo) AccessibleByAccount(ctx context.Context, tenantID, accountID int64, uuid string) (bool, error) {
	var ok bool
	err := r.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1
			  FROM conversations c
			 WHERE c.uuid=$1
			   AND c.tenant_id=$2
			   AND c.deleted_at IS NULL
			   AND (
			        (c.room_id IS NULL AND c.account_id=$3)
			        OR (
			          c.room_id IS NOT NULL
			          AND EXISTS (
			            SELECT 1
			              FROM room_participants rp
			             WHERE rp.room_id=c.room_id
			               AND rp.kind='human'
			               AND rp.account_id=$3
			               AND rp.left_at IS NULL
			          )
			        )
			   )
		)`, uuid, tenantID, accountID).Scan(&ok)
	if err != nil {
		return false, err
	}
	return ok, nil
}

func (r *Repo) Create(ctx context.Context, c *dom.Conversation) (*dom.Conversation, error) {
	meta, _ := json.Marshal(emptyMapIfNil(c.Metadata))
	row := r.pool.QueryRow(ctx, `
		INSERT INTO conversations (tenant_id, account_id, digital_employee_id, room_id, title, source, metadata)
		VALUES ($1,$2,$3,$4,NULLIF($5,''),NULLIF($6,''),$7::jsonb)
		RETURNING `+baseCols,
		c.TenantID, c.AccountID, c.DigitalEmployeeID, c.RoomID, c.Title, c.Source, string(meta))
	return scan(row)
}

func (r *Repo) UpdateTitle(ctx context.Context, id int64, title string) error {
	_, err := r.pool.Exec(ctx, `UPDATE conversations SET title=$1, updated_at=now() WHERE id=$2`, title, id)
	return err
}

func (r *Repo) BumpLastMessage(ctx context.Context, id int64, ts time.Time) error {
	_, err := r.pool.Exec(ctx, `UPDATE conversations SET last_message_at=$1, updated_at=now() WHERE id=$2`, ts, id)
	return err
}

// UpdateMetadataKeys (Plan 16 Phase 2 / ZAP chat MVP) — 合并 patch metadata JSONB。
//
// SQL 守卫: (tenant_id, account_id, id) 三键 + deleted_at IS NULL。命中 0 行不报错
// (调用方语义为 best-effort: token 失效后下一次 Send 会自动 EnsureSession 重新拿)。
//
// 注意: zhiban-app 当前数字员工单聊可走 agent-direct/WuKong 双通道, conversation
// 可能是 room-backed。这里不能再用 room_id IS NULL 拦截, 否则 ZAP HITL respond
// 拿不到 zap_session_id。
// 白名单 (禁止 session_token / runtime_api_key / authorization 等) 由 chat service
// 层包一层 wrapper 强制, 本 repo 信任入参。
func (r *Repo) UpdateMetadataKeys(ctx context.Context, tenantID, accountID, conversationID int64, keys map[string]any) error {
	if len(keys) == 0 {
		return nil
	}
	patch, err := json.Marshal(keys)
	if err != nil {
		return err
	}
	_, err = r.pool.Exec(ctx, `
		UPDATE conversations
		   SET metadata = COALESCE(metadata, '{}'::jsonb) || $4::jsonb,
		       updated_at = now()
		 WHERE id = $3
		   AND tenant_id = $1
		   AND account_id = $2
		   AND deleted_at IS NULL`,
		tenantID, accountID, conversationID, string(patch))
	return err
}

func (r *Repo) List(ctx context.Context, f dom.Filter) ([]dom.Conversation, int64, error) {
	limit := f.Limit
	if limit <= 0 || limit > 200 {
		limit = 20
	}
	var total int64
	if err := r.pool.QueryRow(ctx, `SELECT count(*) FROM conversations WHERE account_id=$1 AND tenant_id=$2 AND deleted_at IS NULL`, f.AccountID, f.TenantID).Scan(&total); err != nil {
		return nil, 0, err
	}
	rows, err := r.pool.Query(ctx, `
		SELECT `+baseCols+` FROM conversations
		WHERE account_id=$1 AND tenant_id=$2 AND deleted_at IS NULL
		ORDER BY COALESCE(last_message_at, created_at) DESC LIMIT $3 OFFSET $4`,
		f.AccountID, f.TenantID, limit, f.Offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []dom.Conversation
	for rows.Next() {
		c, err := scan(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, *c)
	}
	return out, total, rows.Err()
}

func (r *Repo) Delete(ctx context.Context, id int64) error {
	_, err := r.pool.Exec(ctx, `UPDATE conversations SET deleted_at=now() WHERE id=$1`, id)
	return err
}

// ListForAccount Batch 2E T2E.7B: 单聊 + active 群 conversations 混排。
//
// 用 LEFT JOIN rooms 拿 room.uuid/kind/title (单聊行 r 列为 NULL); WHERE 含两条 OR:
//
//	(a) account_id = $accountID AND room_id IS NULL  → 单聊由 caller 拥有
//	(b) room_id IS NOT NULL AND EXISTS rp_is_active_human  → 群里 caller 仍是 active 参与者
//
// rp_is_active_human 走 EXISTS + WHERE rp.kind='human' AND rp.account_id = caller AND rp.left_at IS NULL;
// active-only unique (uq_rp_room_human_active) 保证不会重复计数。
//
// Round-7 P2-2:
//   - LEFT JOIN conversation_account_state cas ON cas.account_id=$2 AND cas.conversation_uuid=c.uuid
//     一次拿全 hidden_at / last_read_message_uuid / unread_snapshot, 不再做 transport in-memory 合并.
//   - includeHidden=false → WHERE 追加 `cas.hidden_at IS NULL`; total 也按这个 WHERE count,
//     避免"分页后内存过滤导致第一页数量不足 / total 含 hidden".
//   - includeHidden=true  → 不过滤 hidden, 全量返 (含 hidden), 行 Hidden 字段照填.
func (r *Repo) ListForAccount(ctx context.Context, tenantID, accountID int64, limit, offset int, includeHidden bool) ([]dom.ListItem, int64, error) {
	// limit < 0 是「不分页/取全集」哨兵(transport 在 WuKong 可用时用它拿全量候选, 再按最终
	// last_message_at 全量排序后分页, 修「PG 旧时间的最新 WuKong 会话被分页挡在首页外」)。
	// total 由独立 count(*) 计算, 与是否分页无关; 现有调用 limit>=0, 行为不变。
	noLimit := limit < 0
	if !noLimit && (limit <= 0 || limit > 200) {
		limit = 20
	}
	baseWhere := `c.tenant_id=$1 AND c.deleted_at IS NULL AND (
		(c.account_id=$2 AND c.room_id IS NULL)
		OR (c.room_id IS NOT NULL AND EXISTS (
			SELECT 1 FROM room_participants rp
			 WHERE rp.room_id = c.room_id
			   AND rp.kind = 'human'
			   AND rp.account_id = $2
			   AND rp.left_at IS NULL))
	)`
	where := baseWhere
	// Old RTC entry points created room conversations for local employees. Keep
	// their history in storage, but do not let these unusable direct rooms replace
	// the employee's normal single conversation. Count and paging share the filter.
	where += ` AND NOT EXISTS (
		SELECT 1 FROM rooms lr
		JOIN room_participants lp ON lp.room_id=lr.id AND lp.kind='agent' AND lp.left_at IS NULL
		JOIN digital_employees le ON le.id=lp.agent_id AND le.tenant_id=c.tenant_id
		WHERE lr.id=c.room_id AND lr.tenant_id=c.tenant_id
		  AND lr.room_kind='direct' AND le.execution_locus='local'
	)`
	if !includeHidden {
		where += ` AND cas.hidden_at IS NULL`
	}
	const joinCAS = ` LEFT JOIN conversation_account_state cas
	                   ON cas.account_id = $2 AND cas.conversation_uuid = c.uuid `
	var total int64
	if err := r.pool.QueryRow(ctx,
		`SELECT count(*) FROM conversations c `+joinCAS+`WHERE `+where,
		tenantID, accountID).Scan(&total); err != nil {
		return nil, 0, err
	}
	// P2.1(ADR-0026):额外取 rooms.wukong_channel_id/type + room_participants 聚合 participants(json)。
	// participants/kind/title 一律以 room_participants 为真理(不读 room_direct_pairs)。
	listQuery := `
		SELECT c.id, c.uuid, c.tenant_id, c.account_id, c.digital_employee_id, c.room_id,
		       COALESCE(c.title,''), COALESCE(c.source,''), c.last_message_at, c.unread_count, c.metadata,
		       c.created_at, c.updated_at,
		       COALESCE(r.uuid::text, ''), COALESCE(r.room_kind, ''), COALESCE(r.title, ''),
		       COALESCE(r.room_kind = 'group' AND r.creator_id = $2, false) AS can_rename_group,
		       cas.hidden_at, cas.cleared_at, COALESCE(cas.last_read_message_uuid::text, ''), cas.last_read_at,
		       COALESCE(cas.unread_snapshot, 0),
		       cas.pinned_at, cas.muted_at, cas.marked_unread_at,
		       COALESCE(r.wukong_channel_id, ''), COALESCE(r.wukong_channel_type, 0),
		       COALESCE((
		         SELECT json_agg(json_build_object(
		                  'kind', rp.kind,
		                  'account_uuid', COALESCE(a.uuid::text, ''),
		                  'agent_uuid', COALESCE(de.uuid::text, ''),
		                  'display_name', CASE
		                    WHEN rp.kind = 'human' THEN ` + conversationHumanDisplayNameSQL + `
		                    ELSE COALESCE(de.name, '')
		                  END,
		                  'avatar', COALESCE(a.avatar_url, de.avatar_url, ''),
		                  'email', CASE WHEN rp.kind = 'human' THEN COALESCE(a.email, '') ELSE '' END,
		                  'company_name', COALESCE(NULLIF(t.display_name, ''), t.name, ''),
		                  -- 部门: 人按 tenant_memberships.department_id 解析, agent 按 digital_employees.workspace_id 解析。
		                  'department_name', COALESCE(hd.name, ad.name, ''))
		                ORDER BY rp.id)
		           FROM room_participants rp
		           LEFT JOIN tenants t ON t.id = c.tenant_id AND t.deleted_at IS NULL
		           LEFT JOIN accounts a ON a.id = rp.account_id
		           LEFT JOIN digital_employees de ON de.id = rp.agent_id
		           LEFT JOIN tenant_memberships tm ON tm.account_id = rp.account_id
		                  AND tm.tenant_id = c.tenant_id AND tm.deleted_at IS NULL
		           LEFT JOIN departments hd ON hd.id = tm.department_id AND hd.deleted_at IS NULL
		           LEFT JOIN departments ad ON ad.id = de.workspace_id AND ad.deleted_at IS NULL
		          WHERE rp.room_id = c.room_id AND rp.left_at IS NULL
		       ), '[]'::json)::text AS participants_json,
		       COALESCE((
		         SELECT CASE
		                  WHEN rp.kind = 'human' THEN ` + conversationHumanDisplayNameSQL + `
		                  ELSE COALESCE(de.name, '')
		                END
		           FROM room_participants rp
		           LEFT JOIN accounts a ON a.id = rp.account_id
		           LEFT JOIN digital_employees de ON de.id = rp.agent_id
		           LEFT JOIN tenant_memberships tm ON tm.account_id = rp.account_id
		                  AND tm.tenant_id = c.tenant_id AND tm.deleted_at IS NULL
		          WHERE rp.room_id = c.room_id AND rp.left_at IS NULL
		            AND (rp.account_id IS NULL OR rp.account_id <> $2)
		          ORDER BY rp.id LIMIT 1
		       ), '') AS peer_title,
		       COALESCE((
		         SELECT COALESCE(a.avatar_url, de.avatar_url, '')
		           FROM room_participants rp
		           LEFT JOIN accounts a ON a.id = rp.account_id
		           LEFT JOIN digital_employees de ON de.id = rp.agent_id
		          WHERE rp.room_id = c.room_id AND rp.left_at IS NULL
		            AND (rp.account_id IS NULL OR rp.account_id <> $2)
		          ORDER BY rp.id LIMIT 1
		       ), '') AS peer_avatar,
		       COALESCE(cde.uuid::text, '') AS single_agent_uuid,
		       COALESCE(cde.name, '') AS single_agent_name,
		       COALESCE(cde.avatar_url, '') AS single_agent_avatar,
		       COALESCE(cde.position_label, '') AS single_agent_position,
		       COALESCE(cdep.name, '') AS single_agent_department,
		       CASE
		         WHEN c.room_id IS NULL AND c.digital_employee_id IS NOT NULL THEN
		           COALESCE(cde.deleted_at IS NOT NULL OR cde.is_deleted, false)
		         WHEN r.room_kind = 'direct' THEN COALESCE((
		           SELECT de.deleted_at IS NOT NULL OR de.is_deleted
		             FROM room_participants rp
		             JOIN digital_employees de ON de.id = rp.agent_id
		            WHERE rp.room_id = c.room_id
		              AND rp.kind = 'agent'
		              AND rp.left_at IS NULL
		            ORDER BY rp.id
		            LIMIT 1
		         ), false)
		         ELSE false
		       END AS agent_deleted,
		       COALESCE(lm.text, '') AS local_last_message_text,
		       lm.created_at AS local_last_message_ts
		  FROM conversations c
		  ` + joinCAS + `
		  LEFT JOIN rooms r ON r.id = c.room_id AND r.deleted_at IS NULL
		  -- 历史单聊必须保留数字员工身份；可用性单独通过 agent_deleted/发送闸口表达。
		  LEFT JOIN digital_employees cde ON cde.id = c.digital_employee_id
		  LEFT JOIN departments cdep ON cdep.id = cde.workspace_id AND cdep.deleted_at IS NULL
		  LEFT JOIN LATERAL (
		         SELECT COALESCE(m.blocks->0->>'text', m.blocks->0->>'markdown', '') AS text,
		                m.created_at
		           FROM messages m
		          WHERE m.tenant_id = c.tenant_id
		            AND m.conversation_id = c.id
		            AND m.status IN ('final', 'failed', 'cancelled')
		            AND (cas.cleared_at IS NULL OR m.created_at > cas.cleared_at)
		            AND jsonb_typeof(m.blocks) = 'array'
		            AND jsonb_array_length(m.blocks) > 0
		            AND COALESCE(m.blocks->0->>'text', m.blocks->0->>'markdown', '') <> ''
		          ORDER BY m.created_at DESC
		          LIMIT 1
		  ) lm ON true
		 WHERE ` + where + `
		 -- F09 P2 「会话列表操作菜单 v2」排序: pinned 整体在前, 组内仍按
		 -- last_message_at 降序(契约权威), pinned_at 不参与组内排序.
		 ORDER BY (cas.pinned_at IS NOT NULL) DESC,
		          COALESCE(c.last_message_at, c.created_at) DESC`
	listArgs := []any{tenantID, accountID}
	if !noLimit {
		listQuery += ` LIMIT $3 OFFSET $4`
		listArgs = append(listArgs, limit, offset)
	}
	rows, err := r.pool.Query(ctx, listQuery, listArgs...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var out []dom.ListItem
	for rows.Next() {
		var item dom.ListItem
		var meta []byte
		var hiddenAt, clearedAt, pinnedAt, mutedAt, markedUnreadAt *time.Time
		var participantsJSON string
		var peerTitle string
		var peerAvatar string
		if err := rows.Scan(
			&item.ID, &item.UUID, &item.TenantID, &item.AccountID, &item.DigitalEmployeeID, &item.RoomID,
			&item.Title, &item.Source, &item.LastMessageAt, &item.UnreadCount, &meta,
			&item.CreatedAt, &item.UpdatedAt,
			&item.RoomUUID, &item.RoomKind, &item.RoomTitle, &item.CanRenameGroup,
			&hiddenAt, &clearedAt, &item.LastReadMessageUUID, &item.LastReadAt, &item.UnreadSnapshot,
			&pinnedAt, &mutedAt, &markedUnreadAt,
			&item.WuKongChannelID, &item.WuKongChannelType, &participantsJSON, &peerTitle, &peerAvatar,
			&item.AgentUUID, &item.AgentName, &item.AgentAvatar, &item.AgentPosition, &item.AgentDepartment,
			&item.AgentDeleted,
			&item.LastMessageText, &item.LastMessageTS,
		); err != nil {
			return nil, 0, err
		}
		if len(meta) > 0 {
			_ = json.Unmarshal(meta, &item.Metadata)
		}
		if participantsJSON != "" {
			_ = json.Unmarshal([]byte(participantsJSON), &item.Participants)
		}
		item.Kind = deriveConversationKind(item.RoomID, item.RoomKind, item.Participants)
		// 标题:group 用 room.title;direct 用对端(非自己)显示名。
		if item.RoomKind == "group" {
			if item.RoomTitle != "" {
				item.Title = item.RoomTitle
			}
		} else if item.RoomID != nil && peerTitle != "" {
			item.Title = peerTitle
		} else if item.RoomID == nil && item.AgentName != "" {
			item.Title = item.AgentName
		}
		// 会话头像:direct/agent_direct 用对端(非自己)头像;group 暂空(后续群头像)。
		if item.RoomID != nil && item.RoomKind != "group" {
			item.Avatar = peerAvatar
		} else if item.RoomID == nil && item.AgentAvatar != "" {
			item.Avatar = item.AgentAvatar
		}
		item.Hidden = hiddenAt != nil
		item.ClearedAt = clearedAt
		item.Pinned = pinnedAt != nil
		item.PinnedAt = pinnedAt
		item.Muted = mutedAt != nil
		item.MarkedUnread = markedUnreadAt != nil
		out = append(out, item)
	}
	return out, total, rows.Err()
}

// deriveConversationKind P2.1 统一 kind:
//   - room_id 为空(legacy 单聊,无 IM room)→ "single"
//   - room_kind='group' → "group"
//   - room_kind='direct' + 含 agent participant → "agent_direct"
//   - room_kind='direct' 全 human → "human_direct"
func deriveConversationKind(roomID *int64, roomKind string, parts []dom.Participant) string {
	if roomID == nil {
		return "single"
	}
	if roomKind == "group" {
		return "group"
	}
	for _, p := range parts {
		if p.Kind == "agent" {
			return "agent_direct"
		}
	}
	return "human_direct"
}

// FindActiveSingle Batch 2D T2D.2: 查 (tenant, account, digital_employee) 唯一活跃 single-chat。
// 详见 dom.Repository 接口注释。无匹配返回 apperr.ErrNotFound。
//
// 排序: last_message_at DESC NULLS LAST → created_at DESC; LIMIT 1。
// 应用层"复用一条活跃会话"语义靠 LIMIT 1 + T2D.9 partial unique index 联合保证;
// 在 index 落地之前并发 Send 仍可能产生 2 行, 调用方按"取最新一条"处理 (LIMIT 1 已对齐)。
func (r *Repo) FindActiveSingle(ctx context.Context, tenantID, accountID, digitalEmployeeID int64) (*dom.Conversation, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT `+baseCols+` FROM conversations
		WHERE tenant_id=$1 AND account_id=$2 AND digital_employee_id=$3
		  AND room_id IS NULL
		  AND deleted_at IS NULL
		ORDER BY last_message_at DESC NULLS LAST, created_at DESC
		LIMIT 1`, tenantID, accountID, digitalEmployeeID)
	c, err := scan(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return c, nil
}

func emptyMapIfNil(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

// ListLiveZapSessions ZAP-1.1 §11.3 技能 resync 用: 列出某数字员工在租户内仍在有效期的 ZAP 会话
// (metadata.zap_session_id 非空且 zap_session_expires_at 未到; 无过期字段视为有效)。
// 覆盖 single-chat (digital_employee_id) 与 agent 直聊房间 (room_direct_pairs_with_agent)。
// 过期判断在 Go 侧做 (metadata 是 Bus 自己写的 RFC3339, 但不让脏值把整条 SQL 拖挂)。
func (r *Repo) ListLiveZapSessions(ctx context.Context, tenantID, agentID int64, now time.Time) ([]dom.ZapLiveSession, error) {
	if tenantID <= 0 || agentID <= 0 {
		return nil, nil
	}
	rows, err := r.pool.Query(ctx, `
		SELECT c.id, c.account_id,
		       COALESCE(c.metadata->>'zap_session_id', ''),
		       COALESCE(c.metadata->>'zap_session_expires_at', '')
		  FROM conversations c
		 WHERE c.tenant_id = $1
		   AND c.deleted_at IS NULL
		   AND COALESCE(c.metadata->>'zap_session_id', '') <> ''
		   AND (c.digital_employee_id = $2
		        OR c.room_id IN (SELECT p.room_id FROM room_direct_pairs_with_agent p
		                          WHERE p.tenant_id = $1 AND p.agent_id = $2 AND p.is_deleted = false))
		 ORDER BY c.updated_at DESC
		 LIMIT 1000`, tenantID, agentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []dom.ZapLiveSession{}
	for rows.Next() {
		var (
			item    dom.ZapLiveSession
			expires string
		)
		if err := rows.Scan(&item.ConversationID, &item.AccountID, &item.SessionID, &expires); err != nil {
			return nil, err
		}
		if expires != "" {
			if exp, perr := time.Parse(time.RFC3339, expires); perr == nil && !exp.After(now.Add(30*time.Second)) {
				continue
			}
		}
		out = append(out, item)
	}
	return out, rows.Err()
}
