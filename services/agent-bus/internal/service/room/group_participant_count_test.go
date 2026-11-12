package room

import (
	"testing"

	domroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
)

func TestValidateGroupParticipantCount(t *testing.T) {
	humanID := int64(10)
	humanID2 := int64(11)
	agentID1 := int64(20)
	agentID2 := int64(21)
	tests := []struct {
		name         string
		participants []domroom.ParticipantInput
		wantErr      bool
	}{
		{name: "caller plus one human is direct", participants: []domroom.ParticipantInput{{Kind: domroom.ParticipantHuman, AccountID: &humanID}}, wantErr: true},
		{name: "caller plus one agent is direct", participants: []domroom.ParticipantInput{{Kind: domroom.ParticipantAgent, AgentID: &agentID1}}, wantErr: true},
		{name: "caller plus two humans is group", participants: []domroom.ParticipantInput{{Kind: domroom.ParticipantHuman, AccountID: &humanID}, {Kind: domroom.ParticipantHuman, AccountID: &humanID2}}},
		{name: "caller plus two agents is group", participants: []domroom.ParticipantInput{{Kind: domroom.ParticipantAgent, AgentID: &agentID1}, {Kind: domroom.ParticipantAgent, AgentID: &agentID2}}},
		{name: "caller plus human and agent is group", participants: []domroom.ParticipantInput{{Kind: domroom.ParticipantHuman, AccountID: &humanID}, {Kind: domroom.ParticipantAgent, AgentID: &agentID1}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateGroupParticipantCount(tt.participants)
			if (err != nil) != tt.wantErr {
				t.Fatalf("error=%v wantErr=%v", err, tt.wantErr)
			}
		})
	}
}
