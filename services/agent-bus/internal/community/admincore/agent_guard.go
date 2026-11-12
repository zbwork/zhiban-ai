// Tenant employee write guard reused from the original admin router.
package admincore

import (
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"net/http"
	"strconv"
	"strings"
)

func (h *Handlers) requireTenantEditableAgent(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tid := middleware.MustTenantID(r.Context())
		uuid := strings.TrimSpace(r.PathValue("uuid"))
		if uuid == "" {
			uuid = strings.TrimSpace(r.PathValue("agent_uuid"))
		}
		if uuid == "" {
			uuid = strings.TrimSpace(r.PathValue("agent_id"))
		}
		if uuid == "" {
			if id, err := strconv.ParseInt(strings.TrimSpace(r.PathValue("id")), 10, 64); err == nil && id > 0 {
				agent, getErr := h.Agent.GetByID(r.Context(), tid, id)
				if getErr != nil {
					encode.JSONError(w, getErr)
					return
				}
				if agent.Source != "enterprise" || agent.TenantID != tid {
					encode.JSONError(w, apperr.ErrForbidden.Withf("租户后台只能修改租户创建的数字员工"))
					return
				}
				next.ServeHTTP(w, r)
				return
			}
		}
		if uuid == "" {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("agent uuid required"))
			return
		}
		agent, err := h.Agent.Get(r.Context(), tid, uuid)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		if agent.Source != "enterprise" || agent.TenantID != tid {
			encode.JSONError(w, apperr.ErrForbidden.Withf("租户后台只能修改租户创建的数字员工"))
			return
		}
		next.ServeHTTP(w, r)
	})
}
