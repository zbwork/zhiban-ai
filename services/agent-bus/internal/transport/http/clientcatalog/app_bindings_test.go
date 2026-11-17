package clientcatalog

import (
	"context"
	"errors"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domapp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	"testing"
)

type catalogAppsFixture struct {
	domapp.Service
	items []domapp.App
	err   error
}

func (f catalogAppsFixture) ListAgentApps(context.Context, int64, int64) ([]domapp.App, error) {
	return f.items, f.err
}
func TestAgentCatalogReturnsLaunchableAppItems(t *testing.T) {
	h := AgentHandlers{Apps: catalogAppsFixture{items: []domapp.App{
		{UUID: "active", TenantID: 11, IsEnabled: true, Name: "应用", Code: "employee_app", IconURL: "https://example.test/icon.png", Status: "active", LaunchURI: "https://private.example.test", Metadata: map[string]any{"secret": "never expose"}},
		{UUID: "tenant-disabled", TenantID: 11, Status: "active", IsEnabled: false},
		{UUID: "disabled", TenantID: 11, Status: "disabled"},
		{UUID: "foreign", TenantID: 12, Status: "active"},
	}}}
	out, err := h.view(context.Background(), 7, domagent.DigitalEmployee{ID: 3, TenantID: 11})
	if err != nil {
		t.Fatal(err)
	}
	apps := out["apps"].([]map[string]any)
	if len(apps) != 1 || apps[0]["uuid"] != "active" || apps[0]["name"] != "应用" || apps[0]["code"] != "employee_app" || len(apps[0]) != 4 {
		t.Fatalf("unexpected app DTO: %#v", apps)
	}
}
func TestAgentCatalogExplicitEmptyAppsClearsRemovedBinding(t *testing.T) {
	h := AgentHandlers{Apps: catalogAppsFixture{}}
	out, err := h.view(context.Background(), 7, domagent.DigitalEmployee{ID: 3, TenantID: 11, Metadata: map[string]any{"selected_app_labels": map[string]any{"removed": "Old"}}})
	if err != nil {
		t.Fatal(err)
	}
	apps, ok := out["apps"].([]map[string]any)
	if !ok || apps == nil || len(apps) != 0 {
		t.Fatalf("missing authoritative empty apps: %#v", out["apps"])
	}
}
func TestAgentCatalogDoesNotHideAppLoadingFailure(t *testing.T) {
	want := errors.New("repository unavailable")
	h := AgentHandlers{Apps: catalogAppsFixture{err: want}}
	_, err := h.view(context.Background(), 7, domagent.DigitalEmployee{ID: 3, TenantID: 11})
	if !errors.Is(err, want) {
		t.Fatalf("got %v", err)
	}
}
