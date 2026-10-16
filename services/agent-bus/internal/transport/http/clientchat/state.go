// B-5-1: per-account conversation view state.
//
// v1 (既有):
//
//	DELETE /api/agent-bus/v1/chat/conversations/{uuid}    → cleared_at=now(), hidden_at=now()
//	POST   /api/agent-bus/v1/chat/conversations/{uuid}/show → hidden_at=NULL (保留 cleared_at)
//	POST   /api/agent-bus/v1/chat/conversations/{uuid}/read body{last_read_message_uuid?}
//
// v2 (F09 P2 「会话列表操作菜单 v2」):
//
//	POST /api/agent-bus/v1/chat/conversations/{uuid}/pin    body{pinned: bool}
//	POST /api/agent-bus/v1/chat/conversations/{uuid}/mute   body{muted: bool}
//	POST /api/agent-bus/v1/chat/conversations/{uuid}/unread (no body → set marked_unread_at)
//
// 不删全局 conversation / 不删 messages / 不影响其他参与者 (per-account 视图态).
// 见 docs/contracts/agent-bus-client-contract.md §「会话列表操作菜单 v2」.
//
// 安全闸 (Codex CR1 修复): 5 个 endpoint 必须先校验 caller 对该 conversation
// 可见/参与 (复用 conversation.Repo.AccessibleByAccount), 否则 ErrForbidden;
// 不允许在不可见会话上凭空创建 conversation_account_state 行 (脏行 / 信息泄露).
package clientchat

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/id"
	logpkg "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
	repoconvstate "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/convstate"
	svcreceipts "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/messagereceipts"
)

// assertConvAccessible · CR1: 所有 conversation_account_state 写动作前共享闸.
// h.ConvAccess=nil 视作未装配 → 500 (与既有 ConvState=nil 一致).
// 不可见 (caller 不是 single owner 且 不是 active room participant) → 403.
// uuid 空 → 400.
func (h *StateHandlers) assertConvAccessible(w http.ResponseWriter, r *http.Request, uuid string) (accountID, tenantID int64, ok bool) {
	if uuid == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid required"))
		return 0, 0, false
	}
	// 客户端在真实 conversation 落库前会用 "pending:<agent_uuid>" 之类占位符本地寻址
	// (ADR-0037 联调实测暴露: 数字员工首次发消息, 客户端在会话真正创建前就打了一次
	// mark-read); 这类非 UUID 格式的值直接进 AccessibleByAccount 的 SQL 会被 Postgres
	// 拒成 "invalid input syntax for type uuid" (SQLSTATE 22P02), 未分类, 兜底成 500
	// 把裸 SQL 报错泄给客户端。当成跟 "uuid 空" 同类的入参问题, 提前 400 掉。
	if !id.IsValidUUID(uuid) {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("uuid malformed"))
		return 0, 0, false
	}
	if h.ConvAccess == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("conv access repo not wired"))
		return 0, 0, false
	}
	accountID = middleware.MustAccountID(r.Context())
	tenantID = middleware.MustTenantID(r.Context())
	allowed, err := h.ConvAccess.AccessibleByAccount(r.Context(), tenantID, accountID, uuid)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return 0, 0, false
	}
	if !allowed {
		encode.JSONError(w, apperr.ErrForbidden.Withf("chat.conversation_not_accessible"))
		return 0, 0, false
	}
	return accountID, tenantID, true
}

func (h *StateHandlers) DeleteConversationForAccount(w http.ResponseWriter, r *http.Request) {
	if h.ConvState == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("conv state repo not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	accountID, tenantID, ok := h.assertConvAccessible(w, r, uuid)
	if !ok {
		return
	}
	if err := h.ConvState.ClearHistory(r.Context(), accountID, tenantID, uuid); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"conversation_uuid": uuid, "hidden": true, "cleared": true})
}

func (h *StateHandlers) ShowConversationForAccount(w http.ResponseWriter, r *http.Request) {
	if h.ConvState == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("conv state repo not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	accountID, tenantID, ok := h.assertConvAccessible(w, r, uuid)
	if !ok {
		return
	}
	if err := h.ConvState.ClearHidden(r.Context(), accountID, tenantID, uuid); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"conversation_uuid": uuid, "hidden": false})
}

func (h *StateHandlers) MarkConversationRead(w http.ResponseWriter, r *http.Request) {
	if h.ConvState == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("conv state repo not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	accountID, tenantID, ok := h.assertConvAccessible(w, r, uuid)
	if !ok {
		return
	}
	var body struct {
		LastReadMessageUUID string `json:"last_read_message_uuid"`
		// F09 P1 「消息级已读回执 v1」: 客户端打开会话 / 滚到底部 / 新消息上屏后
		// 上报当前最新 message_seq 作为水位; 服务端取较大者(防多端乱序回退).
		LastReadMessageSeq int64 `json:"last_read_message_seq"`
	}
	if r.ContentLength > 0 {
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()
		_ = dec.Decode(&body)
	}
	if err := h.ConvState.MarkRead(r.Context(), accountID, tenantID, uuid, body.LastReadMessageUUID, body.LastReadMessageSeq); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	if body.LastReadMessageSeq > 0 {
		h.publishReadReceiptChanged(r.Context(), tenantID, accountID, uuid, body.LastReadMessageSeq)
	}
	encode.JSON(w, map[string]any{"conversation_uuid": uuid, "read": true})
}

func (h *StateHandlers) publishReadReceiptChanged(ctx context.Context, tenantID, readerAccountID int64, conversationUUID string, lastReadMessageSeq int64) {
	if h.ReadReceiptSignals == nil || tenantID <= 0 || readerAccountID <= 0 || conversationUUID == "" || lastReadMessageSeq <= 0 {
		return
	}
	if err := h.ReadReceiptSignals.NotifyReadReceiptChanged(ctx, svcreceipts.NotifyReadReceiptChangedIn{
		TenantID:           tenantID,
		ReaderAccountID:    readerAccountID,
		ConversationUUID:   conversationUUID,
		LastReadMessageSeq: lastReadMessageSeq,
	}); err != nil {
		logpkg.Default().Warn(ctx,
			"read receipt signal publish failed",
			"tenant_id", tenantID,
			"reader_account_id", readerAccountID,
			"conversation_uuid", conversationUUID,
			"last_read_message_seq", lastReadMessageSeq,
			"err", err,
		)
	}
}

// pinConversation POST /chat/conversations/{uuid}/pin body{pinned:bool}.
//
// F09 P2 「会话列表操作菜单 v2」 · per-account pin / unpin. 不改 conversation / 不影响他人.
// pinned=true → upsert pinned_at=now(); false → 清 NULL.
func (h *StateHandlers) PinConversation(w http.ResponseWriter, r *http.Request) {
	if h.ConvState == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("conv state repo not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	accountID, tenantID, ok := h.assertConvAccessible(w, r, uuid)
	if !ok {
		return
	}
	var body struct {
		Pinned bool `json:"pinned"`
	}
	if r.ContentLength > 0 {
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()
		if err := dec.Decode(&body); err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
			return
		}
	}
	if err := h.ConvState.SetPinned(r.Context(), accountID, tenantID, uuid, body.Pinned); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"conversation_uuid": uuid, "pinned": body.Pinned})
}

// muteConversation POST /chat/conversations/{uuid}/mute body{muted:bool}.
//
// F09 P2 「会话列表操作菜单 v2」 · per-account mute / unmute. 只影响客户端红点/通知,
// 不影响消息投递 / 历史 / WuKong 长连接.
func (h *StateHandlers) MuteConversation(w http.ResponseWriter, r *http.Request) {
	if h.ConvState == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("conv state repo not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	accountID, tenantID, ok := h.assertConvAccessible(w, r, uuid)
	if !ok {
		return
	}
	var body struct {
		Muted bool `json:"muted"`
	}
	if r.ContentLength > 0 {
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()
		if err := dec.Decode(&body); err != nil {
			encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
			return
		}
	}
	if err := h.ConvState.SetMuted(r.Context(), accountID, tenantID, uuid, body.Muted); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"conversation_uuid": uuid, "muted": body.Muted})
}

// markConversationUnread POST /chat/conversations/{uuid}/unread (no body).
//
// F09 P2 「会话列表操作菜单 v2」 · 人工标为未读 (marked_unread_at=now()).
// 与 markConversationRead 互斥 (markRead 会清 marked_unread_at).
// 客户端任一 (marked_unread || unread_count>0) 为真即显示红点 (无数字).
func (h *StateHandlers) MarkConversationUnread(w http.ResponseWriter, r *http.Request) {
	if h.ConvState == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("conv state repo not wired"))
		return
	}
	uuid := r.PathValue("uuid")
	accountID, tenantID, ok := h.assertConvAccessible(w, r, uuid)
	if !ok {
		return
	}
	if err := h.ConvState.SetMarkedUnread(r.Context(), accountID, tenantID, uuid); err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, map[string]any{"conversation_uuid": uuid, "marked_unread": true})
}

// ConvStateRepo · narrow interface for bus router (avoid leaking pgx into transport layer).
type ConvStateRepo interface {
	SetHidden(ctx context.Context, accountID, tenantID int64, conversationUUID string) error
	ClearHistory(ctx context.Context, accountID, tenantID int64, conversationUUID string) error
	ClearHidden(ctx context.Context, accountID, tenantID int64, conversationUUID string) error
	MarkRead(ctx context.Context, accountID, tenantID int64, conversationUUID, lastReadMessageUUID string, lastReadMessageSeq int64) error
	ClearedAt(ctx context.Context, accountID, tenantID int64, conversationUUID string) (*time.Time, error)
	// ListForAccount · B-5-1: conv list LEFT JOIN CAS, transport 层 in-memory 合并.
	ListForAccount(ctx context.Context, accountID, tenantID int64) ([]repoconvstate.AccountConvState, error)
	// F09 P2 「会话列表操作菜单 v2」 per-account 视图态扩展.
	SetPinned(ctx context.Context, accountID, tenantID int64, conversationUUID string, pinned bool) error
	SetMuted(ctx context.Context, accountID, tenantID int64, conversationUUID string, muted bool) error
	SetMarkedUnread(ctx context.Context, accountID, tenantID int64, conversationUUID string) error
}

// ConvAccessChecker · CR1: caller 是否对 conversation 可见 (single owner 或 active human room participant).
// 唯一实现是 conversation.Repo.AccessibleByAccount.
type ConvAccessChecker interface {
	AccessibleByAccount(ctx context.Context, tenantID, accountID int64, conversationUUID string) (bool, error)
}

type ReadReceiptNotifier interface {
	NotifyReadReceiptChanged(ctx context.Context, in svcreceipts.NotifyReadReceiptChangedIn) error
}

// type guard.
var _ ConvStateRepo = (*repoconvstate.Repo)(nil)

type StateHandlers struct {
	ConvState  ConvStateRepo
	ConvAccess interface {
		AccessibleByAccount(context.Context, int64, int64, string) (bool, error)
	}
	ReadReceiptSignals interface {
		NotifyReadReceiptChanged(context.Context, svcreceipts.NotifyReadReceiptChangedIn) error
	}
}
