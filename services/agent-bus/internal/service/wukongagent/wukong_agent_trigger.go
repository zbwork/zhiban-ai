// wukong_agent_trigger.go · cmd/bus 装配 WuKong webhook → Agent 触发链路
// (ADR-0026 / F09)。**同一个 Sink 处理两类 channel**:
//   - **group channel**(`t_{tenant}_g_{room}`,type=2):群聊 `@Agent`(handle 的 group 分支),逻辑不变。
//   - **direct channel**(`t_{tenant}_d_{hash}`,type=2):**仅 `agent_direct_wukong_enabled=true`** 时走
//     agent-direct(`handleAgentDirect`);flag=false 时 direct channel 不触发(行为完全不变)。
//
// group @Agent 链路(取代 OpenIM;客户端群聊走 WuKong SDK):
//
//	终端用户在 WuKong group channel 发 "@陈启航 ..." 文本
//	  → WuKong msg.notify webhook (/api/agent-bus/v1/im/wukong/webhook)
//	  → 本 Sink.OnMessage → handle 的 group 分支:
//	     1. group channel(`_g_`)走群 @Agent;direct channel(`_d_`)在 flag 开启时走 agent-direct
//	     2. 防回环: from_uid=t_{tenant}_a_{agent_uuid} (Agent 自己代发的消息) 直接忽略
//	     3. sender 必须是 human (t_{tenant}_u_{account_uuid}) 且是该 room active 成员
//	     4. SpeakerSelector 解析 @mention → 选中 agent
//	     5. supports_group_chat + 可见性 闸口
//	     6. 持久幂等: agent_trigger_log (substrate=wukong, dedup=webhook message_id)
//	     7. SendUserMessageTx 落 shadow user message
//	     8. chat.RunAgentForConversation 启动 agent
//	     9. 后台 goroutine 等终态 → 以 Agent 虚拟用户 (AgentUID) 把 final 回复**经 WuKong-send outbox
//	        入队**(group=source=group_agent_reply;agent-direct=source=agent_direct_agent_final)→ worker
//	        可靠投递回同一 channel;**outbox 未启用 / enqueue 失败 → fallback 直接 SendMessage**(不静默吞)。
//
// agent-direct(`handleAgentDirect`)与 group 的区别:`ResolveAgentDirectWebhookTarget` 解析 + fail-closed、
// **不走 `@` selector**(单 agent 会话)、**trigger_log triggered + shadow anchor 同一 tx 原子写**
// (`SendUserMessageWithTriggerTx`,P1:shadow 失败整体 rollback、同 message_id 可重试)。
//
// 设计要点:
//   - OnMessage 先脱离 webhook request ctx,再同步完成幂等 + shadow; agent 生成 + final 回投独立 goroutine, 失败仅 log。
//   - webhook handler 已先把非文本/空文本过滤掉 (decodeWKText), 这里只收文本事件。
//   - reject (mention 无匹配 / 不支持群聊 / 不可见 / selector 拒) 也写一条 agent_trigger_log
//     (decision=rejected) 以便观测 + 幂等; 纯人对话 (无 @) 不写行不触发。
package wukongagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	domaccount "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	domwkoutbox "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/wukongoutbox"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/messageblocks"
	repoagenttrigger "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agenttrigger"
	reporoom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/room"
	svcchat "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
	svcmessagereceipts "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/messagereceipts"
	svcwkoutbox "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/wukongoutbox"
	wukongwh "github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/wukongwh"
)

const wukongGroupAgentRunTimeout = 30 * time.Minute

// 以下窄接口让 OnMessage 可注入 fake 单测; 生产传 *reporoom.Repo / *repoaccount.Repo 等具体实现。
type wkRooms interface {
	GetByUUID(ctx context.Context, tenantID int64, uuid string) (*domroom.Room, error)
	ListParticipants(ctx context.Context, roomID int64) ([]domroom.Participant, error)
	ConversationUUIDByRoomID(ctx context.Context, roomID int64) (string, error)
	SendUserMessageTx(ctx context.Context, in domroom.SendUserMessageInput) (*domroom.SendUserMessageOutput, error)
	// agent-direct(P1):trigger_log triggered + shadow anchor 同一 tx 原子写。
	SendUserMessageWithTriggerTx(ctx context.Context, trig reporoom.TriggerLogEntry, in domroom.SendUserMessageInput) (*domroom.SendUserMessageOutput, error)
	// agent-direct stream attach(000032):webhook/attach 共享幂等行上的 run 状态机 + stream anchor。
	SetAgentDirectRunAnchor(ctx context.Context, tenantID, roomID int64, substrate, imMessageID, streamID, agentMessageUUID string) error
	SetAgentDirectRunFailed(ctx context.Context, tenantID, roomID int64, substrate, imMessageID, runError string) error
	ClaimAgentDirectRunRetry(ctx context.Context, tenantID, roomID int64, substrate, imMessageID string) (claimed bool, err error)
	GetAgentDirectRunAnchor(ctx context.Context, tenantID, roomID int64, substrate, imMessageID string) (streamID, agentMessageUUID, status string, found bool, err error)
}
type wkAccounts interface {
	GetByUUID(ctx context.Context, uuid string) (*domaccount.Account, error)
}
type wkAccountByID interface {
	GetByID(ctx context.Context, id int64) (*domaccount.Account, error)
}
type wkAgents interface {
	GetByID(ctx context.Context, id int64) (*domagent.DigitalEmployee, error)
	GetByUUID(ctx context.Context, uuid string) (*domagent.DigitalEmployee, error) // agent-direct: target.AgentUUID → agent
}
type wkConvs interface {
	GetByUUID(ctx context.Context, uuid string) (*domconv.Conversation, error)
}
type wkTriggers interface {
	Insert(ctx context.Context, e repoagenttrigger.Entry) (*repoagenttrigger.Entry, error)
}
type wkContacts interface {
	AssertAgentVisible(ctx context.Context, accountID, tenantID int64, agentUUID string) error
}
type wkChatRunner interface {
	RunAgentForConversation(ctx context.Context, in svcchat.RunAgentInput) (*svcchat.RunAgentOutput, error)
	SubscribeWithOwner(ctx context.Context, accountID, tenantID int64, streamID string) (<-chan svcchat.StreamEvent, func(), error)
}
type wkCreditPrechecker interface {
	EnsureCreditsAvailable(ctx context.Context, tenantID, accountID int64, source string) error
}
type wkMessageSender interface {
	SendMessage(ctx context.Context, fromUID, channelID string, channelType int, payload []byte) (messageID int64, err error)
}
type wkEphemeralMessageSender interface {
	SendEphemeralNotification(ctx context.Context, fromUID, channelID string, channelType int, payload []byte) (messageID int64, err error)
}
type wkSpeakerSelector interface {
	Select(ctx context.Context, in svcchat.SelectInput) (*svcchat.SelectResult, error)
}

// wukongOutboxEnqueuer 是 dispatcher 对 WuKong-send outbox 的窄依赖(不直接碰 repository/SQL)。
// *svcwkoutbox.Service 满足之。nil = outbox 未启用 → sendBack 走原直接 SendMessage(默认行为不变)。
type wukongOutboxEnqueuer interface {
	EnqueueWuKongMessage(ctx context.Context, p svcwkoutbox.EnqueueParams) (domwkoutbox.Message, bool, error)
}

// wukongAgentTriggerDeps · 装配依赖 (cmd/bus 内部)。
type wukongAgentTriggerDeps struct {
	logger           *logpkg.Logger
	rooms            wkRooms
	accounts         wkAccounts
	agents           wkAgents
	convs            wkConvs
	triggers         wkTriggers
	contacts         wkContacts
	chat             wkChatRunner
	billing          wkCreditPrechecker
	sender           wkMessageSender // WuKong 特权 REST /message/send
	readReceipt      wkEphemeralMessageSender
	speaker          wkSpeakerSelector    // 可选; 非 nil → Phase B 6 策略 + 审计, nil → 老 SelectSpeakers
	outbox           wukongOutboxEnqueuer // 可选(方案 B 门控); 非 nil → 群 agent 回复 enqueue outbox, nil → 直接 SendMessage
	outboxMaxRetries int                  // outbox 入队 max_retries(<=0 → service/repo 默认 10);来自 cfg.Chat.WuKongSendOutboxMaxRetries

	// agent-direct webhook 最小闭环(ADR-0026)。仅 agentDirectEnabled=true 时 direct channel 走 agent-direct 分支。
	agentDirectEnabled              bool                         // = cfg.Chat.AgentDirectWuKongEnabled
	agentDirectLookup               wukong.AgentDirectRoomLookup // 生产 lookup(room repo adapter);nil → resolve 必 fail-closed
	agentDirectWarmingRetryWindow   time.Duration                // <=0 → 90s；仅 chat.runtime_warming
	agentDirectWarmingRetryInterval time.Duration                // <=0 → 2s
}

// agentDirectRoomLookupAdapter 把 room repo 的 FindAgentDirectByWuKongChannel 适配成
// wukong.AgentDirectRoomLookup(SQL 留在 repository 层;cmd 仅类型映射 + ErrNotFound→found=false)。
type agentDirectRoomLookupAdapter struct{ rooms *reporoom.Repo }

func (a agentDirectRoomLookupAdapter) FindAgentDirectByChannel(ctx context.Context, tenantID int64, channelID string) (wukong.AgentDirectRoom, bool, error) {
	row, err := a.rooms.FindAgentDirectByWuKongChannel(ctx, tenantID, channelID)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return wukong.AgentDirectRoom{}, false, nil
		}
		return wukong.AgentDirectRoom{}, false, err
	}
	return wukong.AgentDirectRoom{
		RoomID:           row.RoomID,
		HumanAccountUUID: row.HumanAccountUUID,
		AgentUUID:        row.AgentUUID,
		ConversationUUID: row.ConversationUUID,
	}, true, nil
}

// wukongAgentTrigger 实现 wukongwh.Sink。
type wukongAgentTrigger struct{ d wukongAgentTriggerDeps }

// buildWuKongAgentTrigger · 装配 Sink。关键依赖缺失返 nil(调用方据此 warn, 不静默挂空 Sink)。
func buildWuKongAgentTrigger(d wukongAgentTriggerDeps) wukongwh.Sink {
	if d.rooms == nil || d.accounts == nil || d.agents == nil || d.convs == nil ||
		d.triggers == nil || d.chat == nil || d.sender == nil {
		return nil
	}
	return &wukongAgentTrigger{d: d}
}

func (t *wukongAgentTrigger) info(ctx context.Context, msg string, kv ...any) {
	if t.d.logger != nil {
		t.d.logger.Info(ctx, msg, kv...)
	}
}
func (t *wukongAgentTrigger) warn(ctx context.Context, msg string, kv ...any) {
	if t.d.logger != nil {
		t.d.logger.Warn(ctx, msg, kv...)
	}
}

// OnMessage 实现 wukongwh.Sink。webhook handler 忽略返回 error 并恒 200, 故此处统一把
// "未触发的原因" warn 出来 (观测性; 用户要求失败可查)。
func (t *wukongAgentTrigger) OnMessage(ctx context.Context, ev wukongwh.Event) error {
	// WuKong webhook 客户端约 5s 会取消请求 ctx。trigger gate(群成员校验、selector、
	// 幂等、shadow write)必须继续完成,否则用户消息已进 WuKong 但 agent run 不会启动。
	triggerCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer cancel()
	err := t.handle(triggerCtx, ev)
	if err != nil {
		t.warn(triggerCtx, "wukong trigger: not fired", "message_id", ev.MessageID,
			"channel_id", ev.ChannelID, "err", err.Error())
	}
	return err
}

func (t *wukongAgentTrigger) handle(ctx context.Context, ev wukongwh.Event) error {
	d := t.d
	// 1) direct(human-human / human-agent)与 group 都是 channel_type=2;按 channel_id kind 分流。
	if ev.ChannelType != wukong.ChannelTypeGroup {
		return nil
	}
	chTenant, chKind, roomUUID, ok := parseNamespacedID(ev.ChannelID)
	if !ok {
		return nil
	}
	// agent-direct webhook 最小闭环:direct channel(kind=d)仅 flag=true 时进 agent-direct 分支;
	// flag=false → direct channel 不触发(行为完全不变);group `@Agent` 路径任何情况都不变。
	if chKind == "d" {
		if !d.agentDirectEnabled {
			return nil
		}
		return t.handleAgentDirect(ctx, ev, chTenant)
	}
	if chKind != "g" {
		return nil
	}
	// 2) 防回环 + sender 必须 human。
	sndTenant, sndKind, sndID, ok := parseSenderID(ev.FromUID)
	if !ok {
		return nil
	}
	if sndKind == "a" {
		// Agent 自己代发的消息回环, 直接忽略 (不写行)。
		return nil
	}
	if sndKind != "u" {
		return nil
	}
	if sndTenant != chTenant {
		t.warn(ctx, "wukong trigger: cross-tenant sender/channel; ignore",
			"sender_tenant", sndTenant, "channel_tenant", chTenant)
		return nil
	}
	tenantID := chTenant

	// 3) sender account_uuid → account_id。
	acc, err := d.accounts.GetByUUID(ctx, sndID)
	if err != nil || acc == nil {
		return fmt.Errorf("wukong trigger: sender account %q miss: %w", sndID, err)
	}
	callerAccountID := acc.ID

	// 4) room + 状态 + channel link 一致性。
	room, err := d.rooms.GetByUUID(ctx, tenantID, roomUUID)
	if err != nil || room == nil {
		return fmt.Errorf("wukong trigger: room %s miss: %w", roomUUID, err)
	}
	if room.Status != "active" {
		return fmt.Errorf("wukong trigger: room %s not active (status=%s)", roomUUID, room.Status)
	}
	if room.WuKongChannelID != "" && room.WuKongChannelID != ev.ChannelID {
		return fmt.Errorf("wukong trigger: room %s channel link mismatch", roomUUID)
	}

	// 5) sender 必须 active human participant; 构造候选。
	parts, err := d.rooms.ListParticipants(ctx, room.ID)
	if err != nil {
		return fmt.Errorf("wukong trigger: list participants: %w", err)
	}
	if !roomHumanIsActive(parts, callerAccountID) {
		return fmt.Errorf("wukong trigger: sender account=%d not active participant in room=%d", callerAccountID, room.ID)
	}
	candidates := buildSpeakerCandidatesFromParts(ctx, d.agents, parts)

	// 6) 选 speaker。优先用结构化 mentions metadata(type=agent),无 metadata 时文本兜底。
	text := ev.Text
	var selected []int64

	agentMentions := agentMentionsOf(ev.Mentions)
	switch {
	case len(ev.Mentions) > 0:
		// 有结构化 mentions:只认 type=agent;type=human/all 不触发 Agent(展示/通知语义)。
		if len(agentMentions) == 0 {
			// 只 @了 human / 所有人 → 不触发, 不写行。
			return nil
		}
		m := matchAgentMentions(agentMentions, candidates)
		// 优先级:**只要存在任一 unmatched agent mention,就记 mention_no_match**(比 ambiguous 更
		// 精确——同一条 metadata 既有 unknown agent 又有重名 ambiguous 时,审计原因取"未命中")。
		if m.unmatched {
			// 任一 type=agent mention 未命中(id 非空不在群内 / name 0 命中)→ **拒绝整条**,
			// 即便同时有有效 agent(混合有效+无效)也不触发, 避免无效项被静默吞掉。
			t.recordReject(ctx, tenantID, room.ID, ev.MessageID, &callerAccountID, nil, "mention_no_match")
			t.info(ctx, "wukong trigger: agent mention matched no group agent; reject whole", "room_id", room.ID)
			return nil
		}
		if m.ambiguous {
			// id 空 + name 重名(且无 unmatched)→ 不能取第一个。
			t.recordReject(ctx, tenantID, room.ID, ev.MessageID, &callerAccountID, nil, "selector_reject")
			t.info(ctx, "wukong trigger: ambiguous agent name mention; selector_reject (multiple_agents_not_supported)", "room_id", room.ID)
			return nil
		}
		if len(m.selected) == 0 {
			// 无可用 agent 身份(全 id 空 + name 空)→ 静默跳过, 不写行。
			return nil
		}
		if len(m.selected) > 1 {
			// metadata 多 agent: 不静默取第一个。WuKong 触发链路单回复, 不实现 fan-out;
			// 保守拒绝(manual 语义 multiple_agents_not_supported; 非 manual 亦不擅自 fan-out)。
			t.recordReject(ctx, tenantID, room.ID, ev.MessageID, &callerAccountID, nil, "selector_reject")
			t.info(ctx, "wukong trigger: multiple agent mentions not supported; selector_reject", "room_id", room.ID, "count", len(m.selected))
			return nil
		}
		selected = m.selected
	default:
		// 无 metadata:文本兜底(复用 selector; nil → 老 SelectSpeakers)。
		var selErr error
		if d.speaker != nil {
			rrLastIdx := -1
			if v, ok := room.SpeakerPolicyConfig["last_idx"]; ok {
				switch x := v.(type) {
				case int:
					rrLastIdx = x
				case int64:
					rrLastIdx = int(x)
				case float64:
					rrLastIdx = int(x)
				}
			}
			res, serr := d.speaker.Select(ctx, svcchat.SelectInput{
				Policy:            room.SpeakerPolicy,
				PolicyConfig:      room.SpeakerPolicyConfig,
				ManagerAgentID:    room.ManagerAgentID,
				Candidates:        candidates,
				UserMsgText:       text,
				RoomID:            room.ID,
				TenantID:          tenantID,
				CreatedBy:         &callerAccountID,
				RoundRobinLastIdx: rrLastIdx,
			})
			if serr != nil {
				selErr = serr
			} else if res != nil {
				selected = res.Selected
			}
		} else {
			selected, selErr = svcchat.SelectSpeakers(room.SpeakerPolicy, room.ManagerAgentID, candidates, text)
		}
		if selErr != nil {
			t.recordReject(ctx, tenantID, room.ID, ev.MessageID, &callerAccountID, nil, "selector_reject")
			return fmt.Errorf("wukong trigger: selector reject: %w", selErr)
		}
		if len(selected) == 0 {
			// 无 metadata 文本未命中:静默跳过, **不**写 mention_no_match(避免 @human/@all/
			// typo/email 污染审计)。仅当有 @token 时记一条 info 便于排查。
			if mentionPresent(text) {
				t.info(ctx, "wukong trigger: text mention matched no agent; skip (no metadata)", "room_id", room.ID)
			}
			return nil
		}
	}
	selectedAgentID := selected[0]
	ag, err := d.agents.GetByID(ctx, selectedAgentID)
	if err != nil || ag == nil {
		return fmt.Errorf("wukong trigger: agent id=%d miss: %w", selectedAgentID, err)
	}

	// 7) supports_group_chat 闸口。
	if !ag.SupportsGroupChat {
		t.recordReject(ctx, tenantID, room.ID, ev.MessageID, &callerAccountID, &selectedAgentID, "agent_not_published_for_group")
		return fmt.Errorf("wukong trigger: agent %s supports_group_chat=false; not fanning out", ag.UUID)
	}
	// 8) 群内授权由 active room_participants 表达。上游已经确认发送者是本群 active human、
	// selectedAgentID 是本群 active agent；这里不能再套用通讯录 AssertAgentVisible，
	// 否则创建者加入群的 private 数字员工会错误拒绝其他群成员。
	// 一对一 agent-direct 仍在 resolveAgentDirect 中执行目录可见性闸口。
	if d.billing != nil {
		if berr := d.billing.EnsureCreditsAvailable(ctx, tenantID, callerAccountID, "group_agent_trigger"); berr != nil {
			t.recordReject(ctx, tenantID, room.ID, ev.MessageID, &callerAccountID, &selectedAgentID, "insufficient_credits")
			return fmt.Errorf("wukong trigger: credits unavailable for caller %d: %w", callerAccountID, berr)
		}
	}

	// 9) 持久幂等: 同 (tenant, room, wukong, message_id) 只触发一次。
	if _, terr := d.triggers.Insert(ctx, repoagenttrigger.Entry{
		TenantID:        tenantID,
		RoomID:          room.ID,
		Substrate:       repoagenttrigger.SubstrateWuKong,
		SenderAccountID: &callerAccountID,
		AgentID:         &selectedAgentID,
		IMMessageID:     ev.MessageID,
		Decision:        repoagenttrigger.DecisionTriggered,
	}); terr != nil {
		if errors.Is(terr, repoagenttrigger.ErrDuplicate) {
			t.info(ctx, "wukong trigger: duplicate message_id; skip", "room_id", room.ID, "message_id", ev.MessageID)
			return nil
		}
		return fmt.Errorf("wukong trigger: agent_trigger_log insert: %w", terr)
	}

	// 10) conversation。
	convUUID, err := d.rooms.ConversationUUIDByRoomID(ctx, room.ID)
	if err != nil || convUUID == "" {
		return fmt.Errorf("wukong trigger: conversation by room id=%d: %w", room.ID, err)
	}
	conv, err := d.convs.GetByUUID(ctx, convUUID)
	if err != nil || conv == nil {
		return fmt.Errorf("wukong trigger: conv by uuid=%s: %w", convUUID, err)
	}

	// 11) shadow user message (复用 room repo tx)。
	var mentions []string
	for _, c := range candidates {
		if c.AgentID == selectedAgentID {
			mentions = append(mentions, c.AgentUUID)
		}
	}
	userOut, err := d.rooms.SendUserMessageTx(ctx, domroom.SendUserMessageInput{
		TenantID:        tenantID,
		RoomID:          room.ID,
		CallerAccountID: callerAccountID,
		ConversationID:  conv.ID,
		SelectedAgentID: &selectedAgentID,
		Text:            text,
		Mentions:        mentions,
		ExtraMetadata: map[string]any{
			"source":             "wukong_webhook",
			"wukong_message_id":  ev.MessageID,
			"wukong_message_seq": ev.MessageSeq,
			"wukong_channel_id":  ev.ChannelID,
		},
	})
	if err != nil {
		return fmt.Errorf("wukong trigger: SendUserMessageTx: %w", err)
	}
	if userOut == nil || strings.TrimSpace(userOut.UserMessageUUID) == "" {
		return fmt.Errorf("wukong trigger: SendUserMessageTx returned empty user message uuid")
	}

	// 12+13) 异步生成 + 代发回 WuKong。
	// 关键: 必须脱离 webhook 请求 ctx —— WuKong webhook 客户端有 ~5s 超时, 同步跑 agent 生成会
	// 超时关连接 → 请求 ctx 取消 → 生成中途 `context canceled`(load agent_versions 失败)。
	// 故 webhook 同步完成 1-11 (幂等 insert + shadow user message 已持久), agent 生成 + 终态回投
	// 放进 detached(WithoutCancel + 6min 超时)goroutine; webhook 立刻 200。
	agentUID := wukong.AgentUID(tenantID, ag.UUID)
	t.sendAgentReadReceiptSignal(ctx, tenantID, agentUID, ev.ChannelID, ev.ChannelType, conv.UUID, ev.MessageSeq)
	runInput := svcchat.RunAgentInput{
		AccountID:        callerAccountID,
		TenantID:         tenantID,
		Conversation:     conv,
		RoomUUID:         room.UUID,
		Agent:            ag,
		PromptText:       text,
		UserMessageUUID:  userOut.UserMessageUUID,
		InputMessageUUID: userOut.UserMessageUUID,
		ForceQueue:       true,
	}
	t.info(ctx, "wukong trigger: agent fired", "room_id", room.ID, "agent_uuid", ag.UUID,
		"message_id", ev.MessageID)
	go func() {
		bg, cancel := context.WithTimeout(context.WithoutCancel(ctx), wukongGroupAgentRunTimeout)
		defer cancel()
		out, rerr := d.chat.RunAgentForConversation(bg, runInput)
		if rerr != nil {
			t.warn(bg, "wukong trigger: RunAgentForConversation failed",
				"message_id", ev.MessageID, "agent_uuid", ag.UUID, "err", rerr.Error())
			return
		}
		disp := &wukongReplyDispatcher{
			logger:           d.logger,
			chat:             d.chat,
			sender:           d.sender,
			outbox:           d.outbox,
			outboxMaxRetries: d.outboxMaxRetries,
			source:           domwkoutbox.SourceGroupAgentReply,
			replyMentions:    humanReplyMention(acc),
		}
		disp.run(bg, out.StreamID, out.AgentMessageUUID, agentUID, ev.ChannelID, ev.ChannelType, callerAccountID, tenantID)
	}()
	return nil
}

func (t *wukongAgentTrigger) sendAgentReadReceiptSignal(ctx context.Context, tenantID int64, agentUID, channelID string, channelType int, conversationUUID string, messageSeq int64) {
	if t.d.readReceipt == nil || tenantID <= 0 || agentUID == "" || channelID == "" || channelType <= 0 || conversationUUID == "" || messageSeq <= 0 {
		return
	}
	payload, err := json.Marshal(map[string]any{
		"type":                  svcmessagereceipts.WKReadReceiptSignalContentType,
		"version":               1,
		"kind":                  "read_receipt.changed",
		"conversation_uuid":     conversationUUID,
		"last_read_message_seq": messageSeq,
		"reader_uid":            agentUID,
		"ts":                    time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		t.warn(ctx, "wukong trigger: marshal agent read receipt signal failed", "err", err.Error())
		return
	}
	if _, err := t.d.readReceipt.SendEphemeralNotification(ctx, agentUID, channelID, channelType, payload); err != nil {
		t.warn(ctx, "wukong trigger: send agent read receipt signal failed",
			"channel_id", channelID, "conversation_uuid", conversationUUID, "message_seq", messageSeq, "err", err.Error())
	}
}

// recordReject 写一条 decision=rejected 的 agent_trigger_log (best-effort; 幂等冲突忽略)。
// handleAgentDirect · ADR-0026 agent-direct webhook 最小闭环(仅 agentDirectEnabled=true 进入)。
// fail-closed classify → FromKind=human 才触发 RunAgentForConversation;agent self-echo / 防回环 ignore;
// agent final 经 outbox(source=agent_direct_agent_final)回投。**不走 group `@` selector**(单 agent 会话)。
// handleAgentDirect 是 webhook 的 agent-direct 分支:薄封装,复用与 attach endpoint **共享**的
// ensureAgentDirectRun(见 wukong_agent_direct_run.go),避免双实现竞态。webhook 把 resolve/visibility
// 类错误翻成「不触发」(return nil),account/agent/conv miss、trigger-tx、run 失败翻成 error(可重试)。
func (t *wukongAgentTrigger) handleAgentDirect(ctx context.Context, ev wukongwh.Event, tenantID int64) error {
	res, err := t.ensureAgentDirectRun(ctx, ensureAgentDirectRunInput{
		TenantID:  tenantID,
		ChannelID: ev.ChannelID,
		MessageID: ev.MessageID,
		Text:      ev.Text,
		Blocks:    ev.Blocks,
		FromUID:   ev.FromUID, // webhook:按 from_uid 分类 + 防回环。
	})
	if err != nil {
		switch {
		case errors.Is(err, wukong.ErrNotDirectChannel), errors.Is(err, wukong.ErrRoomNotFound):
			// 非 agent_direct room(含 human-human direct 无 agent participant)→ 不触发。
			t.info(ctx, "wukong agent_direct: not an agent_direct room; skip", "channel_id", ev.ChannelID)
			return nil
		case errors.Is(err, wukong.ErrTenantMismatch), errors.Is(err, wukong.ErrSenderNotInRoom):
			// tenant mismatch / sender 非 room participant → fail-closed,不触发。
			t.warn(ctx, "wukong agent_direct: resolve fail-closed; not fired",
				"channel_id", ev.ChannelID, "from_uid", ev.FromUID, "err", err.Error())
			return nil
		}
		// 可见性闸口(归一 forbidden)→ 不触发。
		if e, ok := apperr.AsError(err); ok && e.Code == apperr.Forbidden {
			t.warn(ctx, "wukong agent_direct: agent not visible / forbidden; not fired",
				"channel_id", ev.ChannelID, "err", err.Error())
			return nil
		}
		// account/agent/conv miss、trigger+shadow tx、run 失败 → 返回 error(webhook 可重试)。
		return fmt.Errorf("wukong agent_direct: %w", err)
	}
	switch res.Status {
	case adrStatusSkipped:
		t.info(ctx, "wukong agent_direct: non-human sender; ignore (anti-loop)", "channel_id", ev.ChannelID)
	case adrStatusStarted:
		t.info(ctx, "wukong agent_direct: agent fired", "room_id", res.RoomID, "agent_uuid", res.AgentUUID,
			"message_id", ev.MessageID)
	default: // attached / pending
		t.info(ctx, "wukong agent_direct: duplicate message_id; already running; skip",
			"message_id", ev.MessageID, "status", res.Status)
	}
	return nil
}

func (t *wukongAgentTrigger) handleAgentDirectAsync(ctx context.Context, ev wukongwh.Event, tenantID int64) {
	bg, cancel := context.WithTimeout(context.WithoutCancel(ctx), 6*time.Minute)
	go func() {
		defer cancel()
		if err := t.handleAgentDirect(bg, ev, tenantID); err != nil {
			t.warn(bg, "wukong trigger: not fired", "message_id", ev.MessageID,
				"channel_id", ev.ChannelID, "err", err.Error())
		}
	}()
}

func (t *wukongAgentTrigger) recordReject(ctx context.Context, tenantID, roomID int64, msgID string, accountID, agentID *int64, reason string) {
	_, err := t.d.triggers.Insert(ctx, repoagenttrigger.Entry{
		TenantID:        tenantID,
		RoomID:          roomID,
		Substrate:       repoagenttrigger.SubstrateWuKong,
		SenderAccountID: accountID,
		AgentID:         agentID,
		IMMessageID:     msgID,
		Decision:        repoagenttrigger.DecisionRejected,
		RejectReason:    reason,
	})
	if err != nil && !errors.Is(err, repoagenttrigger.ErrDuplicate) {
		t.warn(ctx, "wukong trigger: record reject failed", "reason", reason, "err", err)
	}
}

// wukongReplyDispatcher 订阅 chat stream, 终态 completed/awaiting_user 后把结构化 final payload
// (WKAgentFinalContentType=111: markdown content + EMP blocks + stream/agent_message 元数据)
// 以 AgentUID 发回 WuKong channel(group / agent-direct 同构)。
// failed 终态也回投一条 111 + 安全失败文案 markdown block,避免用户看到"已读但无回复"。
type wukongReplyDispatcher struct {
	logger           *logpkg.Logger
	chat             wkChatRunner
	sender           wkMessageSender
	outbox           wukongOutboxEnqueuer // 非 nil → enqueue outbox 可靠投递; nil → 直接 SendMessage
	outboxMaxRetries int                  // <=0 → service/repo 默认 10
	// source 决定 outbox source + dedup_key 前缀:group_agent_reply(群)/ agent_direct_agent_final(agent-direct)。
	source        string
	replyMentions []wukongwh.Mention // 仅群聊触发回复设置；agent-direct / 主动消息保持空。
}

func (d *wukongReplyDispatcher) run(ctx context.Context, streamID, agentMsgUUID, agentUID, channelID string, channelType int, accountID, tenantID int64) {
	ch, sub, err := d.chat.SubscribeWithOwner(ctx, accountID, tenantID, streamID)
	if err != nil {
		if d.logger != nil {
			d.logger.Warn(ctx, "wukong dispatch: subscribe failed", "stream_id", streamID, "err", err)
		}
		return
	}
	d.consumeSubscribed(ctx, streamID, agentMsgUUID, agentUID, channelID, channelType, tenantID, ch, sub)
}

func (d *wukongReplyDispatcher) consumeSubscribed(ctx context.Context, streamID, agentMsgUUID, agentUID, channelID string, channelType int, tenantID int64, ch <-chan svcchat.StreamEvent, sub func()) {
	defer sub()
	var lastBlocks []map[string]any
	for {
		select {
		case <-ctx.Done():
			return
		case ev, ok := <-ch:
			if !ok {
				return
			}
			if len(ev.Blocks) > 0 {
				lastBlocks = ev.Blocks
			}
			if !ev.IsTerminal() {
				continue
			}
			if ev.Kind == svcchat.EventMessageFailed {
				if d.logger != nil {
					d.logger.Warn(ctx, "wukong dispatch: agent reply failed; sending safe failure message",
						"stream_id", streamID, "kind", ev.Kind, "msg_uuid", agentMsgUUID,
						"error_code", ev.ErrorCode, "safe_error_message", wukongAgentFailureText(ev.ErrorCode, ev.ErrorMessage))
				}
				d.sendBack(ctx, streamID, agentUID, channelID, channelType, agentMsgUUID, tenantID, "failed", wukongAgentFailureBlocks(ev))
				return
			}
			if ev.Kind == svcchat.EventMessageAwaitingUser {
				if d.logger != nil {
					d.logger.Info(ctx, "wukong dispatch: agent awaiting_user reply sent as structured final",
						"stream_id", streamID, "kind", ev.Kind, "msg_uuid", agentMsgUUID)
				}
				d.sendBack(ctx, streamID, agentUID, channelID, channelType, agentMsgUUID, tenantID, "awaiting_user", lastBlocks)
				return
			}
			if ev.Kind != svcchat.EventMessageCompleted {
				if d.logger != nil {
					d.logger.Info(ctx, "wukong dispatch: terminal non-completed; skip send",
						"stream_id", streamID, "kind", ev.Kind, "msg_uuid", agentMsgUUID)
				}
				return
			}
			d.sendBack(ctx, streamID, agentUID, channelID, channelType, agentMsgUUID, tenantID, "final", lastBlocks)
			return
		}
	}
}

func (d *wukongReplyDispatcher) sendBack(ctx context.Context, streamID, agentUID, channelID string, channelType int, agentMsgUUID string, tenantID int64, agentMessageStatus string, blocks []map[string]any) {
	text := strings.TrimSpace(messageblocks.ReadableText(blocks))
	if text == "" {
		if d.logger != nil {
			d.logger.Info(ctx, "wukong dispatch: empty final blocks; skip", "msg_uuid", agentMsgUUID)
		}
		return
	}

	// 方案 B 门控:outbox 注入(WuKong.Enabled && wukong_send_outbox_enabled)→ enqueue 可靠投递;
	// 否则(默认)走原直接 SendMessage,行为不变。
	source := d.source
	if source == "" {
		source = domwkoutbox.SourceGroupAgentReply
	}
	msgType, payload := buildWuKongAgentReplyPayload(streamID, agentMsgUUID, agentMessageStatus, text, blocks, d.replyMentions...)
	if d.outbox != nil {
		// dedup_key 稳定且唯一:source 前缀 + agentMessageUUID(全局唯一)→ 同一条 final reply 重复触发只入队一行。
		// group:`group_agent_reply:...`;agent-direct:`agent_direct_agent_final:...`。
		dedupKey := fmt.Sprintf("%s:%d:%s:%s", source, tenantID, channelID, agentMsgUUID)
		_, inserted, eerr := d.outbox.EnqueueWuKongMessage(ctx, svcwkoutbox.EnqueueParams{
			TenantID:    strconv.FormatInt(tenantID, 10),
			ChannelID:   channelID,
			ChannelType: channelType,
			FromUID:     agentUID,
			MsgType:     msgType,
			Payload:     payload,
			DedupKey:    dedupKey,
			Source:      source,
			MaxRetries:  d.outboxMaxRetries, // <=0 → service/repo 默认 10
		})
		if eerr == nil {
			if d.logger != nil {
				if inserted {
					d.logger.Info(ctx, "wukong dispatch: agent reply enqueued to outbox",
						"msg_uuid", agentMsgUUID, "channel_id", channelID, "from_uid", agentUID,
						"dedup_key", dedupKey, "bytes", len(payload))
				} else {
					// inserted=false = 同一 final reply 已入队(重复触发),不再发送。
					d.logger.Info(ctx, "wukong dispatch: agent reply already enqueued (duplicate); skip",
						"msg_uuid", agentMsgUUID, "channel_id", channelID, "dedup_key", dedupKey)
				}
			}
			return
		}
		// enqueue 失败:不静默吞——warn + fallback 直接 SendMessage(兼容未迁移 / DB 异常环境)。
		if d.logger != nil {
			d.logger.Warn(ctx, "wukong dispatch: outbox enqueue failed; fallback direct send",
				"msg_uuid", agentMsgUUID, "channel_id", channelID, "dedup_key", dedupKey,
				"err", eerr, "fallback_direct_send", true)
		}
		// 落到下面的直接 SendMessage。
	}

	msgID, err := d.sender.SendMessage(ctx, agentUID, channelID, channelType, payload)
	if err != nil {
		if d.logger != nil {
			d.logger.Warn(ctx, "wukong dispatch: SendMessage failed",
				"msg_uuid", agentMsgUUID, "channel_id", channelID, "err", err)
		}
		return
	}
	if d.logger != nil {
		// 可观测: 日志记录回投的 WuKong message_id 与本地 agent message uuid。
		d.logger.Info(ctx, "wukong dispatch: agent reply sent to WuKong group",
			"msg_uuid", agentMsgUUID, "channel_id", channelID, "from_uid", agentUID,
			"wukong_message_id", msgID, "bytes", len(payload))
	}
}

func wukongAgentFailureBlocks(ev svcchat.StreamEvent) []map[string]any {
	return []map[string]any{{
		"type": "markdown",
		"text": wukongAgentFailureText(ev.ErrorCode, ev.ErrorMessage),
	}}
}

func wukongAgentFailureText(code, msg string) string {
	code = strings.TrimSpace(code)
	msg = strings.TrimSpace(msg)
	switch {
	case code == svcchat.ErrCodeRuntimeWarming:
		return "数字员工正在准备中，请稍后重试。"
	case code == "model.not_allowed" || strings.Contains(msg, "模型不被允许"):
		return "数字员工暂时无法回复：当前模型未授权，请联系管理员检查模型授权。"
	case code == "model.key_missing" || strings.Contains(msg, "API Key 未配置"):
		return "数字员工暂时无法回复：模型 API Key 未配置，请联系管理员检查模型网关配置。"
	default:
		return "数字员工暂时无法回复，请稍后再试。"
	}
}

// buildWuKongAgentReplyPayload 构造 agent final 的 WuKong 结构化消息(type=111,group 与
// agent-direct 同构):content/summary 是可读预览文本(ReadableText/截断摘要),blocks 是客户端
// markdown/EMP 渲染权威。failed 终态复用同构 payload(blocks=安全失败文案 markdown block)。
// 2026-07 起群聊不再压平成 type=1 纯文本(契约见 client-contract「WuKong 群 @数字员工」)。
func buildWuKongAgentReplyPayload(streamID, agentMsgUUID, agentMessageStatus, text string, blocks []map[string]any, mentions ...wukongwh.Mention) (int, []byte) {
	body := map[string]any{
		"type":                 wukongwh.WKAgentFinalContentType,
		"version":              1,
		"format":               "markdown",
		"content":              text,
		"summary":              summarizeAgentFinal(text),
		"blocks":               blocks,
		"stream_id":            streamID,
		"agent_message_uuid":   agentMsgUUID,
		"agent_message_status": agentMessageStatus,
	}
	if len(mentions) > 0 {
		body["mentions"] = mentions
	}
	payload, _ := json.Marshal(body)
	return wukongwh.WKAgentFinalContentType, payload
}

func humanReplyMention(acc *domaccount.Account) []wukongwh.Mention {
	if acc == nil || strings.TrimSpace(acc.UUID) == "" {
		return nil
	}
	name := strings.TrimSpace(acc.DisplayName)
	if name == "" {
		name = strings.TrimSpace(acc.Username)
	}
	return []wukongwh.Mention{{Type: "human", ID: acc.UUID, Name: name}}
}

func summarizeAgentFinal(text string) string {
	const maxRunes = 80
	rs := []rune(strings.TrimSpace(text))
	if len(rs) <= maxRunes {
		return string(rs)
	}
	return string(rs[:maxRunes]) + "..."
}

// parseNamespacedID 解析 t_{tenant}_{kind}_{rest}; rest 为 uuid/hash (不含下划线)。
func parseNamespacedID(id string) (tenantID int64, kind string, rest string, ok bool) {
	if !strings.HasPrefix(id, "t_") {
		return 0, "", "", false
	}
	body := id[2:]
	i := strings.IndexByte(body, '_')
	if i <= 0 {
		return 0, "", "", false
	}
	t, err := parseInt64(body[:i])
	if err != nil {
		return 0, "", "", false
	}
	body = body[i+1:]
	j := strings.IndexByte(body, '_')
	if j <= 0 {
		return 0, "", "", false
	}
	kind = body[:j]
	rest = body[j+1:]
	if rest == "" {
		return 0, "", "", false
	}
	return t, kind, rest, true
}

// parseSenderID 是 parseNamespacedID 的别名语义包装 (sender uid)。
func parseSenderID(uid string) (tenantID int64, kind string, id string, ok bool) {
	return parseNamespacedID(uid)
}

// mentionPresent 判断文本是否含 @mention token。复用 chat speaker 的 mention 正则
// (P3-4: 不再 strings.Contains("@"); email a@b 不算)。
func mentionPresent(text string) bool {
	return svcchat.HasMentionToken(text)
}

// agentMentionsOf 过滤出 type=agent 的结构化 mention。
func agentMentionsOf(ms []wukongwh.Mention) []wukongwh.Mention {
	out := make([]wukongwh.Mention, 0, len(ms))
	for _, m := range ms {
		if m.Type == "agent" {
			out = append(out, m)
		}
	}
	return out
}

// agentMatchResult 是 matchAgentMentions 的结果, 供上层区分 mention_no_match 与 selector_reject。
type agentMatchResult struct {
	selected  []int64 // 命中的 agent 内部 id (去重, 保留首次出现顺序)
	ambiguous bool    // name 兜底命中多个同名候选 → selector_reject (不能取第一个)
	unmatched bool    // 有 agent mention 但未命中 (id 非空不在群内 / name 0 命中) → mention_no_match
}

func roomHumanIsActive(parts []domroom.Participant, accountID int64) bool {
	for _, p := range parts {
		if p.Kind == domroom.ParticipantHuman && p.AccountID != nil &&
			*p.AccountID == accountID && p.LeftAt == nil {
			return true
		}
	}
	return false
}

func buildSpeakerCandidatesFromParts(ctx context.Context, agents wkAgents, parts []domroom.Participant) []svcchat.SpeakerCandidate {
	if agents == nil {
		return nil
	}
	out := make([]svcchat.SpeakerCandidate, 0)
	for _, p := range parts {
		if p.Kind != domroom.ParticipantAgent || p.AgentID == nil || p.LeftAt != nil {
			continue
		}
		ag, err := agents.GetByID(ctx, *p.AgentID)
		if err != nil || ag == nil {
			continue
		}
		out = append(out, svcchat.SpeakerCandidate{
			AgentID:   ag.ID,
			AgentUUID: ag.UUID,
			AgentName: ag.Name,
		})
	}
	return out
}

// matchAgentMentions 把 type=agent 的 mention 匹配到群内候选。结构化 mention 的 id 是**权威**字段:
//   - mention.ID 非空: **只**按 id 匹配; 不在群内 → 视为 no match, **不**再按 name 兜底
//     (避免 id=ghost,name=陈启航 误触群内陈启航)。
//   - mention.ID 为空: 才允许 name 兜底; name 命中 0 → no match; 命中 1 → 选中; 命中多个(重名)
//     → ambiguous(交上层 selector_reject, 不取第一个)。
func matchAgentMentions(agentMentions []wukongwh.Mention, candidates []svcchat.SpeakerCandidate) agentMatchResult {
	out := make([]int64, 0, 1)
	seen := map[int64]bool{}
	add := func(id int64) {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	res := agentMatchResult{}
	for _, m := range agentMentions {
		id := strings.ToLower(strings.TrimSpace(m.ID))
		name := strings.TrimSpace(m.Name)
		if id != "" {
			// id 权威: 只按 id 匹配, 不命中即 no match (不 name 兜底)。
			found := false
			for _, c := range candidates {
				if strings.ToLower(c.AgentUUID) == id {
					add(c.AgentID)
					found = true
					break
				}
			}
			if !found {
				res.unmatched = true
			}
			continue
		}
		if name == "" {
			continue // 无可用身份, 跳过
		}
		// id 空 → name 兜底: 统计同名候选数。
		matches := make([]int64, 0, 1)
		for _, c := range candidates {
			if strings.EqualFold(c.AgentName, name) {
				matches = append(matches, c.AgentID)
			}
		}
		switch len(matches) {
		case 0:
			res.unmatched = true
		case 1:
			add(matches[0])
		default:
			res.ambiguous = true // 重名歧义 → selector_reject
		}
	}
	res.selected = out
	return res
}

func parseInt64(s string) (int64, error) {
	var n int64
	if s == "" {
		return 0, errors.New("empty")
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("non-digit %q", s)
		}
		n = n*10 + int64(c-'0')
	}
	return n, nil
}
