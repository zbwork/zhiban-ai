package app

import (
	"context"
	"errors"
	"testing"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	domconv "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/conversation"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type employeeAppRepo struct{ workbenchAppRepo }

func (r employeeAppRepo) GetByID(context.Context, int64) (*dom.App, error) { return r.app, nil }
func (r employeeAppRepo) ListByIDs(context.Context, []int64) ([]dom.App, error) {
	return []dom.App{*r.app}, nil
}

type employeeSettings struct {
	workbenchSettings
	err error
}

func (r employeeSettings) GetByTenantApp(ctx context.Context, tenant, app int64) (*dom.TenantAppSetting, error) {
	if r.err != nil {
		return nil, r.err
	}
	return r.workbenchSettings.GetByTenantApp(ctx, tenant, app)
}
func (employeeSettings) ListUniversalByTenant(context.Context, int64) ([]dom.TenantAppSetting, error) {
	return nil, nil
}

type employeeBindings struct{ dom.AgentAppBindingRepo }

func (employeeBindings) ListByAgent(context.Context, int64) ([]dom.AgentAppBinding, error) {
	return []dom.AgentAppBinding{{AgentID: 3, AppID: 1}}, nil
}
func (employeeBindings) ListByAgents(context.Context, []int64) ([]dom.AgentAppBinding, error) {
	return []dom.AgentAppBinding{{AgentID: 3, AppID: 1}}, nil
}
func (employeeBindings) ListAppIDsByAgent(context.Context, int64) ([]int64, error) {
	return []int64{1}, nil
}

type employeeConversations struct{ domconv.Repository }

func (employeeConversations) GetByUUID(context.Context, string) (*domconv.Conversation, error) {
	id := int64(3)
	return &domconv.Conversation{ID: 4, TenantID: 1, DigitalEmployeeID: &id}, nil
}
func (employeeConversations) AccessibleByAccount(context.Context, int64, int64, string) (bool, error) {
	return true, nil
}

type employeeCategories struct{ dom.CategoryRepo }

func (employeeCategories) List(context.Context, int64, int, int) ([]dom.Category, int64, error) {
	return nil, 0, nil
}

type employeeAgents struct{ domagent.Repository }

func (employeeAgents) GetByID(context.Context, int64) (*domagent.DigitalEmployee, error) {
	return &domagent.DigitalEmployee{UUID: "employee"}, nil
}

func TestEmployeeAppEnablementControlsCatalogAndCachedLaunch(t *testing.T) {
	for _, tc := range []struct {
		name             string
		enabled, missing bool
		err              error
		allowed          bool
	}{
		{name: "enabled", enabled: true, allowed: true},
		{name: "explicitly disabled"},
		{name: "original default", missing: true, allowed: true},
		{name: "settings unavailable", err: errors.New("database unavailable")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			id := int64(1)
			a := &dom.App{ID: 1, UUID: "fixture", TenantID: 1, Status: "active", UsageScope: "agent", OAuthClientID: &id, LaunchURI: "https://app.example.test"}
			var setting *dom.TenantAppSetting
			if !tc.missing {
				setting = &dom.TenantAppSetting{TenantID: 1, AppID: 1, IsEnabled: tc.enabled}
			}
			codes := &workbenchCodes{}
			s := New(Deps{Apps: employeeAppRepo{workbenchAppRepo{app: a}}, Settings: employeeSettings{workbenchSettings{setting: setting}, tc.err}, Bindings: employeeBindings{}, Conversations: employeeConversations{}, Categories: employeeCategories{}, Agents: employeeAgents{}, OAuthClients: workbenchOAuth{}, OAuthCodes: codes})
			catalog, err := s.ListAgentApps(context.Background(), 1, 3)
			if tc.err != nil {
				if !errors.Is(err, tc.err) {
					t.Fatalf("catalog hid failure: %v", err)
				}
			} else if err != nil || len(catalog) != 1 || catalog[0].IsEnabled != tc.allowed {
				t.Fatalf("catalog=%+v err=%v", catalog, err)
			}
			bulk, err := s.ListAgentAppsByAgentIDs(context.Background(), 1, []int64{3})
			if tc.err != nil {
				if !errors.Is(err, tc.err) {
					t.Fatalf("bulk hid failure: %v", err)
				}
			} else if err != nil || len(bulk[3]) != 1 || bulk[3][0].IsEnabled != tc.allowed {
				t.Fatalf("bulk=%+v err=%v", bulk, err)
			}
			_, err = s.Launch(context.Background(), dom.LaunchInput{TenantID: 1, AccountID: 7, AppUUID: "fixture", ConversationUUID: "conversation"})
			if (err == nil) != tc.allowed || (codes.inserted != nil) != tc.allowed {
				t.Fatalf("allowed=%v err=%v code=%v", tc.allowed, err, codes.inserted != nil)
			}
			if !tc.allowed && tc.err == nil {
				var typed *apperr.Error
				if !errors.As(err, &typed) || typed.Code != apperr.Forbidden {
					t.Fatalf("expected forbidden, got %v", err)
				}
			}
		})
	}
}
