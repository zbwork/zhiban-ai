package wukongagent

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"

	"github.com/google/uuid"
	domlocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	domwkoutbox "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/wukongoutbox"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/im/wukong"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	reporoom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/room"
	svcchat "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/wukongwh"
)

type localGroupRuntime interface {
	ResolveDesktop(context.Context, domlocal.Scope, string) (*domlocal.Device, error)
	DefaultModel(context.Context, domlocal.Scope, int64) (string, error)
}

// SendLocalGroup keeps the existing IM channel and reply projection while carrying
// the sender's authenticated desktop identity separately from the IM payload.
func (t *Trigger) SendLocalGroup(ctx context.Context, tenantID, accountID int64, sessionID, deviceID, roomUUID, text string, mentions []wukongwh.Mention) (bool, error) {
	d := t.inner.d
	text = strings.TrimSpace(text)
	if text == "" || len(text) > 16000 || len(mentions) > 50 {
		return false, apperr.ErrInvalidParams
	}
	if _, err := uuid.Parse(deviceID); err != nil || sessionID == "" {
		return false, apperr.ErrForbidden
	}
	rm, err := d.rooms.GetByUUID(ctx, tenantID, roomUUID)
	if err != nil {
		return false, err
	}
	if rm.RoomKind != domroom.KindGroup || rm.Status != "active" || rm.WuKongChannelID == "" {
		return false, apperr.ErrForbidden
	}
	parts, err := d.rooms.ListParticipants(ctx, rm.ID)
	if err != nil {
		return false, err
	}
	if !roomHumanIsActive(parts, accountID) {
		return false, apperr.ErrForbidden
	}
	all, eligible := make([]svcchat.SpeakerCandidate, 0, len(parts)), make([]svcchat.SpeakerCandidate, 0, len(parts))
	unavailable := make(map[int64]bool)
	for _, p := range parts {
		if p.Kind != domroom.ParticipantAgent || p.AgentID == nil || p.LeftAt != nil {
			continue
		}
		agent, err := d.agents.GetByID(ctx, *p.AgentID)
		if err != nil || agent == nil {
			continue
		}
		if agent.ExecutionLocus != "local" {
			return false, nil
		}
		candidate := svcchat.SpeakerCandidate{AgentID: agent.ID, AgentUUID: agent.UUID, AgentName: agent.Name}
		all = append(all, candidate)
		if agent.Status != "published" || !agent.SupportsGroupChat || d.contacts.AssertAgentVisible(ctx, accountID, tenantID, agent.UUID) != nil {
			unavailable[agent.ID] = true
			continue
		}
		eligible = append(eligible, candidate)
	}
	if len(eligible) == 0 {
		return false, nil
	}
	switch rm.SpeakerPolicy {
	case domroom.PolicyManual, domroom.PolicyManager, domroom.PolicyRoundRobin:
	default:
		return false, apperr.New(apperr.PreconditionFailed, "该响应方式暂不支持本机员工群聊")
	}
	index := -1
	if n, ok := rm.SpeakerPolicyConfig["last_idx"].(float64); ok {
		index = int(n)
	}
	selectionText := text
	candidates := eligible
	if rm.SpeakerPolicy == domroom.PolicyRoundRobin {
		candidates = all
	}
	if rm.SpeakerPolicy == domroom.PolicyManual && len(mentions) > 0 {
		matched := matchAgentMentions(agentMentionsOf(mentions), all)
		if matched.unmatched || matched.ambiguous {
			return false, apperr.New(apperr.InvalidParams, "请选择群内的数字员工")
		}
		selectionText = ""
		for _, id := range matched.selected {
			for _, candidate := range candidates {
				if candidate.AgentID == id {
					selectionText += " @" + candidate.AgentUUID
					break
				}
			}
		}
	}
	sel, err := d.speaker.Select(ctx, svcchat.SelectInput{
		Policy: rm.SpeakerPolicy, PolicyConfig: rm.SpeakerPolicyConfig,
		ManagerAgentID: rm.ManagerAgentID, Candidates: candidates,
		UserMsgText: selectionText, RoomID: rm.ID, TenantID: tenantID,
		CreatedBy: &accountID, RoundRobinLastIdx: index, RoundRobinUnavailable: unavailable,
	})
	if err != nil {
		if rm.SpeakerPolicy != domroom.PolicyManual {
			return false, nil
		}
		return false, err
	}
	modelHint := ""
	if len(sel.Selected) > 0 {
		if t.local == nil {
			return false, nil
		}
		scope := domlocal.Scope{TenantID: tenantID, AccountID: accountID, SessionUUID: sessionID}
		device, err := t.local.ResolveDesktop(ctx, scope, deviceID)
		if err != nil || device == nil || device.Scope != scope || device.UUID != deviceID {
			return false, nil
		}
		modelHint, err = t.local.DefaultModel(ctx, scope, sel.Selected[0])
		if err != nil {
			return false, nil
		}
	}
	acc, err := d.accounts.(wkAccountByID).GetByID(ctx, accountID)
	if err != nil {
		return false, err
	}
	if len(sel.NextPolicyConfig) > 0 {
		err := d.rooms.(*reporoom.Repo).AdvanceLocalSpeaker(ctx, tenantID, rm.ID, rm.SpeakerPolicy, rm.SpeakerPolicyConfig, sel.NextPolicyConfig)
		if err != nil {
			return false, err
		}
	}
	channelType := rm.WuKongChannelType
	payload, err := json.Marshal(map[string]any{"type": 1, "content": text, "mentions": mentions})
	if err != nil {
		return false, err
	}
	messageID, err := d.sender.SendMessage(ctx, wukong.UserUID(tenantID, acc.UUID), rm.WuKongChannelID, channelType, payload)
	if err != nil {
		return false, err
	}
	if len(sel.Selected) == 0 {
		return true, nil
	}
	agent, err := d.agents.GetByID(ctx, sel.Selected[0])
	if err != nil {
		return true, err
	}
	convUUID, err := d.rooms.ConversationUUIDByRoomID(ctx, rm.ID)
	if err != nil {
		return true, err
	}
	conv, err := d.convs.GetByUUID(ctx, convUUID)
	if err != nil {
		return true, err
	}
	msgID := strconv.FormatInt(messageID, 10)
	shadow, err := d.rooms.SendUserMessageWithTriggerTx(ctx, reporoom.TriggerLogEntry{
		TenantID: tenantID, RoomID: rm.ID, Substrate: "wukong",
		IMMessageID: msgID, SenderAccountID: &accountID, AgentID: &agent.ID, Decision: "triggered",
	}, domroom.SendUserMessageInput{
		TenantID: tenantID, RoomID: rm.ID, CallerAccountID: accountID, ConversationID: conv.ID,
		SelectedAgentID: &agent.ID, Text: text,
		ExtraMetadata: map[string]any{
			"source": "local_group", "wukong_message_id": msgID, "speaker_policy": string(rm.SpeakerPolicy),
			"speaker_selected_reason": sel.SelectedReason, "speaker_latency_ms": sel.LatencyMs,
			"speaker_candidate_count": len(sel.Candidates),
		},
	})
	if err != nil {
		return true, err
	}
	go func() {
		bg, cancel := context.WithTimeout(context.WithoutCancel(ctx), wukongGroupAgentRunTimeout)
		defer cancel()
		out, err := d.chat.RunAgentForConversation(bg, svcchat.RunAgentInput{
			TenantID: tenantID, AccountID: accountID, RoomUUID: rm.UUID, Conversation: conv, Agent: agent,
			PromptText: text, InputMessageUUID: shadow.UserMessageUUID,
			LocalGroupSessionUUID: sessionID, LocalGroupDeviceUUID: deviceID, LocalGroupModelHint: modelHint,
		})
		if err != nil {
			t.inner.warn(bg, "local group run could not start", "room_id", rm.ID, "err", err.Error())
			return
		}
		dispatch := &wukongReplyDispatcher{
			logger: d.logger, chat: d.chat, sender: d.sender, outbox: d.outbox,
			source: domwkoutbox.SourceGroupAgentReply, replyMentions: humanReplyMention(acc),
		}
		dispatch.run(bg, out.StreamID, out.AgentMessageUUID, wukong.AgentUID(tenantID, agent.UUID), rm.WuKongChannelID, channelType, accountID, tenantID)
	}()
	return true, nil
}
