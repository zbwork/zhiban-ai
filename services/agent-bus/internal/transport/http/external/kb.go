// kb.go — F01 §3.5 第一个对外端点: GET /api/external/v1/knowledge-bases/{knowledge_base_id}/documents。
//
// 复用 service/knowledge.ListDocuments; accountID 用 api_keys.creator_id 当 acting account
// (tenant-visibility KB 与 account 无关; private KB 仅创建者可见, 与 F01 §3.5 风险评估一致)。
package external

import (
	"net/http"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	svckb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge"
)

// externalDocument 是 /api/external/v1 对外暴露的字段集; 与 docs/openapi/zhiban-external-v1.yaml
// 完全对齐 (codex review P2 修复)。**不直接复用** svckb.DocumentDTO, 因为内部 DTO 会演化,
// 对外契约必须稳定。
type externalDocument struct {
	ID              string    `json:"id"`
	KnowledgeBaseID string    `json:"knowledge_base_id"`
	Title           string    `json:"title"`
	MimeType        string    `json:"mime_type,omitempty"`
	SizeBytes       int64     `json:"size_bytes"`
	ChunkCount      int       `json:"chunk_count"`
	Status          string    `json:"status"`
	CreatedAt       time.Time `json:"created_at"`
}

func toExternalDocument(d svckb.DocumentDTO) externalDocument {
	return externalDocument{
		ID:              d.UUID,
		KnowledgeBaseID: d.KBUUID,
		Title:           d.Title,
		MimeType:        d.MimeType,
		SizeBytes:       d.FileSize, // 重命名给对外用 size_bytes (业界更普遍命名)
		ChunkCount:      d.ChunkCount,
		Status:          d.Status,
		CreatedAt:       d.CreatedAt,
	}
}

func (h *Handlers) kbListDocs(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.ExternalTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	// API Key 走时 ExternalAccountID = api_key.creator_id; session_token 走时 = 0
	// (Agent SDK 场景没有"人会话"概念, ListDocuments 在 visibility=tenant 时仍可访问)。
	accountID := middleware.ExternalAccountID(r.Context())
	kbUUID := r.PathValue("knowledge_base_id")
	if kbUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("knowledge_base_id required"))
		return
	}
	internal, err := h.Knowledge.ListDocuments(r.Context(), accountID, tenantID, kbUUID, "")
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	items := make([]externalDocument, 0, len(internal))
	for _, d := range internal {
		items = append(items, toExternalDocument(d))
	}
	encode.JSON(w, map[string]any{"items": items})
}
