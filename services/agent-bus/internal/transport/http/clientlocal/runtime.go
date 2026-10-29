package clientlocal

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	svcdrive "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
	svcmedia "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localmedia"
	svclocal "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/localruntime"
	svcsource "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/modelsource"
	svcsearch "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/websearch"
)

// Handlers serves the community Local Agent control plane, member model platforms,
// image generation, web search and file archiving into the drive.
type Handlers struct {
	Local   *svclocal.Service
	Models  LocalModelProxy
	Sources *svcsource.Service
	Images  *svcmedia.Service
	Search  *svcsearch.Service
	Outputs *svcdrive.ZAPSvc
}

func localScope(r *http.Request) dom.Scope {
	return dom.Scope{AccountID: middleware.MustAccountID(r.Context()), TenantID: middleware.MustTenantID(r.Context()), SessionUUID: middleware.SessionUUID(r.Context())}
}
func localError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, dom.ErrUpgradeRequired):
		encode.JSONErrorWithCode(w, http.StatusConflict, map[string]any{"code": "local_runtime.upgrade_required", "message": "电脑已在线，请更新电脑端后再派活"})
	case errors.Is(err, dom.ErrOffline):
		encode.JSONError(w, apperr.ErrUpstreamUnavailable.Withf("这台电脑不在线，请保持桌面应用登录并唤醒电脑"))
	case errors.Is(err, dom.ErrConflict), errors.Is(err, dom.ErrSequence):
		encode.JSONErrorWithCode(w, http.StatusConflict, map[string]any{"code": "local_runtime.conflict", "message": "本机任务或连接状态已变化，请刷新后重试"})
	case errors.Is(err, dom.ErrDenied):
		encode.JSONError(w, apperr.ErrForbidden.Withf("本机运行授权已失效"))
	default:
		encode.JSONError(w, apperr.ErrUpstreamUnavailable.Withf("本机运行服务暂不可用"))
	}
}

func (h *Handlers) localRegister(w http.ResponseWriter, r *http.Request) {
	if h.Local == nil {
		localError(w, dom.ErrOffline)
		return
	}
	var input struct {
		Engines         map[string]string `json:"engines"`
		ProtocolVersion int               `json:"protocol_version"`
		Platform        string            `json:"platform"`
		InstallationID  string            `json:"installation_id"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil {
		encode.JSONError(w, apperr.ErrInvalidParams)
		return
	}
	device, err := h.Local.RegisterWithEngines(r.Context(), localScope(r), input.Platform, input.InstallationID, input.ProtocolVersion, input.Engines)
	if err != nil {
		logpkg.Default().Warn(r.Context(), "local_runtime.register_failed", "account_id", middleware.MustAccountID(r.Context()), "tenant_id", middleware.MustTenantID(r.Context()), "platform", input.Platform, "protocol_version", input.ProtocolVersion, "error", err.Error())
		localError(w, err)
		return
	}
	logpkg.Default().Info(r.Context(), "local_runtime.register_succeeded", "account_id", middleware.MustAccountID(r.Context()), "tenant_id", middleware.MustTenantID(r.Context()), "device", device.UUID, "generation", device.Generation, "platform", input.Platform, "protocol_version", input.ProtocolVersion)
	w.Header().Set("Cache-Control", "no-store")
	encode.JSON(w, device)
}
func (h *Handlers) localRevoke(w http.ResponseWriter, r *http.Request) {
	if h.Local == nil {
		localError(w, dom.ErrOffline)
		return
	}
	if err := h.Local.Revoke(r.Context(), localScope(r), r.PathValue("device")); err != nil {
		localError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

type localInput struct {
	Type  string          `json:"type"`
	Run   string          `json:"run_id"`
	Fence int64           `json:"fencing_token"`
	Seq   int64           `json:"seq"`
	Event string          `json:"event"`
	Data  json.RawMessage `json:"data"`
}

func (h *Handlers) localChannel(w http.ResponseWriter, r *http.Request) {
	if h.Local == nil {
		localError(w, dom.ErrOffline)
		return
	}
	if r.Header.Get("Origin") != "" {
		logpkg.Default().Warn(r.Context(), "local_runtime.connect_rejected", "stage", "origin", "account_id", middleware.MustAccountID(r.Context()), "tenant_id", middleware.MustTenantID(r.Context()))
		localError(w, dom.ErrDenied)
		return
	}
	scope := localScope(r)
	generation, err := strconv.ParseInt(r.Header.Get("X-Local-Generation"), 10, 64)
	if err != nil || generation < 0 {
		logpkg.Default().Warn(r.Context(), "local_runtime.connect_rejected", "stage", "generation", "account_id", scope.AccountID, "tenant_id", scope.TenantID, "device", r.Header.Get("X-Local-Device"), "generation_header", r.Header.Get("X-Local-Generation"), "error", "invalid generation")
		localError(w, dom.ErrDenied)
		return
	}
	device, err := h.Local.Connect(r.Context(), scope, r.Header.Get("X-Local-Device"), generation, r.Header.Get("X-Local-Connect-Token"))
	if err != nil {
		logpkg.Default().Warn(r.Context(), "local_runtime.connect_failed", "account_id", scope.AccountID, "tenant_id", scope.TenantID, "device", r.Header.Get("X-Local-Device"), "generation", generation, "error", err.Error())
		localError(w, err)
		return
	}
	logpkg.Default().Info(r.Context(), "local_runtime.connect_succeeded", "account_id", scope.AccountID, "tenant_id", scope.TenantID, "device", device.UUID, "generation", device.Generation)
	defer func() {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
		defer cancel()
		if err := h.Local.Disconnect(ctx, scope, device.UUID, device.Generation); err != nil {
			logpkg.Default().Warn(ctx, "local_runtime.disconnect_failed", "account_id", scope.AccountID, "tenant_id", scope.TenantID, "device", device.UUID, "generation", device.Generation, "error", err.Error())
		}
	}()
	upgrader := websocket.Upgrader{CheckOrigin: func(req *http.Request) bool { return req.Header.Get("Origin") == "" }, ReadBufferSize: 4096, WriteBufferSize: 4096}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		logpkg.Default().Warn(r.Context(), "local_runtime.websocket_upgrade_failed", "account_id", scope.AccountID, "tenant_id", scope.TenantID, "device", device.UUID, "generation", device.Generation, "error", err.Error())
		return
	}
	logpkg.Default().Info(r.Context(), "local_runtime.websocket_opened", "account_id", scope.AccountID, "tenant_id", scope.TenantID, "device", device.UUID, "generation", device.Generation)
	defer conn.Close()
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	conn.SetReadLimit(1024*1024 + 4096)
	inputs := make(chan localInput, 32)
	readErrors := make(chan error, 1)
	go func() {
		for {
			var input localInput
			_ = conn.SetReadDeadline(time.Now().Add(15 * time.Second))
			if err := conn.ReadJSON(&input); err != nil {
				readErrors <- err
				return
			}
			select {
			case inputs <- input:
			case <-ctx.Done():
				return
			}
		}
	}()
	write := func(value any) error {
		_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		return conn.WriteJSON(value)
	}
	if write(map[string]any{"type": "hello", "version": 1, "device_id": device.UUID, "generation": device.Generation}) != nil {
		return
	}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	active := map[string]int64{}
	sent := map[string]bool{}
	for {
		select {
		case <-ctx.Done():
			return
		case err := <-readErrors:
			logpkg.Default().Warn(ctx, "local_runtime.channel_closed", "stage", "read", "account_id", scope.AccountID, "tenant_id", scope.TenantID, "device", device.UUID, "generation", device.Generation, "error", err.Error())
			return
		case input := <-inputs:
			switch input.Type {
			case "heartbeat":
				if err := h.Local.Heartbeat(ctx, scope, device.UUID, device.Generation); err != nil {
					logpkg.Default().Warn(ctx, "local_runtime.channel_closed", "stage", "heartbeat", "error", err)
					return
				}
				if write(map[string]any{"type": "heartbeat.ack", "generation": device.Generation}) != nil {
					return
				}
			case "task.resume":
				task, err := h.Local.Task(ctx, scope, input.Run)
				if err != nil || task.DeviceUUID != device.UUID || task.Fence != input.Fence {
					return
				}
				if task.Status == "accepted" || task.Status == "dispatched" {
					active[input.Run] = task.Fence
				}
				if write(map[string]any{"type": "task.state", "run_id": input.Run, "fencing_token": task.Fence, "status": task.Status, "seq": task.LastSeq}) != nil {
					return
				}
			case "task.accepted":
				if err := h.Local.Accept(ctx, scope, device.UUID, device.Generation, input.Run, input.Fence); err != nil {
					if write(map[string]any{"type": "task.rejected", "run_id": input.Run, "code": "local_runtime.conflict"}) != nil {
						return
					}
					continue
				}
				active[input.Run] = input.Fence
				if write(map[string]any{"type": "task.accepted_ack", "run_id": input.Run, "fencing_token": input.Fence}) != nil {
					return
				}
			case "event":
				seq, err := h.Local.Append(ctx, scope, device.UUID, device.Generation, dom.Event{RunUUID: input.Run, Fence: input.Fence, Seq: input.Seq, Name: input.Event, Data: input.Data})
				if err != nil {
					if write(map[string]any{"type": "event.rejected", "run_id": input.Run, "seq": seq, "code": "local_runtime.conflict"}) != nil {
						return
					}
					continue
				}
				if write(map[string]any{"type": "event.ack", "run_id": input.Run, "fencing_token": input.Fence, "seq": seq}) != nil {
					return
				}
				if input.Event == "message.completed" || input.Event == "message.failed" || input.Event == "message.cancelled" {
					delete(active, input.Run)
				}
			default:
				return
			}
		case <-ticker.C:
			pending, err := h.Local.Pending(ctx, scope, device.UUID, device.Generation)
			if err != nil {
				logpkg.Default().Warn(ctx, "local_runtime.channel_closed", "stage", "pending", "error", err)
				return
			}
			for _, delivery := range pending {
				if sent[delivery.Task.UUID] {
					continue
				}
				active[delivery.Task.UUID] = delivery.Task.Fence
				sent[delivery.Task.UUID] = true
				if write(map[string]any{"type": "task.dispatch", "task": delivery.Task, "capability": delivery.Capability}) != nil {
					return
				}
			}
			for run, fence := range active {
				task, err := h.Local.Task(ctx, scope, run)
				if err != nil {
					return
				}
				if task.Status == "cancelled" || task.Status == "failed" || !task.ExpiresAt.After(time.Now()) {
					if write(map[string]any{"type": "task.cancel", "run_id": run, "fencing_token": fence}) != nil {
						return
					}
					delete(active, run)
				}
			}
		}
	}
}

func (h *Handlers) localRun(r *http.Request) (*dom.Task, string, error) {
	if h.Local == nil {
		return nil, "", dom.ErrOffline
	}
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		return nil, "", dom.ErrDenied
	}
	token := strings.TrimPrefix(auth, "Bearer ")
	fence, err := strconv.ParseInt(r.Header.Get("X-Local-Fence"), 10, 64)
	if err != nil {
		return nil, "", dom.ErrDenied
	}
	task, err := h.Local.AuthorizeRun(r.Context(), token, r.PathValue("run"), fence)
	return task, token, err
}
func (h *Handlers) localAuthorize(w http.ResponseWriter, r *http.Request) {
	task, _, err := h.localRun(r)
	if err != nil {
		localError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	encode.JSON(w, map[string]any{"valid": true, "expires_at": task.ExpiresAt})
}
