// Package knowledge 是 M8 知识库的 PG 仓储 (Phase A).
//
// 覆盖表: knowledge_bases, kb_documents, kb_provider_config, kb_recall_logs, kb_chunks (chunks 写入由 provider/stub).
package knowledge

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	domkb "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/knowledge"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

const kbSelectColumns = `id, uuid::text, tenant_id, creator_id, owner_account_id,
       space_kind, name, COALESCE(description,''), visibility, access_mode, status,
       provider_id, COALESCE(provider_kind,'stub'), COALESCE(ragflow_dataset_id,''),
       COALESCE(provision_status,'active'), COALESCE(provision_error,''), total_documents, retrieval_config, metadata,
       created_at, updated_at`

// Repo 知识库仓储.
type Repo struct {
	pool *pgxpool.Pool
}

// New 构造 Repo.
func New(pool *pgxpool.Pool) *Repo {
	if pool == nil {
		panic("knowledge.Repo: pool required")
	}
	return &Repo{pool: pool}
}

// Pool 暴露 pool 供 service 层做事务.
func (r *Repo) Pool() *pgxpool.Pool { return r.pool }

// =====================================================
// kb_provider_config
// =====================================================

// GetDefaultProvider 返回默认 provider 行.
func (r *Repo) GetDefaultProvider(ctx context.Context) (*domkb.ProviderConfig, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT id, uuid::text, provider_kind, name, endpoint_url, api_key_ref, settings, admin_email, is_default, status
		   FROM kb_provider_config
		  WHERE is_default = true
		  LIMIT 1`)
	return scanProvider(row)
}

// GetProviderByID · M8B Resolver 用; 反查 knowledge_bases.provider_id → 提供配置.
func (r *Repo) GetProviderByID(ctx context.Context, id int64) (*domkb.ProviderConfig, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT id, uuid::text, provider_kind, name, endpoint_url, api_key_ref, settings, admin_email, is_default, status
		   FROM kb_provider_config WHERE id=$1 LIMIT 1`, id)
	return scanProvider(row)
}

// ListProviders · admin /platform/kb-providers list.
func (r *Repo) ListProviders(ctx context.Context) ([]domkb.ProviderConfig, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT id, uuid::text, provider_kind, name, endpoint_url, api_key_ref, settings, admin_email, is_default, status
		   FROM kb_provider_config ORDER BY id ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domkb.ProviderConfig{}
	for rows.Next() {
		var p domkb.ProviderConfig
		var settings []byte
		if err := rows.Scan(&p.ID, &p.UUID, &p.ProviderKind, &p.Name, &p.EndpointURL, &p.APIKeyRef,
			&settings, &p.AdminEmail, &p.IsDefault, &p.Status); err != nil {
			return nil, err
		}
		if len(settings) > 0 {
			_ = json.Unmarshal(settings, &p.Settings)
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ProviderCRUDInput · admin POST/PATCH /platform/kb-providers body subset.
type ProviderCRUDInput struct {
	ProviderKind string
	Name         string
	EndpointURL  string
	APIKeyRef    string
	Settings     map[string]any
	IsDefault    *bool
}

func kbProviderNotifyPayload(id int64) string {
	return "kb_provider_config:" + strconv.FormatInt(id, 10)
}

// CreateProvider · POST. status='active'; settings JSONB; 同 tx pg_notify.
func (r *Repo) CreateProvider(ctx context.Context, in ProviderCRUDInput) (*domkb.ProviderConfig, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	settingsBytes, _ := json.Marshal(in.Settings)
	isDefault := in.IsDefault != nil && *in.IsDefault
	row := tx.QueryRow(ctx,
		`INSERT INTO kb_provider_config (provider_kind, name, endpoint_url, api_key_ref, settings, is_default, status)
		 VALUES ($1, $2, $3, $4, $5::jsonb, $6, 'active')
		 RETURNING id, uuid::text, provider_kind, name, endpoint_url, api_key_ref, settings, admin_email, is_default, status`,
		in.ProviderKind, in.Name, in.EndpointURL, in.APIKeyRef, string(settingsBytes), isDefault,
	)
	cfg, err := scanProvider(row)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify($1, $2)`, "config_change", kbProviderNotifyPayload(cfg.ID)); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return cfg, nil
}

// PatchProvider · 按 provider_uuid 字段更新; nil 字段保留; pg_notify 同 tx.
// status 字段允许 admin 手动写 'active' / 'disabled' (启用/禁用); 'degraded' 仍由 health-check 写。
// provider_kind 只读, 不可 PATCH.
func (r *Repo) PatchProvider(ctx context.Context, providerUUID string, name, endpointURL, apiKeyRef, status *string, settings *map[string]any) (*domkb.ProviderConfig, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var settingsArg any
	if settings != nil {
		bs, _ := json.Marshal(*settings)
		settingsArg = string(bs)
	}
	row := tx.QueryRow(ctx,
		`UPDATE kb_provider_config
		    SET name         = COALESCE($2, name),
		        endpoint_url = COALESCE(NULLIF($3, ''), endpoint_url),
		        api_key_ref  = COALESCE(NULLIF($4, ''), api_key_ref),
		        settings     = COALESCE($5::jsonb, settings),
		        status       = COALESCE($6, status)
		  WHERE uuid = $1::uuid
		  RETURNING id, uuid::text, provider_kind, name, endpoint_url, api_key_ref, settings, admin_email, is_default, status`,
		providerUUID, name, endpointURL, apiKeyRef, settingsArg, status,
	)
	cfg, err := scanProvider(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify($1, $2)`, "config_change", kbProviderNotifyPayload(cfg.ID)); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return cfg, nil
}

// DeleteProvider · 拒绝有 knowledge_bases 引用的 provider; 同 tx pg_notify.
func (r *Repo) DeleteProvider(ctx context.Context, providerUUID string) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var providerID int64
	if err := tx.QueryRow(ctx, `SELECT id FROM kb_provider_config WHERE uuid=$1::uuid`, providerUUID).Scan(&providerID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		return err
	}
	var refCount int64
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM knowledge_bases WHERE provider_id=$1 AND deleted_at IS NULL`, providerID).Scan(&refCount); err != nil {
		return err
	}
	if refCount > 0 {
		return apperr.ErrConflict.Withf("kb_provider.has_references (%d KB still using this provider)", refCount)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM kb_provider_config WHERE id=$1`, providerID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify($1, $2)`, "config_change", kbProviderNotifyPayload(providerID)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// SetDefaultProvider · partial unique 强制只一个 is_default=true; 必须 status='active'.
// 同 tx pg_notify 让两个 provider 的 cache 都失效.
func (r *Repo) SetDefaultProvider(ctx context.Context, providerUUID string) (*domkb.ProviderConfig, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	var providerID int64
	var status string
	if err := tx.QueryRow(ctx, `SELECT id, status FROM kb_provider_config WHERE uuid=$1::uuid`, providerUUID).Scan(&providerID, &status); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	if status != "active" {
		return nil, apperr.ErrConflict.Withf("kb_provider.set_default_requires_active (current=%s)", status)
	}
	if _, err := tx.Exec(ctx, `UPDATE kb_provider_config SET is_default=false WHERE id != $1`, providerID); err != nil {
		return nil, err
	}
	row := tx.QueryRow(ctx,
		`UPDATE kb_provider_config SET is_default=true WHERE id=$1
		 RETURNING id, uuid::text, provider_kind, name, endpoint_url, api_key_ref, settings, admin_email, is_default, status`, providerID,
	)
	cfg, err := scanProvider(row)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify($1, $2)`, "config_change", "kb_provider_config:*"); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return cfg, nil
}

// UpdateProviderHealth · admin health-check 用; 把 status / 时间 / 文本写回.
// status 必须是 'active' / 'degraded' / 'disabled' (与 000036 CHECK 一致).
//
// Codex round-3 P1-3: 同事务 pg_notify('config_change','kb_provider_config:<id>')
// 让 bus 端 Resolver listener 立即 Invalidate 缓存; 不再依赖 admin 显式调
// Invalidate.
func (r *Repo) UpdateProviderHealth(ctx context.Context, id int64, status, message string) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx,
		`UPDATE kb_provider_config
		    SET status = $2, health_checked_at = now(), health_message = NULLIF($3, '')
		  WHERE id = $1`, id, status, message); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `SELECT pg_notify($1, $2)`, "config_change", kbProviderNotifyPayload(id)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func scanProvider(row pgx.Row) (*domkb.ProviderConfig, error) {
	var p domkb.ProviderConfig
	var settings []byte
	if err := row.Scan(&p.ID, &p.UUID, &p.ProviderKind, &p.Name, &p.EndpointURL, &p.APIKeyRef,
		&settings, &p.AdminEmail, &p.IsDefault, &p.Status); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	if len(settings) > 0 {
		_ = json.Unmarshal(settings, &p.Settings)
	}
	return &p, nil
}

// =====================================================
// knowledge_bases CRUD
// =====================================================

// CreateKB 同事务版本; service 层负责开 tx + pg_notify.
func (r *Repo) CreateKB(ctx context.Context, tx pgx.Tx, in domkb.CreateKBInput) (*domkb.KnowledgeBase, error) {
	desc := in.Description
	row := tx.QueryRow(ctx,
		`INSERT INTO knowledge_bases (
			    tenant_id, creator_id, owner_account_id, space_kind, visibility, access_mode, name, description,
			    provider_id, provider_kind, provision_status, total_documents, retrieval_config, status, metadata)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 0,
			         '{"top_k":5,"threshold":0.05,"use_rerank":false}'::jsonb,
			         'active', '{}'::jsonb)
			 RETURNING `+kbSelectColumns,
		in.TenantID, in.CreatorID, in.OwnerAccountID, in.SpaceKind, in.Visibility, in.AccessMode, in.Name, desc, in.ProviderID, in.ProviderKind, in.ProvisionStatus,
	)
	return scanKB(row)
}

// GetKBByUUID 读 KB; 软删行不返.
func (r *Repo) GetKBByUUID(ctx context.Context, uuid string) (*domkb.KnowledgeBase, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+kbSelectColumns+`
			   FROM knowledge_bases
			  WHERE uuid = $1::uuid AND deleted_at IS NULL`, uuid)
	return scanKB(row)
}

// AgentKBBindingView · agent 已绑知识库的展示摘要 (uuid + name)，供列表/详情 hydrate。
type AgentKBBindingView struct {
	ID               int64
	UUID             string
	Name             string
	KBUpdatedAt      time.Time
	BindingUpdatedAt time.Time
	SpaceKind        string
	ProvisionStatus  string
	Status           string
}

// ListAgentKBBindings join agent_kb_bindings + knowledge_bases，返回某 agent 当前
// 已绑、未删的知识库 (按 priority 倒序，与 ReplaceForAgent 写入顺序一致)。
func (r *Repo) ListAgentKBBindings(ctx context.Context, agentID int64) ([]AgentKBBindingView, error) {
	rows, err := r.pool.Query(ctx, `
SELECT k.id, k.uuid::text, k.name, k.updated_at, b.updated_at,
       k.space_kind, k.provision_status, k.status
FROM agent_kb_bindings b
JOIN knowledge_bases k ON k.id = b.kb_id
  AND k.deleted_at IS NULL AND k.status = 'active' AND k.provision_status = 'active'
WHERE b.agent_id = $1 AND b.deleted_at IS NULL
ORDER BY b.priority DESC, b.id ASC`, agentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]AgentKBBindingView, 0)
	for rows.Next() {
		var v AgentKBBindingView
		if err := rows.Scan(&v.ID, &v.UUID, &v.Name, &v.KBUpdatedAt, &v.BindingUpdatedAt,
			&v.SpaceKind, &v.ProvisionStatus, &v.Status); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

// ListAgentKBBindingsByAgents 批量版 ListAgentKBBindings（客户端 /agents 列表 hydrate 用）：
// 一条 SQL 取多个 agent 的已绑未删知识库，按 agent_id 分桶；桶内序与逐条版一致
// (priority DESC, id ASC)。
func (r *Repo) ListAgentKBBindingsByAgents(ctx context.Context, agentIDs []int64) (map[int64][]AgentKBBindingView, error) {
	out := make(map[int64][]AgentKBBindingView, len(agentIDs))
	if len(agentIDs) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx, `
SELECT b.agent_id, k.id, k.uuid::text, k.name, k.updated_at, b.updated_at,
       k.space_kind, k.provision_status, k.status
FROM agent_kb_bindings b
JOIN knowledge_bases k ON k.id = b.kb_id
  AND k.deleted_at IS NULL AND k.status = 'active' AND k.provision_status = 'active'
WHERE b.agent_id = ANY($1) AND b.deleted_at IS NULL
ORDER BY b.agent_id, b.priority DESC, b.id ASC`, agentIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var agentID int64
		var v AgentKBBindingView
		if err := rows.Scan(&agentID, &v.ID, &v.UUID, &v.Name, &v.KBUpdatedAt, &v.BindingUpdatedAt,
			&v.SpaceKind, &v.ProvisionStatus, &v.Status); err != nil {
			return nil, err
		}
		out[agentID] = append(out[agentID], v)
	}
	return out, rows.Err()
}

// GetKBByID 读 KB by 内部 id.
func (r *Repo) GetKBByID(ctx context.Context, id int64) (*domkb.KnowledgeBase, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+kbSelectColumns+`
			   FROM knowledge_bases
			  WHERE id = $1 AND deleted_at IS NULL`, id)
	return scanKB(row)
}

// ListVisibleKB 列出 caller 可见的 KB:
//   - 同租户 + 软删未行 + (visibility=tenant OR (visibility=private AND creator_id=accountID))
func (r *Repo) ListVisibleKB(ctx context.Context, f domkb.ListKBFilter) ([]domkb.KnowledgeBase, error) {
	limit := f.Limit
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, err := r.pool.Query(ctx,
		`SELECT `+kbSelectColumns+`
			   FROM knowledge_bases
			  WHERE tenant_id = $1 AND deleted_at IS NULL
			    AND status = 'active'
			    AND provision_status = 'active'
			    AND ( visibility = 'tenant'
			          OR (visibility = 'private' AND owner_account_id = $2) )
			  ORDER BY id DESC
			  LIMIT $3`, f.TenantID, f.AccountID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]domkb.KnowledgeBase, 0, limit)
	for rows.Next() {
		kb, err := scanKB(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *kb)
	}
	return out, rows.Err()
}

// ListManagedKB returns only the collection an admin actor is allowed to
// manage. Personal/workspace rows are deliberately excluded from tenant CRUD.
func (r *Repo) ListManagedKB(ctx context.Context, actor domkb.Actor, q, status string, limit, offset int) ([]domkb.KnowledgeBase, int, error) {
	if limit <= 0 || limit > 200 {
		limit = 20
	}
	if offset < 0 {
		offset = 0
	}
	q = strings.TrimSpace(q)
	status = strings.TrimSpace(status)
	var tenantID any
	var scope string
	switch actor.ScopeKind {
	case domkb.ScopePlatform:
		scope = domkb.SpaceKindPlatform
		tenantID = nil
	case domkb.ScopeTenant:
		if actor.TenantID == nil || *actor.TenantID <= 0 {
			return nil, 0, apperr.ErrInvalidParams.Withf("tenant scope requires tenant id")
		}
		scope = domkb.SpaceKindTenant
		tenantID = *actor.TenantID
	default:
		return nil, 0, apperr.ErrInvalidParams.Withf("unsupported managed kb scope")
	}
	rows, err := r.pool.Query(ctx, `
SELECT `+kbSelectColumns+`, count(*) OVER()
  FROM knowledge_bases
 WHERE deleted_at IS NULL
   AND space_kind = $1
   AND (($1 = 'platform' AND tenant_id IS NULL) OR ($1 = 'tenant' AND tenant_id = $2))
   AND ($3 = '' OR name ILIKE '%' || $3 || '%' OR COALESCE(description, '') ILIKE '%' || $3 || '%')
   AND ($4 = ''
        OR ($4 = 'active' AND status = 'active' AND provision_status = 'active')
        OR ($4 IN ('pending','failed') AND provision_status = $4)
        OR ($4 NOT IN ('active','pending','failed') AND status = $4))
 ORDER BY updated_at DESC, id DESC
 LIMIT $5 OFFSET $6`, scope, tenantID, q, status, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := make([]domkb.KnowledgeBase, 0, limit)
	total := 0
	for rows.Next() {
		kb, err := scanKBWithTotal(rows, &total)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, *kb)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && offset > 0 {
		if err := r.pool.QueryRow(ctx, `
SELECT count(*) FROM knowledge_bases
 WHERE deleted_at IS NULL AND space_kind=$1
   AND (($1='platform' AND tenant_id IS NULL) OR ($1='tenant' AND tenant_id=$2))
   AND ($3='' OR name ILIKE '%' || $3 || '%' OR COALESCE(description,'') ILIKE '%' || $3 || '%')
   AND ($4=''
        OR ($4='active' AND status='active' AND provision_status='active')
        OR ($4 IN ('pending','failed') AND provision_status=$4)
        OR ($4 NOT IN ('active','pending','failed') AND status=$4))`, scope, tenantID, q, status).Scan(&total); err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

// GetManagedKBByUUID scopes in SQL to prevent UUID-based object leakage.
func (r *Repo) GetManagedKBByUUID(ctx context.Context, actor domkb.Actor, uuid string) (*domkb.KnowledgeBase, error) {
	var tenantID any
	var scope string
	switch actor.ScopeKind {
	case domkb.ScopePlatform:
		scope = domkb.SpaceKindPlatform
		tenantID = nil
	case domkb.ScopeTenant:
		if actor.TenantID == nil {
			return nil, apperr.ErrNotFound
		}
		scope = domkb.SpaceKindTenant
		tenantID = *actor.TenantID
	default:
		return nil, apperr.ErrNotFound
	}
	row := r.pool.QueryRow(ctx, `SELECT `+kbSelectColumns+`
	  FROM knowledge_bases
	 WHERE uuid=$1::uuid AND deleted_at IS NULL AND space_kind=$2
	   AND (($2='platform' AND tenant_id IS NULL) OR ($2='tenant' AND tenant_id=$3))`, uuid, scope, tenantID)
	return scanKB(row)
}

func (r *Repo) CountActiveBindings(ctx context.Context, kbID int64) (int64, error) {
	var n int64
	err := r.pool.QueryRow(ctx, `SELECT count(*) FROM agent_kb_bindings WHERE kb_id=$1 AND deleted_at IS NULL`, kbID).Scan(&n)
	return n, err
}

// PatchKB 单事务更新; service 层管校验.
func (r *Repo) PatchKB(ctx context.Context, tx pgx.Tx, id int64, in domkb.UpdateKBInput) error {
	if in.Name == nil && in.Description == nil && in.Visibility == nil {
		return nil
	}
	sets := ""
	args := []any{id}
	idx := 2
	if in.Name != nil {
		sets += ", name = $" + itoa(idx)
		args = append(args, *in.Name)
		idx++
	}
	if in.Description != nil {
		sets += ", description = $" + itoa(idx)
		args = append(args, *in.Description)
		idx++
	}
	if in.Visibility != nil {
		sets += ", visibility = $" + itoa(idx)
		args = append(args, *in.Visibility)
		idx++
	}
	if sets == "" {
		return nil
	}
	sql := `UPDATE knowledge_bases SET updated_at = now()` + sets + ` WHERE id = $1 AND deleted_at IS NULL`
	tag, err := tx.Exec(ctx, sql, args...)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// SoftDeleteKB 软删 KB.
func (r *Repo) SoftDeleteKB(ctx context.Context, tx pgx.Tx, id int64) error {
	tag, err := tx.Exec(ctx,
		`UPDATE knowledge_bases SET deleted_at = now(), updated_at = now()
		  WHERE id = $1 AND deleted_at IS NULL`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// IncrTotalDocuments 同事务 += delta.
func (r *Repo) IncrTotalDocuments(ctx context.Context, tx pgx.Tx, kbID int64, delta int) error {
	_, err := tx.Exec(ctx,
		`UPDATE knowledge_bases SET total_documents = GREATEST(total_documents + $2, 0), updated_at = now()
		  WHERE id = $1`, kbID, delta)
	return err
}

// =====================================================
// kb_folders
// =====================================================

func (r *Repo) ListFolders(ctx context.Context, kbID int64) ([]domkb.Folder, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT f.id, f.uuid::text, f.kb_id, f.parent_id, COALESCE(p.uuid::text, ''),
		        f.path, f.name, f.created_at, f.updated_at
		   FROM kb_folders f
		   LEFT JOIN kb_folders p ON p.id = f.parent_id
		  WHERE f.kb_id=$1 AND f.deleted_at IS NULL
		  ORDER BY f.path ASC, f.id ASC`, kbID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []domkb.Folder{}
	for rows.Next() {
		f, err := scanFolder(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *f)
	}
	return out, rows.Err()
}

func (r *Repo) GetFolderByUUID(ctx context.Context, uuid string) (*domkb.Folder, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT f.id, f.uuid::text, f.kb_id, f.parent_id, COALESCE(p.uuid::text, ''),
		        f.path, f.name, f.created_at, f.updated_at
		   FROM kb_folders f
		   LEFT JOIN kb_folders p ON p.id = f.parent_id
		  WHERE f.uuid=$1::uuid AND f.deleted_at IS NULL`, uuid)
	return scanFolder(row)
}

func (r *Repo) CreateFolder(ctx context.Context, tx pgx.Tx, kbID int64, parentID *int64, name, path string) (*domkb.Folder, error) {
	row := tx.QueryRow(ctx,
		`WITH inserted AS (
		   INSERT INTO kb_folders (kb_id, parent_id, name, path)
		   VALUES ($1, $2, $3, $4)
		   RETURNING id, uuid::text, kb_id, parent_id, path, name, created_at, updated_at
		 )
		 SELECT i.id, i.uuid, i.kb_id, i.parent_id, COALESCE(p.uuid::text, ''),
		        i.path, i.name, i.created_at, i.updated_at
		   FROM inserted i
		   LEFT JOIN kb_folders p ON p.id = i.parent_id`,
		kbID, parentID, name, path)
	return scanFolder(row)
}

func (r *Repo) PatchFolder(ctx context.Context, tx pgx.Tx, folderID int64, name, path string) (*domkb.Folder, error) {
	row := tx.QueryRow(ctx,
		`WITH updated AS (
		   UPDATE kb_folders SET name=$2, path=$3, updated_at=now()
		    WHERE id=$1 AND deleted_at IS NULL
		    RETURNING id, uuid::text, kb_id, parent_id, path, name, created_at, updated_at
		 )
		 SELECT u.id, u.uuid, u.kb_id, u.parent_id, COALESCE(p.uuid::text, ''),
		        u.path, u.name, u.created_at, u.updated_at
		   FROM updated u
		   LEFT JOIN kb_folders p ON p.id = u.parent_id`,
		folderID, name, path)
	return scanFolder(row)
}

// RenameFolderTree updates the folder and all descendant materialized paths in
// one transaction. A KB-scoped advisory lock prevents interleaved renames.
func (r *Repo) RenameFolderTree(ctx context.Context, tx pgx.Tx, kbID, folderID int64, oldPath, name, newPath string) (*domkb.Folder, error) {
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, kbID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `
UPDATE kb_folders
   SET path = $4 || substr(path, length($3) + 1), updated_at = now()
 WHERE kb_id=$1 AND deleted_at IS NULL AND id<>$2
   AND path LIKE $3 || '/%'`, kbID, folderID, oldPath, newPath); err != nil {
		return nil, err
	}
	row := tx.QueryRow(ctx, `WITH updated AS (
  UPDATE kb_folders SET name=$3, path=$4, updated_at=now()
   WHERE id=$1 AND kb_id=$2 AND deleted_at IS NULL
   RETURNING id, uuid::text, kb_id, parent_id, path, name, created_at, updated_at
)
SELECT u.id, u.uuid, u.kb_id, u.parent_id, COALESCE(p.uuid::text, ''),
       u.path, u.name, u.created_at, u.updated_at
  FROM updated u LEFT JOIN kb_folders p ON p.id=u.parent_id`, folderID, kbID, name, newPath)
	return scanFolder(row)
}

func (r *Repo) FolderHasChildrenOrDocuments(ctx context.Context, folderID int64) (bool, error) {
	var n int
	if err := r.pool.QueryRow(ctx,
		`SELECT
		   (SELECT count(*) FROM kb_folders WHERE parent_id=$1 AND deleted_at IS NULL) +
		   (SELECT count(*) FROM kb_documents WHERE folder_id=$1 AND deleted_at IS NULL)`,
		folderID).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

func (r *Repo) SoftDeleteFolder(ctx context.Context, tx pgx.Tx, folderID int64) error {
	tag, err := tx.Exec(ctx,
		`UPDATE kb_folders SET deleted_at=now(), updated_at=now()
		  WHERE id=$1 AND deleted_at IS NULL`, folderID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// =====================================================
// kb_documents
// =====================================================

// CreateDocument 同事务 INSERT.
func (r *Repo) CreateDocument(ctx context.Context, tx pgx.Tx, in domkb.CreateDocumentInput) (*domkb.Document, error) {
	meta, _ := json.Marshal(in.Metadata)
	if len(meta) == 0 {
		meta = []byte("{}")
	}
	row := tx.QueryRow(ctx,
		`WITH inserted AS (
		   INSERT INTO kb_documents (kb_id, folder_id, title, source_kind, mime_type, file_size,
		                             chunk_count, status, storage_key, content_sha256, original_name,
		                             upload_idempotency_key, upload_ordinal, metadata)
		   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NULLIF($9,''), NULLIF($10,''), NULLIF($11,''),
		           NULLIF($12,'')::uuid, $13, $14::jsonb)
		   RETURNING id, uuid::text, kb_id, folder_id, title, source_kind, mime_type,
		             file_size, chunk_count, status, error_message, provider_doc_id,
		             COALESCE(storage_key,'') AS storage_key,
		             COALESCE(content_sha256,'') AS content_sha256,
		             COALESCE(original_name,'') AS original_name,
		             metadata, created_at, updated_at
		 )
		 SELECT i.id, i.uuid, i.kb_id, i.folder_id, COALESCE(f.uuid::text, ''),
		        i.title, i.source_kind, COALESCE(i.mime_type,''),
		        COALESCE(i.file_size,0), i.chunk_count, i.status, COALESCE(i.error_message,''),
		        COALESCE(i.provider_doc_id,''), i.storage_key, i.content_sha256, i.original_name,
		        i.metadata, i.created_at, i.updated_at
		   FROM inserted i
		   LEFT JOIN kb_folders f ON f.id = i.folder_id`,
		in.KBID, in.FolderID, in.Title, in.SourceKind, nullableString(in.MimeType), in.FileSize,
		in.ChunkCount, in.Status, in.StorageKey, in.ContentSHA256, in.OriginalName,
		in.UploadIdempotencyKey, in.UploadOrdinal, meta,
	)
	return scanDocument(row)
}

func (r *Repo) GetDocumentByUploadKey(ctx context.Context, kbID int64, key string, ordinal int) (*domkb.Document, error) {
	row := r.pool.QueryRow(ctx, `
SELECT d.id, d.uuid::text, d.kb_id, d.folder_id, COALESCE(f.uuid::text,''),
       d.title, d.source_kind, COALESCE(d.mime_type,''), COALESCE(d.file_size,0),
       d.chunk_count, d.status, COALESCE(d.error_message,''), COALESCE(d.provider_doc_id,''),
       COALESCE(d.storage_key,''), COALESCE(d.content_sha256,''), COALESCE(d.original_name,''),
       d.metadata, d.created_at, d.updated_at
FROM kb_documents d LEFT JOIN kb_folders f ON f.id=d.folder_id
WHERE d.kb_id=$1 AND d.upload_idempotency_key=$2::uuid AND d.upload_ordinal=$3 AND d.deleted_at IS NULL`,
		kbID, key, ordinal)
	return scanDocument(row)
}

func (r *Repo) ReservePlatformQuotaBytes(ctx context.Context, tx pgx.Tx, needBytes, limitBytes int64) error {
	if needBytes <= 0 {
		return nil
	}
	if _, err := tx.Exec(ctx, `
INSERT INTO kb_platform_quota_usage (singleton_id, used_bytes, updated_at)
	VALUES (1,0,now())
	ON CONFLICT (singleton_id) DO NOTHING`); err != nil {
		return err
	}
	var used int64
	err := tx.QueryRow(ctx, `
UPDATE kb_platform_quota_usage
   SET used_bytes=used_bytes+$1, updated_at=now()
 WHERE singleton_id=1 AND used_bytes+$1 <= $2
 RETURNING used_bytes`, needBytes, limitBytes).Scan(&used)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.New(apperr.PreconditionFailed, "kb.quota_exceeded").
			Withf("平台知识库容量不足：本次需要 %d，平台上限 %d", needBytes, limitBytes)
	}
	return err
}

func (r *Repo) ReleasePlatformQuotaBytes(ctx context.Context, tx pgx.Tx, releaseBytes int64) error {
	if releaseBytes <= 0 {
		return nil
	}
	_, err := tx.Exec(ctx, `
UPDATE kb_platform_quota_usage SET used_bytes=GREATEST(0, used_bytes-$1), updated_at=now()
WHERE singleton_id=1`, releaseBytes)
	return err
}

func (r *Repo) ListDocumentStorageKeys(ctx context.Context, kbID int64) ([]string, error) {
	rows, err := r.pool.Query(ctx, `SELECT storage_key FROM kb_documents WHERE kb_id=$1 AND deleted_at IS NULL AND storage_key IS NOT NULL AND storage_key<>''`, kbID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]string, 0)
	for rows.Next() {
		var key string
		if err := rows.Scan(&key); err != nil {
			return nil, err
		}
		out = append(out, key)
	}
	return out, rows.Err()
}

func (r *Repo) InsertKBOutbox(ctx context.Context, tx pgx.Tx, scopeKind string, tenantID *int64, kbID int64, op string, payload []byte) error {
	_, err := tx.Exec(ctx, `
INSERT INTO kb_outbox_events (tenant_id, scope_kind, kb_id, op, payload, status)
VALUES ($1,$2,$3,$4,$5,'pending')`, tenantID, scopeKind, kbID, op, payload)
	return err
}

// UpdateDocumentReady 把 status 切到 ready 并写 chunk_count + provider_doc_id.
func (r *Repo) UpdateDocumentReady(ctx context.Context, tx pgx.Tx, docID int64, chunkCount int, providerDocID string) error {
	_, err := tx.Exec(ctx,
		`UPDATE kb_documents
		    SET status='ready', chunk_count=$2, provider_doc_id=$3, updated_at=now()
		  WHERE id=$1`,
		docID, chunkCount, providerDocID)
	return err
}

func (r *Repo) UpdateDocumentStorage(ctx context.Context, docID int64, storageKey, sha256Hex, originalName string) error {
	_, err := r.pool.Exec(ctx, `
UPDATE kb_documents SET storage_key=$2, content_sha256=$3, original_name=$4, updated_at=now()
WHERE id=$1 AND deleted_at IS NULL`, docID, storageKey, sha256Hex, originalName)
	return err
}

// MarkDocumentFailed 同事务: status=failed + error_message.
func (r *Repo) MarkDocumentFailed(ctx context.Context, tx pgx.Tx, docID int64, msg string) error {
	_, err := tx.Exec(ctx,
		`UPDATE kb_documents
		    SET status='failed', error_message=$2, updated_at=now()
		  WHERE id=$1`, docID, msg)
	return err
}

// UpdateDocumentTitle 更新知识库文档展示标题。
func (r *Repo) UpdateDocumentTitle(ctx context.Context, tx pgx.Tx, docID int64, title string) error {
	tag, err := tx.Exec(ctx,
		`UPDATE kb_documents
		    SET title=$2, updated_at=now()
		  WHERE id=$1 AND deleted_at IS NULL`, docID, title)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// GetDocumentByUUID 拉文档.
func (r *Repo) GetDocumentByUUID(ctx context.Context, uuid string) (*domkb.Document, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT d.id, d.uuid::text, d.kb_id, d.folder_id, COALESCE(f.uuid::text, ''),
		        d.title, d.source_kind, COALESCE(d.mime_type,''),
		        COALESCE(d.file_size,0), d.chunk_count, d.status, COALESCE(d.error_message,''),
		        COALESCE(d.provider_doc_id,''), COALESCE(d.storage_key,''), COALESCE(d.content_sha256,''),
		        COALESCE(d.original_name,''), d.metadata, d.created_at, d.updated_at
		   FROM kb_documents d
		   LEFT JOIN kb_folders f ON f.id = d.folder_id
		  WHERE d.uuid=$1::uuid AND d.deleted_at IS NULL`, uuid)
	return scanDocument(row)
}

// ListDocuments 按 kb_id 列文档.
func (r *Repo) ListDocuments(ctx context.Context, kbID int64, limit int) ([]domkb.Document, error) {
	docs, _, err := r.ListDocumentsPaged(ctx, kbID, limit, 0)
	return docs, err
}

func (r *Repo) SumTenantFileSize(ctx context.Context, tenantID int64) (int64, error) {
	var n int64
	err := r.pool.QueryRow(ctx,
		`SELECT COALESCE(SUM(d.file_size), 0)
		   FROM kb_documents d
		   JOIN knowledge_bases k ON k.id = d.kb_id
		  WHERE k.tenant_id=$1
		    AND k.deleted_at IS NULL
		    AND d.deleted_at IS NULL
		    AND d.status NOT IN ('failed', 'disabled')`, tenantID).Scan(&n)
	return n, err
}

func (r *Repo) SumKBQuotaTrackedFileSize(ctx context.Context, tx pgx.Tx, kbID int64) (int64, error) {
	var n int64
	err := tx.QueryRow(ctx,
		`SELECT COALESCE(SUM(file_size), 0)
		   FROM kb_documents
		  WHERE kb_id=$1
		    AND deleted_at IS NULL
		    AND status NOT IN ('failed', 'disabled')`, kbID).Scan(&n)
	return n, err
}

func (r *Repo) GetTenantQuotaUsedBytes(ctx context.Context, tenantID int64) (int64, error) {
	var n int64
	err := r.pool.QueryRow(ctx,
		`SELECT used_bytes FROM kb_tenant_quota_usage WHERE tenant_id=$1`, tenantID).Scan(&n)
	if errors.Is(err, pgx.ErrNoRows) {
		return r.SumTenantFileSize(ctx, tenantID)
	}
	return n, err
}

func (r *Repo) ReserveTenantQuotaBytes(ctx context.Context, tx pgx.Tx, tenantID, needBytes int64, limitBytes *int64) (int64, error) {
	if needBytes < 0 {
		needBytes = 0
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO kb_tenant_quota_usage (tenant_id, used_bytes, updated_at)
		 VALUES ($1, 0, now())
		 ON CONFLICT (tenant_id) DO NOTHING`, tenantID); err != nil {
		return 0, err
	}
	var used int64
	if limitBytes == nil {
		err := tx.QueryRow(ctx,
			`UPDATE kb_tenant_quota_usage
			    SET used_bytes=used_bytes+$2, updated_at=now()
			  WHERE tenant_id=$1
			  RETURNING used_bytes`, tenantID, needBytes).Scan(&used)
		return used, err
	}
	err := tx.QueryRow(ctx,
		`UPDATE kb_tenant_quota_usage
		    SET used_bytes=used_bytes+$2, updated_at=now()
		  WHERE tenant_id=$1
		    AND used_bytes+$2 <= $3
		  RETURNING used_bytes`, tenantID, needBytes, *limitBytes).Scan(&used)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, apperr.New(apperr.PreconditionFailed, "kb.quota_exceeded").
			Withf("知识库容量不足：本次需要 %d，套餐上限 %d", needBytes, *limitBytes)
	}
	return used, err
}

func (r *Repo) ReleaseTenantQuotaBytes(ctx context.Context, tx pgx.Tx, tenantID, releaseBytes int64) error {
	if releaseBytes <= 0 {
		return nil
	}
	_, err := tx.Exec(ctx,
		`UPDATE kb_tenant_quota_usage
		    SET used_bytes=GREATEST(0, used_bytes-$2), updated_at=now()
		  WHERE tenant_id=$1`, tenantID, releaseBytes)
	return err
}

// ListDocumentsPaged 支持 limit/offset 分页, 同时返 total count (供 admin web 显示总数 + 分页器)。
// limit <=0 → 50; limit >500 → 500 (上限防 OOM)。offset 负数 → 0。
func (r *Repo) ListDocumentsPaged(ctx context.Context, kbID int64, limit, offset int) ([]domkb.Document, int, error) {
	return r.ListDocumentsPagedInFolder(ctx, kbID, nil, limit, offset)
}

func (r *Repo) ListDocumentsPagedInFolder(ctx context.Context, kbID int64, folderID *int64, limit, offset int) ([]domkb.Document, int, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 500 {
		limit = 500
	}
	if offset < 0 {
		offset = 0
	}
	rows, err := r.pool.Query(ctx,
		`SELECT d.id, d.uuid::text, d.kb_id, d.folder_id, COALESCE(f.uuid::text, ''),
		        d.title, d.source_kind, COALESCE(d.mime_type,''),
		        COALESCE(d.file_size,0), d.chunk_count, d.status, COALESCE(d.error_message,''),
		        COALESCE(d.provider_doc_id,''), COALESCE(d.storage_key,''), COALESCE(d.content_sha256,''),
		        COALESCE(d.original_name,''), d.metadata, d.created_at, d.updated_at, COUNT(*) OVER()
		   FROM kb_documents d
		   LEFT JOIN kb_folders f ON f.id = d.folder_id
		  WHERE d.kb_id=$1 AND d.deleted_at IS NULL
		    AND ($4::bigint IS NULL OR d.folder_id=$4)
		  ORDER BY d.id DESC
		  LIMIT $2 OFFSET $3`, kbID, limit, offset, folderID)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []domkb.Document{}
	var total int
	for rows.Next() {
		var meta []byte
		var folderID pgtype.Int8
		var d domkb.Document
		if err := rows.Scan(&d.ID, &d.UUID, &d.KBID, &folderID, &d.FolderUUID, &d.Title, &d.SourceKind, &d.MimeType,
			&d.FileSize, &d.ChunkCount, &d.Status, &d.ErrorMessage, &d.ProviderDocID,
			&d.StorageKey, &d.ContentSHA256, &d.OriginalName,
			&meta, &d.CreatedAt, &d.UpdatedAt, &total); err != nil {
			return nil, 0, err
		}
		if folderID.Valid {
			v := folderID.Int64
			d.FolderID = &v
		}
		if len(meta) > 0 {
			_ = json.Unmarshal(meta, &d.Metadata)
		}
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	if len(out) == 0 && offset > 0 {
		if err := r.pool.QueryRow(ctx,
			`SELECT count(*) FROM kb_documents WHERE kb_id=$1 AND deleted_at IS NULL
			  AND ($2::bigint IS NULL OR folder_id=$2)`, kbID, folderID).Scan(&total); err != nil {
			return nil, 0, err
		}
	}
	return out, total, nil
}

// SoftDeleteDocument 同事务软删.
func (r *Repo) SoftDeleteDocument(ctx context.Context, tx pgx.Tx, docID int64) error {
	tag, err := tx.Exec(ctx,
		`UPDATE kb_documents SET deleted_at=now(), updated_at=now()
		  WHERE id=$1 AND deleted_at IS NULL`, docID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// =====================================================
// kb_recall_logs
// =====================================================

// InsertRecallLog 同事务/池 INSERT.
func (r *Repo) InsertRecallLog(ctx context.Context, log domkb.RecallLog) error {
	meta, _ := json.Marshal(log.Metadata)
	if len(meta) == 0 {
		meta = []byte("{}")
	}
	_, err := r.pool.Exec(ctx,
		`INSERT INTO kb_recall_logs (
		    occurred_at, tenant_id, account_id, agent_id, kb_id, kb_scope_kind, caller_kind,
		    conversation_uuid, query_text, top_k, threshold, chunk_hits, score_top,
		    latency_ms, error_code, metadata, api_key_prefix, session_token_id)
		 VALUES ($1,$2,NULLIF($3,0),NULLIF($4,0),$5,$6,$7,NULLIF($8,''),
		         $9,$10,$11,$12,$13,$14,NULLIF($15,''),$16::jsonb,NULLIF($17,''),$18)`,
		time.Now().UTC(), log.TenantID, log.AccountID, log.AgentID, log.KBID, log.KBScopeKind,
		log.CallerKind, log.ConversationUUID, log.QueryText, log.TopK, log.Threshold,
		log.ChunkHits, log.ScoreTop, log.LatencyMs, log.ErrorCode, meta, log.APIKeyPrefix, log.SessionTokenID)
	return err
}

// =====================================================
// agent_capability_bindings (复用 M3 表)
// =====================================================

// IsKBAttachedToAgent 检查 KB UUID 是否已装配到 agent.
//
// 仅看 capability_kind='knowledge_base'; agent_version_id 任意 (草稿态 / 已发布版均算).
func (r *Repo) IsKBAttachedToAgent(ctx context.Context, deID int64, kbUUID string) (bool, error) {
	var n int
	err := r.pool.QueryRow(ctx,
		`SELECT 1 FROM agent_capability_bindings
		  WHERE digital_employee_id=$1 AND capability_kind='knowledge_base' AND capability_uuid=$2::uuid
		  LIMIT 1`, deID, kbUUID).Scan(&n)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// AttachKBToAgent 给 agent 装配 KB 草稿态 (agent_version_id NULL).
func (r *Repo) AttachKBToAgent(ctx context.Context, deID int64, kbUUID string) error {
	_, err := r.pool.Exec(ctx,
		`INSERT INTO agent_capability_bindings (
		    digital_employee_id, agent_version_id, capability_kind, capability_uuid,
		    source, granted_tools, granted_scopes, sort_order, pinned, recall_config)
		 VALUES ($1, NULL, 'knowledge_base', $2::uuid, 'borrow', '{}', '{}', 0, false, '{}'::jsonb)
		 ON CONFLICT DO NOTHING`,
		deID, kbUUID)
	return err
}

// DetachKBFromAgent 删除 agent 的 KB 装配 (草稿态).
func (r *Repo) DetachKBFromAgent(ctx context.Context, deID int64, kbUUID string) error {
	_, err := r.pool.Exec(ctx,
		`DELETE FROM agent_capability_bindings
		  WHERE digital_employee_id=$1
		    AND capability_kind='knowledge_base'
		    AND capability_uuid=$2::uuid
		    AND agent_version_id IS NULL`,
		deID, kbUUID)
	return err
}

// =====================================================
// scan helpers
// =====================================================

func scanKB(row pgx.Row) (*domkb.KnowledgeBase, error) {
	var kb domkb.KnowledgeBase
	var rcfg, meta []byte
	var owner pgtype.Int8
	if err := row.Scan(&kb.ID, &kb.UUID, &kb.TenantID, &kb.CreatorID, &owner, &kb.SpaceKind, &kb.Name,
		&kb.Description, &kb.Visibility, &kb.AccessMode, &kb.Status, &kb.ProviderID, &kb.ProviderKind, &kb.RagflowDatasetID,
		&kb.ProvisionStatus, &kb.ProvisionError, &kb.TotalDocuments, &rcfg, &meta, &kb.CreatedAt, &kb.UpdatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	if owner.Valid {
		v := owner.Int64
		kb.OwnerAccountID = &v
	}
	if len(rcfg) > 0 {
		_ = json.Unmarshal(rcfg, &kb.RetrievalConfig)
	}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &kb.Metadata)
	}
	return &kb, nil
}

func scanKBWithTotal(row pgx.Row, total *int) (*domkb.KnowledgeBase, error) {
	var kb domkb.KnowledgeBase
	var rcfg, meta []byte
	var owner pgtype.Int8
	if err := row.Scan(&kb.ID, &kb.UUID, &kb.TenantID, &kb.CreatorID, &owner, &kb.SpaceKind, &kb.Name,
		&kb.Description, &kb.Visibility, &kb.AccessMode, &kb.Status, &kb.ProviderID, &kb.ProviderKind, &kb.RagflowDatasetID,
		&kb.ProvisionStatus, &kb.ProvisionError, &kb.TotalDocuments, &rcfg, &meta, &kb.CreatedAt, &kb.UpdatedAt, total); err != nil {
		return nil, err
	}
	if owner.Valid {
		v := owner.Int64
		kb.OwnerAccountID = &v
	}
	if len(rcfg) > 0 {
		_ = json.Unmarshal(rcfg, &kb.RetrievalConfig)
	}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &kb.Metadata)
	}
	return &kb, nil
}

func scanDocument(row pgx.Row) (*domkb.Document, error) {
	var d domkb.Document
	var meta []byte
	var folderID pgtype.Int8
	if err := row.Scan(&d.ID, &d.UUID, &d.KBID, &folderID, &d.FolderUUID, &d.Title, &d.SourceKind, &d.MimeType,
		&d.FileSize, &d.ChunkCount, &d.Status, &d.ErrorMessage, &d.ProviderDocID,
		&d.StorageKey, &d.ContentSHA256, &d.OriginalName,
		&meta, &d.CreatedAt, &d.UpdatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	if folderID.Valid {
		v := folderID.Int64
		d.FolderID = &v
	}
	if len(meta) > 0 {
		_ = json.Unmarshal(meta, &d.Metadata)
	}
	return &d, nil
}

func scanFolder(row pgx.Row) (*domkb.Folder, error) {
	var f domkb.Folder
	var parentID pgtype.Int8
	if err := row.Scan(&f.ID, &f.UUID, &f.KBID, &parentID, &f.ParentUUID,
		&f.Path, &f.Name, &f.CreatedAt, &f.UpdatedAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	if parentID.Valid {
		v := parentID.Int64
		f.ParentID = &v
	}
	return &f, nil
}

func nullableString(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func itoa(n int) string {
	if n < 10 {
		return string('0' + byte(n))
	}
	// small numbers only (1..99 used here)
	return string('0'+byte(n/10)) + string('0'+byte(n%10))
}
