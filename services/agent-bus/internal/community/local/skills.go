package local

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"regexp"

	"github.com/google/uuid"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	skill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/skill"
)

type skillPackageStore interface {
	Key(string, string) string
	ReadObject(context.Context, string, int64, ...string) ([]byte, error)
}

// SkillPackages reads only the immutable package selected in an authenticated run.
type SkillPackages struct{ Store skillPackageStore }

var localSkillVersion = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._+-]{0,99}$`)

func (s SkillPackages) ReadTaskSkill(ctx context.Context, task *dom.Task, skillID string) ([]byte, error) {
	if task == nil || s.Store == nil {
		return nil, dom.ErrDenied
	}
	if _, err := uuid.Parse(skillID); err != nil {
		return nil, dom.ErrDenied
	}
	var payload struct {
		Skills *skill.SkillsCarrier `json:"skills"`
	}
	if json.Unmarshal(task.Payload, &payload) != nil || payload.Skills == nil {
		return nil, dom.ErrDenied
	}
	for _, entry := range payload.Skills.AgentSkills {
		if entry.SkillID != skillID {
			continue
		}
		if !localSkillVersion.MatchString(entry.Version) || entry.PackageSizeBytes <= 0 || entry.PackageSizeBytes > 20<<20 {
			return nil, dom.ErrDenied
		}
		bytes, err := s.Store.ReadObject(ctx, s.Store.Key(entry.SkillID, entry.Version), entry.PackageSizeBytes, "skill/")
		if err != nil {
			return nil, err
		}
		digest := sha256.Sum256(bytes)
		if int64(len(bytes)) != entry.PackageSizeBytes || hex.EncodeToString(digest[:]) != entry.PackageSHA256 {
			return nil, dom.ErrDenied
		}
		return bytes, nil
	}
	return nil, dom.ErrDenied
}
