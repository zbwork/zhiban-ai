// chat_media.go — P2.2c: 聊天文件消息会话级媒体引用 transport。
//
//	POST /api/agent-bus/v1/chat/media                    → 建 ref (发送方鉴权)
//	GET  /api/agent-bus/v1/chat/media/{uuid}/preview     → 302 (room 成员鉴权 → 现签 inline)
//	GET  /api/agent-bus/v1/chat/media/{uuid}/download     → 302 (room 成员鉴权 → 现签 attachment)
//
// WuKong payload 只存 /chat/media/{ref}/preview|download 稳定 URL;不存 S3 signed / :5001 / 原始 drive URL。
package clientfiles

import (
	"encoding/json"
	"net/http"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/drive"
)

func (h *Handlers) CreateMedia(w http.ResponseWriter, r *http.Request) {
	if h.ChatMedia == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("chat-media service not wired"))
		return
	}
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	var req drive.ChatMediaCreateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	resp, err := h.ChatMedia.CreateRef(r.Context(), accID, tid, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, resp)
}

func (h *Handlers) PreviewMedia(w http.ResponseWriter, r *http.Request) {
	h.serveMedia(w, r, true)
}

func (h *Handlers) DownloadMedia(w http.ResponseWriter, r *http.Request) {
	h.serveMedia(w, r, false)
}

func (h *Handlers) serveMedia(w http.ResponseWriter, r *http.Request, inline bool) {
	if h.ChatMedia == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("chat-media service not wired"))
		return
	}
	accID := middleware.MustAccountID(r.Context())
	tid := middleware.MustTenantID(r.Context())
	refUUID := r.PathValue("uuid")
	if refUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("ref_uuid required"))
		return
	}
	var (
		resp *drive.ChatMediaDownloadResp
		err  error
	)
	if inline {
		resp, err = h.ChatMedia.Preview(r.Context(), accID, tid, refUUID)
	} else {
		resp, err = h.ChatMedia.Download(r.Context(), accID, tid, refUUID)
	}
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if r.Header.Get("Accept") == "application/json" {
		encode.JSON(w, resp)
		return
	}
	http.Redirect(w, r, resp.URL, http.StatusFound)
}
