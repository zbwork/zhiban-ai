package admincore

import (
	"net/http"
	"strings"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svcmedia "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/media"
)

func isMediaUserError(msg string) bool {
	return strings.Contains(msg, "media.unsupported_kind") ||
		strings.Contains(msg, "media.unsupported_mime") ||
		strings.Contains(msg, "media.too_large") ||
		strings.Contains(msg, "media.empty_body")
}

type mediaPreviewReq struct {
	URIs []string `json:"uris"`
}

type mediaPreviewItem struct {
	StorageURI string `json:"storage_uri"`
	PreviewURL string `json:"preview_url"`
}

func (h *Handlers) uploadSkillIconMedia(w http.ResponseWriter, r *http.Request) {
	h.uploadMedia(w, r, svcmedia.KindSkillIcon)
}

func (h *Handlers) uploadSkillExampleImageMedia(w http.ResponseWriter, r *http.Request) {
	h.uploadMedia(w, r, svcmedia.KindSkillExampleImage)
}

func (h *Handlers) uploadAgentAvatarMedia(w http.ResponseWriter, r *http.Request) {
	h.uploadMedia(w, r, svcmedia.KindAgentAvatar)
}

func (h *Handlers) uploadMedia(w http.ResponseWriter, r *http.Request, kind svcmedia.Kind) {
	if h.Media == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("media service not configured"))
		return
	}
	if err := r.ParseMultipartForm(4 << 20); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("parse multipart: %v", err))
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("missing file field: %v", err))
		return
	}
	defer file.Close()
	if header.Size <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("empty file"))
		return
	}
	out, err := h.Media.UploadForTenant(r.Context(), 0, svcmedia.UploadInput{
		Kind:        kind,
		Body:        file,
		ContentType: header.Header.Get("Content-Type"),
	})
	if err != nil {
		msg := err.Error()
		if isMediaUserError(msg) {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("%s", msg))
		} else {
			encode.JSONError(w, apperr.ErrUpstreamUnavailable.Withf("media storage unavailable"))
		}
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) previewMedia(w http.ResponseWriter, r *http.Request) {
	if h.Media == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("media service not configured"))
		return
	}
	body, err := readJSON[mediaPreviewReq](r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	resolved := h.Media.ResolveURLMapForTenant(r.Context(), 0, body.URIs)
	items := make([]mediaPreviewItem, 0, len(body.URIs))
	seen := map[string]struct{}{}
	for _, uri := range body.URIs {
		if uri == "" {
			continue
		}
		if _, ok := seen[uri]; ok {
			continue
		}
		seen[uri] = struct{}{}
		items = append(items, mediaPreviewItem{StorageURI: uri, PreviewURL: resolved[uri]})
	}
	encode.JSON(w, map[string]any{"items": items})
}
