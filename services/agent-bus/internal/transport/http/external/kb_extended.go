// kb_extended.go — 对外 KB 接口 (F07 §3.2 扩展, 5 个 endpoint).
package external

import (
	"context"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svckb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
)

const uploadMaxMemory = 4 * 1024 * 1024

// externalKB 是对外暴露的 KB 字段 (不直接复用 svckb.KBDTO, 对外契约稳定)。
type externalKB struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	Description    string    `json:"description,omitempty"`
	SpaceKind      string    `json:"space_kind"` // tenant / personal
	OwnerAccountID int64     `json:"owner_account_id,omitempty"`
	Visibility     string    `json:"visibility"`
	Status         string    `json:"status"`
	DocumentCount  int       `json:"document_count"`
	CreatedAt      time.Time `json:"created_at"`
}

func toExternalKB(d svckb.KBDTO) externalKB {
	var ownerID int64
	if d.OwnerAccountID != nil {
		ownerID = *d.OwnerAccountID
	}
	return externalKB{
		ID:             d.UUID,
		Name:           d.Name,
		Description:    d.Description,
		SpaceKind:      d.SpaceKind,
		OwnerAccountID: ownerID,
		Visibility:     d.Visibility,
		Status:         d.Status,
		DocumentCount:  d.TotalDocuments,
		CreatedAt:      d.CreatedAt,
	}
}

// kbList — GET /api/external/v1/knowledge-bases
// 列租户级 KB (visibility=tenant)。
func (h *Handlers) kbList(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	internal, err := h.Knowledge.ListTenantKB(r.Context(), tenantID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]externalKB, 0, len(internal))
	for _, kb := range internal {
		items = append(items, toExternalKB(kb))
	}
	encode.JSON(w, map[string]any{"items": items})
}

// kbGet — GET /api/external/v1/knowledge-bases/{knowledge_base_id}
func (h *Handlers) kbGet(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	accountID := middleware.ExternalAccountID(r.Context())
	kbUUID := r.PathValue("knowledge_base_id")
	if kbUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("knowledge_base_id required"))
		return
	}
	internal, err := h.Knowledge.GetKB(r.Context(), accountID, tenantID, nil, kbUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toExternalKB(*internal))
}

// kbCreate — POST /api/external/v1/knowledge-bases
// 外部系统只能创建 tenant 级 KB; personal KB 仍走用户侧 client API。
func (h *Handlers) kbCreate(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	accountID := middleware.ExternalAccountID(r.Context())
	if tenantID <= 0 || accountID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized.Withf("api key creator required"))
		return
	}
	var body svckb.CreateKBReq
	if err := decodeStrictJSON(r.Body, &body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	body.SpaceKind = "tenant"
	body.Visibility = "tenant"
	out, err := h.Knowledge.CreateKB(r.Context(), accountID, tenantID, []string{svckb.PermTenantKBUpdate}, body)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toExternalKB(*out))
}

func (h *Handlers) kbGetDoc(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	accountID := middleware.ExternalAccountID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	doc, err := h.Knowledge.GetDocument(r.Context(), accountID, tenantID, r.PathValue("knowledge_base_id"), r.PathValue("document_id"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toExternalDocument(*doc))
}

func (h *Handlers) kbUploadDoc(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	accountID := middleware.ExternalAccountID(r.Context())
	if tenantID <= 0 || accountID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized.Withf("api key creator required"))
		return
	}
	req, err := parseUploadDocReq(r)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	out, err := h.Knowledge.UploadDocument(r.Context(), accountID, tenantID, []string{svckb.PermTenantKBUpdate}, r.PathValue("knowledge_base_id"), req)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, toExternalDocument(*out))
}

type externalRetrieveReq struct {
	Query     string  `json:"query"`
	TopK      int     `json:"top_k,omitempty"`
	Threshold float64 `json:"threshold,omitempty"`
	Rerank    bool    `json:"rerank,omitempty"`
}

type externalRetrieveChunk struct {
	Content       string  `json:"content"`
	DocumentID    string  `json:"document_id"`
	DocumentTitle string  `json:"document_title,omitempty"`
	Similarity    float64 `json:"similarity"`
}

// kbRetrieve — POST /api/external/v1/knowledge-bases/{knowledge_base_id}/retrieve
// 检索 KB, 返 chunks (核心对外 API)。
func (h *Handlers) kbRetrieve(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	accountID := middleware.ExternalAccountID(r.Context())
	kbUUID := r.PathValue("knowledge_base_id")
	if kbUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("knowledge_base_id required"))
		return
	}
	var body externalRetrieveReq
	if err := decodeStrictJSON(r.Body, &body); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if body.Query == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("query required"))
		return
	}
	if body.TopK <= 0 {
		body.TopK = 5
	}
	if body.Threshold == 0 {
		body.Threshold = 0.2
	}

	// 复用 service/knowledge.Search; 服务层强制 dataset_ids 注入 (D9 不变量)
	// 注: rerank 字段当前未透到 svckb.SearchReq; M5 follow-up 扩 SearchReq.Rerank 后接进来
	resp, err := h.Knowledge.Search(r.Context(), accountID, tenantID, kbUUID, svckb.SearchReq{
		Query:     body.Query,
		TopK:      body.TopK,
		Threshold: body.Threshold,
	})
	_ = body.Rerank // M5 follow-up
	if err != nil {
		encode.JSONError(w, err)
		return
	}

	chunks := make([]externalRetrieveChunk, 0, len(resp.Chunks))
	for _, c := range resp.Chunks {
		chunks = append(chunks, externalRetrieveChunk{
			Content:    c.Content,
			DocumentID: c.UUID,
			Similarity: c.Score,
		})
	}
	encode.JSON(w, map[string]any{
		"chunks":            chunks,
		"total":             len(chunks),
		"knowledge_base_id": kbUUID,
	})
}

// kbListUserPrivate — GET /api/external/v1/users/{user_id}/knowledge-bases
// 跨用户列私有 KB (D13: 需 ScopeTenantKBListUserPrivate, 自动审计)。
//
// audit event: 'tenant.admin.user_kb_inspect' (服务层自动写)
func (h *Handlers) kbListUserPrivate(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	userUUID := r.PathValue("user_id")
	if userUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("user_id required"))
		return
	}
	targetAccountID, err := h.resolveAccountIDByUUID(r.Context(), userUUID)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	internal, err := h.Knowledge.ListUserPrivateKB(r.Context(), tenantID, targetAccountID, "", middleware.APIKeyScopes(r.Context()))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]externalKB, 0, len(internal))
	for _, kb := range internal {
		items = append(items, toExternalKB(kb))
	}
	encode.JSON(w, map[string]any{"items": items})
}

func (h *Handlers) kbGetUserPrivate(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	targetAccountID, err := h.resolveAccountIDByUUID(r.Context(), r.PathValue("user_id"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	kb, err := h.Knowledge.GetKB(r.Context(), targetAccountID, tenantID, nil, r.PathValue("knowledge_base_id"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if kb.SpaceKind != "personal" || kb.OwnerAccountID == nil || *kb.OwnerAccountID != targetAccountID {
		encode.JSONError(w, apperr.New(apperr.NotFound, "kb.not_found").Withf("private kb not found"))
		return
	}
	encode.JSON(w, toExternalKB(*kb))
}

func (h *Handlers) kbListUserPrivateDocs(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	targetAccountID, err := h.resolveAccountIDByUUID(r.Context(), r.PathValue("user_id"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	kb, err := h.Knowledge.GetKB(r.Context(), targetAccountID, tenantID, nil, r.PathValue("knowledge_base_id"))
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	if kb.SpaceKind != "personal" || kb.OwnerAccountID == nil || *kb.OwnerAccountID != targetAccountID {
		encode.JSONError(w, apperr.New(apperr.NotFound, "kb.not_found").Withf("private kb not found"))
		return
	}
	docs, err := h.Knowledge.ListDocuments(r.Context(), targetAccountID, tenantID, r.PathValue("knowledge_base_id"), "")
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]externalDocument, 0, len(docs))
	for _, d := range docs {
		items = append(items, toExternalDocument(d))
	}
	encode.JSON(w, map[string]any{"items": items})
}

func parseUploadDocReq(r *http.Request) (svckb.UploadDocReq, error) {
	ct := strings.ToLower(strings.TrimSpace(r.Header.Get("Content-Type")))
	var req svckb.UploadDocReq
	if strings.HasPrefix(ct, "multipart/form-data") {
		if err := r.ParseMultipartForm(uploadMaxMemory); err != nil {
			return req, apperr.ErrInvalidParams.Wrap(err)
		}
		file, fh, err := r.FormFile("file")
		if err != nil {
			return req, apperr.ErrInvalidParams.Withf("file part missing: %v", err)
		}
		defer file.Close()
		buf, err := io.ReadAll(file)
		if err != nil {
			return req, apperr.ErrInternal.Wrap(err)
		}
		req.Title = strings.TrimSpace(r.FormValue("title"))
		if req.Title == "" {
			req.Title = fh.Filename
		}
		req.MimeType = strings.ToLower(strings.TrimSpace(r.FormValue("mime_type")))
		if req.MimeType == "" {
			req.MimeType = fh.Header.Get("Content-Type")
		}
		req.Content = buf
		return req, nil
	}
	buf, err := io.ReadAll(r.Body)
	if err != nil {
		return req, apperr.ErrInvalidParams.Wrap(err)
	}
	req.Title = strings.TrimSpace(r.URL.Query().Get("title"))
	req.MimeType = strings.ToLower(strings.TrimSpace(r.URL.Query().Get("mime_type")))
	if req.MimeType == "" {
		req.MimeType = r.Header.Get("Content-Type")
	}
	req.Content = buf
	return req, nil
}

// resolveAccountIDByUUID — 给 accounts.uuid 反查 id; 不存在返 404 (Handlers 没注入 account repo, 直查 PG)。
func (h *Handlers) resolveAccountIDByUUID(ctx context.Context, uuid string) (int64, error) {
	if h.Pool == nil {
		return 0, apperr.ErrInternal.Withf("pool not wired")
	}
	var id int64
	err := h.Pool.QueryRow(ctx,
		`SELECT id FROM accounts WHERE uuid=$1 AND deleted_at IS NULL`, uuid).Scan(&id)
	if err != nil {
		return 0, apperr.New(apperr.NotFound, "tenant.user.not_found").Withf("account %s not found", uuid)
	}
	return id, nil
}
