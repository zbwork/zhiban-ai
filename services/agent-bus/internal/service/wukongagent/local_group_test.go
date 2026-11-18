package wukongagent

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"

	"github.com/google/uuid"
	domaccount "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/account"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcchat "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/transport/http/wukongwh"
)

func TestLocalGroupDeliversTextWithoutInvokingUnavailableAgents(t *testing.T) {
	ctx := context.Background()
	liveID, hiddenID, archivedID := int64(10), int64(11), int64(12)
	rooms := groupTestRooms{
		room: &domroom.Room{RoomKind: domroom.KindGroup, Status: "active", WuKongChannelID: "group", SpeakerPolicy: domroom.PolicyManual},
		parts: []domroom.Participant{
			{Kind: domroom.ParticipantHuman, AccountID: &liveID},
			{Kind: domroom.ParticipantAgent, AgentID: &liveID},
			{Kind: domroom.ParticipantAgent, AgentID: &hiddenID},
			{Kind: domroom.ParticipantAgent, AgentID: &archivedID},
		},
	}
	agents := groupTestAgents{agents: map[int64]*domagent.DigitalEmployee{
		liveID:     {ID: liveID, UUID: "live", Name: "可用员工", Status: "published", ExecutionLocus: "local", SupportsGroupChat: true},
		hiddenID:   {ID: hiddenID, UUID: "hidden", Name: "隐藏员工", Status: "published", ExecutionLocus: "local", SupportsGroupChat: true},
		archivedID: {ID: archivedID, UUID: "archived", Name: "已下架员工", Status: "archived", ExecutionLocus: "local", SupportsGroupChat: true},
	}}
	sender := &groupTestSender{}
	tr := &Trigger{inner: &wukongAgentTrigger{d: wukongAgentTriggerDeps{
		rooms: rooms, agents: agents, contacts: groupTestVisibility{}, accounts: groupTestAccounts{}, sender: sender,
		speaker: svcchat.NewSelector(svcchat.SelectorDeps{}),
	}}}
	for _, tc := range []struct {
		text     string
		mentions []wukongwh.Mention
	}{
		{text: "发给群成员的普通消息"},
		{text: "@隐藏员工 留作群消息", mentions: []wukongwh.Mention{{Type: "agent", ID: "hidden"}}},
	} {
		handled, err := tr.SendLocalGroup(ctx, 1, liveID, "session", uuid.NewString(), "group", tc.text, tc.mentions)
		if err != nil || !handled {
			t.Fatalf("want IM delivery for %q, handled=%v, err=%v", tc.text, handled, err)
		}
	}
	if want := []string{"发给群成员的普通消息", "@隐藏员工 留作群消息"}; !reflect.DeepEqual(sender.messages, want) {
		t.Fatalf("sent %v, want %v", sender.messages, want)
	}
	rooms.room.SpeakerPolicy, rooms.room.ManagerAgentID = domroom.PolicyManager, &hiddenID
	handled, err := tr.SendLocalGroup(ctx, 1, liveID, "session", uuid.NewString(), "group", "主持人不可用时继续聊天", nil)
	if err != nil || handled || len(sender.messages) != 2 {
		t.Fatalf("want ordinary IM route for an unavailable host, handled=%v, err=%v, sent=%v", handled, err, sender.messages)
	}
	handled, err = tr.SendLocalGroup(ctx, 1, 999, "session", uuid.NewString(), "group", "群外成员", nil)
	if err == nil || handled || len(sender.messages) != 2 {
		t.Fatalf("want non-member rejected, handled=%v, err=%v, sent=%v", handled, err, sender.messages)
	}
}

func TestLocalGroupRoundRobinKeepsUnavailableSpeakerInSharedOrder(t *testing.T) {
	selector := svcchat.NewSelector(svcchat.SelectorDeps{})
	in := svcchat.SelectInput{
		Policy: domroom.PolicyRoundRobin, PolicyConfig: map[string]any{"order": []any{float64(1), float64(2), float64(3)}},
		Candidates:            []svcchat.SpeakerCandidate{{AgentID: 1}, {AgentID: 2}, {AgentID: 3}},
		RoundRobinLastIdx:     0,
		RoundRobinUnavailable: map[int64]bool{2: true},
	}
	out, err := selector.Select(context.Background(), in)
	if err != nil || !reflect.DeepEqual(out.Selected, []int64{3}) || out.NextPolicyConfig["last_idx"] != 2 {
		t.Fatalf("want third speaker while second is unavailable, got %+v, %v", out, err)
	}
	if got := out.NextPolicyConfig["order"]; !reflect.DeepEqual(got, []any{int64(1), int64(2), int64(3)}) {
		t.Fatalf("shared order changed to %#v", got)
	}
	in.PolicyConfig, in.RoundRobinLastIdx, in.RoundRobinUnavailable = out.NextPolicyConfig, 0, nil
	out, err = selector.Select(context.Background(), in)
	if err != nil || !reflect.DeepEqual(out.Selected, []int64{2}) {
		t.Fatalf("want second speaker when available, got %+v, %v", out, err)
	}
}

type groupTestRooms struct {
	wkRooms
	room  *domroom.Room
	parts []domroom.Participant
}

func (r groupTestRooms) GetByUUID(context.Context, int64, string) (*domroom.Room, error) {
	return r.room, nil
}
func (r groupTestRooms) ListParticipants(context.Context, int64) ([]domroom.Participant, error) {
	return r.parts, nil
}

type groupTestAgents struct {
	wkAgents
	agents map[int64]*domagent.DigitalEmployee
}

func (a groupTestAgents) GetByID(_ context.Context, id int64) (*domagent.DigitalEmployee, error) {
	return a.agents[id], nil
}

type groupTestVisibility struct{}

func (groupTestVisibility) AssertAgentVisible(_ context.Context, _, _ int64, id string) error {
	if id == "hidden" {
		return apperr.ErrForbidden
	}
	return nil
}

type groupTestAccounts struct{ wkAccounts }

func (groupTestAccounts) GetByID(context.Context, int64) (*domaccount.Account, error) {
	return &domaccount.Account{UUID: "sender"}, nil
}

type groupTestSender struct{ messages []string }

func (s *groupTestSender) SendMessage(_ context.Context, _, _ string, _ int, payload []byte) (int64, error) {
	var msg struct {
		Content string `json:"content"`
	}
	if err := json.Unmarshal(payload, &msg); err != nil {
		return 0, err
	}
	s.messages = append(s.messages, msg.Content)
	return int64(len(s.messages)), nil
}
