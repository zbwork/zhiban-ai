package app

import (
	"context"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	errx "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"testing"
)

type workbenchAppRepo struct {
	dom.AppRepo
	app *dom.App
}

func (r workbenchAppRepo) GetByUUID(context.Context, int64, string) (*dom.App, error) {
	return r.app, nil
}

type workbenchSettings struct {
	dom.TenantAppSettingRepo
	setting *dom.TenantAppSetting
}

func (r workbenchSettings) GetByTenantApp(context.Context, int64, int64) (*dom.TenantAppSetting, error) {
	if r.setting == nil {
		return nil, errx.ErrNotFound
	}
	return r.setting, nil
}

type workbenchOAuth struct{ dom.OAuthClientRepo }

func (workbenchOAuth) GetByID(context.Context, int64) (*dom.OAuthClient, error) {
	return &dom.OAuthClient{ID: 1, Status: "active", RedirectURIs: []string{"https://app.example.test/callback"}}, nil
}

type workbenchCodes struct {
	dom.OAuthCodeRepo
	inserted *dom.OAuthCode
}

func (r *workbenchCodes) Insert(_ context.Context, c *dom.OAuthCode) error {
	r.inserted = c
	return nil
}
func TestWorkbenchLaunchRetainsTenantAndEnablementBoundary(t *testing.T) {
	for _, tc := range []struct {
		name, usage                                        string
		tenant                                             int64
		system, open, enabled, universal, missing, allowed bool
	}{
		{name: "tenant enabled", usage: "all", tenant: 1, enabled: true, universal: true, allowed: true},
		{name: "disabled", usage: "all", tenant: 1, universal: true},
		{name: "agent only", usage: "agent", tenant: 1, enabled: true, universal: true},
		{name: "not universal", usage: "all", tenant: 1, enabled: true},
		{name: "other tenant", usage: "all", tenant: 2, enabled: true, universal: true},
		{name: "missing setting", usage: "all", tenant: 1, missing: true},
		{name: "platform closed", usage: "all", system: true, enabled: true, universal: true},
		{name: "platform open", usage: "end_user", system: true, open: true, enabled: true, universal: true, allowed: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			id := int64(1)
			a := &dom.App{ID: 1, UUID: "fixture", TenantID: tc.tenant, IsSystem: tc.system, OpenToTenants: tc.open, UsageScope: tc.usage, Status: "active", OAuthClientID: &id, LaunchURI: "https://app.example.test"}
			var setting *dom.TenantAppSetting
			if !tc.missing {
				setting = &dom.TenantAppSetting{TenantID: 1, AppID: 1, IsEnabled: tc.enabled, IsUniversal: tc.universal}
			}
			codes := &workbenchCodes{}
			s := New(Deps{Apps: workbenchAppRepo{app: a}, Settings: workbenchSettings{setting: setting}, OAuthClients: workbenchOAuth{}, OAuthCodes: codes})
			_, err := s.Launch(context.Background(), dom.LaunchInput{TenantID: 1, AccountID: 7, AppUUID: "fixture", State: "fixture-state"})
			if (err == nil) != tc.allowed {
				t.Fatalf("allowed=%v error=%v", tc.allowed, err)
			}
			if tc.allowed && (codes.inserted == nil || codes.inserted.ConversationID != nil) {
				t.Fatal("workbench launch must issue code without invented conversation")
			}
			if !tc.allowed && codes.inserted != nil {
				t.Fatal("unauthorized launch issued code")
			}
		})
	}
}
