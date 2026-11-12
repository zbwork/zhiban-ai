package room

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
)

func TestSendMessageReqDecodesFileUUIDs(t *testing.T) {
	var req SendMessageReq
	if err := json.Unmarshal([]byte(`{
		"text":"看下附件",
		"file_uuids":["11111111-1111-1111-1111-111111111111"]
	}`), &req); err != nil {
		t.Fatalf("unmarshal SendMessageReq: %v", err)
	}
	if req.Text != "看下附件" {
		t.Fatalf("Text = %q", req.Text)
	}
	if got, want := len(req.FileUUIDs), 1; got != want {
		t.Fatalf("len(FileUUIDs) = %d, want %d", got, want)
	}
	if got := req.FileUUIDs[0]; got != "11111111-1111-1111-1111-111111111111" {
		t.Fatalf("FileUUIDs[0] = %q", got)
	}
}

func TestDirectHumanAgentSelectedAgentID(t *testing.T) {
	agentID := int64(37)
	rm := &domroom.Room{
		RoomKind: domroom.KindDirect,
		Metadata: map[string]any{"direct_room_kind": "human-agent"},
	}
	got := directHumanAgentSelectedAgentID(rm, []domroom.Participant{
		{Kind: domroom.ParticipantHuman, AccountID: ptrInt64(1039)},
		{Kind: domroom.ParticipantAgent, AgentID: &agentID},
	})
	if got == nil || *got != agentID {
		t.Fatalf("selected agent = %v, want %d", got, agentID)
	}
}

func TestDirectHumanAgentSelectedAgentIDIgnoresNonDirectRoom(t *testing.T) {
	agentID := int64(37)
	got := directHumanAgentSelectedAgentID(&domroom.Room{
		RoomKind: domroom.KindGroup,
		Metadata: map[string]any{"direct_room_kind": "human-agent"},
	}, []domroom.Participant{{Kind: domroom.ParticipantAgent, AgentID: &agentID}})
	if got != nil {
		t.Fatalf("selected agent = %v, want nil", *got)
	}
}

func TestDirectHumanAgentSelectedAgentIDRejectsAmbiguousAgents(t *testing.T) {
	first := int64(37)
	second := int64(38)
	got := directHumanAgentSelectedAgentID(&domroom.Room{
		RoomKind: domroom.KindDirect,
		Metadata: map[string]any{"direct_room_kind": "human-agent"},
	}, []domroom.Participant{
		{Kind: domroom.ParticipantAgent, AgentID: &first},
		{Kind: domroom.ParticipantAgent, AgentID: &second},
	})
	if got != nil {
		t.Fatalf("selected agent = %v, want nil", *got)
	}
}

func TestDirectHumanAgentSelectedAgentIDSkipsLeftAgent(t *testing.T) {
	agentID := int64(37)
	leftAt := time.Now()
	got := directHumanAgentSelectedAgentID(&domroom.Room{
		RoomKind: domroom.KindDirect,
		Metadata: map[string]any{"direct_room_kind": "human-agent"},
	}, []domroom.Participant{{Kind: domroom.ParticipantAgent, AgentID: &agentID, LeftAt: &leftAt}})
	if got != nil {
		t.Fatalf("selected agent = %v, want nil", *got)
	}
}

func TestTruncateRunesKeepsUTF8Valid(t *testing.T) {
	input := strings.Repeat("哇", 210)
	got := truncateRunes(input, 200)
	if !utf8.ValidString(got) {
		t.Fatalf("truncated text must be valid UTF-8")
	}
	if want := 201; utf8.RuneCountInString(got) != want {
		t.Fatalf("runes=%d, want %d", utf8.RuneCountInString(got), want)
	}
	if !strings.HasSuffix(got, "…") {
		t.Fatalf("truncated text should end with ellipsis: %q", got)
	}
}

func TestRoomHumanDisplayNamePrefersTenantNickname(t *testing.T) {
	tests := []struct {
		name        string
		nickname    string
		accountName string
		want        string
	}{
		{
			name:        "tenant nickname wins over global placeholder",
			nickname:    "刘明明",
			accountName: "用户9874的组织 管理员",
			want:        "刘明明",
		},
		{
			name:        "global placeholder is hidden without nickname",
			nickname:    "",
			accountName: "用户9874的组织 管理员",
			want:        "",
		},
		{
			name:        "global display name fallback",
			nickname:    "",
			accountName: "陈晓宇",
			want:        "陈晓宇",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := roomHumanDisplayName(tt.nickname, tt.accountName); got != tt.want {
				t.Fatalf("roomHumanDisplayName(%q, %q) = %q, want %q",
					tt.nickname, tt.accountName, got, tt.want)
			}
		})
	}
}

func ptrInt64(v int64) *int64 {
	return &v
}
