package chat

import (
	"context"
	"errors"
	runtime "github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/skill"
	"strings"
	"testing"
)

type skillStub struct{ err error }

func (skillStub) ListVersionFiles(context.Context, string, string) ([]svc.VersionFileEntry, error) {
	return nil, nil
}

func (s skillStub) GetSkillRail(context.Context, dom.GetSkillRailInput) (*dom.SkillRail, error) {
	if s.err != nil {
		return nil, s.err
	}
	return &dom.SkillRail{ChipRail: []dom.SkillRailItem{{Kind: dom.KindAgent, Name: "test", SkillUUID: "s", VersionUUID: "v"}}}, nil
}
func (skillStub) GetVersionFileContent(context.Context, string, string, string) (*svc.VersionFileContent, error) {
	return &svc.VersionFileContent{Content: "Use the supplied checklist."}, nil
}

type captureRuntime struct {
	runtime.Adapter
	request runtime.StreamRequest
}

type resourceStub struct {
	skillStub
	files   []svc.VersionFileEntry
	content string
	readErr error
	reads   []string
}

func (s *resourceStub) ListVersionFiles(context.Context, string, string) ([]svc.VersionFileEntry, error) {
	return s.files, nil
}
func (s *resourceStub) GetVersionFileContent(ctx context.Context, skill, version, name string) (*svc.VersionFileContent, error) {
	if name == "SKILL.md" {
		return s.skillStub.GetVersionFileContent(ctx, skill, version, name)
	}
	if skill != "s" || version != "v" {
		return nil, errors.New("wrong version")
	}
	s.reads = append(s.reads, name)
	return &svc.VersionFileContent{Content: s.content}, s.readErr
}
func TestSkillResources(t *testing.T) {
	for _, tc := range []struct {
		name    string
		files   []svc.VersionFileEntry
		content string
		readErr error
		fail    bool
	}{
		{name: "text and binary", files: []svc.VersionFileEntry{{Path: "references/guide.md"}, {Path: "assets/photo.png", IsBinary: true}}, content: "Reference checklist"},
		{name: "truncated", files: []svc.VersionFileEntry{{Path: "guide.md", Truncated: true}}, fail: true},
		{name: "traversal", files: []svc.VersionFileEntry{{Path: "../secret"}}, fail: true},
		{name: "duplicate", files: []svc.VersionFileEntry{{Path: "a.md"}, {Path: "a.md"}}, fail: true},
		{name: "budget", files: []svc.VersionFileEntry{{Path: "a.md"}}, content: strings.Repeat("a", 256<<10), fail: true},
		{name: "read failure", files: []svc.VersionFileEntry{{Path: "a.md"}}, readErr: errors.New("unavailable"), fail: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &resourceStub{files: tc.files, content: tc.content, readErr: tc.readErr}
			base := &captureRuntime{}
			_, err := (&skillRuntime{Adapter: base, skills: s}).Stream(context.Background(), runtime.StreamRequest{})
			if (err != nil) != tc.fail {
				t.Fatalf("err=%v", err)
			}
			if tc.fail && base.request.SystemPrompt != "" {
				t.Fatal("failed resources reached model")
			}
			if !tc.fail {
				if len(s.reads) != 1 || s.reads[0] != "references/guide.md" || !strings.Contains(base.request.SystemPrompt, tc.content) || !strings.Contains(base.request.SystemPrompt, "binary; content unavailable") {
					t.Fatalf("reads=%v prompt=%s", s.reads, base.request.SystemPrompt)
				}
			}
		})
	}
}

func (c *captureRuntime) Stream(_ context.Context, r runtime.StreamRequest) (runtime.Stream, error) {
	c.request = r
	return nil, nil
}
func TestSkillInstructionsAndFailure(t *testing.T) {
	base := &captureRuntime{}
	a := &skillRuntime{Adapter: base, skills: skillStub{}}
	_, err := a.Stream(context.Background(), runtime.StreamRequest{SystemPrompt: "Original"})
	if err != nil || !strings.Contains(base.request.SystemPrompt, "Original") || !strings.Contains(base.request.SystemPrompt, "Use the supplied checklist.") {
		t.Fatalf("request=%+v err=%v", base.request, err)
	}
	a.skills = skillStub{err: errors.New("denied")}
	base.request = runtime.StreamRequest{}
	if _, err = a.Stream(context.Background(), runtime.StreamRequest{}); err == nil || base.request.SystemPrompt != "" {
		t.Fatal("skill authorization failure ignored")
	}
}
