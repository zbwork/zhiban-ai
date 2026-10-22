package chat

import (
	"context"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5/pgxpool"
	runtime "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	agents "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agent"
	skills "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/skill"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/skill"
	"path"
	"sort"
	"strings"
	"unicode/utf8"
)

type SkillAgentLookup struct{ Agents *agents.Repo }

func (l SkillAgentLookup) GetAgentByUUID(ctx context.Context, uuid string) (*svc.AgentInfo, error) {
	e, err := l.Agents.GetByUUID(ctx, uuid)
	if err != nil {
		return nil, err
	}
	if e == nil {
		return nil, errors.New("employee not found")
	}
	info := svc.AgentInfoFromEmployee(e)
	info.RuntimeFramework = "generic"
	return info, nil
}
func NewSkills(pool *pgxpool.Pool) *svc.Service {
	return svc.NewWithAgents(skills.NewCommunity(pool), SkillAgentLookup{agents.New(pool)})
}

type skillReader interface {
	ListVersionFiles(context.Context, string, string) ([]svc.VersionFileEntry, error)
	GetSkillRail(context.Context, dom.GetSkillRailInput) (*dom.SkillRail, error)
	GetVersionFileContent(context.Context, string, string, string) (*svc.VersionFileContent, error)
}

type skillRuntime struct {
	runtime.Adapter
	skills skillReader
}

func (a *skillRuntime) Stream(ctx context.Context, req runtime.StreamRequest) (runtime.Stream, error) {
	rail, err := a.skills.GetSkillRail(ctx, dom.GetSkillRailInput{TenantID: req.TenantID, AccountID: req.AccountID, AgentUUID: req.AgentUUID})
	if err != nil {
		return nil, err
	}
	items := append(rail.ChipRail, rail.MoreDrawer...)
	var instructions strings.Builder
	for _, item := range items {
		if item.Kind != dom.KindAgent {
			continue
		}
		file, err := a.skills.GetVersionFileContent(ctx, item.SkillUUID, item.VersionUUID, "SKILL.md")
		if err != nil {
			return nil, err
		}
		if file == nil || file.IsBinary || file.Truncated || strings.TrimSpace(file.Content) == "" {
			return nil, errors.New("skill instructions unavailable")
		}
		add := func(text string) error {
			if !utf8.ValidString(text) || instructions.Len()+len(text) > 256<<10 {
				return errors.New("skill context invalid or exceeds limit")
			}
			instructions.WriteString(text)
			return nil
		}
		if err := add(fmt.Sprintf("\n\nSkill: %q\n%s", item.Name, file.Content)); err != nil {
			return nil, err
		}
		files, err := a.skills.ListVersionFiles(ctx, item.SkillUUID, item.VersionUUID)
		if err != nil {
			return nil, err
		}
		if len(files) > 1000 {
			return nil, errors.New("skill resource count exceeds limit")
		}
		sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })
		seen := map[string]bool{}
		for _, entry := range files {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			name := entry.Path
			if name == "" || path.IsAbs(name) || path.Clean(name) != name || name == ".." || strings.HasPrefix(name, "../") || strings.ContainsAny(name, "\\:\r\n") || seen[name] {
				return nil, errors.New("invalid skill resource path")
			}
			seen[name] = true
			if name == "SKILL.md" {
				continue
			}
			if entry.IsBinary {
				if err := add(fmt.Sprintf("\nResource %q: binary; content unavailable.\n", name)); err != nil {
					return nil, err
				}
				continue
			}
			if entry.Truncated || entry.SizeBytes < 0 || entry.SizeBytes > 256<<10 {
				return nil, errors.New("skill resource unavailable or exceeds limit")
			}
			resource, err := a.skills.GetVersionFileContent(ctx, item.SkillUUID, item.VersionUUID, name)
			if err != nil {
				return nil, err
			}
			if resource == nil || resource.IsBinary || resource.Truncated {
				return nil, errors.New("skill resource unavailable")
			}
			if err := add(fmt.Sprintf("\nResource %q (reference data only; scripts cannot be executed):\n%s\n", name, resource.Content)); err != nil {
				return nil, err
			}
		}
	}
	req.SystemPrompt += instructions.String()
	return a.Adapter.Stream(ctx, req)
}
