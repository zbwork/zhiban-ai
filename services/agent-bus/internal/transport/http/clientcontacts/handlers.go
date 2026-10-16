package clientcontacts

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svccontacts "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/contacts"
)

// callerCtx 从 HTTP 请求中提取 contacts.CallerCtx, 含 tenant.admin 判定。
//
// departmentID 解析顺序 (P1-B):
//  1. JWT act_workspace_id (用户主动切到某个 workspace 时显式带入)
//  2. tenant_memberships.department_id (普通成员从未 switch scope, 取真实部门)
//
// 不直接用 act_workspace_id 是因为大多数 tenant token 该字段为 0,
// 会导致 search scope=current_dept 退化成全租户搜索 (跨部门泄漏)。
func (h *Handlers) CallerCtx(r *http.Request) (svccontacts.CallerCtx, error) {
	c := svccontacts.CallerCtx{
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
		ok, err := h.Contacts.IsTenantAdmin(r.Context(), c.AccountID, c.TenantID)
		if err != nil {
			return c, err
		}
		c.IsTenantAdmin = ok
	}
	return c, nil
}

func (h *Handlers) ContactsTree(w http.ResponseWriter, r *http.Request) {
	caller, err := h.CallerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	out, err := h.Contacts.Tree(r.Context(), caller)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": out})
}

func (h *Handlers) ContactsList(w http.ResponseWriter, r *http.Request) {
	caller, err := h.CallerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	out, err := h.Contacts.List(r.Context(), caller, svccontacts.ListContactsParams{
		DepartmentID: q.Get("department_id"),
		Kind:         q.Get("kind"),
		Q:            q.Get("q"),
		Limit:        limit,
		Cursor:       q.Get("cursor"),
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) ContactsAgents(w http.ResponseWriter, r *http.Request) {
	caller, err := h.CallerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	out, err := h.Contacts.Agents(r.Context(), caller, svccontacts.ListAgentsParams{
		Source: q.Get("source"),
		Q:      q.Get("q"),
		Limit:  limit,
		Cursor: q.Get("cursor"),
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

// contactsRecent M2 返回空列表; M4 接最近聊天/群; 客户端用本地最近详情兜底。
func (h *Handlers) ContactsRecent(w http.ResponseWriter, _ *http.Request) {
	encode.JSON(w, map[string]any{"items": []any{}})
}

func (h *Handlers) ContactsSearch(w http.ResponseWriter, r *http.Request) {
	caller, err := h.CallerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var req svccontacts.SearchReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Contacts.Search(r.Context(), caller, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) ContactsMember(w http.ResponseWriter, r *http.Request) {
	caller, err := h.CallerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	uuid := r.PathValue("account_uuid")
	out, err := h.Contacts.GetMember(r.Context(), caller, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) ContactsAgent(w http.ResponseWriter, r *http.Request) {
	caller, err := h.CallerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	uuid := r.PathValue("agent_uuid")
	out, err := h.Contacts.GetAgent(r.Context(), caller, uuid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) ContactsPolicy(w http.ResponseWriter, r *http.Request) {
	caller, err := h.CallerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	out, err := h.Contacts.Policy(r.Context(), caller)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

func (h *Handlers) ContactsCanCreateGroup(w http.ResponseWriter, r *http.Request) {
	caller, err := h.CallerCtx(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	var req svccontacts.CanCreateGroupReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	out, err := h.Contacts.CanCreateGroup(r.Context(), caller, req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, out)
}

type Handlers struct{ Contacts svccontacts.Service }
