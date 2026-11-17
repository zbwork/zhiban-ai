package contacts

import (
	"context"
	"testing"
)

func TestAgentContactResolvesAvatarInCallerScope(t *testing.T) {
	s := &impl{avatarURLResolver: func(_ context.Context, tid int64, raw string) string {
		if tid != 42 || raw != "oss://agent-avatars/test.png" {
			t.Fatalf("wrong asset scope: tenant=%d raw=%q", tid, raw)
		}
		return "https://assets.example.test/avatar.png"
	}}
	c := s.buildAgent(context.Background(), 42, agentRow{UUID: "employee", Source: "enterprise", Status: "published", AvatarURL: "oss://agent-avatars/test.png"}, ContactPolicy{})
	if c.AvatarURL != "https://assets.example.test/avatar.png" {
		t.Fatalf("avatar was not resolved: %q", c.AvatarURL)
	}
}
