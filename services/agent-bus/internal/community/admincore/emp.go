package admincore

import (
	"encoding/json"
	domemp "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/empblock"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"net/http"
	"strconv"
)

// listEMPBlocks (3D Codex review #3): 4 个 /platform/emp-blocks 路由统一走 h.EMP,
// 不再分流到 h.Platform.ListEMPBlocks; 让 admin 端 EMP 注册表只有一个数据源, 字段
// 命名 / 序列化形状一致 (含 BreakingChanges / DeprecatedAt / EOL 等 GET-only 字段).
func (h *Handlers) listEMPBlocks(w http.ResponseWriter, r *http.Request) {
	if h.EMP == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("emp service not wired"))
		return
	}
	items, err := h.EMP.List(r.Context())
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"items": newEMPBlockDTOs(items), "total": len(items)})
}

// ---------- Batch 3D T3.10: EMP block registry CRUD ----------

// empBlockCreateReq POST body. 字段命名与 emp_block_registry 列名对齐.
type empBlockCreateReq struct {
	Code              string         `json:"code"`
	Version           int            `json:"version,omitempty"`
	Name              string         `json:"name"`
	Category          string         `json:"category"`
	JSONSchema        map[string]any `json:"json_schema,omitempty"`
	Status            string         `json:"status,omitempty"`
	MinClientVersion  string         `json:"min_client_version,omitempty"`
	FallbackBlockType string         `json:"fallback_block_type,omitempty"`
	Description       string         `json:"description,omitempty"`
}

// empBlockUpdateReq PATCH body. 全字段可选; nil 表示不动.
type empBlockUpdateReq struct {
	Name              *string         `json:"name,omitempty"`
	Category          *string         `json:"category,omitempty"`
	JSONSchema        *map[string]any `json:"json_schema,omitempty"`
	Status            *string         `json:"status,omitempty"`
	MinClientVersion  *string         `json:"min_client_version,omitempty"`
	FallbackBlockType *string         `json:"fallback_block_type,omitempty"`
	BreakingChanges   *string         `json:"breaking_changes,omitempty"`
	Description       *string         `json:"description,omitempty"`
}

func (h *Handlers) createEMPBlock(w http.ResponseWriter, r *http.Request) {
	if h.EMP == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("emp service not wired"))
		return
	}
	var req empBlockCreateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	b, err := h.EMP.Create(r.Context(), domemp.CreateInput{
		Code:              req.Code,
		Version:           req.Version,
		Name:              req.Name,
		Category:          req.Category,
		JSONSchema:        req.JSONSchema,
		Status:            req.Status,
		MinClientVersion:  req.MinClientVersion,
		FallbackBlockType: req.FallbackBlockType,
		Description:       req.Description,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, newEMPBlockDTO(b))
}

func (h *Handlers) updateEMPBlock(w http.ResponseWriter, r *http.Request) {
	if h.EMP == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("emp service not wired"))
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("id required"))
		return
	}
	var req empBlockUpdateReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	b, err := h.EMP.Update(r.Context(), id, domemp.UpdateInput{
		Name:              req.Name,
		Category:          req.Category,
		JSONSchema:        req.JSONSchema,
		Status:            req.Status,
		MinClientVersion:  req.MinClientVersion,
		FallbackBlockType: req.FallbackBlockType,
		BreakingChanges:   req.BreakingChanges,
		Description:       req.Description,
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, newEMPBlockDTO(b))
}

func (h *Handlers) getEMPBlock(w http.ResponseWriter, r *http.Request) {
	if h.EMP == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("emp service not wired"))
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("id required"))
		return
	}
	b, err := h.EMP.Get(r.Context(), id)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, newEMPBlockDTO(b))
}
