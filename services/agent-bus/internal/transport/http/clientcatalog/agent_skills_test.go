package clientcatalog

import (
	"testing"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
)

func TestApplyAgentSkillBindingCapabilities(t *testing.T) {
	tests := []struct {
		name      string
		accountID int64
		creatorID int64
		framework string
		metadata  map[string]any
		supports  bool
		canManage bool
	}{
		{name: "creator regular runtime", accountID: 7, creatorID: 7, framework: "openclaw", supports: true, canManage: true},
		{name: "non creator regular runtime", accountID: 8, creatorID: 7, framework: "hermes", supports: true, canManage: false},
		{name: "creator zap runtime", accountID: 7, creatorID: 7, framework: "zap", supports: true, canManage: true}, // ZAP-1.1 §11 接通后 zap/dsh 员工支持客户端技能绑定
		{name: "creator dsh runtime", accountID: 7, creatorID: 7, framework: "dsh", supports: true, canManage: true},
		{name: "support builtin runtime kind", accountID: 7, creatorID: 7, metadata: map[string]any{"runtime_kind": "support_builtin"}, supports: false, canManage: false},
		{name: "support builtin agent key", accountID: 7, creatorID: 7, metadata: map[string]any{"agent_key": "zhiban-support"}, supports: false, canManage: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			out := map[string]any{}
			ApplyAgentSkillBindingCapabilities(out, &domagent.DigitalEmployee{
				CreatorID: tt.creatorID,
				Metadata:  tt.metadata,
			}, tt.accountID, tt.framework)
			if out["supports_skill_bindings"] != tt.supports || out["can_manage_skills"] != tt.canManage {
				t.Fatalf("unexpected capabilities: %#v", out)
			}
		})
	}
}
