// me_sessions.go — F01 §4.5 多设备管理 /me/sessions endpoints。
//
// 列当前账号 active session, 一键撤销其他设备 (踢自己), 必走撤销实时生效链路
// (RedisRevoker + pglistener)。
package admincore

import (
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

func (h *Handlers) listMySessions(w http.ResponseWriter, r *http.Request) {
	aid := middleware.MustAccountID(r.Context())
	if aid <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	currentSession := middleware.SessionUUID(r.Context())
	items, err := h.Auth.ListMySessions(r.Context(), aid, currentSession)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items})
}

func (h *Handlers) revokeMySession(w http.ResponseWriter, r *http.Request) {
	aid := middleware.MustAccountID(r.Context())
	if aid <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	uuid := r.PathValue("uuid")
	if err := h.Auth.RevokeMySession(r.Context(), aid, uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "revoked": true})
}
