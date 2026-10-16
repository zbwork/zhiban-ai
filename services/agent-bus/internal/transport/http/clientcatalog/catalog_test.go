package clientcatalog

import (
	"context"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"net/http/httptest"
	"testing"
)

type reader struct{ filter dom.Filter }

func (s *reader) List(ctx context.Context, f dom.Filter) ([]dom.DigitalEmployee, int64, error) {
	s.filter = f
	return []dom.DigitalEmployee{}, 0, nil
}
func (s *reader) GetByUUID(context.Context, string) (*dom.DigitalEmployee, error) { return nil, nil }
func TestListScopesToCreator(t *testing.T) {
	stub := &reader{}
	h := &AgentHandlers{Agents: stub}
	req := httptest.NewRequest("GET", "/agents?limit=200&mine=1", nil)
	req = req.WithContext(middleware.ContextWithIdentityForTest(req.Context(), 17, 23))
	out := httptest.NewRecorder()
	h.List(out, req)
	if out.Code != 200 || stub.filter.CreatorID != 17 || stub.filter.TenantID != 23 || !stub.filter.ExcludeTenantInitSeeds {
		t.Fatalf("status=%d filter=%+v", out.Code, stub.filter)
	}
}
func TestGetRejectsForeignCreator(t *testing.T) {
	h := &AgentHandlers{Agents: &foreignReader{}}
	req := httptest.NewRequest("GET", "/agents/x", nil)
	req.SetPathValue("uuid", "x")
	req = req.WithContext(middleware.ContextWithIdentityForTest(req.Context(), 17, 23))
	out := httptest.NewRecorder()
	h.Get(out, req)
	if out.Code != 403 {
		t.Fatalf("status=%d body=%s", out.Code, out.Body.String())
	}
}

type foreignReader struct{ reader }

func (*foreignReader) GetByUUID(context.Context, string) (*dom.DigitalEmployee, error) {
	return &dom.DigitalEmployee{TenantID: 23, CreatorID: 99}, nil
}
