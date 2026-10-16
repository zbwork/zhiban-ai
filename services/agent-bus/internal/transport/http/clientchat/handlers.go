package clientchat

import (
	"context"
	"encoding/json"
	dommsg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/message"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcchat "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/chat"
	"net/http"
	"strconv"
	"time"
)

type Service interface {
	Send(context.Context, int64, int64, svcchat.SendReq) (*svcchat.SendResp, error)
	SubscribeWithOwner(context.Context, int64, int64, string) (<-chan svcchat.StreamEvent, func(), error)
	ReplayTerminalIfDone(context.Context, string) *svcchat.StreamEvent
	History(context.Context, int64, int64, string, int) ([]dommsg.Message, error)
	Stop(context.Context, int64, int64, svcchat.StopReq) (*svcchat.StopResp, error)
	Retry(context.Context, int64, int64, svcchat.RetryReq) (*svcchat.RetryResp, error)
}
type Handlers struct {
	Chat       Service
	BeforeSend func(http.ResponseWriter, *http.Request, svcchat.SendReq) bool
}

func (h *Handlers) Stream(w http.ResponseWriter, r *http.Request) {
	streamID := r.URL.Query().Get("stream_id")
	if streamID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("stream_id required"))
		return
	}
	// Batch1 返修 #5: 校验 stream 归属（与 admin try-chat 一致）
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	ch, cancel, err := h.Chat.SubscribeWithOwner(r.Context(), accID, tid, streamID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	defer cancel()
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	flusher, _ := w.(http.Flusher)
	if flusher == nil {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}
	enc := json.NewEncoder(w)
	// 晚订阅竞态兜底: ZAP/dsh 快回复可能在订阅前就把终帧发布到 fanout(per-stream Subscribe 不回放),
	// 此时读通道会永久阻塞、客户端卡"处理中"。订阅成功后若该 stream 已终态,从落库消息补发一次终帧即结束。
	// 订阅在前、判定在后: 通道里若已有该终帧(订阅赶在发布前)则本次补发即客户端唯一终帧,不重复。
	if term := h.Chat.ReplayTerminalIfDone(r.Context(), streamID); term != nil {
		w.Write([]byte("data: "))
		_ = enc.Encode(*term)
		w.Write([]byte("\n"))
		flusher.Flush()
		return
	}
	for {
		select {
		case <-r.Context().Done():
			return
		case ev, ok := <-ch:
			if !ok {
				return
			}
			w.Write([]byte("data: "))
			_ = enc.Encode(ev)
			w.Write([]byte("\n"))
			flusher.Flush()
			// T2D.5: 任一终态事件 (completed / failed / cancelled) 后断 SSE。
			if ev.IsTerminal() {
				return
			}
		}
	}
}

func (h *Handlers) Stop(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("message_uuid required"))
		return
	}
	var body chatStopReq
	// body 可选; 解析失败仅在传了非空 body 时报错
	if r.ContentLength > 0 {
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
			return
		}
	}
	resp, err := h.Chat.Stop(r.Context(), accID, tid, svcchat.StopReq{
		MessageUUID: uuid,
		Reason:      body.Reason,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) Retry(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("message_uuid required"))
		return
	}
	resp, err := h.Chat.Retry(r.Context(), accID, tid, svcchat.RetryReq{MessageUUID: uuid})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) History(w http.ResponseWriter, r *http.Request) {
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	items, err := h.Chat.History(r.Context(), accID, tid, uuid, limit)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	out := make([]chatMessageDTO, 0, len(items))
	for _, m := range items {
		out = append(out, chatMessageDTO{
			UUID:         m.UUID,
			Role:         m.Role,
			Blocks:       MessageBlocksForClient(m.Status, m.Blocks),
			Status:       m.Status,
			Final:        m.Final,
			StreamID:     m.StreamID,
			ErrorCode:    m.ErrorCode,
			ErrorMessage: m.ErrorMessage,
			Metadata:     m.Metadata,
			CreatedAt:    m.CreatedAt.Format(time.RFC3339),
		})
	}
	encode.JSON(w, map[string]any{"items": out})
}

type chatStopReq struct {
	Reason string `json:"reason,omitempty"`
}
type chatMessageDTO struct {
	UUID         string           `json:"uuid"`
	Role         string           `json:"role"`   // user / agent / system / tool
	Blocks       []map[string]any `json:"blocks"` // EMP block 数组
	Status       string           `json:"status"` // streaming / final / cancelled / failed
	Final        bool             `json:"final"`
	StreamID     string           `json:"stream_id,omitempty"`
	ErrorCode    string           `json:"error_code,omitempty"`
	ErrorMessage string           `json:"error_message,omitempty"`
	Metadata     map[string]any   `json:"metadata,omitempty"`
	CreatedAt    string           `json:"created_at"`
}

func MessageBlocksForClient(status string, blocks []map[string]any) []map[string]any {
	if status == "cancelled" || blocks == nil {
		return []map[string]any{}
	}
	return blocks
}

func (h *Handlers) Send(w http.ResponseWriter, r *http.Request) {
	var req svcchat.SendReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	req.LocalLoginSessionUUID = middleware.SessionUUID(r.Context())
	if h.BeforeSend != nil && !h.BeforeSend(w, r, req) {
		return
	}
	resp, err := h.Chat.Send(r.Context(), middleware.MustAccountID(r.Context()), middleware.MustTenantID(r.Context()), req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}
