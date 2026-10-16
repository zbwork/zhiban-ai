package wukongagent

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	domwkoutbox "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/wukongoutbox"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	repoagenttrigger "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agenttrigger"
	reporoom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/room"
	svcchat "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
)

const (
	defaultAgentDirectWarmingRetryWindow   = 90 * time.Second
	defaultAgentDirectWarmingRetryInterval = 2 * time.Second
)

// ADR-0026 agent-direct stream attach:webhook 与 attach endpoint **共享**幂等真相,但**职责分离**:
//   - webhook(`ensureAgentDirectRun`)= **唯一 run 入口**:gate(`agent_trigger_log` 唯一索引,占位 status=starting)
//     赢 → detached run → 成功或可持久化失败都写 status=started+stream;仅失败消息也无法创建时写 status=failed;gate 冲突 → 读 run 状态机决定
//     attached / pending / 认领 failed 重跑。webhook 不等待 LLM/runtime,避免 WuKong 5s 超时取消请求 ctx。
//   - attach(`attachAgentDirectStream`)= **只读**:查 run 状态机返回 started/attached/pending/failed,
//     **绝不写、不 run、不占幂等键**(避免 attach 先到时用空 text 启动 Agent)。
//
// failed trigger 状态仅用于“正式失败消息也无法持久化”的基础设施故障；webhook 重投可认领重跑。
const (
	adrStatusStarted  = "started"  // 本次新建 run
	adrStatusAttached = "attached" // 命中既有 run,返回同一 stream
	adrStatusPending  = "pending"  // gate 占位 / run 启动中,stream 未回写,客户端稍后重试
	adrStatusFailed   = "failed"   // run 启动失败(非永久 pending),客户端可重发 / 等 webhook 重投自愈
	adrStatusSkipped  = "skipped"  // 非 human 发送方(webhook 防回环)→ 不 run
)

type ensureAgentDirectRunInput struct {
	TenantID  int64
	ChannelID string
	MessageID string
	Text      string // webhook 用真实 payload text 启动 run;attach 不用(不传)。
	Blocks    []map[string]any
	// FromUID:webhook 传 ev.FromUID(分类 + 防回环);attach 传 ""(由 CallerAccountID 确认 human)。
	FromUID string
	// CallerAccountID:attach 传 authed account(>0 → 校验 == 解析出的 human participant);webhook 传 0。
	CallerAccountID int64
	// ExpectedConversationUUID:attach 传 client 的 conversation_uuid(非空则交叉校验);webhook 传 ""。
	ExpectedConversationUUID string
}

type ensureAgentDirectRunResult struct {
	Status           string
	StreamID         string
	AgentMessageUUID string
	ConversationUUID string
	RoomID           int64
	AgentUUID        string
}

// adResolved = resolve + 鉴权(可见性)+ conversation 的结果。skip=true → webhook 非 human(防回环)。
type adResolved struct {
	target          *wukong.AgentDirectTarget
	agent           *domagent.DigitalEmployee
	conv            *domconv.Conversation
	callerAccountID int64
	skip            bool
}

// resolveAgentDirect 两路共用:webhook 按 from_uid 分类(非 human → skip),attach 按 channel + caller 校验;
// 再做 conversation 交叉校验 + account/agent/可见性/conversation。错误由调用方按场景翻译。
func (t *wukongAgentTrigger) resolveAgentDirect(ctx context.Context, in ensureAgentDirectRunInput) (*adResolved, error) {
	d := t.d
	if in.TenantID <= 0 || in.ChannelID == "" || in.MessageID == "" {
		return nil, fmt.Errorf("agent_direct: tenant/channel/message required")
	}
	var target *wukong.AgentDirectTarget
	if in.FromUID != "" {
		tg, err := wukong.ResolveAgentDirectWebhookTarget(ctx, d.agentDirectLookup, in.TenantID, in.ChannelID, in.FromUID)
		if err != nil {
			return nil, err
		}
		if tg.FromKind != wukong.FromKindHuman {
			return &adResolved{target: tg, skip: true}, nil
		}
		target = tg
	} else {
		tg, err := t.resolveAgentDirectForCaller(ctx, in.TenantID, in.ChannelID, in.CallerAccountID)
		if err != nil {
			return nil, err
		}
		target = tg
	}
	if in.ExpectedConversationUUID != "" && in.ExpectedConversationUUID != target.ConversationUUID {
		return nil, apperr.ErrForbidden.Withf("agent_direct: conversation mismatch")
	}
	acc, err := d.accounts.GetByUUID(ctx, target.AccountUUID)
	if err != nil || acc == nil {
		return nil, fmt.Errorf("agent_direct: account %q miss: %w", target.AccountUUID, err)
	}
	ag, err := d.agents.GetByUUID(ctx, target.AgentUUID)
	if err != nil || ag == nil {
		return nil, fmt.Errorf("agent_direct: agent %q miss: %w", target.AgentUUID, err)
	}
	if d.contacts != nil {
		if verr := d.contacts.AssertAgentVisible(ctx, acc.ID, in.TenantID, ag.UUID); verr != nil {
			return nil, apperr.ErrForbidden.Withf("agent not accessible")
		}
	}
	conv, err := d.convs.GetByUUID(ctx, target.ConversationUUID)
	if err != nil || conv == nil {
		return nil, fmt.Errorf("agent_direct: conv %q miss: %w", target.ConversationUUID, err)
	}
	return &adResolved{target: target, agent: ag, conv: conv, callerAccountID: acc.ID}, nil
}

// ensureAgentDirectRun 是 webhook 分支:gate → run / duplicate→重试。仅 webhook 调用(可启动/重试 run)。
func (t *wukongAgentTrigger) ensureAgentDirectRun(ctx context.Context, in ensureAgentDirectRunInput) (*ensureAgentDirectRunResult, error) {
	d := t.d
	r, err := t.resolveAgentDirect(ctx, in)
	if err != nil {
		return nil, err
	}
	if r.skip {
		return &ensureAgentDirectRunResult{Status: adrStatusSkipped, ConversationUUID: r.target.ConversationUUID, RoomID: r.target.RoomID, AgentUUID: r.target.AgentUUID}, nil
	}
	substrate := repoagenttrigger.SubstrateWuKong
	// gate:trigger_log(status=starting)+ shadow 原子写。命中唯一索引 = duplicate。
	userOut, terr := d.rooms.SendUserMessageWithTriggerTx(ctx,
		reporoom.TriggerLogEntry{
			TenantID:        in.TenantID,
			RoomID:          r.target.RoomID,
			Substrate:       substrate,
			SenderAccountID: &r.callerAccountID,
			AgentID:         &r.agent.ID,
			IMMessageID:     in.MessageID,
			Decision:        repoagenttrigger.DecisionTriggered,
		},
		domroom.SendUserMessageInput{
			TenantID:        in.TenantID,
			RoomID:          r.target.RoomID,
			CallerAccountID: r.callerAccountID,
			ConversationID:  r.conv.ID,
			SelectedAgentID: &r.agent.ID,
			Text:            in.Text,
			Blocks:          in.Blocks,
			FileUUIDs:       fileUUIDsFromBlocks(in.Blocks),
			Mentions:        []string{r.agent.UUID},
			ExtraMetadata: map[string]any{
				"source":            "agent_direct_wukong",
				"wukong_message_id": in.MessageID,
				"wukong_channel_id": in.ChannelID,
			},
		})
	if terr != nil {
		if errors.Is(terr, reporoom.ErrTriggerDuplicate) {
			return t.resolveDuplicateRun(ctx, in, r, true /*allowRetry: webhook 可认领 failed 重跑*/)
		}
		return nil, terr
	}
	// gate 赢(首次)→ detached run + 写状态机 + 起 dispatcher。
	return t.startRunAndAnchor(ctx, in, r, userOut.UserMessageUUID)
}

// attachAgentDirectStream 是 attach 分支:**只读**查 run 状态机,绝不写 / 不 run / 不占幂等键。
func (t *wukongAgentTrigger) attachAgentDirectStream(ctx context.Context, in ensureAgentDirectRunInput) (*ensureAgentDirectRunResult, error) {
	d := t.d
	r, err := t.resolveAgentDirect(ctx, in)
	if err != nil {
		return nil, err
	}
	// attach 调用方是 authed human(resolveAgentDirectForCaller 已校验),不会 skip。
	substrate := repoagenttrigger.SubstrateWuKong
	sid, amu, status, found, gerr := d.rooms.GetAgentDirectRunAnchor(ctx, in.TenantID, r.target.RoomID, substrate, in.MessageID)
	if gerr != nil {
		return nil, gerr
	}
	res := &ensureAgentDirectRunResult{ConversationUUID: r.target.ConversationUUID, RoomID: r.target.RoomID, AgentUUID: r.agent.UUID}
	if !found {
		// webhook 尚未建 run → pending(客户端按 retry_after_ms 重试)。
		res.Status = adrStatusPending
		return res, nil
	}
	switch status {
	case reporoom.WuKongRunStatusStarted:
		if sid != "" {
			res.Status, res.StreamID, res.AgentMessageUUID = adrStatusAttached, sid, amu
		} else {
			res.Status = adrStatusPending // started 但 stream 空(理论不该)→ 让客户端重试
		}
	case reporoom.WuKongRunStatusFailed:
		res.Status = adrStatusFailed
	default: // starting
		res.Status = adrStatusPending
	}
	return res, nil
}

// resolveDuplicateRun 处理 webhook gate 冲突:按 run 状态机决定 attached / pending / 认领 failed 重跑。
// allowRetry=true(webhook)→ failed 可认领重跑;attach 不走此路径(只读)。
func (t *wukongAgentTrigger) resolveDuplicateRun(ctx context.Context, in ensureAgentDirectRunInput, r *adResolved, allowRetry bool) (*ensureAgentDirectRunResult, error) {
	d := t.d
	substrate := repoagenttrigger.SubstrateWuKong
	sid, amu, status, found, gerr := d.rooms.GetAgentDirectRunAnchor(ctx, in.TenantID, r.target.RoomID, substrate, in.MessageID)
	if gerr != nil {
		return nil, gerr
	}
	res := &ensureAgentDirectRunResult{ConversationUUID: r.target.ConversationUUID, RoomID: r.target.RoomID, AgentUUID: r.agent.UUID}
	if !found {
		res.Status = adrStatusPending // 防御(gate dup 理应有行)
		return res, nil
	}
	switch status {
	case reporoom.WuKongRunStatusStarted:
		if sid != "" {
			res.Status, res.StreamID, res.AgentMessageUUID = adrStatusAttached, sid, amu
			return res, nil
		}
		res.Status = adrStatusPending
		return res, nil
	case reporoom.WuKongRunStatusFailed:
		if allowRetry {
			claimed, cerr := d.rooms.ClaimAgentDirectRunRetry(ctx, in.TenantID, r.target.RoomID, substrate, in.MessageID)
			if cerr != nil {
				return nil, cerr
			}
			if claimed {
				return t.startRunAndAnchor(ctx, in, r, "") // 认领成功 → detached 重跑
			}
			res.Status = adrStatusPending // 另一投递认领中
			return res, nil
		}
		res.Status = adrStatusFailed
		return res, nil
	default: // starting
		res.Status = adrStatusPending
		return res, nil
	}
}

// startRunAndAnchor 在 webhook 请求外启动 Agent run,并立即返回 started/pending 语义。
//
// 关键:不能同步等待 RunAgentForConversation。WuKong webhook 客户端约 5s 超时,
// 同步等待会在 run/anchor 途中触发 request context canceled,导致客户端 attach-stream
// 一直 pending。
func (t *wukongAgentTrigger) startRunAndAnchor(ctx context.Context, in ensureAgentDirectRunInput, r *adResolved, inputMessageUUID string) (*ensureAgentDirectRunResult, error) {
	bg, cancel := context.WithTimeout(context.WithoutCancel(ctx), 6*time.Minute)
	go t.runAndAnchor(bg, cancel, in, r, inputMessageUUID)
	return &ensureAgentDirectRunResult{
		Status:           adrStatusStarted,
		ConversationUUID: r.target.ConversationUUID,
		RoomID:           r.target.RoomID,
		AgentUUID:        r.agent.UUID,
	}, nil
}

// runAndAnchor 起 run；成功或正式失败消息创建成功都写 status=started+stream 并起 dispatcher。
// 只有失败消息本身也无法持久化时才写 trigger status=failed。
func (t *wukongAgentTrigger) runAndAnchor(ctx context.Context, cancel context.CancelFunc, in ensureAgentDirectRunInput, r *adResolved, inputMessageUUID string) {
	d := t.d
	substrate := repoagenttrigger.SubstrateWuKong
	agentUID := wukong.AgentUID(in.TenantID, r.agent.UUID)
	runInput := svcchat.RunAgentInput{
		AccountID:        r.callerAccountID,
		TenantID:         in.TenantID,
		Conversation:     r.conv,
		RoomUUID:         "", // single-chat 语义。
		Agent:            r.agent,
		PromptText:       in.Text,
		SkillSlugs:       skillSlugsFromBlocks(in.Blocks),
		InputMessageUUID: inputMessageUUID,
	}
	retryWindow := d.agentDirectWarmingRetryWindow
	if retryWindow <= 0 {
		retryWindow = defaultAgentDirectWarmingRetryWindow
	}
	retryInterval := d.agentDirectWarmingRetryInterval
	if retryInterval <= 0 {
		retryInterval = defaultAgentDirectWarmingRetryInterval
	}
	deadline := time.Now().Add(retryWindow)
	runOut, rerr := d.chat.RunAgentForConversation(ctx, runInput)
	for rerr != nil && isAgentDirectRuntimeWarming(rerr) && time.Now().Before(deadline) {
		wait := retryInterval
		if remaining := time.Until(deadline); remaining < wait {
			wait = remaining
		}
		if wait <= 0 {
			break
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			rerr = ctx.Err()
		case <-timer.C:
			runOut, rerr = d.chat.RunAgentForConversation(ctx, runInput)
		}
	}
	if rerr != nil {
		// 用户消息已经进入 WuKong 时间线：最终启动失败也必须创建正式 failed Agent
		// message + stream，后续 dispatcher 会按 type=111 回投安全失败文案。
		failedInput := runInput
		failedInput.StartFailureCause = rerr
		var persistErr error
		runOut, persistErr = d.chat.RunAgentForConversation(ctx, failedInput)
		if persistErr != nil {
			// 只有失败消息本身也无法持久化时，才退回旧 trigger failed 状态供重投自愈。
			writeCtx, writeCancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
			if serr := d.rooms.SetAgentDirectRunFailed(writeCtx, in.TenantID, r.target.RoomID, substrate, in.MessageID, "failed reply persistence unavailable"); serr != nil {
				t.warn(writeCtx, "wukong agent_direct: mark run failed failed", "message_id", in.MessageID, "err", serr.Error())
			}
			writeCancel()
			cancel()
			t.warn(ctx, "wukong agent_direct: persist failed reply failed", "message_id", in.MessageID, "err", persistErr.Error())
			return
		}
		t.warn(ctx, "wukong agent_direct: run start failed; persisted failed reply", "message_id", in.MessageID, "err", rerr.Error())
	}
	writeCtx, writeCancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	if serr := d.rooms.SetAgentDirectRunAnchor(writeCtx, in.TenantID, r.target.RoomID, substrate, in.MessageID, runOut.StreamID, runOut.AgentMessageUUID); serr != nil {
		t.warn(writeCtx, "wukong agent_direct: set run anchor failed (duplicate 将 pending 重试)", "message_id", in.MessageID, "err", serr.Error())
	}
	writeCancel()
	go func() {
		defer cancel()
		disp := &wukongReplyDispatcher{
			logger: d.logger, chat: d.chat, sender: d.sender,
			outbox: d.outbox, outboxMaxRetries: d.outboxMaxRetries,
			source: domwkoutbox.SourceAgentDirectAgentFinal,
		}
		if d.outbox == nil {
			t.warn(ctx, "wukong agent_direct: outbox disabled; final 走 direct send fallback", "message_id", in.MessageID)
		}
		disp.run(ctx, runOut.StreamID, runOut.AgentMessageUUID, agentUID, r.target.ChannelID, r.target.ChannelType, r.callerAccountID, in.TenantID)
	}()
}

func isAgentDirectRuntimeWarming(err error) bool {
	if err == nil {
		return false
	}
	if appErr, ok := apperr.AsError(err); ok && appErr.Message == svcchat.ErrCodeRuntimeWarming {
		return true
	}
	return strings.Contains(err.Error(), svcchat.ErrCodeRuntimeWarming)
}

func skillSlugsFromBlocks(blocks []map[string]any) []string {
	if len(blocks) == 0 {
		return nil
	}
	out := make([]string, 0, len(blocks))
	seen := make(map[string]struct{}, len(blocks))
	for _, b := range blocks {
		kind := strings.TrimSpace(blockStringField(b, "type"))
		if kind == "" {
			kind = strings.TrimSpace(blockStringField(b, "kind"))
		}
		if !strings.EqualFold(kind, "skill") {
			continue
		}
		slug := strings.TrimSpace(blockStringField(b, "slug"))
		if slug == "" {
			continue
		}
		if _, ok := seen[slug]; ok {
			continue
		}
		seen[slug] = struct{}{}
		out = append(out, slug)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func fileUUIDsFromBlocks(blocks []map[string]any) []string {
	if len(blocks) == 0 {
		return nil
	}
	out := make([]string, 0, len(blocks))
	seen := make(map[string]struct{}, len(blocks))
	for _, b := range blocks {
		kind := strings.TrimSpace(blockStringField(b, "type"))
		if kind == "" {
			kind = strings.TrimSpace(blockStringField(b, "kind"))
		}
		if !strings.EqualFold(kind, "file") && !strings.EqualFold(kind, "image") {
			continue
		}
		uuid := strings.TrimSpace(blockStringField(b, "file_uuid"))
		if uuid == "" {
			continue
		}
		if _, ok := seen[uuid]; ok {
			continue
		}
		seen[uuid] = struct{}{}
		out = append(out, uuid)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func blockStringField(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprint(v)
}

// resolveAgentDirectForCaller 为 attach 路径解析 human-agent room:caller 已是 authed human,
// 按 channel 解析 room 并校验 caller==human participant(fail-closed)。返回与 webhook 同形态 target。
func (t *wukongAgentTrigger) resolveAgentDirectForCaller(ctx context.Context, tenantID int64, channelID string, callerAccountID int64) (*wukong.AgentDirectTarget, error) {
	d := t.d
	if callerAccountID <= 0 {
		return nil, apperr.ErrForbidden.Withf("agent_direct attach: caller required")
	}
	pt, kind, _, ok := wukong.ParseNamespacedID(channelID)
	if !ok || kind != "d" {
		return nil, wukong.ErrNotDirectChannel
	}
	if pt != tenantID {
		return nil, wukong.ErrTenantMismatch
	}
	if d.agentDirectLookup == nil {
		return nil, wukong.ErrRoomNotFound
	}
	room, found, err := d.agentDirectLookup.FindAgentDirectByChannel(ctx, tenantID, channelID)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, wukong.ErrRoomNotFound
	}
	humanAcc, err := d.accounts.GetByUUID(ctx, room.HumanAccountUUID)
	if err != nil || humanAcc == nil {
		return nil, fmt.Errorf("agent_direct attach: human %q miss: %w", room.HumanAccountUUID, err)
	}
	if humanAcc.ID != callerAccountID {
		return nil, wukong.ErrSenderNotInRoom
	}
	return &wukong.AgentDirectTarget{
		TenantID:         tenantID,
		AccountUUID:      room.HumanAccountUUID,
		AgentUUID:        room.AgentUUID,
		ConversationUUID: room.ConversationUUID,
		RoomID:           room.RoomID,
		ChannelID:        channelID,
		ChannelType:      wukong.ChannelTypeGroup,
		FromKind:         wukong.FromKindHuman,
		FromUUID:         room.HumanAccountUUID,
	}, nil
}
