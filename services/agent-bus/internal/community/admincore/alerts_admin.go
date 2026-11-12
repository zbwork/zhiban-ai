// F25 告警中心 admin API（docs/features/F25-alert-center-and-admin-visibility.md §4.1）。
//
// 路由（router.go 注册）：
//
//	GET  /api/admin/v1/platform/alerts                     perm platform.alerts.read
//	GET  /api/admin/v1/platform/alerts/unhandled-count     perm platform.alerts.read
//	GET  /api/admin/v1/platform/alerts/{uuid}              perm platform.alerts.read
//	POST /api/admin/v1/platform/alerts/{uuid}/acknowledge  perm platform.alerts.manage（写审计）
//	POST /api/admin/v1/platform/alerts/{uuid}/resolve      perm platform.alerts.manage（写审计，body.reason 必填）
//	tenant 同构 5 条：一律 MustTenantID，仅 scope_kind='tenant' AND tenant_id=当前租户；
//	传他租户 uuid 统一 alert.not_found，不泄漏存在性。
package admincore

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	domalert "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/alert"
	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// AlertsAdminHandler F25 告警中心。
type AlertsAdminHandler struct {
	Store domalert.Store
	Audit domaudit.Store
}

type alertDTO struct {
	UUID             string         `json:"uuid"`
	ScopeKind        string         `json:"scopeKind"`
	TenantID         *int64         `json:"tenantId"`
	TenantName       string         `json:"tenantName,omitempty"`
	SourceKind       string         `json:"sourceKind"`
	AlertType        string         `json:"alertType"`
	Severity         string         `json:"severity"`
	Status           string         `json:"status"`
	Title            string         `json:"title"`
	Summary          string         `json:"summary"`
	ResourceKind     string         `json:"resourceKind"`
	ResourceUUID     string         `json:"resourceUuid"`
	FirstTriggeredAt time.Time      `json:"firstTriggeredAt"`
	LastTriggeredAt  time.Time      `json:"lastTriggeredAt"`
	OccurrenceCount  int            `json:"occurrenceCount"`
	AcknowledgedBy   *int64         `json:"acknowledgedBy"`
	AcknowledgedAt   *time.Time     `json:"acknowledgedAt"`
	ResolvedAt       *time.Time     `json:"resolvedAt"`
	ResolvedBy       *int64         `json:"resolvedBy"`
	Context          map[string]any `json:"context"`
}

func toAlertDTO(a *domalert.Alert) alertDTO {
	return alertDTO{
		UUID: a.UUID, ScopeKind: a.ScopeKind, TenantID: a.TenantID, TenantName: a.TenantName,
		SourceKind: a.SourceKind, AlertType: a.AlertType, Severity: a.Severity, Status: a.Status,
		Title: a.Title, Summary: a.Summary, ResourceKind: a.ResourceKind, ResourceUUID: a.ResourceUUID,
		FirstTriggeredAt: a.FirstTriggeredAt, LastTriggeredAt: a.LastTriggeredAt, OccurrenceCount: a.OccurrenceCount,
		AcknowledgedBy: a.AcknowledgedBy, AcknowledgedAt: a.AcknowledgedAt,
		ResolvedAt: a.ResolvedAt, ResolvedBy: a.ResolvedBy, Context: a.Context,
	}
}

// tenantScope 返回租户侧隔离谓词；platform 侧返回 nil。
func alertTenantScope(r *http.Request, platform bool) (*int64, bool) {
	if platform {
		return nil, true
	}
	tid := middleware.MustTenantID(r.Context())
	if tid <= 0 {
		return nil, false
	}
	return &tid, true
}

func (h *AlertsAdminHandler) list(platform bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantOnly, ok := alertTenantScope(r, platform)
		if !ok {
			encode.JSONError(w, apperr.ErrUnauthorized)
			return
		}
		q := r.URL.Query()
		f := domalert.ListFilter{
			TenantOnly: tenantOnly,
			Status:     q.Get("status"),
			Severity:   q.Get("severity"),
			SourceKind: q.Get("source_kind"),
			AlertType:  q.Get("alert_type"),
		}
		f.Limit, _ = strconv.Atoi(q.Get("limit"))
		f.Offset, _ = strconv.Atoi(q.Get("offset"))
		if platform {
			if v := q.Get("tenant_id"); v != "" {
				if id, err := strconv.ParseInt(v, 10, 64); err == nil && id > 0 {
					f.TenantID = &id
				}
			}
			// 平台侧默认排除租户经营类（quota/credit_low/subscription_expiring）；显式带参可看
			f.IncludeTenantOps = q.Get("include_tenant_ops") == "true"
		}
		if v := q.Get("from"); v != "" {
			if t, err := time.Parse(time.RFC3339, v); err == nil {
				f.From = &t
			}
		}
		if v := q.Get("to"); v != "" {
			if t, err := time.Parse(time.RFC3339, v); err == nil {
				f.To = &t
			}
		}
		items, total, err := h.Store.List(r.Context(), f)
		if err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		out := make([]alertDTO, 0, len(items))
		for i := range items {
			out = append(out, toAlertDTO(&items[i]))
		}
		encode.JSON(w, map[string]any{"items": out, "total": total})
	}
}

func (h *AlertsAdminHandler) unhandledCount(platform bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantOnly, ok := alertTenantScope(r, platform)
		if !ok {
			encode.JSONError(w, apperr.ErrUnauthorized)
			return
		}
		n, err := h.Store.CountFiring(r.Context(), tenantOnly)
		if err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		encode.JSON(w, map[string]any{"count": n})
	}
}

func (h *AlertsAdminHandler) get(platform bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantOnly, ok := alertTenantScope(r, platform)
		if !ok {
			encode.JSONError(w, apperr.ErrUnauthorized)
			return
		}
		a, err := h.Store.GetByUUID(r.Context(), r.PathValue("uuid"), tenantOnly)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		encode.JSON(w, toAlertDTO(a))
	}
}

func (h *AlertsAdminHandler) acknowledge(platform bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantOnly, ok := alertTenantScope(r, platform)
		if !ok {
			encode.JSONError(w, apperr.ErrUnauthorized)
			return
		}
		by := middleware.MustAccountID(r.Context())
		a, err := h.Store.Acknowledge(r.Context(), r.PathValue("uuid"), tenantOnly, by)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		h.fireAudit(r, platform, a, "alert.acknowledge", "")
		encode.JSON(w, toAlertDTO(a))
	}
}

func (h *AlertsAdminHandler) resolve(platform bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantOnly, ok := alertTenantScope(r, platform)
		if !ok {
			encode.JSONError(w, apperr.ErrUnauthorized)
			return
		}
		var in struct {
			Reason string `json:"reason"`
		}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil || len([]rune(in.Reason)) < 2 {
			encode.JSONError(w, apperr.ErrInvalidParams.Withf("reason required (>=2 chars)"))
			return
		}
		by := middleware.MustAccountID(r.Context())
		a, err := h.Store.ResolveManual(r.Context(), r.PathValue("uuid"), tenantOnly, by)
		if err != nil {
			encode.JSONError(w, err)
			return
		}
		h.fireAudit(r, platform, a, "alert.resolve", in.Reason)
		encode.JSON(w, toAlertDTO(a))
	}
}

// fireAudit 告警处置审计：payload 白名单字段，不含正文类内容。写失败只静默（不阻断处置结果返回，
// 与既有 fireAgentCollaborationAudit 容错口径一致）。
func (h *AlertsAdminHandler) fireAudit(r *http.Request, platform bool, a *domalert.Alert, eventKind, reason string) {
	if h.Audit == nil {
		return
	}
	var tenantID int64
	if a.TenantID != nil {
		tenantID = *a.TenantID
	}
	actorKind := domaudit.ActorAdmin
	if platform {
		actorKind = domaudit.ActorPlatformAdmin
	}
	payload, err := json.Marshal(map[string]any{
		"alert_type": a.AlertType,
		"severity":   a.Severity,
		"status":     a.Status,
		"scope_kind": a.ScopeKind,
		"reason":     reason,
	})
	if err != nil {
		return
	}
	_ = h.Audit.Insert(r.Context(), domaudit.Event{
		OccurredAt:   time.Now(),
		TenantID:     tenantID,
		AccountID:    middleware.MustAccountID(r.Context()),
		ActorKind:    actorKind,
		Domain:       "alerts",
		EventKind:    eventKind,
		Severity:     domaudit.SeverityInfo,
		ResourceKind: "alert",
		ResourceUUID: a.UUID,
		Payload:      payload,
	})
}

// RegisterAlertsRoutes 由 router.Register 调用（platformPerm/tenantPerm 为权限中间件组合子）。
func (h *AlertsAdminHandler) RegisterAlertsRoutes(mux *http.ServeMux,
	platformPerm func(code string, handler http.Handler) http.Handler,
	tenantPerm func(code string, handler http.Handler) http.Handler) {
	mux.Handle("GET /api/admin/v1/platform/alerts", platformPerm("platform.alerts.read", h.list(true)))
	mux.Handle("GET /api/admin/v1/platform/alerts/unhandled-count", platformPerm("platform.alerts.read", h.unhandledCount(true)))
	mux.Handle("GET /api/admin/v1/platform/alerts/{uuid}", platformPerm("platform.alerts.read", h.get(true)))
	mux.Handle("POST /api/admin/v1/platform/alerts/{uuid}/acknowledge", platformPerm("platform.alerts.manage", h.acknowledge(true)))
	mux.Handle("POST /api/admin/v1/platform/alerts/{uuid}/resolve", platformPerm("platform.alerts.manage", h.resolve(true)))

	mux.Handle("GET /api/admin/v1/tenant/alerts", tenantPerm("tenant.alerts.read", h.list(false)))
	mux.Handle("GET /api/admin/v1/tenant/alerts/unhandled-count", tenantPerm("tenant.alerts.read", h.unhandledCount(false)))
	mux.Handle("GET /api/admin/v1/tenant/alerts/{uuid}", tenantPerm("tenant.alerts.read", h.get(false)))
	mux.Handle("POST /api/admin/v1/tenant/alerts/{uuid}/acknowledge", tenantPerm("tenant.alerts.manage", h.acknowledge(false)))
	mux.Handle("POST /api/admin/v1/tenant/alerts/{uuid}/resolve", tenantPerm("tenant.alerts.manage", h.resolve(false)))
}
