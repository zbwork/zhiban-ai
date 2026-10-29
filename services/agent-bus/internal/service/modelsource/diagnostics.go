package modelsource

import (
	"context"
	"errors"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
)

// Internal classification retains errors.Is without retaining request data.
type proxyFailure struct {
	kind  string
	cause error
}

func (e *proxyFailure) Error() string { return "model_source.proxy_rejected" }
func (e *proxyFailure) Unwrap() error { return e.cause }

// ProxyFailureDetails returns allowlisted diagnostic values only. Never log err
// directly: transport errors can contain URLs and provider errors can echo keys.
func ProxyFailureDetails(err error) (kind string, upstreamStatus int) {
	if errors.Is(err, context.Canceled) {
		return "cancelled", 0
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout", 0
	}
	var rejected *proxyFailure
	if errors.As(err, &rejected) {
		switch rejected.kind {
		case "authorization", "run_check", "run_inactive", "binding_unavailable":
			return rejected.kind, 0
		}
	}
	var transport *TransportError
	if errors.As(err, &transport) {
		if transport.Kind == "timeout" {
			return "timeout", 0
		}
		return "connection", 0
	}
	var upstream *UpstreamError
	if errors.As(err, &upstream) {
		kind = "upstream"
		switch upstream.Kind {
		case "quota", "authentication", "context_limit", "token_limit", "temperature", "tools", "model_unavailable":
			kind += "_" + upstream.Kind
		}
		if upstream.Status >= 100 && upstream.Status <= 599 {
			upstreamStatus = upstream.Status
		}
		return kind, upstreamStatus
	}
	if errors.Is(err, dom.ErrConfiguration) {
		return "configuration", 0
	}
	if errors.Is(err, dom.ErrDenied) {
		return "binding_unavailable", 0
	}
	return "internal", 0
}
