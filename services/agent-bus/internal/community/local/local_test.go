package local

import (
	"context"
	"errors"
	"strings"
	"testing"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

type agents map[int64]*domagent.DigitalEmployee

func (a agents) GetByID(_ context.Context, id int64) (*domagent.DigitalEmployee, error) {
	return a[id], nil
}

func ownLocal() *domagent.DigitalEmployee {
	return &domagent.DigitalEmployee{ID: 1, UUID: "e", TenantID: 7, CreatorID: 9, ExecutionLocus: "local", Status: "published", Source: "personal", Visibility: "private"}
}

func TestRunnableInScopePersonalEmployeeOwnership(t *testing.T) {
	scope := dom.Scope{TenantID: 7, AccountID: 9}
	if !runnableInScope(ownLocal(), scope) {
		t.Fatal("own local employee must be runnable")
	}
	for name, mutate := range map[string]func(*domagent.DigitalEmployee){
		"cloud":         func(e *domagent.DigitalEmployee) { e.ExecutionLocus = "cloud" },
		"draft":         func(e *domagent.DigitalEmployee) { e.Status = "draft" },
		"deleted":       func(e *domagent.DigitalEmployee) { e.IsDeleted = true },
		"other tenant":  func(e *domagent.DigitalEmployee) { e.TenantID = 8 },
		"other creator": func(e *domagent.DigitalEmployee) { e.CreatorID = 10 },
	} {
		e := ownLocal()
		mutate(e)
		if runnableInScope(e, scope) {
			t.Fatalf("%s employee must not be runnable", name)
		}
	}
}

// Without a configured model platform service every selection fails closed,
// and plain model IDs are never accepted in place of a platform reference.
func TestSelectionFailsClosed(t *testing.T) {
	m := NewModels(nil, agents{1: ownLocal()}, []byte(strings.Repeat("k", 32)), nil)
	scope := dom.Scope{TenantID: 7, AccountID: 9}
	for _, hint := range []string{"", "gpt-4o", "msel:00000000-0000-0000-0000-000000000000:Z3B0"} {
		if _, err := m.SelectLocalModel(context.Background(), scope, 1, hint); err == nil {
			t.Fatalf("accepted %q", hint)
		}
		if _, err := m.PrepareLocalModel(context.Background(), scope, 1, hint); err == nil {
			t.Fatalf("prepared %q", hint)
		}
	}
}

type visibilityProbe struct {
	calls               int
	accountID, tenantID int64
	denied              bool
}

func (v *visibilityProbe) AssertAgentVisible(_ context.Context, accountID, tenantID int64, _ string) error {
	v.calls++
	v.accountID = accountID
	v.tenantID = tenantID
	if v.denied {
		return errors.New("not visible")
	}
	return nil
}
func TestOrganizationLocalModelUsesCallerVisibility(t *testing.T) {
	scope := dom.Scope{TenantID: 7, AccountID: 9}
	e := ownLocal()
	e.Source = "enterprise"
	e.Visibility = "tenant"
	e.CreatorID = 100
	visibility := &visibilityProbe{}
	m := NewModels(nil, agents{1: e}, []byte(strings.Repeat("k", 32)), visibility)
	if !m.authorizeEmployee(context.Background(), e, scope) {
		t.Fatal("authorized tenant member rejected")
	}
	if visibility.accountID != 9 || visibility.tenantID != 7 || visibility.calls != 1 {
		t.Fatal("must use caller scope, never administrator scope")
	}
	visibility.denied = true
	if m.authorizeEmployee(context.Background(), e, scope) {
		t.Fatal("revoked or hidden organization employee accepted")
	}
	e.TenantID = 8
	visibility.denied = false
	if m.authorizeEmployee(context.Background(), e, scope) {
		t.Fatal("cross tenant employee accepted")
	}
	e.TenantID = 7
	m.visibility = nil
	if m.authorizeEmployee(context.Background(), e, scope) {
		t.Fatal("unwired organization visibility must fail closed")
	}
}
