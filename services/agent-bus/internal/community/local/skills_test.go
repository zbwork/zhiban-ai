package local

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"testing"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	skill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/skill"
)

type packageFixture struct {
	bytes []byte
	calls int
}

func (f *packageFixture) Key(id, version string) string {
	return "skill/" + id + "/" + version + ".zip"
}
func (f *packageFixture) ReadObject(_ context.Context, key string, max int64, prefixes ...string) ([]byte, error) {
	f.calls++
	return f.bytes, nil
}

func TestRunSkillSnapshotBoundsAndIntegrity(t *testing.T) {
	const id = "582d21b6-4424-4cee-a386-f07be9480bb2"
	bytes := []byte("verified package")
	digest := sha256.Sum256(bytes)
	entry := skill.AgentSkillCarrier{SkillID: id, Version: "0.1.0", PackageSHA256: hex.EncodeToString(digest[:]), PackageSizeBytes: int64(len(bytes)), PackageURL: "https://ignored.example/arbitrary"}
	for _, tc := range []struct {
		name, request string
		change        func(*skill.AgentSkillCarrier)
		deny          bool
		reads         int
	}{
		{name: "authorized snapshot", request: id, reads: 1},
		{name: "another skill", request: "123e4567-e89b-42d3-a456-426614174000", deny: true},
		{name: "path injection", request: "../other", deny: true},
		{name: "version traversal", request: id, change: func(e *skill.AgentSkillCarrier) { e.Version = "../../other" }, deny: true},
		{name: "oversize", request: id, change: func(e *skill.AgentSkillCarrier) { e.PackageSizeBytes = 21 << 20 }, deny: true},
		{name: "hash mismatch", request: id, change: func(e *skill.AgentSkillCarrier) { e.PackageSHA256 = "incorrect" }, deny: true, reads: 1},
		{name: "length mismatch", request: id, change: func(e *skill.AgentSkillCarrier) { e.PackageSizeBytes++ }, deny: true, reads: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := entry
			if tc.change != nil {
				tc.change(&e)
			}
			payload, _ := json.Marshal(map[string]any{"skills": skill.SkillsCarrier{AgentSkills: []skill.AgentSkillCarrier{e}}})
			store := &packageFixture{bytes: bytes}
			got, err := (SkillPackages{Store: store}).ReadTaskSkill(context.Background(), &dom.Task{Payload: payload}, tc.request)
			if (err != nil) != tc.deny || store.calls != tc.reads || (!tc.deny && string(got) != string(bytes)) {
				t.Fatalf("error=%v reads=%d bytes=%q", err, store.calls, got)
			}
		})
	}
}
