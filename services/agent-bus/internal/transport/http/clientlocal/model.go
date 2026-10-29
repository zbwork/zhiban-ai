package clientlocal

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	modelsource "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/modelerror"
	svclocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localruntime"
	svcsource "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/modelsource"
)

// LocalModelProxy forwards one run-authorized model request to the member platform.
type LocalModelProxy interface {
	ProxyLocalModel(context.Context, *dom.Task, string, json.RawMessage) (*http.Response, error)
}

func (h *Handlers) localModel(w http.ResponseWriter, r *http.Request) {
	protocol := r.PathValue("protocol")
	if protocol != "chat/completions" && protocol != "messages" && protocol != "responses" {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	task, token, err := h.localRun(r)
	if err != nil {
		localError(w, err)
		return
	}
	if h.Models == nil {
		localError(w, dom.ErrOffline)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 8*1024*1024))
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	var input map[string]json.RawMessage
	var model string
	if json.Unmarshal(body, &input) != nil || json.Unmarshal(input["model"], &model) != nil || model != task.Model {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("模型与本轮授权不一致"))
		return
	}
	if protocol == "responses" {
		if task.LocalEngine != dom.EngineCodex {
			localError(w, dom.ErrDenied)
			return
		}
		body, err = svclocal.NormalizeResponses(body)
		if err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("不支持本轮模型请求的服务端工具或跨轮状态"))
			return
		}
	}
	ctx, cancel := context.WithDeadline(r.Context(), task.ExpiresAt)
	defer cancel()
	// Long model streams must stop after a login/tenant/device revocation too.
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if _, err := h.Local.AuthorizeRun(ctx, token, task.UUID, task.Fence); err != nil {
					cancel()
					return
				}
			}
		}
	}()
	slot := r.Header.Get("X-Local-Model-Slot")
	var response *http.Response
	if slot == "" || slot == "0" {
		response, err = h.Models.ProxyLocalModel(ctx, task, protocol, body)
	} else if recovery, ok := h.Models.(interface {
		ProxyLocalRecovery(context.Context, *dom.Task, string, json.RawMessage, int) (*http.Response, error)
	}); ok && (slot == "1" || slot == "2") {
		response, err = recovery.ProxyLocalRecovery(ctx, task, protocol, body, int(slot[0]-'0'))
	} else {
		localError(w, dom.ErrDenied)
		return
	}
	logpkg.Default().Info(ctx, "local_runtime.model_route", "run", task.UUID, "slot", slot, "body_bytes", len(body), "portable", svcsource.PortableRecoveryBody(body))
	if errors.Is(err, dom.ErrDenied) || errors.Is(err, modelsource.ErrDenied) {
		localError(w, dom.ErrDenied)
		return
	}
	if err != nil {
		var transport *svcsource.TransportError
		if errors.As(err, &transport) {
			if ctx.Err() == nil {
				w.Header().Set("X-Local-Model-Retryable", "1")
			}
			logpkg.Default().Warn(ctx, "local_runtime.model_unavailable", "stage", "transport", "kind", transport.Kind)
			writeLocalModelFailure(w, "model.connection_failed", 0)
			return
		}
		var upstream *svcsource.UpstreamError
		if errors.As(err, &upstream) {
			if upstream.Retryable() {
				w.Header().Set("X-Local-Model-Retryable", "1")
			}
			logpkg.Default().Warn(ctx, "local_runtime.model_unavailable", "stage", "upstream", "status", upstream.Status, "kind", upstream.Kind, "reason", upstream.Reason)
			writeLocalModelFailure(w, upstream.PublicCode(), upstream.Status)
			return
		}
		logpkg.Default().Warn(ctx, "local_runtime.model_unavailable", "stage", "request", "cancelled", ctx.Err() != nil)
		writeLocalModelFailure(w, "model.connection_failed", 0)
		return
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		if retryableLocalModelStatus(response.StatusCode) {
			w.Header().Set("X-Local-Model-Retryable", "1")
		}
		logpkg.Default().Warn(ctx, "local_runtime.model_unavailable", "stage", "response", "status", response.StatusCode)
		upstream := &svcsource.UpstreamError{Status: response.StatusCode}
		writeLocalModelFailure(w, upstream.PublicCode(), upstream.Status)
		return
	}
	w.Header().Set("Content-Type", response.Header.Get("Content-Type"))
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(response.StatusCode)
	buffer := make([]byte, 32*1024)
	for {
		n, readErr := response.Body.Read(buffer)
		if n > 0 {
			if _, err = w.Write(buffer[:n]); err != nil {
				return
			}
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
		}
		if readErr != nil {
			return
		}
	}
}

func retryableLocalModelStatus(status int) bool {
	switch status {
	case 408, 429, 500, 502, 503, 504:
		return true
	}
	return false
}

// Preserve provider status separately from the HTTP gateway's 502 envelope.
func writeLocalModelFailure(w http.ResponseWriter, code string, status int) {
	if status >= 400 && status <= 599 {
		w.Header().Set("X-Local-Model-Upstream-Status", strconv.Itoa(status))
	}
	encode.JSONError(w, apperr.New(apperr.UpstreamUnavailable, code).Withf("%s", modelerror.Message(code, status)))
}
