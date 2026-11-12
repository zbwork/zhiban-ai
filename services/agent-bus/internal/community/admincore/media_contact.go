package admincore

import (
	"context"
	"encoding/json"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svccontactpolicy "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/contactpolicy"
	"net/http"
	"strings"
)

func (h *Handlers) resolveMediaURL(ctx context.Context, raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://") || strings.HasPrefix(raw, "/api/") {
		return raw
	}
	if h.Media != nil {
		return h.Media.ResolveURLForTenant(ctx, 0, raw)
	}
	return ""
}

func (h *Handlers) resolveMediaURLMap(ctx context.Context, raws []string) map[string]string {
	if h.Media != nil {
		return h.Media.ResolveURLMapForTenant(ctx, 0, raws)
	}
	out := make(map[string]string, len(raws))
	for _, raw := range raws {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		if _, ok := out[raw]; ok {
			continue
		}
		out[raw] = h.resolveMediaURL(ctx, raw)
	}
	return out
}

func (h *Handlers) getContactPolicy(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	p, err := h.ContactPolicy.Get(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, p)
}

// updateContactPolicy M2 §5.2 PUT /tenant/contact-policy。
func (h *Handlers) updateContactPolicy(w http.ResponseWriter, r *http.Request) {
	tid := middleware.MustTenantID(r.Context())
	var body svccontactpolicy.UpdateInput
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	p, err := h.ContactPolicy.Update(r.Context(), tid, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, p)
}
