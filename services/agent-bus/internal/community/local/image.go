package local

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"strings"
	"time"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	media "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localmedia"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	domsource "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	svc "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localruntime"
	svcsource "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/modelsource"
)

// PrepareLocalImage sends the image request to the run's selected member platform.
func (m *Models) PrepareLocalImage(ctx context.Context, t *dom.Task, in media.Request) (func(context.Context) (*http.Response, error), error) {
	route, err := m.route(ctx, t.Scope, t.EmployeeID, t.Model)
	if err != nil || !svc.MatchesModel(t, route.selected) || route.selected.Protocol != "openai-compatible" {
		return nil, dom.ErrDenied
	}
	// Image generation often returns no headers until it finishes. Do not inherit the text model's 30s TTFT timeout.
	transport := m.guard.SafeTransport()
	transport.ResponseHeaderTimeout = 5 * time.Minute
	client := &http.Client{Transport: transport, Timeout: 5 * time.Minute, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	endpoint := strings.TrimSuffix(route.endpoint, "/chat/completions") + "/images/generations"
	body := map[string]any{"model": in.Model, "prompt": in.Prompt, "size": in.Size, "n": 1}
	// GPT Image always returns base64 and rejects the DALL-E response_format parameter.
	if !strings.HasPrefix(in.Model, "gpt-image-") {
		body["response_format"] = "b64_json"
	}
	raw, _ := json.Marshal(body)
	return func(callCtx context.Context) (*http.Response, error) {
		req, err := http.NewRequestWithContext(callCtx, http.MethodPost, endpoint, bytes.NewReader(raw))
		if err != nil {
			return nil, media.ErrUnavailable
		}
		for k, v := range route.headers {
			req.Header.Set(k, v)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+route.key)
		// No retries or assumed provider idempotency support. Bus has already durably claimed this operation.
		req.Close = true
		res, err := client.Do(req)
		if err != nil {
			kind := "connection"
			var network net.Error
			if errors.As(err, &network) && network.Timeout() {
				kind = "timeout"
			}
			if callCtx.Err() != nil {
				kind = "cancelled_or_deadline"
			}
			logpkg.Default().Warn(callCtx, "local_runtime.image_provider_failure", "run", t.UUID, "kind", kind)
			return nil, media.ErrUnavailable
		}
		if res.StatusCode < 200 || res.StatusCode >= 300 {
			logpkg.Default().Warn(callCtx, "local_runtime.image_provider_failure", "run", t.UUID, "kind", "upstream_status", "status", res.StatusCode)
		}
		return res, nil
	}, nil
}

// ValidateConversationModel accepts only the caller's own member platform references,
// after chat visibility authorization.
func (m *Models) ValidateConversationModel(ctx context.Context, account, tenant int64, employee *domagent.DigitalEmployee, hint string) error {
	if employee == nil || hint == "" || len(hint) > 1024 || (employee.Visibility == "private" && employee.CreatorID != account) {
		return dom.ErrDenied
	}
	if m.sources == nil || !svcsource.IsReference(hint) {
		return dom.ErrDenied
	}
	if _, err := m.sources.Resolve(ctx, domsource.Scope{TenantID: tenant, AccountID: account}, svcsource.SelectionReference(hint)); err != nil {
		return dom.ErrDenied
	}
	return nil
}
