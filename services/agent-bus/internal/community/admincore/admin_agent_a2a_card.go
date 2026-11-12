// A2A v1b (plans/2026-07-06 §8.2 / §14.1): 协作卡片最小后端 API。
//
// 路由:
//   GET /api/admin/v1/tenant/agents/{agent_id}/a2a-card   → 归一化卡片 (未配置 = 默认空卡, card_version=0)
//   PUT /api/admin/v1/tenant/agents/{agent_id}/a2a-card   body = 卡片 JSON → 校验 + 归一化 + 落库
//
// 权限: tenant.agent.read / tenant.agent.update。只能操作本租户未软删 agent。
// 校验: domagent.ValidateA2ACard (严格 fail-closed: unknown field / 枚举非法 / 超限 → 400)。
// card_version 由服务端在 UPDATE 内原子 +1 (忽略客户端传入值, 防并发写丢版本号)。
// audit: PUT 成功后写 tenant.agent.a2a_card.update, 只记录卡片摘要, 不记录完整 schema。

package admincore

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/model"
	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	repoa2aembedding "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/a2aembedding"
)

// a2aCardUpdateSQL: $3 = 归一化卡片 (不含可信 card_version); card_version 在 SQL 内原子 +1。
// 提为常量供单测断言 (tenant 谓词 / updated_by / 原子自增)。
const a2aCardUpdateSQL = `
	UPDATE digital_employees
	   SET a2a_card = $3::jsonb || jsonb_build_object(
	           'card_version', COALESCE((a2a_card->>'card_version')::int, 0) + 1),
	       updated_by = $4,
	       updated_at = now()
	 WHERE uuid=$1 AND tenant_id=$2 AND source='enterprise' AND is_deleted=false
	RETURNING id, name, tags, a2a_card::text`

// platformPresetA2ACardUpdateSQL 是平台模板协作说明写入路径:只允许平台模板原行,不触碰租户实例。
// 提为常量供单测断言 (tenant_id NULL / source platform / visibility platform / updated_by / 原子自增)。
const platformPresetA2ACardUpdateSQL = `
	UPDATE digital_employees
	   SET a2a_card = $2::jsonb || jsonb_build_object(
	           'card_version', COALESCE((a2a_card->>'card_version')::int, 0) + 1),
	       updated_by = $3,
	       updated_at = now()
	 WHERE uuid=$1
	   AND tenant_id IS NULL
	   AND source='platform'
	   AND visibility='platform'
	   AND is_deleted=false
	RETURNING a2a_card::text`

// AdminAgentA2ACardHandler · A2A v1b 协作卡片读写。
type AdminAgentA2ACardHandler struct {
	Pool              *pgxpool.Pool
	Audit             domaudit.Store
	A2AEmbedding      A2ACardEmbeddingStore
	A2AEmbedder       model.Embedder
	A2AEmbeddingModel string
	A2AEmbeddingDims  int
}

type A2ACardEmbeddingStore interface {
	Upsert(ctx context.Context, in repoa2aembedding.UpsertInput) error
}

// Get GET /api/admin/v1/tenant/agents/{agent_id}/a2a-card
func (h *AdminAgentA2ACardHandler) Get(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	agentUUID := r.PathValue("agent_id")
	if agentUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("agent_id required"))
		return
	}
	var raw string
	err := h.Pool.QueryRow(r.Context(),
		`SELECT a2a_card::text FROM digital_employees
		  WHERE uuid=$1 AND tenant_id=$2 AND is_deleted=false`,
		agentUUID, tenantID).Scan(&raw)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			encode.JSONError(w, apperr.New(apperr.NotFound, "agent.not_found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	// 读路径宽松: 历史脏数据按空卡默认值返回, 不 500。
	encode.JSON(w, domagent.ParseA2ACardLenient(raw))
}

// Update PUT /api/admin/v1/tenant/agents/{agent_id}/a2a-card
func (h *AdminAgentA2ACardHandler) Update(w http.ResponseWriter, r *http.Request) {
	tenantID := middleware.MustTenantID(r.Context())
	if tenantID <= 0 {
		encode.JSONError(w, apperr.ErrUnauthorized)
		return
	}
	agentUUID := r.PathValue("agent_id")
	if agentUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("agent_id required"))
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, domagent.A2ACardMaxBytes+1))
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("read body: %v", err))
		return
	}
	card, verr := domagent.ValidateA2ACard(body)
	if verr != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("a2a_card.invalid: %v", verr))
		return
	}
	// card_version 由 SQL 原子 +1; 归一化文档里的版本字段在写入前剥离 (marshal 后被 || 覆盖)。
	card.CardVersion = 0
	normalized, merr := json.Marshal(card)
	if merr != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(merr))
		return
	}
	var stored string
	var agentID int64
	var agentName string
	var tags []string
	err = h.Pool.QueryRow(r.Context(), a2aCardUpdateSQL,
		agentUUID, tenantID, string(normalized), nullableAccountID(middleware.MustAccountID(r.Context()))).
		Scan(&agentID, &agentName, &tags, &stored)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			encode.JSONError(w, apperr.New(apperr.NotFound, "agent.not_found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	out := domagent.ParseA2ACardLenient(stored)
	fireAgentCollaborationAudit(r.Context(), h.Audit, tenantID, middleware.MustAccountID(r.Context()), agentUUID,
		"tenant.agent.a2a_card.update", map[string]any{
			"card_version":      out.CardVersion,
			"risk_level":        out.RiskLevel,
			"requires_approval": out.RequiresApproval,
			"supported_modes":   out.SupportedModes,
			"summary_present":   out.Summary != "",
		})
	h.upsertA2ACardEmbedding(r.Context(), tenantID, agentID, agentUUID, agentName, tags, out)
	encode.JSON(w, out)
}

// GetPlatformPreset GET /api/admin/v1/platform/preset-agents/{agent_id}/a2a-card
func (h *AdminAgentA2ACardHandler) GetPlatformPreset(w http.ResponseWriter, r *http.Request) {
	agentUUID := r.PathValue("agent_id")
	if agentUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("agent_id required"))
		return
	}
	var raw string
	err := h.Pool.QueryRow(r.Context(),
		`SELECT a2a_card::text FROM digital_employees
		  WHERE uuid=$1
		    AND tenant_id IS NULL
		    AND source='platform'
		    AND visibility='platform'
		    AND is_deleted=false`,
		agentUUID).Scan(&raw)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			encode.JSONError(w, apperr.New(apperr.NotFound, "agent.not_found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	encode.JSON(w, domagent.ParseA2ACardLenient(raw))
}

// UpdatePlatformPreset PUT /api/admin/v1/platform/preset-agents/{agent_id}/a2a-card
func (h *AdminAgentA2ACardHandler) UpdatePlatformPreset(w http.ResponseWriter, r *http.Request) {
	agentUUID := r.PathValue("agent_id")
	if agentUUID == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("agent_id required"))
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, domagent.A2ACardMaxBytes+1))
	if err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("read body: %v", err))
		return
	}
	card, verr := domagent.ValidateA2ACard(body)
	if verr != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("a2a_card.invalid: %v", verr))
		return
	}
	card.CardVersion = 0
	normalized, merr := json.Marshal(card)
	if merr != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(merr))
		return
	}
	var stored string
	err = h.Pool.QueryRow(r.Context(), platformPresetA2ACardUpdateSQL,
		agentUUID, string(normalized), nullableAccountID(middleware.MustAccountID(r.Context()))).
		Scan(&stored)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			encode.JSONError(w, apperr.New(apperr.NotFound, "agent.not_found"))
			return
		}
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	out := domagent.ParseA2ACardLenient(stored)
	firePlatformAgentAudit(r.Context(), h.Audit, middleware.MustAccountID(r.Context()), agentUUID,
		"platform.preset_agent.a2a_card.update", map[string]any{
			"card_version":      out.CardVersion,
			"risk_level":        out.RiskLevel,
			"requires_approval": out.RequiresApproval,
			"supported_modes":   out.SupportedModes,
			"summary_present":   out.Summary != "",
		})
	encode.JSON(w, out)
}

func (h *AdminAgentA2ACardHandler) upsertA2ACardEmbedding(ctx context.Context, tenantID, agentID int64, agentUUID, agentName string, tags []string, card domagent.A2ACard) {
	if h == nil || h.A2AEmbedding == nil || h.A2AEmbedder == nil || tenantID <= 0 || agentID <= 0 ||
		strings.TrimSpace(h.A2AEmbeddingModel) == "" {
		return
	}
	content := domagent.A2ACardEmbeddingText(agentName, tags, card)
	if strings.TrimSpace(content) == "" {
		return
	}
	timeoutCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	resp, err := h.A2AEmbedder.Embed(timeoutCtx, model.EmbeddingRequest{
		Model: h.A2AEmbeddingModel,
		Input: []string{content},
		Metadata: map[string]any{
			"usageScene": "a2a_card_embedding_index",
			"agentId":    agentUUID,
		},
	})
	if err != nil || resp == nil || len(resp.Embeddings) != 1 {
		return
	}
	embedding := resp.Embeddings[0]
	dims := h.A2AEmbeddingDims
	if dims <= 0 {
		dims = len(embedding)
	}
	if len(embedding) != dims {
		return
	}
	_ = h.A2AEmbedding.Upsert(timeoutCtx, repoa2aembedding.UpsertInput{
		TenantID:          tenantID,
		DigitalEmployeeID: agentID,
		AgentUUID:         agentUUID,
		CardVersion:       card.CardVersion,
		EmbeddingModel:    h.A2AEmbeddingModel,
		EmbeddingDims:     dims,
		Embedding:         embedding,
		Content:           content,
	})
}
