// Package room postgres 实现 (Batch 2E)。
//
// 关键设计:
//   - CreateGroup 一个 BEGIN/COMMIT 事务串起 rooms + room_participants + conversations 三张表;
//     任意一步失败整事务回滚 (满足 plan §4.1)
//   - AddParticipant 一个 tx 内做 SELECT room FOR UPDATE + FOR SHARE 复查 source row + 幂等查重
//   - SendUserMessageTx 一个 tx 内做 SELECT room FOR UPDATE + FOR SHARE 复查 caller / agent
//   - INSERT user message + UPDATE conversations.last_message_at (rework #1)
//   - speaker_policy_config / metadata 走 ::jsonb cast (与现有 conversation/repo 风格一致)
//   - 通过 jackc/pgx/v5 直接读写, 不引入 GORM
//
// 不在本文件: 群消息历史分页 (走 message repo); audit outbox (在 service 层短 tx 写); PG NOTIFY
// (M5 完整版按需补)。
package room

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/messageblocks"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const roomCols = `id, uuid, tenant_id, creator_id, room_kind, title, COALESCE(goal,''),
    speaker_policy, speaker_policy_config, manager_agent_id, max_round_count, max_a2a_depth,
    round_count, status, metadata, created_at, updated_at, deleted_at,
    COALESCE(wukong_channel_id,''), COALESCE(wukong_channel_type, 0)::int`

func scanRoom(row pgx.Row) (*dom.Room, error) {
	var r dom.Room
	var policyCfg, meta []byte
	var roomKind, policy, status string
	if err := row.Scan(
		&r.ID, &r.UUID, &r.TenantID, &r.CreatorID, &roomKind, &r.Title, &r.Goal,
		&policy, &policyCfg, &r.ManagerAgentID, &r.MaxRoundCount, &r.MaxA2ADepth,
		&r.RoundCount, &status, &meta, &r.CreatedAt, &r.UpdatedAt, &r.DeletedAt,
		&r.WuKongChannelID, &r.WuKongChannelType,
	); err != nil {
		return nil, err
	}
	r.RoomKind = dom.Kind(roomKind)
	r.SpeakerPolicy = dom.SpeakerPolicy(policy)
	r.Status = status
	if len(policyCfg) > 0 {
		_ = json.Unmarshal(policyCfg, &r.SpeakerPolicyConfig)
	}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &r.Metadata)
	}
	return &r, nil
}

const participantCols = `id, uuid, room_id, kind, account_id, agent_id, role_in_room, joined_at, left_at`

func scanParticipant(row pgx.Row) (*dom.Participant, error) {
	var p dom.Participant
	var kind, role string
	if err := row.Scan(
		&p.ID, &p.UUID, &p.RoomID, &kind, &p.AccountID, &p.AgentID, &role, &p.JoinedAt, &p.LeftAt,
	); err != nil {
		return nil, err
	}
	p.Kind = dom.ParticipantKind(kind)
	p.RoleInRoom = dom.RoleInRoom(role)
	return &p, nil
}

// CreateGroup 一个事务内: 复查 caller + participants 仍 active (FOR SHARE) → INSERT rooms +
// participants (含 caller) + conversation。任一步失败整事务回滚, 不会出现 "rooms 已写但
// conversation 没建" 的半状态; 也不会出现 "pre-check 通过但 tx 内 agent 已 unpublished" 的
// TOCTOU 漂移 (R-2E-10)。
func (r *Repo) CreateGroup(ctx context.Context, in dom.CreateInput) (*dom.Room, int64, error) {
	return r.CreateGroupWithHook(ctx, in, nil)
}

// CreateGroupWithHook · 同 CreateGroup 但 commit 前调 hook (业务 TX 内注入额外写入).
// hook=nil → 等价 CreateGroup.
func (r *Repo) CreateGroupWithHook(ctx context.Context, in dom.CreateInput, hook dom.CreateGroupHook) (*dom.Room, int64, error) {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, 0, err
	}
	defer func() { _ = tx.Rollback(ctx) }() // commit 前 rollback 是 no-op

	// 0) 事务内 FOR SHARE 复查 caller + 全部 human / agent 仍 active
	if err := assertActiveCaller(ctx, tx, in.CreatorID, in.TenantID); err != nil {
		return nil, 0, err
	}
	for _, p := range in.Participants {
		if p.Kind == dom.ParticipantHuman && p.AccountID != nil && *p.AccountID != in.CreatorID {
			if err := assertActiveHuman(ctx, tx, *p.AccountID, in.TenantID); err != nil {
				return nil, 0, err
			}
		}
		if p.Kind == dom.ParticipantAgent && p.AgentID != nil {
			if err := assertActiveAgent(ctx, tx, *p.AgentID, in.TenantID); err != nil {
				return nil, 0, err
			}
		}
	}

	policyCfg, _ := json.Marshal(emptyMapIfNil(in.SpeakerPolicyConfig))
	meta := []byte("{}")

	// 1) INSERT rooms
	//    P2.3a: uuid 可由 service 预生成传入(provision-after-auth: WuKong channel 先派生);
	//    空 → schema 默认 gen_random_uuid()。wukong link 两列空则写 NULL。
	row := tx.QueryRow(ctx, `
		INSERT INTO rooms (
			uuid, tenant_id, creator_id, room_kind, title, goal,
			speaker_policy, speaker_policy_config, manager_agent_id,
			max_round_count, metadata, wukong_channel_id, wukong_channel_type)
		VALUES (
			COALESCE(NULLIF($1,'')::uuid, gen_random_uuid()), $2, $3, $4, $5, NULLIF($6, ''),
			$7, $8::jsonb, $9,
			COALESCE(NULLIF($10, 0), 100), $11::jsonb, NULLIF($12,''), NULLIF($13,0)::smallint)
		RETURNING `+roomCols,
		in.RoomUUID, in.TenantID, in.CreatorID, string(in.RoomKind), in.Title, in.Goal,
		string(in.SpeakerPolicy), string(policyCfg), in.ManagerAgentID,
		in.MaxRoundCount, string(meta), in.WuKongChannelID, in.WuKongChannelType,
	)
	rm, err := scanRoom(row)
	if err != nil {
		return nil, 0, err
	}

	// 2) INSERT room_participants — caller 先写 (member), 再写其余入参
	if err := insertParticipant(ctx, tx, rm.ID, dom.ParticipantInput{
		Kind:       dom.ParticipantHuman,
		AccountID:  &in.CreatorID,
		RoleInRoom: dom.RoleMember,
	}); err != nil {
		return nil, 0, err
	}
	for _, p := range in.Participants {
		// caller 不重复写 (service 层应已去重, 但 repo 也兜底)
		if p.Kind == dom.ParticipantHuman && p.AccountID != nil && *p.AccountID == in.CreatorID {
			continue
		}
		role := p.RoleInRoom
		if role == "" {
			role = dom.RoleMember
		}
		if err := insertParticipant(ctx, tx, rm.ID, dom.ParticipantInput{
			Kind:       p.Kind,
			AccountID:  p.AccountID,
			AgentID:    p.AgentID,
			RoleInRoom: role,
		}); err != nil {
			return nil, 0, err
		}
	}

	// 3) INSERT conversations (room conversation)
	//    digital_employee_id IS NULL + room_id NOT NULL; idx_conv_room_active_v2e
	//    保证 (room_id) 唯一活跃。
	var convID int64
	if err := tx.QueryRow(ctx, `
		INSERT INTO conversations (tenant_id, account_id, room_id, title, source, metadata)
		VALUES ($1, $2, $3, NULLIF($4,''), 'group', '{}'::jsonb)
		RETURNING id`,
		in.TenantID, in.CreatorID, rm.ID, in.Title,
	).Scan(&convID); err != nil {
		return nil, 0, err
	}

	// 4) tx 内 hook。
	if hook != nil {
		// 拉 active participants 给 hook 用 (含 caller, 跟 INSERT 的顺序一致).
		parts, err := listParticipantsInTx(ctx, tx, rm.ID)
		if err != nil {
			return nil, 0, fmt.Errorf("CreateGroupWithHook: list participants in tx: %w", err)
		}
		if err := hook(ctx, tx, rm, parts); err != nil {
			return nil, 0, fmt.Errorf("CreateGroupWithHook: hook: %w", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, 0, err
	}
	return rm, convID, nil
}

// listParticipantsInTx · F09-A6-04: 给 hook 拿事务内 active participants 快照.
func listParticipantsInTx(ctx context.Context, tx pgx.Tx, roomID int64) ([]dom.Participant, error) {
	rows, err := tx.Query(ctx, `
		SELECT `+participantCols+`
		  FROM room_participants
		 WHERE room_id=$1 AND left_at IS NULL
		 ORDER BY joined_at ASC, id ASC`, roomID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Participant
	for rows.Next() {
		p, err := scanParticipant(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *p)
	}
	return out, rows.Err()
}

// assertActiveCaller 复查 caller 仍是 tenant active member + accounts.status='active'。
//
// FOR SHARE 锁住 tenant_memberships 行, 防 admin 在本 tx 内 disable 该 caller。
func assertActiveCaller(ctx context.Context, tx pgx.Tx, accountID, tenantID int64) error {
	var ok bool
	err := tx.QueryRow(ctx, `
		SELECT TRUE FROM tenant_memberships
		 WHERE account_id=$1 AND tenant_id=$2 AND status='active' AND deleted_at IS NULL
		 FOR SHARE`, accountID, tenantID,
	).Scan(&ok)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrConflict.Withf("room.member_not_invitable: caller membership not active in tenant")
		}
		return err
	}
	return nil
}

// assertActiveHuman 复查目标 human 仍是 tenant active member。
func assertActiveHuman(ctx context.Context, tx pgx.Tx, accountID, tenantID int64) error {
	var ok bool
	err := tx.QueryRow(ctx, `
		SELECT TRUE FROM tenant_memberships
		 WHERE account_id=$1 AND tenant_id=$2 AND status='active' AND deleted_at IS NULL
		 FOR SHARE`, accountID, tenantID,
	).Scan(&ok)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrConflict.Withf("room.member_not_invitable: target human not active in tenant")
		}
		return err
	}
	return nil
}

// assertActiveAgent 复查 agent 仍 published + allow_invite_to_group + 同租户或 platform。
func assertActiveAgent(ctx context.Context, tx pgx.Tx, agentID, tenantID int64) error {
	var ok bool
	err := tx.QueryRow(ctx, `
		SELECT TRUE FROM digital_employees
		 WHERE id=$1
		   AND status='published'
		   AND allow_invite_to_group=TRUE
		   AND deleted_at IS NULL
		   AND (tenant_id IS NULL OR tenant_id=$2)
		 FOR SHARE`, agentID, tenantID,
	).Scan(&ok)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrConflict.Withf("chat.agent_unavailable: agent unpublished or invite-disabled")
		}
		return err
	}
	return nil
}

// assertActiveAgentDirect 复查 human↔agent 单聊目标仍可单聊。
// 单聊不是"拉入群聊",因此不要求 allow_invite_to_group=TRUE。
func assertActiveAgentDirect(ctx context.Context, tx pgx.Tx, agentID, tenantID int64) error {
	var ok bool
	err := tx.QueryRow(ctx, `
		SELECT TRUE FROM digital_employees
		 WHERE id=$1
		   AND status='published'
		   AND COALESCE(current_version, 0) > 0
		   AND deleted_at IS NULL
		   AND (tenant_id IS NULL OR tenant_id=$2)
		 FOR SHARE`, agentID, tenantID,
	).Scan(&ok)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrConflict.Withf("chat.agent_unavailable: agent unpublished or no current_version")
		}
		return err
	}
	return nil
}

// insertParticipant 不带 caller 去重逻辑; CreateGroup 已自处理。
func insertParticipant(ctx context.Context, tx pgx.Tx, roomID int64, p dom.ParticipantInput) error {
	role := p.RoleInRoom
	if role == "" {
		role = dom.RoleMember
	}
	_, err := tx.Exec(ctx, `
		INSERT INTO room_participants (room_id, kind, account_id, agent_id, role_in_room)
		VALUES ($1, $2, $3, $4, $5)`,
		roomID, string(p.Kind), p.AccountID, p.AgentID, string(role),
	)
	return err
}

// CreateDirectWithPairInput · direct 1v1 房间创建入参。
//
// 参与者固定 2 human, 无 agent. peer 与 caller 必须同 tenant.
type CreateDirectWithPairInput struct {
	TenantID int64
	CallerID int64
	PeerID   int64
	Title    string
	// P2.1(ADR-0026):WuKong 频道 link,与底座无关地存进 rooms。调用方(directroom.Service)
	// 传入确定性派生的 channel id;命中既有 room 时同步修正旧 link。空 = 不写。
	WuKongChannelID   string
	WuKongChannelType int
}

// CreateDirectWithPairOutput · 返事务内创建/已存在的 room + pair + conversation.
type CreateDirectWithPairOutput struct {
	Room              *dom.Room
	ConversationID    int64
	PairUUID          string
	PairCreated       bool // false = 命中既有 pair, true = 新建
	WuKongChannelID   string
	WuKongChannelType int
}

// CreateDirectWithPair 一个 tx 内创建 rooms(kind='direct') + 2 个 room_participants +
// conversation + room_direct_pairs.
//
// 幂等键: room_direct_pairs.uq_rdp_tenant_pair_active.
//   - 命中 (同 tenant 同对 active) → 返既有 room + conversation; PairCreated=false.
//   - 未命中 → 走 CreateGroup 同款 tx 风格新建; PairCreated=true.
//
// 不调 IM substrate, 不依赖 contacts visibility; 调用方 (directroom.Service) 负责。
func (r *Repo) CreateDirectWithPair(ctx context.Context, in CreateDirectWithPairInput) (*CreateDirectWithPairOutput, error) {
	if in.CallerID == in.PeerID {
		return nil, apperr.ErrInvalidParams.Withf("direct room: caller cannot equal peer")
	}
	a, b := in.CallerID, in.PeerID
	if a > b {
		a, b = b, a
	}
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// 1) 同 tenant + 同对账号 active pair 命中 → 返已有 room/conv.
	var existingRoomID int64
	var existingPairUUID string
	if err := tx.QueryRow(ctx, `
		SELECT room_id, uuid FROM room_direct_pairs
		 WHERE tenant_id=$1 AND account_a_id=$2 AND account_b_id=$3 AND deleted_at IS NULL
		 FOR UPDATE`, in.TenantID, a, b).Scan(&existingRoomID, &existingPairUUID); err == nil {
		// 既有 pair: 反查 room + conv.
		row := tx.QueryRow(ctx, `SELECT `+roomCols+` FROM rooms WHERE id=$1 AND deleted_at IS NULL`, existingRoomID)
		room, err := scanRoom(row)
		if err != nil {
			return nil, err
		}
		var convID int64
		if err := tx.QueryRow(ctx,
			`SELECT id FROM conversations WHERE room_id=$1 ORDER BY id ASC LIMIT 1`, existingRoomID,
		).Scan(&convID); err != nil {
			return nil, err
		}
		// 命中既有 room:用本次 provision 出来的确定性 link 修正遗留旧 link。
		wkID, wkType := backfillRoomWuKongLink(ctx, tx, existingRoomID, in.WuKongChannelID, in.WuKongChannelType)
		room.WuKongChannelID = wkID
		room.WuKongChannelType = wkType
		if err := tx.Commit(ctx); err != nil {
			return nil, err
		}
		return &CreateDirectWithPairOutput{Room: room, ConversationID: convID, PairUUID: existingPairUUID, PairCreated: false,
			WuKongChannelID: wkID, WuKongChannelType: wkType}, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}

	// 2) 复查两端 active membership (FOR SHARE 防 admin 并发 disable).
	if err := assertActiveCaller(ctx, tx, in.CallerID, in.TenantID); err != nil {
		return nil, err
	}
	if err := assertActiveHuman(ctx, tx, in.PeerID, in.TenantID); err != nil {
		return nil, err
	}

	// 3) INSERT rooms (kind=direct, metadata.direct_room_kind='human-human' 与 human-agent 对齐口径;
	//    speaker_policy=manual + manager NULL + wukong link).
	roomRow := tx.QueryRow(ctx, `
		INSERT INTO rooms (tenant_id, creator_id, room_kind, title, goal,
			speaker_policy, speaker_policy_config, manager_agent_id,
			max_round_count, metadata, wukong_channel_id, wukong_channel_type)
		VALUES ($1, $2, 'direct', $3, NULL,
			'manual', '{}'::jsonb, NULL,
			100, jsonb_build_object('direct_room_kind','human-human'), NULLIF($4,''), NULLIF($5,0)::smallint)
		RETURNING `+roomCols,
		in.TenantID, in.CallerID, in.Title, in.WuKongChannelID, in.WuKongChannelType,
	)
	room, err := scanRoom(roomRow)
	if err != nil {
		return nil, err
	}

	// 4) 2 个 room_participants (caller + peer; 都是 human/member).
	if err := insertParticipant(ctx, tx, room.ID, dom.ParticipantInput{
		Kind: dom.ParticipantHuman, AccountID: &in.CallerID, RoleInRoom: dom.RoleMember,
	}); err != nil {
		return nil, err
	}
	if err := insertParticipant(ctx, tx, room.ID, dom.ParticipantInput{
		Kind: dom.ParticipantHuman, AccountID: &in.PeerID, RoleInRoom: dom.RoleMember,
	}); err != nil {
		return nil, err
	}

	// 5) conversations (room_id 唯一活跃约束已有).
	var convID int64
	if err := tx.QueryRow(ctx, `
		INSERT INTO conversations (tenant_id, account_id, room_id, title, source, metadata)
		VALUES ($1, $2, $3, NULLIF($4,''), 'direct', '{}'::jsonb)
		RETURNING id`,
		in.TenantID, in.CallerID, room.ID, in.Title,
	).Scan(&convID); err != nil {
		return nil, err
	}

	// 6) room_direct_pairs (同事务幂等键).
	var pairUUID string
	if err := tx.QueryRow(ctx, `
		INSERT INTO room_direct_pairs (tenant_id, room_id, account_a_id, account_b_id)
		VALUES ($1, $2, $3, $4)
		RETURNING uuid::text`,
		in.TenantID, room.ID, a, b,
	).Scan(&pairUUID); err != nil {
		if isUniqueViolation(err) {
			_ = tx.Rollback(ctx)
			return r.fetchExistingDirectPair(ctx, in, a, b)
		}
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return &CreateDirectWithPairOutput{Room: room, ConversationID: convID, PairUUID: pairUUID, PairCreated: true,
		WuKongChannelID: in.WuKongChannelID, WuKongChannelType: in.WuKongChannelType}, nil
}

func (r *Repo) fetchExistingDirectPair(ctx context.Context, in CreateDirectWithPairInput, a, b int64) (*CreateDirectWithPairOutput, error) {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var existingRoomID int64
	var existingPairUUID string
	if err := tx.QueryRow(ctx, `
		SELECT room_id, uuid FROM room_direct_pairs
		 WHERE tenant_id=$1 AND account_a_id=$2 AND account_b_id=$3 AND deleted_at IS NULL
		 FOR UPDATE`, in.TenantID, a, b).Scan(&existingRoomID, &existingPairUUID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrConflict.Withf("direct room pair was created concurrently but is not visible")
		}
		return nil, err
	}
	row := tx.QueryRow(ctx, `SELECT `+roomCols+` FROM rooms WHERE id=$1 AND deleted_at IS NULL`, existingRoomID)
	room, err := scanRoom(row)
	if err != nil {
		return nil, err
	}
	var convID int64
	if err := tx.QueryRow(ctx,
		`SELECT id FROM conversations WHERE room_id=$1 ORDER BY id ASC LIMIT 1`, existingRoomID,
	).Scan(&convID); err != nil {
		return nil, err
	}
	wkID, wkType := backfillRoomWuKongLink(ctx, tx, existingRoomID, in.WuKongChannelID, in.WuKongChannelType)
	room.WuKongChannelID = wkID
	room.WuKongChannelType = wkType
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return &CreateDirectWithPairOutput{
		Room:              room,
		ConversationID:    convID,
		PairUUID:          existingPairUUID,
		PairCreated:       false,
		WuKongChannelID:   wkID,
		WuKongChannelType: wkType,
	}, nil
}

// backfillRoomWuKongLink 命中既有 room 时修正 wukong link。
// channelID 非空时以本次 provision 出来的确定性 channel 为准,用于修复开发期遗留
// 旧 hash / 旧 link；channelID 为空则不改、返回库中现值。
func backfillRoomWuKongLink(ctx context.Context, tx pgx.Tx, roomID int64, channelID string, channelType int) (string, int) {
	var gotID *string
	var gotType *int16
	_ = tx.QueryRow(ctx, `
		UPDATE rooms
		   SET wukong_channel_id   = COALESCE(NULLIF($2,''), wukong_channel_id),
		       wukong_channel_type = COALESCE(NULLIF($3,0)::smallint, wukong_channel_type)
		 WHERE id=$1
		 RETURNING wukong_channel_id, wukong_channel_type`,
		roomID, channelID, channelType).Scan(&gotID, &gotType)
	id := ""
	if gotID != nil {
		id = *gotID
	}
	t := 0
	if gotType != nil {
		t = int(*gotType)
	}
	return id, t
}

// CreateDirectWithAgentPairInput · F09 Phase C (PR12 / C1-02): 人聊 Agent 1v1 入参.
type CreateDirectWithAgentPairInput struct {
	TenantID int64
	CallerID int64 // human account
	AgentID  int64 // digital_employees.id; service 层已校 visibility + published
	Title    string
	// P2.1(ADR-0026):WuKong 频道 link(同 CreateDirectWithPair)。
	WuKongChannelID   string
	WuKongChannelType int
}

// CreateDirectWithAgentPairOutput · 返事务内创建/已存在的 room + pair + conversation.
type CreateDirectWithAgentPairOutput struct {
	Room              *dom.Room
	ConversationID    int64
	PairUUID          string
	PairCreated       bool
	WuKongChannelID   string
	WuKongChannelType int
}

// CreateDirectWithAgentPair · F09 Phase C: 一个 tx 内创建 rooms(kind='direct',
// metadata.direct_room_kind='human-agent') + 2 room_participants (caller human + agent) +
// conversation + room_direct_pairs_with_agent.
//
// 幂等键: room_direct_pairs_with_agent.uq_rdpwa_tenant_account_agent_active.
//   - 命中 (同 tenant + 同 account + 同 agent 未删除) → 返既有 room + conversation; PairCreated=false.
//   - 未命中 → 走 CreateDirectWithPair 同款 tx 风格新建.
//
// 不调 IM substrate, 不依赖 contacts visibility;调用方负责完成
// Agent.status='published' / 同租户 / visible 校验。
func (r *Repo) CreateDirectWithAgentPair(ctx context.Context, in CreateDirectWithAgentPairInput) (*CreateDirectWithAgentPairOutput, error) {
	if in.TenantID <= 0 || in.CallerID <= 0 || in.AgentID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("direct-with-agent: tenant/caller/agent required")
	}
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// 1) 命中既有 (tenant, account, agent) 未删除 pair → 直接返既有 room/conv.
	var existingRoomID int64
	var existingPairUUID string
	if err := tx.QueryRow(ctx, `
		SELECT room_id, uuid FROM room_direct_pairs_with_agent
		 WHERE tenant_id=$1 AND account_id=$2 AND agent_id=$3 AND is_deleted=false
		 FOR UPDATE`,
		in.TenantID, in.CallerID, in.AgentID).Scan(&existingRoomID, &existingPairUUID); err == nil {
		row := tx.QueryRow(ctx, `SELECT `+roomCols+` FROM rooms WHERE id=$1 AND deleted_at IS NULL`, existingRoomID)
		room, err := scanRoom(row)
		if err != nil {
			return nil, err
		}
		convID, err := ensureAgentDirectConversationForRoomTx(ctx, tx, in, existingRoomID)
		if err != nil {
			return nil, err
		}
		wkID, wkType := backfillRoomWuKongLink(ctx, tx, existingRoomID, in.WuKongChannelID, in.WuKongChannelType)
		room.WuKongChannelID = wkID
		room.WuKongChannelType = wkType
		if err := tx.Commit(ctx); err != nil {
			return nil, err
		}
		return &CreateDirectWithAgentPairOutput{Room: room, ConversationID: convID, PairUUID: existingPairUUID, PairCreated: false,
			WuKongChannelID: wkID, WuKongChannelType: wkType}, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}

	// 2) 复查 caller active membership + agent active/published/同租户.
	if err := assertActiveCaller(ctx, tx, in.CallerID, in.TenantID); err != nil {
		return nil, err
	}
	if err := assertActiveAgentDirect(ctx, tx, in.AgentID, in.TenantID); err != nil {
		return nil, err
	}

	// 3) INSERT rooms (kind=direct + metadata.direct_room_kind='human-agent';
	//    speaker_policy='manual' / manager NULL — direct 不需要 selector).
	roomRow := tx.QueryRow(ctx, `
		INSERT INTO rooms (tenant_id, creator_id, room_kind, title, goal,
			speaker_policy, speaker_policy_config, manager_agent_id,
			max_round_count, metadata, wukong_channel_id, wukong_channel_type)
		VALUES ($1, $2, 'direct', $3, NULL,
			'manual', '{}'::jsonb, NULL,
			100, jsonb_build_object('direct_room_kind','human-agent'),
			NULLIF($4,''), NULLIF($5,0)::smallint)
		RETURNING `+roomCols,
		in.TenantID, in.CallerID, in.Title, in.WuKongChannelID, in.WuKongChannelType,
	)
	room, err := scanRoom(roomRow)
	if err != nil {
		return nil, err
	}

	// 4) 2 participants: caller (human) + agent.
	if err := insertParticipant(ctx, tx, room.ID, dom.ParticipantInput{
		Kind: dom.ParticipantHuman, AccountID: &in.CallerID, RoleInRoom: dom.RoleMember,
	}); err != nil {
		return nil, err
	}
	if err := insertParticipant(ctx, tx, room.ID, dom.ParticipantInput{
		Kind: dom.ParticipantAgent, AgentID: &in.AgentID, RoleInRoom: dom.RoleMember,
	}); err != nil {
		return nil, err
	}

	// 5) conversations.
	var convID int64
	if err := tx.QueryRow(ctx, `
		INSERT INTO conversations (tenant_id, account_id, room_id, title, source, metadata)
		VALUES ($1, $2, $3, NULLIF($4,''), 'direct', '{}'::jsonb)
		RETURNING id`,
		in.TenantID, in.CallerID, room.ID, in.Title,
	).Scan(&convID); err != nil {
		return nil, err
	}

	// 6) room_direct_pairs_with_agent (幂等键).
	var pairUUID string
	if err := tx.QueryRow(ctx, `
		INSERT INTO room_direct_pairs_with_agent (tenant_id, room_id, account_id, agent_id, created_by, updated_by)
		VALUES ($1, $2, $3, $4, $3, $3)
		RETURNING uuid::text`,
		in.TenantID, room.ID, in.CallerID, in.AgentID,
	).Scan(&pairUUID); err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return &CreateDirectWithAgentPairOutput{Room: room, ConversationID: convID, PairUUID: pairUUID, PairCreated: true,
		WuKongChannelID: in.WuKongChannelID, WuKongChannelType: in.WuKongChannelType}, nil
}

func ensureAgentDirectConversationForRoomTx(ctx context.Context, tx pgx.Tx, in CreateDirectWithAgentPairInput, roomID int64) (int64, error) {
	var convID int64
	err := tx.QueryRow(ctx, `
		SELECT id FROM conversations
		 WHERE room_id=$1 AND deleted_at IS NULL
		 ORDER BY id ASC
		 LIMIT 1`, roomID,
	).Scan(&convID)
	if err == nil {
		return convID, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return 0, err
	}
	err = tx.QueryRow(ctx, `
		INSERT INTO conversations (tenant_id, account_id, room_id, title, source, metadata)
		VALUES ($1, $2, $3, NULLIF($4,''), 'direct', jsonb_build_object('repair_source','agent_direct_pair_existing'))
		RETURNING id`,
		in.TenantID, in.CallerID, roomID, in.Title,
	).Scan(&convID)
	if err == nil {
		return convID, nil
	}
	if !isUniqueViolation(err) {
		return 0, err
	}
	err = tx.QueryRow(ctx, `
		SELECT id FROM conversations
		 WHERE room_id=$1 AND deleted_at IS NULL
		 ORDER BY id ASC
		 LIMIT 1`, roomID,
	).Scan(&convID)
	if err != nil {
		return 0, err
	}
	return convID, nil
}

// GetByID · 按内部 room id 取 Room (不带 tenant 约束);调用方需自行做租户校验。
func (r *Repo) GetByID(ctx context.Context, roomID int64) (*dom.Room, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT `+roomCols+`
		  FROM rooms
		 WHERE id=$1 AND deleted_at IS NULL`,
		roomID,
	)
	rm, err := scanRoom(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return rm, nil
}

// GetByUUID 仅返回 deleted_at IS NULL 且属于 tenantID 的 room。
func (r *Repo) GetByUUID(ctx context.Context, tenantID int64, uuid string) (*dom.Room, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT `+roomCols+`
		  FROM rooms
		 WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		uuid, tenantID,
	)
	rm, err := scanRoom(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return rm, nil
}

// UpdateTitle · F09 P2 「会话列表操作菜单 v2」: 群改名.
// service 层已校验 caller=creator + title 1-64 char + room_kind=group;
// 这里只对未删 / 同租户 / 非 archived 的行 UPDATE.
// UPDATE 影响 0 行 → ErrNotFound.
func (r *Repo) UpdateTitle(ctx context.Context, tenantID, roomID int64, title string) error {
	t := strings.TrimSpace(title)
	if t == "" {
		return apperr.ErrInvalidParams.Withf("title required")
	}
	runeLen := utf8.RuneCountInString(t)
	if runeLen > 64 {
		return apperr.ErrInvalidParams.Withf("title too long (max 64 chars)")
	}
	tag, err := r.pool.Exec(ctx,
		`UPDATE rooms
		    SET title=$1, updated_at=now()
		  WHERE id=$2 AND tenant_id=$3 AND deleted_at IS NULL AND status <> 'archived'`,
		t, roomID, tenantID,
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// UpgradeDirectToGroup 见 dom.Repository 接口注释。room_kind 已是 'group' 时
// UPDATE 影响 0 行，视为幂等成功，不再动 room_direct_pairs（首次升级时已清过）。
func (r *Repo) UpgradeDirectToGroup(ctx context.Context, tenantID, roomID int64) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var exists bool
	if err := tx.QueryRow(ctx,
		`SELECT true FROM rooms WHERE id=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		roomID, tenantID,
	).Scan(&exists); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		return err
	}

	tag, err := tx.Exec(ctx,
		`UPDATE rooms SET room_kind='group', updated_at=now()
		  WHERE id=$1 AND tenant_id=$2 AND room_kind='direct'`,
		roomID, tenantID,
	)
	if err != nil {
		return err
	}
	if tag.RowsAffected() > 0 {
		if _, err := tx.Exec(ctx,
			`UPDATE room_direct_pairs SET deleted_at=now() WHERE room_id=$1 AND deleted_at IS NULL`,
			roomID,
		); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// ListParticipants 仅 active (left_at IS NULL)。
func (r *Repo) ListParticipants(ctx context.Context, roomID int64) ([]dom.Participant, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT `+participantCols+`
		  FROM room_participants
		 WHERE room_id=$1 AND left_at IS NULL
		 ORDER BY joined_at ASC, id ASC`,
		roomID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Participant
	for rows.Next() {
		p, err := scanParticipant(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *p)
	}
	return out, rows.Err()
}

// AddParticipant 一个事务内:
//  1. SELECT rooms FOR UPDATE (room 还存在 + 没被 archive)
//  2. FOR SHARE 复查 source human / agent 仍 active
//  3. SELECT 现有 (room_id, account_id|agent_id) AND left_at IS NULL → 命中 → 幂等返回
//  4. 否则 INSERT 新行 (active-only unique 允许 leave 后重邀)
func (r *Repo) AddParticipant(ctx context.Context, roomID int64, tenantID int64, p dom.ParticipantInput) (*dom.Participant, error) {
	return r.AddParticipantWithHook(ctx, roomID, tenantID, p, nil)
}

// AddParticipantWithHook · F09-A6-04 commit-2: 同 AddParticipant 但 commit 前调 hook.
// hook=nil → 等价 AddParticipant. participant 是本次写入 (或幂等命中) 的 active 行.
func (r *Repo) AddParticipantWithHook(ctx context.Context, roomID int64, tenantID int64, p dom.ParticipantInput, hook dom.AddParticipantHook) (*dom.Participant, error) {
	role := p.RoleInRoom
	if role == "" {
		role = dom.RoleMember
	}

	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// 1) lock room 保证并发不会同时 archive
	var rowExists bool
	if err := tx.QueryRow(ctx, `
		SELECT TRUE FROM rooms
		 WHERE id=$1 AND tenant_id=$2 AND deleted_at IS NULL AND status='active'
		 FOR UPDATE`, roomID, tenantID,
	).Scan(&rowExists); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("room.not_found_or_inactive")
		}
		return nil, err
	}

	// 2) FOR SHARE 复查 source row 仍 active
	if p.Kind == dom.ParticipantHuman && p.AccountID != nil {
		if err := assertActiveHuman(ctx, tx, *p.AccountID, tenantID); err != nil {
			return nil, err
		}
	}
	if p.Kind == dom.ParticipantAgent && p.AgentID != nil {
		if err := assertActiveAgent(ctx, tx, *p.AgentID, tenantID); err != nil {
			return nil, err
		}
	}

	// 3) 幂等查: 已 active 则返回现有行
	var existing dom.Participant
	var kind, roleStr string
	var lookupErr error
	switch p.Kind {
	case dom.ParticipantHuman:
		lookupErr = tx.QueryRow(ctx, `
			SELECT `+participantCols+`
			  FROM room_participants
			 WHERE room_id=$1 AND kind='human' AND account_id=$2 AND left_at IS NULL`,
			roomID, p.AccountID,
		).Scan(
			&existing.ID, &existing.UUID, &existing.RoomID, &kind,
			&existing.AccountID, &existing.AgentID, &roleStr,
			&existing.JoinedAt, &existing.LeftAt,
		)
	case dom.ParticipantAgent:
		lookupErr = tx.QueryRow(ctx, `
			SELECT `+participantCols+`
			  FROM room_participants
			 WHERE room_id=$1 AND kind='agent' AND agent_id=$2 AND left_at IS NULL`,
			roomID, p.AgentID,
		).Scan(
			&existing.ID, &existing.UUID, &existing.RoomID, &kind,
			&existing.AccountID, &existing.AgentID, &roleStr,
			&existing.JoinedAt, &existing.LeftAt,
		)
	default:
		return nil, apperr.ErrInvalidParams.Withf("room.unknown_participant_kind: %q", p.Kind)
	}
	if lookupErr == nil {
		// 幂等命中: 直接返回现有 row, 不 INSERT, 不查 cap (rework #5: 已是成员则不受 cap 影响)
		existing.Kind = dom.ParticipantKind(kind)
		existing.RoleInRoom = dom.RoleInRoom(roleStr)
		// 即使幂等命中, hook 仍调;hook 调用方负责自身幂等。
		if hook != nil {
			if err := hook(ctx, tx, roomID, &existing); err != nil {
				return nil, fmt.Errorf("AddParticipantWithHook: hook (idempotent hit): %w", err)
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return nil, err
		}
		return &existing, nil
	}
	if !errors.Is(lookupErr, pgx.ErrNoRows) {
		return nil, lookupErr
	}

	// 4) Cap 检查 (rework #5): 新插入前 tx 内 count active participants;
	//    防 service 层 resolveParticipants 只算 "caller + 入参" 漏掉 room 已有成员的 race。
	//    SELECT rooms FOR UPDATE (步骤 1) 已序列化并发 AddParticipant, count 是事务内一致性视图。
	var activeCount int
	if err := tx.QueryRow(ctx, `
		SELECT count(*) FROM room_participants
		 WHERE room_id=$1 AND left_at IS NULL`, roomID,
	).Scan(&activeCount); err != nil {
		return nil, err
	}
	if activeCount >= dom.MaxParticipants {
		return nil, apperr.ErrInvalidParams.Withf(
			"room.max_participants_exceeded: room already has %d active members (cap=%d)",
			activeCount, dom.MaxParticipants)
	}

	// 5) INSERT 新行
	row := tx.QueryRow(ctx, `
		INSERT INTO room_participants (room_id, kind, account_id, agent_id, role_in_room)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING `+participantCols,
		roomID, string(p.Kind), p.AccountID, p.AgentID, string(role),
	)
	added, err := scanParticipant(row)
	if err != nil {
		return nil, err
	}
	// hook 调用方负责自身额外写入。
	if hook != nil {
		if err := hook(ctx, tx, roomID, added); err != nil {
			return nil, fmt.Errorf("AddParticipantWithHook: hook: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return added, nil
}

// MarkParticipantLeft 按 participant_uuid 找 active 行 → UPDATE left_at=now()。
// 已 left 的行 / 不存在 → ErrNotFound。
func (r *Repo) MarkParticipantLeft(ctx context.Context, roomID int64, participantUUID string) error {
	return r.MarkParticipantLeftWithHook(ctx, roomID, participantUUID, nil)
}

// MarkParticipantLeftWithHook · 同 MarkParticipantLeft 但 commit 前调 hook.
// hook 接收已 UPDATE 的 *Participant (含 kind/account_id/agent_id).
// hook=nil → 等价 MarkParticipantLeft.
func (r *Repo) MarkParticipantLeftWithHook(ctx context.Context, roomID int64, participantUUID string, hook dom.MarkParticipantLeftHook) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	row := tx.QueryRow(ctx, `
		UPDATE room_participants
		   SET left_at = now()
		 WHERE room_id=$1 AND uuid=$2 AND left_at IS NULL
		 RETURNING `+participantCols,
		roomID, participantUUID,
	)
	updated, err := scanParticipant(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		return err
	}
	if hook != nil {
		if err := hook(ctx, tx, roomID, updated); err != nil {
			return fmt.Errorf("MarkParticipantLeftWithHook: hook: %w", err)
		}
	}
	return tx.Commit(ctx)
}

func emptyMapIfNil(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

// SendUserMessageTx Batch 2E rework #1: SendMessage 三步装一个 tx (复查 + INSERT messages +
// UPDATE conversations.last_message_at)。详见 dom.Repository 接口文档。
//
// 复查失败映射:
//   - room 不在 / 已 archive / 已 deleted   → ErrConflict (room.not_active_or_deleted)
//   - caller 不再是 active human participant → ErrForbidden (room.permission_denied)
//   - selected agent 不再 active participant / 未 published / current_version=0 / 不可邀
//     → ErrConflict (chat.agent_unavailable)
//
// 任何复查失败整事务回滚, user message 绝**不**写。
func (r *Repo) SendUserMessageTx(ctx context.Context, in dom.SendUserMessageInput) (*dom.SendUserMessageOutput, error) {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	out, err := sendUserMessageInTx(ctx, tx, in, sendModeGroup)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return out, nil
}

// sendUserMode 区分群 @Agent 与 human↔agent 单聊的 agent 校验语义(P2 修复)。
type sendUserMode int

const (
	// sendModeGroup 群 @Agent:agent 必须 published + current_version>0 + **allow_invite_to_group=TRUE**(群邀请语义)。
	sendModeGroup sendUserMode = iota
	// sendModeAgentDirect human↔agent 单聊:agent 必须 published + current_version>0,**不**要求 allow_invite_to_group
	// (单聊不是"被拉入群",allow_invite_to_group=FALSE 不应拦截)。可见性由调用方(webhook AssertAgentVisible)闸口。
	sendModeAgentDirect
)

// agentGateSQL 构造 selected-agent 闸口 SQL($1=agent_id)。group 模式额外要求 allow_invite_to_group=TRUE;
// agent-direct 单聊不要求(P2 修复)。两者都要 published + 未删 + current_version>0。
func agentGateSQL(mode sendUserMode) string {
	q := `
			SELECT TRUE FROM digital_employees
			 WHERE id=$1
			   AND status='published'
			   AND deleted_at IS NULL
			   AND COALESCE(current_version, 0) > 0`
	if mode == sendModeGroup {
		q += `
			   AND allow_invite_to_group=TRUE`
	}
	return q + `
			 FOR SHARE`
}

// sendUserMessageInTx 在给定 tx 内做 room 锁 + 参与者校验 + 插 user message + bump last_message_at
// (**不 commit**;供 SendUserMessageTx(group)与 SendUserMessageWithTriggerTx(agent-direct)共用)。
func sendUserMessageInTx(ctx context.Context, tx pgx.Tx, in dom.SendUserMessageInput, mode sendUserMode) (*dom.SendUserMessageOutput, error) {
	// 1) lock room (序列化并发 SendMessage)
	var ok bool
	var roomKind, directKind string
	if err := tx.QueryRow(ctx, `
		SELECT room_kind, COALESCE(metadata->>'direct_room_kind','') FROM rooms
		 WHERE id=$1 AND tenant_id=$2 AND deleted_at IS NULL AND status='active'
		 FOR UPDATE`, in.RoomID, in.TenantID,
	).Scan(&roomKind, &directKind); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrConflict.Withf("room.not_active_or_deleted: room_id=%d", in.RoomID)
		}
		return nil, err
	}

	if roomKind == "direct" && directKind == "human-agent" {
		mode = sendModeAgentDirect
	}

	// 2) caller 仍 active human participant
	if err := tx.QueryRow(ctx, `
		SELECT TRUE FROM room_participants
		 WHERE room_id=$1 AND kind='human' AND account_id=$2 AND left_at IS NULL
		 FOR SHARE`, in.RoomID, in.CallerAccountID,
	).Scan(&ok); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrForbidden.Withf("room.permission_denied: caller no longer participant")
		}
		return nil, err
	}

	// 3) selected agent 仍 active participant + published + current_version > 0 + invitable
	if in.SelectedAgentID != nil {
		if err := tx.QueryRow(ctx, `
			SELECT TRUE FROM room_participants
			 WHERE room_id=$1 AND kind='agent' AND agent_id=$2 AND left_at IS NULL
			 FOR SHARE`, in.RoomID, *in.SelectedAgentID,
		).Scan(&ok); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, apperr.New(apperr.UpstreamUnavailable, "chat.agent_unavailable").Withf("agent left room")
			}
			return nil, err
		}
		// agent 必须 published + 有 current_version;group 模式额外要求 allow_invite_to_group=TRUE。
		// 群内调用授权由 active room_participants 表达；agent-direct 另走目录可见性闸口。
		if err := tx.QueryRow(ctx, agentGateSQL(mode), *in.SelectedAgentID).Scan(&ok); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, apperr.New(apperr.UpstreamUnavailable, "chat.agent_unavailable").Withf("agent unpublished or no current_version")
			}
			return nil, err
		}
	}

	// 4) INSERT user message
	// M6 Phase A: ExtraMetadata 合并到 metadata, mentions 同时保留. 命名冲突时 ExtraMetadata
	// 不允许覆盖 mentions 字段 (mentions 由 selector 唯一权威源头计算).
	metaMap := map[string]any{"mentions": in.Mentions}
	for k, v := range in.ExtraMetadata {
		if k == "mentions" {
			continue
		}
		metaMap[k] = v
	}
	mentionsJSON, _ := json.Marshal(metaMap)
	blocks := in.Blocks
	if len(blocks) == 0 {
		blocks = []map[string]any{{"type": "plain", "text": in.Text}}
	}
	fileUUIDs := uniqueNonEmptyStrings(in.FileUUIDs)
	var (
		conversationUUID    string
		resolvedAttachments []messageblocks.Attachment
	)
	if len(fileUUIDs) > 0 {
		var err error
		conversationUUID, resolvedAttachments, err = resolveUserInputFilesInTx(ctx, tx, in, fileUUIDs)
		if err != nil {
			return nil, err
		}
		blocks = messageblocks.AppendAttachments(blocks, resolvedAttachments)
	}
	blocksJSON, _ := json.Marshal(blocks)

	var (
		msgID   int64
		msgUUID string
	)
	if err := tx.QueryRow(ctx, `
		INSERT INTO messages (
			tenant_id, conversation_id, room_id, role, sender_account_id,
			blocks, status, final, metadata)
		VALUES (
			$1, $2, $3, 'user', $4,
			$5::jsonb, 'final', TRUE, $6::jsonb)
		RETURNING id, uuid`,
		in.TenantID, in.ConversationID, in.RoomID, in.CallerAccountID,
		string(blocksJSON), string(mentionsJSON),
	).Scan(&msgID, &msgUUID); err != nil {
		return nil, err
	}

	// 5) Bind chat-scope attachment files to the same user message before the
	// trigger tx can commit. This keeps agent-direct file inputs visible to the
	// runtime ingest path and avoids a triggered-but-unbound half state.
	if err := bindResolvedUserInputFilesInTx(ctx, tx, in, msgUUID, conversationUUID, resolvedAttachments); err != nil {
		return nil, err
	}

	// 6) bump last_message_at
	if _, err := tx.Exec(ctx, `
		UPDATE conversations SET last_message_at = now(), updated_at = now()
		 WHERE id = $1`, in.ConversationID,
	); err != nil {
		return nil, err
	}

	return &dom.SendUserMessageOutput{UserMessageID: msgID, UserMessageUUID: msgUUID}, nil
}

func bindUserInputFilesInTx(ctx context.Context, tx pgx.Tx, in dom.SendUserMessageInput, msgUUID string) error {
	fileUUIDs := uniqueNonEmptyStrings(in.FileUUIDs)
	if len(fileUUIDs) == 0 {
		return nil
	}
	conversationUUID, resolved, err := resolveUserInputFilesInTx(ctx, tx, in, fileUUIDs)
	if err != nil {
		return err
	}
	return bindResolvedUserInputFilesInTx(ctx, tx, in, msgUUID, conversationUUID, resolved)
}

func resolveUserInputFilesInTx(ctx context.Context, tx pgx.Tx, in dom.SendUserMessageInput, fileUUIDs []string) (string, []messageblocks.Attachment, error) {
	if in.CallerAccountID <= 0 || in.TenantID <= 0 {
		return "", nil, apperr.ErrUnauthorized.Withf("auth required")
	}

	var conversationUUID string
	if err := tx.QueryRow(ctx, `
		SELECT uuid::text
		  FROM conversations
		 WHERE id=$1 AND tenant_id=$2 AND deleted_at IS NULL
		 LIMIT 1`,
		in.ConversationID, in.TenantID,
	).Scan(&conversationUUID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", nil, apperr.ErrNotFound.Withf("chat.conversation_not_found")
		}
		return "", nil, err
	}

	resolved := make([]messageblocks.Attachment, 0, len(fileUUIDs))
	for _, fileUUID := range fileUUIDs {
		var file messageblocks.Attachment
		if err := tx.QueryRow(ctx, `
			WITH RECURSIVE target_file AS (
				SELECT f.id,
				       f.uuid::text AS uuid,
				       f.name,
				       f.mime_type,
				       f.size_bytes,
				       f.scope,
				       f.created_by,
				       f.copy_status,
				       f.drive_folder_id,
				       s.id AS space_id,
				       s.kind AS space_kind,
				       s.owner_account_id,
				       s.department_id
				  FROM drive_files f
				  JOIN drive_spaces s ON s.id = f.space_id
				 WHERE f.uuid = $1::uuid
				   AND f.is_deleted = false
				   AND s.is_deleted = false
				   AND s.tenant_id = $3
				 LIMIT 1
			),
			folder_chain AS (
				SELECT df.id, df.parent_id, 1 AS depth
				  FROM drive_folders df
				  JOIN target_file tf ON df.id = tf.drive_folder_id
				 WHERE df.is_deleted = false
				UNION ALL
				SELECT parent.id, parent.parent_id, fc.depth + 1
				  FROM drive_folders parent
				  JOIN folder_chain fc ON parent.id = fc.parent_id
				 WHERE parent.is_deleted = false
			),
			targets AS (
				SELECT 'file'::text AS target_kind, id AS target_id, 0 AS depth FROM target_file
				UNION ALL
				SELECT 'folder'::text AS target_kind, id AS target_id, depth FROM folder_chain
				UNION ALL
				SELECT 'space'::text AS target_kind, space_id AS target_id, 100000 AS depth FROM target_file
			),
			membership AS (
				SELECT department_id
				  FROM tenant_memberships
				 WHERE account_id = $2
				   AND tenant_id = $3
				   AND status = 'active'
				   AND deleted_at IS NULL
				 LIMIT 1
			)
			SELECT tf.uuid, tf.name, tf.mime_type, tf.size_bytes
			  FROM target_file tf
			 WHERE (
					tf.scope = 'chat'
					AND tf.created_by = $2
				   )
			    OR (
					tf.scope = 'drive'
					AND tf.copy_status = 'ready'
					AND (
						(tf.space_kind IN ('personal', 'shared') AND tf.owner_account_id = $2)
						OR (tf.space_kind IN ('tenant', 'department') AND EXISTS (SELECT 1 FROM membership))
						OR (
							EXISTS (SELECT 1 FROM membership)
							AND EXISTS (
								SELECT 1
								  FROM drive_acl_entries ae
								  JOIN targets t ON t.target_kind = ae.target_kind AND t.target_id = ae.target_id
								  LEFT JOIN drive_share_links sl ON ae.link_token_id = sl.id
								 WHERE ae.is_deleted = false
								   AND ae.role IN ('viewer', 'editor', 'manager')
								   AND (
									   (ae.subject_kind = 'account' AND ae.subject_id = $2)
									OR (
										ae.subject_kind = 'department'
										AND ae.subject_id = (SELECT department_id FROM membership)
										AND (SELECT department_id FROM membership) IS NOT NULL
									)
									OR (
										ae.subject_kind = 'link_token'
										AND sl.id IS NOT NULL
										AND sl.is_deleted = false
										AND sl.revoked_at IS NULL
										AND (sl.expires_at IS NULL OR sl.expires_at > now())
									)
								   )
							)
						)
					)
				   )
			 LIMIT 1`,
			fileUUID, in.CallerAccountID, in.TenantID,
		).Scan(&file.UUID, &file.Name, &file.MimeType, &file.SizeBytes); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return "", nil, apperr.ErrForbidden.Withf("chat.attachment_not_owned: %s", fileUUID)
			}
			return "", nil, err
		}
		resolved = append(resolved, file)
	}
	return conversationUUID, resolved, nil
}

func bindResolvedUserInputFilesInTx(ctx context.Context, tx pgx.Tx, in dom.SendUserMessageInput, msgUUID string, conversationUUID string, files []messageblocks.Attachment) error {
	if len(files) == 0 {
		return nil
	}
	if msgUUID == "" {
		return apperr.ErrInvalidParams.Withf("message_uuid required")
	}
	if conversationUUID == "" {
		return apperr.ErrNotFound.Withf("chat.conversation_not_found")
	}

	for _, file := range files {
		if _, err := tx.Exec(ctx, `
			INSERT INTO conversation_message_files
				(tenant_id, conversation_uuid, message_uuid, account_id, role, drive_file_uuid, created_by, updated_by)
			VALUES
				($1, $2, $3, $4, 'user_input', $5::uuid, $4, $4)
			ON CONFLICT (conversation_uuid, message_uuid, drive_file_uuid)
				WHERE is_deleted = false
			DO NOTHING`,
			in.TenantID, conversationUUID, msgUUID, in.CallerAccountID, file.UUID,
		); err != nil {
			return err
		}
	}
	return nil
}

func uniqueNonEmptyStrings(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, raw := range in {
		v := strings.TrimSpace(raw)
		if v == "" {
			continue
		}
		if _, ok := seen[v]; ok {
			continue
		}
		seen[v] = struct{}{}
		out = append(out, v)
	}
	return out
}

// TriggerLogEntry · agent-direct webhook 原子幂等用的 agent_trigger_log triggered 行(最小子集)。
type TriggerLogEntry struct {
	TenantID        int64
	RoomID          int64
	Substrate       string // 'wukong'
	SenderAccountID *int64
	AgentID         *int64
	IMMessageID     string // openim_client_msg_id 列(wukong=webhook message_id)
	Decision        string // 'triggered'
}

// ErrTriggerDuplicate · 同 (tenant, room, substrate, message_id) 已记录(幂等命中)。
var ErrTriggerDuplicate = errors.New("room: agent_trigger_log duplicate (already triggered)")

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

// SendUserMessageWithTriggerTx · P1 修复:在**同一 DB tx** 内原子完成「agent_trigger_log(triggered)插入」+
// 「shadow user message anchor 写入」(agent-direct webhook 用)。
//   - trigger_log UNIQUE 冲突(同 message_id 已触发)→ rollback + ErrTriggerDuplicate(不写 shadow、不触发)。
//   - shadow 写失败 → 整体 rollback → **不会留下"已 triggered 但无 shadow"的不可重试记录**(同 message_id 可重试)。
//   - 任一步失败整体 rollback。成功 → triggered 一条 + shadow 一条。
func (r *Repo) SendUserMessageWithTriggerTx(ctx context.Context, trig TriggerLogEntry, in dom.SendUserMessageInput) (*dom.SendUserMessageOutput, error) {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// 1) trigger_log(幂等先行):UNIQUE 冲突 → rollback + ErrTriggerDuplicate。
	// agent-direct stream attach(000032):占位写 wukong_run_status='starting'(run 起后由 SetAgentDirectRunAnchor
	// 改 'started';run 失败由 SetAgentDirectRunFailed 改 'failed')。
	if _, terr := tx.Exec(ctx, `
		INSERT INTO agent_trigger_log
			(tenant_id, room_id, substrate, sender_account_id, agent_id, openim_client_msg_id, decision, wukong_run_status)
		VALUES ($1, $2, $3, $4, $5, $6, $7, 'starting')`,
		trig.TenantID, trig.RoomID, trig.Substrate, trig.SenderAccountID, trig.AgentID, trig.IMMessageID, trig.Decision,
	); terr != nil {
		if isUniqueViolation(terr) {
			return nil, ErrTriggerDuplicate
		}
		return nil, terr
	}

	// 2) shadow user message anchor(同 tx;失败 → 上面 trigger_log 一并 rollback)。
	// agent-direct 单聊语义:不要求 allow_invite_to_group(P2 修复)。
	out, err := sendUserMessageInTx(ctx, tx, in, sendModeAgentDirect)
	if err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return out, nil
}

// agent-direct run 状态机(ADR-0026,migration 000032 列 wukong_run_status)。
const (
	WuKongRunStatusStarting = "starting" // gate 占位,run 尚未起 / stream 未回写
	WuKongRunStatusStarted  = "started"  // run 已起、stream_id 已回写
	WuKongRunStatusFailed   = "failed"   // RunAgentForConversation 出错
)

// SetAgentDirectRunAnchor 在 run 成功启动后回写 stream/amu + 置 status='started'(清 error)。
// agentMessageUUID 存 varchar,**不做 ::uuid cast**(避免回写失败 → duplicate 永久 pending)。
func (r *Repo) SetAgentDirectRunAnchor(ctx context.Context, tenantID, roomID int64, substrate, imMessageID, streamID, agentMessageUUID string) error {
	if tenantID <= 0 || roomID <= 0 || substrate == "" || imMessageID == "" || streamID == "" {
		return apperr.ErrInvalidParams.Withf("agent-direct run anchor: tenant/room/substrate/message_id/stream_id required")
	}
	ct, err := r.pool.Exec(ctx, `
		UPDATE agent_trigger_log
		   SET wukong_stream_id=$5, wukong_agent_message_uuid=NULLIF($6,''),
		       wukong_run_status='started', wukong_run_error=NULL
		 WHERE tenant_id=$1 AND room_id=$2 AND substrate=$3 AND openim_client_msg_id=$4`,
		tenantID, roomID, substrate, imMessageID, streamID, agentMessageUUID,
	)
	if err != nil {
		return err
	}
	if ct.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("agent-direct run anchor: trigger_log row not found")
	}
	return nil
}

// SetAgentDirectRunFailed 在 RunAgentForConversation 失败时置 status='failed' + 记 error,
// 使后到的 webhook 能认领重试、attach 返回 failed(而非永久 pending)。
func (r *Repo) SetAgentDirectRunFailed(ctx context.Context, tenantID, roomID int64, substrate, imMessageID, runError string) error {
	if tenantID <= 0 || roomID <= 0 || substrate == "" || imMessageID == "" {
		return apperr.ErrInvalidParams.Withf("agent-direct run failed: tenant/room/substrate/message_id required")
	}
	_, err := r.pool.Exec(ctx, `
		UPDATE agent_trigger_log
		   SET wukong_run_status='failed', wukong_run_error=NULLIF($5,'')
		 WHERE tenant_id=$1 AND room_id=$2 AND substrate=$3 AND openim_client_msg_id=$4`,
		tenantID, roomID, substrate, imMessageID, runError,
	)
	return err
}

// ClaimAgentDirectRunRetry 单行原子认领一个 failed run 去重跑:仅当当前 status='failed' 时翻成 'starting'。
// claimed=true → 调用方应重跑;false → 0 行(非 failed / 另一投递已认领)→ skip。**防并发双跑**。
func (r *Repo) ClaimAgentDirectRunRetry(ctx context.Context, tenantID, roomID int64, substrate, imMessageID string) (claimed bool, err error) {
	if tenantID <= 0 || roomID <= 0 || substrate == "" || imMessageID == "" {
		return false, apperr.ErrInvalidParams.Withf("agent-direct run retry: tenant/room/substrate/message_id required")
	}
	ct, err := r.pool.Exec(ctx, `
		UPDATE agent_trigger_log
		   SET wukong_run_status='starting', wukong_run_error=NULL
		 WHERE tenant_id=$1 AND room_id=$2 AND substrate=$3 AND openim_client_msg_id=$4
		   AND wukong_run_status='failed'`,
		tenantID, roomID, substrate, imMessageID,
	)
	if err != nil {
		return false, err
	}
	return ct.RowsAffected() == 1, nil
}

// GetAgentDirectRunAnchor 读 run 状态机 + stream 锚点。found=false → 无该 message_id 行;
// found=true 时 status ∈ {starting, started, failed}(starting+空 stream = pending)。ADR-0026 agent-direct stream attach。
func (r *Repo) GetAgentDirectRunAnchor(ctx context.Context, tenantID, roomID int64, substrate, imMessageID string) (streamID, agentMessageUUID, status string, found bool, err error) {
	if tenantID <= 0 || roomID <= 0 || substrate == "" || imMessageID == "" {
		return "", "", "", false, apperr.ErrInvalidParams.Withf("agent-direct run anchor: tenant/room/substrate/message_id required")
	}
	var sid, amu, st *string
	row := r.pool.QueryRow(ctx, `
		SELECT wukong_stream_id, wukong_agent_message_uuid, wukong_run_status
		  FROM agent_trigger_log
		 WHERE tenant_id=$1 AND room_id=$2 AND substrate=$3 AND openim_client_msg_id=$4`,
		tenantID, roomID, substrate, imMessageID,
	)
	if scanErr := row.Scan(&sid, &amu, &st); scanErr != nil {
		if errors.Is(scanErr, pgx.ErrNoRows) {
			return "", "", "", false, nil
		}
		return "", "", "", false, scanErr
	}
	if sid != nil {
		streamID = *sid
	}
	if amu != nil {
		agentMessageUUID = *amu
	}
	if st != nil {
		status = *st
	}
	return streamID, agentMessageUUID, status, true, nil
}

// UpdateSpeakerPolicyConfig · F09 Phase B PR7 (PR7-E):
// 在 SpeakerSelector 返 NextPolicyConfig 后, 把 selector 计算出的"应当持久化的 policy state"
// 回写到 rooms.speaker_policy_config (JSONB).
//
// 用 jsonb 的合并语义 (`||`): 把新字段 merge 到老 config 上, 不会丢失外部 admin 设置的策略选项.
// 注意: 当前实现是 last-write-wins; 没并发锁, 因为 selector 是发消息路径单进程跑.
// 高并发同 room 多用户同时发消息 → speaker_policy_config 是计数器型字段,
// 最坏情况是少计一两次 round_robin tick, 不影响业务正确性 (worst case 同一 speaker 多说一句).
//
// 失败仅记日志, 由调用方决定是否传播; 不持久化 NextPolicyConfig 不会阻塞当前消息发送.
func (r *Repo) UpdateSpeakerPolicyConfig(ctx context.Context, roomID int64, patch map[string]any) error {
	if len(patch) == 0 {
		return nil
	}
	bs, err := json.Marshal(patch)
	if err != nil {
		return fmt.Errorf("UpdateSpeakerPolicyConfig: marshal: %w", err)
	}
	cmd, err := r.pool.Exec(ctx, `
		UPDATE rooms
		   SET speaker_policy_config = COALESCE(speaker_policy_config, '{}'::jsonb) || $2::jsonb,
		       updated_at = now()
		 WHERE id = $1 AND deleted_at IS NULL`,
		roomID, string(bs),
	)
	if err != nil {
		return fmt.Errorf("UpdateSpeakerPolicyConfig: exec: %w", err)
	}
	if cmd.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// ChannelMembership · P2.3a 群历史闸:按 WuKong channel_id 反查 room,判断 caller 是否为该 room
// 的 active human participant。
//
//	linked=false           : 该 channel 未绑定任何未删除 room → 调用方按租户命名空间校验放行(向后兼容)。
//	linked=true, allowed=T  : caller 是 active human participant。
//	linked=true, allowed=F  : caller 不是(移出/退出/从不是成员)→ 拒。
//
// idx_rooms_wukong_channel_id 非唯一,实践 1:1;反查多行时取首个 room(ORDER BY id)判定。
func (r *Repo) ChannelMembership(ctx context.Context, tenantID, callerAccountID int64, channelID string) (linked bool, allowed bool, err error) {
	var roomID int64
	err = r.pool.QueryRow(ctx, `
		SELECT id FROM rooms
		 WHERE wukong_channel_id=$1 AND tenant_id=$2 AND deleted_at IS NULL
		 ORDER BY id ASC LIMIT 1`, channelID, tenantID).Scan(&roomID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, false, nil
		}
		return false, false, err
	}
	var ok bool
	if err := r.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM room_participants
			 WHERE room_id=$1 AND kind='human' AND account_id=$2 AND left_at IS NULL)`,
		roomID, callerAccountID).Scan(&ok); err != nil {
		return true, false, err
	}
	return true, ok, nil
}

// ConversationUUIDByRoomID room 对应的活跃 conversation UUID。
//
// service 层 Get 用此查 RoomDTO.ConversationUUID。idx_conv_room_active_v2e
// 保证一个 room 仅一条活跃 conversation, 因此 LIMIT 1 总是确定结果。
// 找不到 → ErrNotFound (不应该发生, 除非软删了 conversation 但没删 room)。
// AgentDirectRoomRow · F09 / ADR-0026 agent-direct webhook 最小闭环:按 WuKong direct channel 找
// human-agent direct room 的解析结果(成员真理来自 room_participants)。
type AgentDirectRoomRow struct {
	RoomID           int64
	RoomUUID         string
	HumanAccountUUID string
	AgentUUID        string
	ConversationUUID string
}

// FindAgentDirectByWuKongChannel 按 (tenantID, wukong channelID) 找 **human-agent** direct room。
// 成员真理 = room_participants(active human + active agent);并取 accounts/digital_employees 的 uuid + conversation uuid。
// fail-closed:非 human-agent direct / 不存在 / 非 active → ErrNotFound;participant 异常(非恰好 1 human + 1 agent)→ error。
// **不靠 channel hash 反推**;显式传 tenantID/channelID,不读 ctx user。
func (r *Repo) FindAgentDirectByWuKongChannel(ctx context.Context, tenantID int64, channelID string) (*AgentDirectRoomRow, error) {
	rows, err := r.pool.Query(ctx, `
SELECT r.id, r.uuid, ha.uuid::text, ag.uuid::text
  FROM rooms r
  JOIN room_participants rph ON rph.room_id=r.id AND rph.kind='human' AND rph.left_at IS NULL
  JOIN accounts ha            ON ha.id=rph.account_id
  JOIN room_participants rpa ON rpa.room_id=r.id AND rpa.kind='agent' AND rpa.left_at IS NULL
  JOIN digital_employees ag   ON ag.id=rpa.agent_id
 WHERE r.tenant_id=$1
   AND r.wukong_channel_id=$2
   AND r.room_kind='direct'
   AND r.metadata->>'direct_room_kind'='human-agent'
   AND r.status='active'
   AND r.deleted_at IS NULL`, tenantID, channelID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AgentDirectRoomRow
	for rows.Next() {
		var row AgentDirectRoomRow
		if serr := rows.Scan(&row.RoomID, &row.RoomUUID, &row.HumanAccountUUID, &row.AgentUUID); serr != nil {
			return nil, serr
		}
		out = append(out, row)
	}
	if rerr := rows.Err(); rerr != nil {
		return nil, rerr
	}
	if len(out) == 0 {
		return nil, apperr.ErrNotFound
	}
	if len(out) > 1 {
		// participant 异常(多 human/agent 组合)→ fail-closed,不猜测。
		return nil, fmt.Errorf("room: agent_direct channel %q resolved %d human/agent combos (expect exactly 1)", channelID, len(out))
	}
	row := out[0]
	convUUID, err := r.ConversationUUIDByRoomID(ctx, row.RoomID)
	if err != nil {
		return nil, err
	}
	row.ConversationUUID = convUUID
	return &row, nil
}

func (r *Repo) ConversationUUIDByRoomID(ctx context.Context, roomID int64) (string, error) {
	var uuid string
	err := r.pool.QueryRow(ctx, `
		SELECT uuid FROM conversations
		 WHERE room_id=$1 AND deleted_at IS NULL
		 LIMIT 1`, roomID,
	).Scan(&uuid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", apperr.ErrNotFound
		}
		return "", err
	}
	return uuid, nil
}
