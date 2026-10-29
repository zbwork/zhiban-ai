// Package local composes the community Local Agent runtime.
package local

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	domsource "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	agentrepo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/agent"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/localruntime"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localruntime"
	svcsource "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/modelsource"
	svcruntime "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/runtime"
)

type agentReader interface {
	GetByID(context.Context, int64) (*domagent.DigitalEmployee, error)
}

// Models resolves only member model platform references synced from the client
// model service (ADR-0042). Provider keys stay encrypted in Bus and are used only
// by the proxy; the desktop receives a run-scoped capability, never the key.
type Models struct {
	sources    *svcsource.Service
	agents     agentReader
	bindingKey []byte
	guard      *svcruntime.SSRFGuard
}

func NewModels(sources *svcsource.Service, agents agentReader, bindingKey []byte) *Models {
	return &Models{sources: sources, agents: agents, bindingKey: bindingKey, guard: &svcruntime.SSRFGuard{}}
}

type modelRoute struct {
	selected      svc.ModelSelection
	endpoint, key string
	headers       map[string]string
}

func (m *Models) resolve(ctx context.Context, scope dom.Scope, employeeID int64, hint string) (svc.ModelSelection, error) {
	r, err := m.route(ctx, scope, employeeID, hint)
	return r.selected, err
}

func (m *Models) route(ctx context.Context, scope dom.Scope, employeeID int64, hint string) (modelRoute, error) {
	employee, err := m.agents.GetByID(ctx, employeeID)
	if err != nil || !runnableInScope(employee, scope) || m.sources == nil || !svcsource.IsReference(hint) || len(m.bindingKey) < 32 {
		return modelRoute{}, dom.ErrDenied
	}
	route, err := m.sources.Resolve(ctx, domsource.Scope{TenantID: scope.TenantID, AccountID: scope.AccountID}, hint)
	if err != nil {
		return modelRoute{}, err
	}
	if route.APIKey == "" || m.guard.Validate(ctx, route.BaseURL) != nil {
		return modelRoute{}, dom.ErrDenied
	}
	suffix := "chat/completions"
	switch route.Protocol {
	case "openai-compatible":
	case "anthropic-messages":
		suffix = "messages"
	default:
		return modelRoute{}, dom.ErrDenied
	}
	endpoint, err := url.Parse(strings.TrimRight(strings.TrimSpace(route.BaseURL), "/"))
	if err != nil || endpoint.Host == "" || endpoint.User != nil || endpoint.RawQuery != "" || endpoint.Fragment != "" {
		return modelRoute{}, dom.ErrDenied
	}
	if endpoint.Path == "" {
		endpoint.Path = "/v1"
	}
	endpoint.Path += "/" + suffix
	// HMAC avoids publishing an offline credential-guessing oracle in task metadata.
	encoded, _ := json.Marshal([]any{"local-model-v1", scope.TenantID, scope.AccountID, employee.UUID, "member_platform", hint, route.Protocol, endpoint.String(), route.APIKey})
	mac := hmac.New(sha256.New, m.bindingKey)
	_, _ = mac.Write(encoded)
	selected := svc.ModelSelection{Model: hint, Protocol: route.Protocol, Binding: hex.EncodeToString(mac.Sum(nil))}
	return modelRoute{selected: selected, endpoint: endpoint.String(), key: route.APIKey, headers: route.Headers}, nil
}

func runnableInScope(employee *domagent.DigitalEmployee, scope dom.Scope) bool {
	return employee != nil && !employee.IsDeleted && employee.ExecutionLocus == "local" && employee.Status == "published" &&
		employee.Source == "personal" && employee.Visibility == "private" && employee.TenantID == scope.TenantID && employee.CreatorID == scope.AccountID
}

// PrepareLocalModel binds a fresh selection for new work only; runs stay strict.
func (m *Models) PrepareLocalModel(ctx context.Context, scope dom.Scope, employeeID int64, hint string) (svc.ModelSelection, error) {
	if m.sources == nil || !svcsource.IsReference(hint) {
		return svc.ModelSelection{}, dom.ErrDenied
	}
	bound, err := m.sources.BindSelection(ctx, domsource.Scope{TenantID: scope.TenantID, AccountID: scope.AccountID}, hint)
	if err != nil {
		return svc.ModelSelection{}, err
	}
	return m.resolve(ctx, scope, employeeID, bound)
}

func (m *Models) SelectLocalModel(ctx context.Context, scope dom.Scope, employeeID int64, hint string) (svc.ModelSelection, error) {
	return m.resolve(ctx, scope, employeeID, hint)
}

func (m *Models) ProxyLocalModel(ctx context.Context, task *dom.Task, protocol string, body json.RawMessage) (*http.Response, error) {
	selected, err := m.resolve(ctx, task.Scope, task.EmployeeID, task.Model)
	if err != nil || !svc.MatchesModel(task, selected) {
		return nil, dom.ErrDenied
	}
	scope := domsource.Scope{TenantID: task.Scope.TenantID, AccountID: task.Scope.AccountID}
	if protocol == "responses" {
		if task.LocalEngine != dom.EngineCodex || selected.Protocol != "openai-compatible" {
			return nil, dom.ErrDenied
		}
		return m.sources.ProxyLocalResponses(ctx, scope, task.Model, body)
	}
	return m.sources.Proxy(ctx, scope, task.Model, protocol, body)
}

// Compose builds the local runtime and the model platform service. The JWT key file
// only supplies domain-separated HMAC material; when the model platform cipher is
// not configured, platform sync and every model call fail closed.
func Compose(pool *pgxpool.Pool, jwtKeyFile string, sources *svcsource.Service) (*svc.Service, *Models, error) {
	pem, err := os.ReadFile(jwtKeyFile)
	if err != nil {
		return nil, nil, errors.New("JWT private key cannot be read")
	}
	models := NewModels(sources, agentrepo.New(pool), pem)
	local, err := svc.New(repo.New(pool), pem, models)
	return local, models, err
}
