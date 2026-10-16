// Package messagereceipts F09 P1「消息级已读回执 v1」.
//
// 见 docs/contracts/agent-bus-client-contract.md §「消息级已读回执 v1」.
//
// 设计要点:
//   - 底层水位 = conversation_account_state.last_read_message_seq (per-account per-conversation).
//   - **endpoint 只允许查询 caller 自己发送的消息** (FX1 P1 fix): caller==sender 是前置;
//     任一 seq 非 caller 发送 → 403 chat.read_receipts.not_sender, 不返回成员列表 (避免枚举).
//   - 普通消息统计 active human participants (kind='human', left_at IS NULL), 排除 caller 本人 (自己不计未读).
//   - @Agent 消息统计被提及且仍在群内的 active agent; agent_trigger_log 记录 triggered 即视为该 agent 已收到/已读.
//   - 不依赖 WuKong WKMsgExtra.readed / readedCount (端到端未验证).
//   - 不复用会话 unread_count (语义不同).
//
// 闸口顺序 (任一失败 → 不返回成员列表):
//  1. AccessibleByAccount: caller 必须对 conversation 可见 (与 CR1 同口径).
//  2. ResolveChannelAndCaller: conv→channel+caller_uuid, 跨租户/无 WuKong room → 403/400.
//  3. SenderResolver.LookupSendersBySeqs: 拉 WuKong 历史; 任一 seq 的 from_uid != callerWKUid → 403.
//  4. 上述全过 → SQL 聚合 read/unread members.
//
// message_seqs 上限 100; 超出 400.
package messagereceipts

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Service 接口 (便于装配 / 单测).
type Service interface {
	GetReadReceipts(ctx context.Context, in GetReadReceiptsIn) (*GetReadReceiptsOut, error)
}

// GetReadReceiptsIn 入参.
type GetReadReceiptsIn struct {
	TenantID         int64
	CallerAccountID  int64
	ConversationUUID string
	MessageSeqs      []int64 // 去重后 len ≤ MaxSeqs
}

// MaxSeqs 一次最多查多少条消息的回执 (避免被 abused).
const MaxSeqs = 100

// Member 已读/未读成员条目.
type Member struct {
	AccountUUID string `json:"account_uuid"`
	DisplayName string `json:"display_name"`
	Avatar      string `json:"avatar"`
	Subtitle    string `json:"subtitle,omitempty"` // department name
}

// ReceiptItem 单条消息的回执.
type ReceiptItem struct {
	MessageSeq    int64    `json:"message_seq"`
	ReadCount     int      `json:"read_count"`
	UnreadCount   int      `json:"unread_count"`
	AllRead       bool     `json:"all_read"`
	ReadMembers   []Member `json:"read_members"`
	UnreadMembers []Member `json:"unread_members"`
}

// GetReadReceiptsOut 返回值.
type GetReadReceiptsOut struct {
	Items []ReceiptItem `json:"items"`
}

// ConvAccessChecker · 仅访问性闸口 (向后兼容).
type ConvAccessChecker interface {
	AccessibleByAccount(ctx context.Context, tenantID, accountID int64, conversationUUID string) (bool, error)
}

// ConvLookup · FX1 扩展: 在 AccessibleByAccount 之外增加 ResolveChannelAndCaller
// 用于 sender 校验拉 WuKong 历史 + 比对 caller WuKong UID.
type ConvLookup interface {
	ConvAccessChecker
	// ResolveChannelAndCaller 返回 (channelID, channelType, callerAccountUUID).
	// conv 不存在 / 跨租户 / 无 room 绑定 / 无 WuKong channel → 透传 apperr.
	ResolveChannelAndCaller(ctx context.Context, tenantID, callerAccountID int64, conversationUUID string) (
		channelID string, channelType int, callerAccountUUID string, err error,
	)
}

// SenderResolver · FX1: 批量查询 WuKong message_seq → from_uid 映射.
// 生产实现 = wukong.MessageSyncProxy.LookupSendersBySeqs (复用 SyncChannelMessages, 自带租户/成员闸).
// 单测可用 fake.
type SenderResolver interface {
	LookupSendersBySeqs(ctx context.Context, tenantID, callerAccountID int64,
		channelID string, channelType int, seqs []int64) (map[int64]string, error)
}

// MessageInfoResolver 是 SenderResolver 的可选增强:除 from_uid 外还能返回 WuKong message_id。
// 生产实现由 wukong.MessageSyncProxy 提供;旧 fake/实现只实现 SenderResolver 时,回退为真人水位语义。
type MessageInfoResolver interface {
	LookupMessagesBySeqs(ctx context.Context, tenantID, callerAccountID int64,
		channelID string, channelType int, seqs []int64) (map[int64]wukong.SeqMessageInfo, error)
}

// ErrTooManySeqs message_seqs 超长.
var ErrTooManySeqs = errors.New("chat.read_receipts.too_many_seqs")

// ErrNotSender · FX1 P1: 请求的 message_seq 不属于 caller 自己发送.
// 客户端不应该把别人发的消息的 seq 传上来; 后端返 403 不泄露成员列表.
var ErrNotSender = errors.New("chat.read_receipts.not_sender")

// New 构造 service.
//
// pool 用于读 conversation / room_participants / accounts / departments / conversation_account_state 的窄聚合 SQL.
// conv/sender 可分别注入 fake 给单测使用; senders=nil 时所有请求都按"无法验证 sender"拒.
func New(pool *pgxpool.Pool, conv ConvLookup, senders SenderResolver) Service {
	return &impl{pool: pool, conv: conv, senders: senders}
}

type impl struct {
	pool    *pgxpool.Pool
	conv    ConvLookup
	senders SenderResolver
}

// participantRow 单个 active human participant + 其水位.
type participantRow struct {
	accountID          int64
	accountUUID        string
	membershipNickname string
	accountDisplayName string
	avatar             string
	department         string
	lastReadMessageSeq int64
}

// readReceiptHumanDisplayName 与通讯录、会话 participants、群成员详情保持同一租户口径。
// 租户昵称优先；全局账号名仅作兜底，且不得把自助注册/预热生成的系统占位名暴露到成员列表。
func readReceiptHumanDisplayName(membershipNickname, accountDisplayName string) string {
	if name := strings.TrimSpace(membershipNickname); name != "" {
		return name
	}
	name := strings.TrimSpace(accountDisplayName)
	if name == "" || strings.Contains(name, "的组织 管理员") || strings.HasPrefix(name, "预热优化") {
		return ""
	}
	return name
}

type agentParticipantSnapshot struct {
	AgentID     int64
	AgentUUID   string
	DisplayName string
	Avatar      string
}

type messageMetadata struct {
	Mentions []string `json:"mentions"`
}

// ParticipantSnapshot · 测试可见的 participant 视图 (与 participantRow 数据一致).
// 用于把切分算法 (PartitionForSeqs) 暴露成纯函数, 让 SQL/handler 之外能单测.
type ParticipantSnapshot struct {
	AccountUUID        string
	DisplayName        string
	Avatar             string
	Department         string
	LastReadMessageSeq int64
}

// PartitionForSeqs 纯函数: 给定 active human participants 快照(已排除 caller 自己)和 seqs,
// 切分出每条 seq 的 read / unread members.
//
// 与 GetReadReceipts 内部使用同一份逻辑, 抽出便于单测覆盖核心切分语义,
// 不必把 SQL 真集成进单测。
//
// 行为:
//   - 无 participants → 每条 seq 都是 read=0/unread=0/all_read=false (调用方可隐藏 indicator).
//   - participant.LastReadMessageSeq >= seq → read_members.
//   - 否则 → unread_members.
func PartitionForSeqs(snapshots []ParticipantSnapshot, seqs []int64) []ReceiptItem {
	out := make([]ReceiptItem, 0, len(seqs))
	for _, seq := range seqs {
		item := ReceiptItem{MessageSeq: seq, ReadMembers: []Member{}, UnreadMembers: []Member{}}
		for _, p := range snapshots {
			m := Member{
				AccountUUID: p.AccountUUID,
				DisplayName: p.DisplayName,
				Avatar:      p.Avatar,
				Subtitle:    p.Department,
			}
			if p.LastReadMessageSeq >= seq {
				item.ReadMembers = append(item.ReadMembers, m)
				item.ReadCount++
			} else {
				item.UnreadMembers = append(item.UnreadMembers, m)
				item.UnreadCount++
			}
		}
		item.AllRead = item.UnreadCount == 0 && item.ReadCount > 0
		out = append(out, item)
	}
	return out
}

func partitionAgentMentionReceipts(mentioned []agentParticipantSnapshot, triggered map[int64]bool, seq int64) ReceiptItem {
	item := ReceiptItem{MessageSeq: seq, ReadMembers: []Member{}, UnreadMembers: []Member{}}
	for _, a := range mentioned {
		m := Member{
			AccountUUID: a.AgentUUID,
			DisplayName: a.DisplayName,
			Avatar:      a.Avatar,
			Subtitle:    "数字员工",
		}
		if triggered[a.AgentID] {
			item.ReadMembers = append(item.ReadMembers, m)
			item.ReadCount++
		} else {
			item.UnreadMembers = append(item.UnreadMembers, m)
			item.UnreadCount++
		}
	}
	item.AllRead = item.UnreadCount == 0 && item.ReadCount > 0
	return item
}

func applyAgentMentionReceiptOverrides(items []ReceiptItem, overrides map[int64]ReceiptItem) []ReceiptItem {
	if len(overrides) == 0 {
		return items
	}
	for i := range items {
		if item, ok := overrides[items[i].MessageSeq]; ok {
			items[i] = item
		}
	}
	return items
}

func (s *impl) GetReadReceipts(ctx context.Context, in GetReadReceiptsIn) (*GetReadReceiptsOut, error) {
	if in.TenantID <= 0 || in.CallerAccountID <= 0 {
		return nil, apperr.ErrForbidden.Withf("missing identity")
	}
	if in.ConversationUUID == "" {
		return nil, apperr.ErrInvalidParams.Withf("conversation_uuid required")
	}
	// dedup + sanitize seqs.
	seen := make(map[int64]struct{}, len(in.MessageSeqs))
	uniqSeqs := make([]int64, 0, len(in.MessageSeqs))
	for _, q := range in.MessageSeqs {
		if q <= 0 {
			continue
		}
		if _, ok := seen[q]; ok {
			continue
		}
		seen[q] = struct{}{}
		uniqSeqs = append(uniqSeqs, q)
	}
	if len(uniqSeqs) == 0 {
		return &GetReadReceiptsOut{Items: []ReceiptItem{}}, nil
	}
	if len(uniqSeqs) > MaxSeqs {
		return nil, apperr.ErrInvalidParams.Wrap(fmt.Errorf("%w: max %d", ErrTooManySeqs, MaxSeqs))
	}
	// (1) 可见性闸 (沿用 CR1; 也兜底跨租户).
	allowed, err := s.conv.AccessibleByAccount(ctx, in.TenantID, in.CallerAccountID, in.ConversationUUID)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if !allowed {
		return nil, apperr.ErrForbidden.Withf("chat.conversation_not_accessible")
	}
	// (2) 解析 channel + caller_uuid → callerWKUid.
	channelID, channelType, callerAcctUUID, err := s.conv.ResolveChannelAndCaller(ctx, in.TenantID, in.CallerAccountID, in.ConversationUUID)
	if err != nil {
		return nil, err
	}
	if channelID == "" || channelType <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("conversation has no WuKong channel; agent_direct/legacy single not supported")
	}
	if callerAcctUUID == "" {
		return nil, apperr.ErrInternal.Withf("caller account uuid lookup empty")
	}
	callerWKUid := wukong.UserUID(in.TenantID, callerAcctUUID)
	// (3) FX1 P1: sender 校验 — 任一 seq 非 caller 发送 → 403, 不返回成员列表.
	//     无 SenderResolver 注入 → 拒绝 (避免误把无校验路径放行).
	if s.senders == nil {
		return nil, apperr.ErrInternal.Withf("sender resolver not wired")
	}
	var (
		senders      map[int64]string
		messageInfos map[int64]wukong.SeqMessageInfo
	)
	if resolver, ok := s.senders.(MessageInfoResolver); ok {
		messageInfos, err = resolver.LookupMessagesBySeqs(ctx, in.TenantID, in.CallerAccountID, channelID, channelType, uniqSeqs)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		senders = make(map[int64]string, len(messageInfos))
		for seq, info := range messageInfos {
			senders[seq] = info.FromUID
		}
	} else {
		senders, err = s.senders.LookupSendersBySeqs(ctx, in.TenantID, in.CallerAccountID, channelID, channelType, uniqSeqs)
		if err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
	}
	for _, seq := range uniqSeqs {
		from, ok := senders[seq]
		// (a) WuKong 没找到这条消息(可能不在 channel、已被删除、seq 非法)→ 拒, 不泄露.
		if !ok {
			return nil, apperr.ErrForbidden.Withf(ErrNotSender.Error())
		}
		// (b) 找到了, 但不是 caller 发的 → 拒.
		if from != callerWKUid {
			return nil, apperr.ErrForbidden.Withf(ErrNotSender.Error())
		}
	}
	// (4) 全部 seq 都是 caller 自己发的 → 进入聚合.
	// 一次聚合 SQL: 拿 (conversation→room) active human participants 的水位 + 元数据.
	//
	// 注意:
	//   - 排除 caller 自己 (自己不计未读).
	//   - kind='human' AND left_at IS NULL 才算.
	//   - @Agent 消息会在下方用 agent 收到状态覆盖.
	//   - display_name: tenant_memberships.nickname 优先，accounts.display_name 仅作过滤占位名后的兜底.
	//   - department: 走 tenant_memberships → departments.
	rows, err := s.pool.Query(ctx, `
		SELECT a.id, a.uuid::text,
		       COALESCE(tm.nickname, ''),
		       COALESCE(a.display_name, ''),
		       COALESCE(a.avatar_url, ''),
		       COALESCE(d.name, '') AS department_name,
		       COALESCE(cas.last_read_message_seq, 0) AS last_read_seq
		  FROM conversations c
		  JOIN rooms r ON r.id = c.room_id AND r.deleted_at IS NULL
		  JOIN room_participants rp ON rp.room_id = r.id
		                           AND rp.kind = 'human'
		                           AND rp.left_at IS NULL
		                           AND rp.account_id IS NOT NULL
		                           AND rp.account_id <> $3
		  JOIN accounts a ON a.id = rp.account_id
		  LEFT JOIN tenant_memberships tm ON tm.account_id = a.id
		                                AND tm.tenant_id = c.tenant_id
		                                AND tm.deleted_at IS NULL
		  LEFT JOIN departments d ON d.id = tm.department_id AND d.deleted_at IS NULL
		  LEFT JOIN conversation_account_state cas ON cas.account_id = a.id
		                                          AND cas.conversation_uuid = c.uuid
		 WHERE c.uuid = $1::uuid
		   AND c.tenant_id = $2
		   AND c.deleted_at IS NULL
		   AND c.room_id IS NOT NULL`,
		in.ConversationUUID, in.TenantID, in.CallerAccountID,
	)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	defer rows.Close()
	participants := make([]participantRow, 0)
	for rows.Next() {
		var p participantRow
		if err := rows.Scan(&p.accountID, &p.accountUUID, &p.membershipNickname, &p.accountDisplayName, &p.avatar, &p.department, &p.lastReadMessageSeq); err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		participants = append(participants, p)
	}
	if err := rows.Err(); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	// 切分算法走纯函数 PartitionForSeqs (可单测). 普通消息先按 human 水位算;
	// 后续若识别为 @Agent 消息,再用 agent 收到状态覆盖对应 seq。
	snapshots := make([]ParticipantSnapshot, 0, len(participants))
	for _, p := range participants {
		snapshots = append(snapshots, ParticipantSnapshot{
			AccountUUID:        p.accountUUID,
			DisplayName:        readReceiptHumanDisplayName(p.membershipNickname, p.accountDisplayName),
			Avatar:             p.avatar,
			Department:         p.department,
			LastReadMessageSeq: p.lastReadMessageSeq,
		})
	}
	items := PartitionForSeqs(snapshots, uniqSeqs)
	if len(messageInfos) > 0 {
		overrides, err := s.agentMentionReceiptOverrides(ctx, in, messageInfos)
		if err != nil {
			return nil, err
		}
		items = applyAgentMentionReceiptOverrides(items, overrides)
	}
	return &GetReadReceiptsOut{Items: items}, nil
}

func (s *impl) agentMentionReceiptOverrides(ctx context.Context, in GetReadReceiptsIn, infos map[int64]wukong.SeqMessageInfo) (map[int64]ReceiptItem, error) {
	seqByMessageID := make(map[string]int64, len(infos))
	messageIDs := make([]string, 0, len(infos))
	for seq, info := range infos {
		if info.MessageID == "" {
			continue
		}
		if _, exists := seqByMessageID[info.MessageID]; exists {
			continue
		}
		seqByMessageID[info.MessageID] = seq
		messageIDs = append(messageIDs, info.MessageID)
	}
	if len(messageIDs) == 0 {
		return nil, nil
	}

	rows, err := s.pool.Query(ctx, `
		SELECT m.metadata->>'wukong_message_id' AS wukong_message_id,
		       COALESCE(m.metadata, '{}'::jsonb)
		  FROM conversations c
		  JOIN messages m ON m.conversation_id = c.id
		                 AND m.tenant_id = c.tenant_id
		                 AND m.role = 'user'
		                 AND m.metadata->>'wukong_message_id' = ANY($3::text[])
		 WHERE c.uuid = $1::uuid
		   AND c.tenant_id = $2
		   AND c.deleted_at IS NULL`,
		in.ConversationUUID, in.TenantID, messageIDs,
	)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	defer rows.Close()

	mentionsBySeq := make(map[int64][]string)
	mentionSet := make(map[string]struct{})
	for rows.Next() {
		var (
			wukongMessageID string
			rawMeta         []byte
		)
		if err := rows.Scan(&wukongMessageID, &rawMeta); err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		seq, ok := seqByMessageID[wukongMessageID]
		if !ok {
			continue
		}
		var meta messageMetadata
		if err := json.Unmarshal(rawMeta, &meta); err != nil {
			return nil, apperr.ErrInternal.Wrap(fmt.Errorf("chat.read_receipts metadata decode: %w", err))
		}
		mentions := uniqueNonEmptyStrings(meta.Mentions)
		if len(mentions) == 0 {
			continue
		}
		mentionsBySeq[seq] = mentions
		for _, uuid := range mentions {
			mentionSet[uuid] = struct{}{}
		}
	}
	if err := rows.Err(); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	if len(mentionsBySeq) == 0 {
		return nil, nil
	}

	mentionUUIDs := make([]string, 0, len(mentionSet))
	for uuid := range mentionSet {
		mentionUUIDs = append(mentionUUIDs, uuid)
	}
	agentsByUUID, err := s.loadActiveMentionedAgents(ctx, in, mentionUUIDs)
	if err != nil {
		return nil, err
	}
	if len(agentsByUUID) == 0 {
		return nil, nil
	}
	triggeredByMessageID, err := s.loadTriggeredAgents(ctx, in, messageIDs)
	if err != nil {
		return nil, err
	}

	overrides := make(map[int64]ReceiptItem, len(mentionsBySeq))
	for seq, mentions := range mentionsBySeq {
		mentionedAgents := make([]agentParticipantSnapshot, 0, len(mentions))
		for _, uuid := range mentions {
			if agent, ok := agentsByUUID[uuid]; ok {
				mentionedAgents = append(mentionedAgents, agent)
			}
		}
		if len(mentionedAgents) == 0 {
			continue
		}
		triggered := map[int64]bool(nil)
		if info, ok := infos[seq]; ok {
			triggered = triggeredByMessageID[info.MessageID]
		}
		overrides[seq] = partitionAgentMentionReceipts(mentionedAgents, triggered, seq)
	}
	return overrides, nil
}

func (s *impl) loadActiveMentionedAgents(ctx context.Context, in GetReadReceiptsIn, agentUUIDs []string) (map[string]agentParticipantSnapshot, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT de.id,
		       de.uuid::text,
		       COALESCE(de.name, ''),
		       COALESCE(de.avatar_url, '')
		  FROM conversations c
		  JOIN rooms r ON r.id = c.room_id AND r.deleted_at IS NULL
		  JOIN room_participants rp ON rp.room_id = r.id
		                           AND rp.kind = 'agent'
		                           AND rp.left_at IS NULL
		                           AND rp.agent_id IS NOT NULL
		  JOIN digital_employees de ON de.id = rp.agent_id
		                           AND de.is_deleted = FALSE
		                           AND de.deleted_at IS NULL
		 WHERE c.uuid = $1::uuid
		   AND c.tenant_id = $2
		   AND c.deleted_at IS NULL
		   AND de.uuid::text = ANY($3::text[])`,
		in.ConversationUUID, in.TenantID, agentUUIDs,
	)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	defer rows.Close()

	out := make(map[string]agentParticipantSnapshot)
	for rows.Next() {
		var a agentParticipantSnapshot
		if err := rows.Scan(&a.AgentID, &a.AgentUUID, &a.DisplayName, &a.Avatar); err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		out[a.AgentUUID] = a
	}
	if err := rows.Err(); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return out, nil
}

func (s *impl) loadTriggeredAgents(ctx context.Context, in GetReadReceiptsIn, messageIDs []string) (map[string]map[int64]bool, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT atl.openim_client_msg_id,
		       atl.agent_id
		  FROM conversations c
		  JOIN agent_trigger_log atl ON atl.room_id = c.room_id
		                            AND atl.tenant_id = c.tenant_id
		                            AND atl.substrate = 'wukong'
		                            AND atl.decision = 'triggered'
		                            AND atl.openim_client_msg_id = ANY($3::text[])
		 WHERE c.uuid = $1::uuid
		   AND c.tenant_id = $2
		   AND c.deleted_at IS NULL
		   AND c.room_id IS NOT NULL`,
		in.ConversationUUID, in.TenantID, messageIDs,
	)
	if err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	defer rows.Close()

	out := make(map[string]map[int64]bool)
	for rows.Next() {
		var (
			messageID string
			agentID   int64
		)
		if err := rows.Scan(&messageID, &agentID); err != nil {
			return nil, apperr.ErrInternal.Wrap(err)
		}
		if out[messageID] == nil {
			out[messageID] = make(map[int64]bool)
		}
		out[messageID][agentID] = true
	}
	if err := rows.Err(); err != nil {
		return nil, apperr.ErrInternal.Wrap(err)
	}
	return out, nil
}

func uniqueNonEmptyStrings(in []string) []string {
	seen := make(map[string]struct{}, len(in))
	out := make([]string, 0, len(in))
	for _, v := range in {
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
