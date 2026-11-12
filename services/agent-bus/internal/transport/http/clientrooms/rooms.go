// Batch 2E T2E.5: rooms HTTP handlers (group chat).
//
// 路径前缀 /api/agent-bus/v1/rooms; 全部走 authT (auth + requireTenant)。
// caller 身份从中间件取 + 调用 contacts.IsTenantAdmin / ResolveCallerDepartment 补全
// IsTenantAdmin / DepartmentID, 给 room.Service.CanCreateGroup 预检用。
package clientrooms

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcroom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/room"
)

// callerCtx 复用 contacts.go 的 IsTenantAdmin / dept 解析逻辑。
func (h *Handlers) callerCtx(r *http.Request) (svcroom.CallerCtx, error) {
	c := svcroom.CallerCtx{
		AccountID:    middleware.MustAccountID(r.Context()),
		TenantID:     middleware.MustTenantID(r.Context()),
		DepartmentID: middleware.WorkspaceID(r.Context()),
	}
	if c.TenantID > 0 && h.Contacts != nil {
		if c.DepartmentID == 0 {
			did, err := h.Contacts.ResolveCallerDepartment(r.Context(), c.AccountID, c.TenantID)
			if err != nil {
				return c, err
			}
			c.DepartmentID = did
		}
		isAdmin, err := h.Contacts.IsTenantAdmin(r.Context(), c.AccountID, c.TenantID)
		if err != nil {
			return c, err
		}
		c.IsTenantAdmin = isAdmin
	}
	return c, nil
}

func (h *Handlers) Create(w http.ResponseWriter, r *http.Request) {
	caller, err := h.callerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var req svcroom.CreateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Room.Create(r.Context(), caller, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) Get(w http.ResponseWriter, r *http.Request) {
	caller, err := h.callerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	out, err := h.Room.Get(r.Context(), caller, r.PathValue("room_uuid"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) AddParticipants(w http.ResponseWriter, r *http.Request) {
	caller, err := h.callerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var req svcroom.AddParticipantsReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Room.AddParticipant(r.Context(), caller, r.PathValue("room_uuid"), req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"participants": out})
}

func (h *Handlers) RemoveParticipant(w http.ResponseWriter, r *http.Request) {
	caller, err := h.callerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if err := h.Room.RemoveParticipant(r.Context(), caller, r.PathValue("room_uuid"), r.PathValue("participant_uuid")); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}

// SendMessage · F09 PR13 / C2-06: client API 已 deprecated; 客户端必须经 WuKongIM SDK 发群消息.
// 仍保留 endpoint 给 ZAP backchannel (`/zap/v1/internal/messages/inbox`) / cron-into-group (F08) /
// admin scope backfill 内部调用 (它们有自己的 auth, 不经此路径; 此处客户端 session 路径仅作 audit + 兼容).
//
// 增加 Deprecation/Sunset 响应头 (RFC 8594) 提示 client 迁移. 真客户端 (zhiban-app /
// example-demo) 已确认无调用 (grep confirmed PR13 audit). 一旦真 prod 监测到外部调用,
// 通过 `f09_legacy_room_messages_client_call_total` (TBD; follow-up) 或 nginx log 排查.
func (h *Handlers) SendMessage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Deprecation", "true")
	w.Header().Set("Sunset", "F09 PR13: client path deprecated; use WuKongIM SDK sendMessage (see docs/contracts/agent-bus-client-contract.md §10)")
	caller, err := h.callerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var req svcroom.SendMessageReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Room.SendMessage(r.Context(), caller, r.PathValue("room_uuid"), req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// Rename · F09 P2 「会话列表操作菜单 v2」: PATCH /api/agent-bus/v1/rooms/{room_uuid} body{title}.
// 仅 group, 仅 creator. 见 docs/contracts/agent-bus-client-contract.md §「会话列表操作菜单 v2」.
func (h *Handlers) Rename(w http.ResponseWriter, r *http.Request) {
	caller, err := h.callerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var body struct {
		Title string `json:"title"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Room.RenameGroup(r.Context(), caller, r.PathValue("room_uuid"), body.Title)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// ListMessages · F09 PR13 / C2-06: 同 SendMessage deprecation gate.
// 客户端拉群历史必须经 WuKongIM SDK/Bus proxy; Bus 端这里只保留兼容路径。
func (h *Handlers) ListMessages(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Deprecation", "true")
	w.Header().Set("Sunset", "F09 PR13: client path deprecated; use WuKongIM history path")
	caller, err := h.callerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	req := svcroom.ListMessagesReq{
		Limit:      limit,
		BeforeUUID: r.URL.Query().Get("before_uuid"),
	}
	items, err := h.Room.ListMessages(r.Context(), caller, r.PathValue("room_uuid"), req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}
