// Package admintenant implements tenant management. Routes require platform RBAC.
package admintenant

import (
	"context"
	"encoding/json"
	domtenant "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/tenant"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svctenant "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/tenant"
	"net/http"
	"strconv"
)

type Service interface {
	List(context.Context, string, string, int, int) ([]domtenant.Tenant, int64, error)
	Get(context.Context, int64) (*domtenant.Tenant, error)
	ResolveOwner(context.Context, int64) (*svctenant.OwnerInfo, error)
	Provision(context.Context, *domtenant.Tenant, svctenant.AdminInput) (*svctenant.ProvisionResult, error)
	Update(context.Context, *domtenant.Tenant) (*domtenant.Tenant, error)
	Delete(context.Context, int64) error
}
type Handlers struct {
	Tenant                  Service
	AllowExistingEmailAdmin bool
}

func (h *Handlers) ListTenants(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	items, total, err := h.Tenant.List(r.Context(), r.URL.Query().Get("status"), r.URL.Query().Get("q"), limit, offset)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}

func (h *Handlers) GetTenant(w http.ResponseWriter, r *http.Request) {
	idStr := r.PathValue("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)
	t, err := h.Tenant.Get(r.Context(), id)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	// 平台后台「编辑租户」弹窗需要展示开通管理员；解析失败不阻塞详情返回。
	owner, _ := h.Tenant.ResolveOwner(r.Context(), id)
	encode.JSON(w, struct {
		*domtenant.Tenant
		OwnerInfo *svctenant.OwnerInfo `json:"OwnerInfo,omitempty"`
	}{Tenant: t, OwnerInfo: owner})
}

func (h *Handlers) CreateTenant(w http.ResponseWriter, r *http.Request) {
	var body struct {
		domtenant.Tenant
		Admin svctenant.AdminInput `json:"admin"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	// 必须指定管理员 (M1 §5.3 + 业务需求: 该手机号即账号)
	if body.Admin.Mobile == "" && (!h.AllowExistingEmailAdmin || body.Admin.Email == "") {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("admin.mobile 必填: 创建租户必须指定管理员手机号"))
		return
	}
	res, err := h.Tenant.Provision(r.Context(), &body.Tenant, body.Admin)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	// 新建管理员账号不生成密码（与 F28 targeted invite 一致）：该手机号必须先走
	// 短信验证码登录，登录后再自行设置密码；这里不再返回明文密码字段。
	encode.JSON(w, map[string]any{
		"tenant":                res.Tenant,
		"tenant_admin_role_id":  res.TenantAdminRoleID,
		"default_department_id": res.DefaultDepartmentID,
		"initial_admin": map[string]any{
			"phone":          res.AdminMobile,
			"account_id":     res.AdminAccountID,
			"account_uuid":   res.AdminAccountUUID,
			"account_reused": res.AdminAccountReused,
		},
	})
}

func (h *Handlers) UpdateTenant(w http.ResponseWriter, r *http.Request) {
	idStr := r.PathValue("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)
	var t domtenant.Tenant
	if err := json.NewDecoder(r.Body).Decode(&t); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	t.ID = id
	updated, err := h.Tenant.Update(r.Context(), &t)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, updated)
}

func (h *Handlers) DeleteTenant(w http.ResponseWriter, r *http.Request) {
	idStr := r.PathValue("id")
	id, _ := strconv.ParseInt(idStr, 10, 64)
	if id <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("invalid id"))
		return
	}
	if err := h.Tenant.Delete(r.Context(), id); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]bool{"ok": true})
}
