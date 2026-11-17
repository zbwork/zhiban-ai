package admincore

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/jwt"
	agentsvc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/agent"
)

type localEditorAgentStub struct {
	agentsvc.Service
	accountID, tenantID int64
	saved               *domagent.DigitalEmployee
}

func (s *localEditorAgentStub) Create(_ context.Context, accountID, tenantID int64, e *domagent.DigitalEmployee) (*domagent.DigitalEmployee, error) {
	s.accountID, s.tenantID = accountID, tenantID
	s.saved = e
	e.ID = 42
	e.UUID = "local-editor-agent"
	return e, nil
}
func TestTenantEditorPreservesLocalExecutionAndPersona(t *testing.T) {
	for _, engine := range []string{"dsh", "codex_app_server"} {
		t.Run(engine, func(t *testing.T) {
			key, _, err := jwt.GenerateDevKeypair()
			if err != nil {
				t.Fatal(err)
			}
			issuer, err := jwt.New(key, "", "local-editor", time.Minute)
			if err != nil {
				t.Fatal(err)
			}
			token, err := issuer.Issue(jwt.IssueOptions{AccountID: 5, ActScope: "tenant", ActTenantID: 10, Admin: true, Perms: []string{"tenant.agent.create"}})
			if err != nil {
				t.Fatal(err)
			}
			stub := &localEditorAgentStub{}
			h := &Handlers{Agent: stub}
			handler := middleware.Auth(issuer, nil, false)(middleware.RequireAdmin(nil)(middleware.RequireTenant(middleware.RequirePermission("tenant.agent.create")(http.HandlerFunc(h.createAgent)))))
			body := `{"Name":"Local editor","Intro":"Description","Description":"Full persona","execution_locus":"local","local_engine":"` + engine + `","Metadata":{"system_prompt":"Keep this persona"},"RuntimeEnvironmentID":null}`
			r := httptest.NewRequest("POST", "/api/admin/v1/tenant/agents", strings.NewReader(body))
			r.Header.Set("Authorization", "Bearer "+token)
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, r)
			if w.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
			if stub.accountID != 5 || stub.tenantID != 10 || stub.saved.Source != "enterprise" || stub.saved.LocalEngine != engine || stub.saved.ExecutionLocus != "local" || stub.saved.RuntimeEnvironmentID != nil || stub.saved.Metadata["system_prompt"] != "Keep this persona" || stub.saved.Description != "Full persona" {
				t.Fatalf("editor fields or authoritative scope lost: %+v", stub.saved)
			}
			var response struct {
				Data struct {
					ID          int64
					LocalEngine string `json:"local_engine"`
					Description string
				}
			}
			if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
				t.Fatal(err)
			}
			if response.Data.ID != 42 || response.Data.LocalEngine != engine || response.Data.Description != "Full persona" {
				t.Fatalf("full employee DTO missing: %s", w.Body.String())
			}
		})
	}
}
