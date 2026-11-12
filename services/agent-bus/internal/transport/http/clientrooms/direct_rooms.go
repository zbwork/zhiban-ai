// M5B: direct 1v1 rooms HTTP handler.
//
// 路径: POST /api/agent-bus/v1/direct-rooms · 走 authT (auth + requireTenant);
// caller / tenant 从中间件取; peer_account_uuid 由 body 提供.
//
// 当前只创建 WuKongIM direct channel(type=2) 对应的业务房间。
package clientrooms

import (
	"bytes"
	"encoding/json"
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// CreateDirectReq · POST /direct-rooms body.
type CreateDirectReq struct {
	PeerAccountUUID string `json:"peer_account_uuid"`
	Title           string `json:"title,omitempty"`
}

// CreateDirect 幂等创建 (或返回已有) direct 1v1 room.
//
// 失败码:
//   - 400 directroom.cannot_chat_with_self
//   - 404 directroom.peer_not_found
//   - 403 directroom.peer_cross_tenant
func (h *Handlers) CreateDirect(w http.ResponseWriter, r *http.Request) {
	// ADR-0026: directroom.Service 内部统一编排:peer 校验 → WuKong provisioning(有副作用)
	// → 写 rooms/participants/pair/conversation/wukong link。
	// 不在 handler 触发 WuKong 副作用、不重写事务。fail-closed:service 未装配直接拒。
	if h.DirectRoom == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("direct room service not wired"))
		return
	}
	defer r.Body.Close()
	body := new(bytes.Buffer)
	if _, err := body.ReadFrom(r.Body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	dec := json.NewDecoder(bytes.NewReader(body.Bytes()))
	dec.DisallowUnknownFields()
	var req CreateDirectReq
	if err := dec.Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if req.PeerAccountUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("peer_account_uuid required"))
		return
	}
	accountID := middleware.MustAccountID(r.Context())
	tenantID := middleware.MustTenantID(r.Context())

	res, err := h.DirectRoom.CreateOrGet(r.Context(), accountID, tenantID, req.PeerAccountUUID, req.Title)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{
		"room_uuid":           res.RoomUUID,
		"conversation_uuid":   res.ConversationUUID,
		"pair_uuid":           res.PairUUID,
		"pair_created":        res.PairCreated,
		"im_substrate":        res.IMSubstrate,
		"wukong_channel_id":   res.WuKongChannelID,
		"wukong_channel_type": res.WuKongChannelType,
		"cleared_at":          res.ClearedAt,
	})
}
