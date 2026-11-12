// tenant_idp.go — 租户 admin SSO IdP 配置 CRUD (F01 §4.3, M4)。
//
// 路由 /api/admin/v1/tenant/identity-providers, 权限 tenant.identity_provider.read/create/update/delete。
//
// 为快速落地接口形状, 这里直接走 pgxpool (跟 kb_providers.go 同款薄 admin-only 模式),
// 没有单独建 domain/identity 仓储; M4.x 真接入 OIDC 后再决定是否抽业务 service 层。
//
// client_secret 入库前走 AES-256-GCM (pkg/secretbox); key 来自 AGBUS_SECRETBOX_KEY env。
// codex challenge #6 修复: 之前是 base64 裸存, 任何拿 DB / 备份的人都能解。
package admincore

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// TenantIDPStore 是窄抽象, 实现是 cmd/admin 里包的 pgx 直查 (避免再起一个 service 包)。
type TenantIDPStore interface {
	ListByTenant(ctx context.Context, tenantID int64) ([]TenantIDPRow, error)
	Insert(ctx context.Context, in TenantIDPRow) (*TenantIDPRow, error)
	Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*TenantIDPRow, error)
	SoftDelete(ctx context.Context, tenantID int64, uuid string) error
}

// SecretSealer 客户端 secret 加密接口; 实际实现是 secretbox.Box。
// 中间件 / handler 用它, 不直接依赖 pkg/secretbox 以便测试 mock。
type SecretSealer interface {
	Seal(plaintext string) (string, error)
	Open(ciphertext string) (string, error)
}

type TenantIDPRow struct {
	ID              int64          `json:"-"`
	UUID            string         `json:"uuid"`
	TenantID        int64          `json:"tenantId"`
	Kind            string         `json:"kind"`
	Name            string         `json:"name"`
	Issuer          string         `json:"issuer,omitempty"`
	ClientID        string         `json:"clientId,omitempty"`
	ClientSecretEnc string         `json:"-"` // 不外露
	RedirectURI     string         `json:"redirectUri,omitempty"`
	Scopes          []string       `json:"scopes"`
	Settings        map[string]any `json:"settings"`
	Status          string         `json:"status"`
	CreatedAt       time.Time      `json:"createdAt"`
	UpdatedAt       time.Time      `json:"updatedAt"`
}

type listTenantIDPResp struct {
	Items []TenantIDPRow `json:"items"`
}

func (h *Handlers) listTenantIDP(w http.ResponseWriter, r *http.Request) {
	if h.TenantIDP == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("tenant_idp store not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	items, err := h.TenantIDP.ListByTenant(r.Context(), tid)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, listTenantIDPResp{Items: items})
}

type createTenantIDPReq struct {
	Kind         string         `json:"kind"`
	Name         string         `json:"name"`
	Issuer       string         `json:"issuer,omitempty"`
	ClientID     string         `json:"clientId,omitempty"`
	ClientSecret string         `json:"clientSecret,omitempty"` // 入库前编码
	RedirectURI  string         `json:"redirectUri,omitempty"`
	Scopes       []string       `json:"scopes,omitempty"`
	Settings     map[string]any `json:"settings,omitempty"`
}

func (h *Handlers) createTenantIDP(w http.ResponseWriter, r *http.Request) {
	if h.TenantIDP == nil || h.SecretSealer == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("tenant_idp store / secret sealer not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	var req createTenantIDPReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	if req.Kind == "" || req.Name == "" {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("kind/name required"))
		return
	}
	switch req.Kind {
	case "oidc", "saml", "ldap", "scim":
	default:
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("unknown kind %q", req.Kind))
		return
	}
	if req.Kind == "oidc" && (req.Issuer == "" || req.ClientID == "" || req.ClientSecret == "" || req.RedirectURI == "") {
		encode.JSONError(w, apperr.ErrInvalidParams.Withf("oidc requires issuer/clientId/clientSecret/redirectUri"))
		return
	}
	enc, err := h.SecretSealer.Seal(req.ClientSecret)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	row, err := h.TenantIDP.Insert(r.Context(), TenantIDPRow{
		TenantID:        tid,
		Kind:            req.Kind,
		Name:            strings.TrimSpace(req.Name),
		Issuer:          req.Issuer,
		ClientID:        req.ClientID,
		ClientSecretEnc: enc,
		RedirectURI:     req.RedirectURI,
		Scopes:          req.Scopes,
		Settings:        req.Settings,
		Status:          "active",
	})
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, row)
}

type patchTenantIDPReq struct {
	Name         *string        `json:"name,omitempty"`
	Issuer       *string        `json:"issuer,omitempty"`
	ClientID     *string        `json:"clientId,omitempty"`
	ClientSecret *string        `json:"clientSecret,omitempty"`
	RedirectURI  *string        `json:"redirectUri,omitempty"`
	Scopes       []string       `json:"scopes,omitempty"`
	Settings     map[string]any `json:"settings,omitempty"`
	Status       *string        `json:"status,omitempty"`
}

func (h *Handlers) patchTenantIDP(w http.ResponseWriter, r *http.Request) {
	if h.TenantIDP == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("tenant_idp store not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	var req patchTenantIDPReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		encode.JSONError(w, apperr.ErrInvalidParams.Wrap(err))
		return
	}
	fields := map[string]any{}
	if req.Name != nil {
		fields["name"] = *req.Name
	}
	if req.Issuer != nil {
		fields["issuer"] = *req.Issuer
	}
	if req.ClientID != nil {
		fields["client_id"] = *req.ClientID
	}
	if req.ClientSecret != nil {
		if h.SecretSealer == nil {
			encode.JSONError(w, apperr.ErrInternal.Withf("secret sealer not wired"))
			return
		}
		enc, err := h.SecretSealer.Seal(*req.ClientSecret)
		if err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		fields["client_secret_enc"] = enc
	}
	if req.RedirectURI != nil {
		fields["redirect_uri"] = *req.RedirectURI
	}
	if len(req.Scopes) > 0 {
		fields["scopes"] = req.Scopes
	}
	if req.Settings != nil {
		fields["settings"] = req.Settings
	}
	if req.Status != nil {
		fields["status"] = *req.Status
	}
	row, err := h.TenantIDP.Patch(r.Context(), tid, uuid, fields)
	if err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, row)
}

func (h *Handlers) deleteTenantIDP(w http.ResponseWriter, r *http.Request) {
	if h.TenantIDP == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("tenant_idp store not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	uuid := r.PathValue("uuid")
	if err := h.TenantIDP.SoftDelete(r.Context(), tid, uuid); err != nil {
		encode.JSONError(w, err)
		return
	}
	encode.JSON(w, map[string]any{"uuid": uuid, "deleted": true})
}

// =====================================================
// PgxTenantIDPStore: 默认实现 — 走 pgxpool 直查 (cmd/admin 注入)。
// =====================================================

type PgxTenantIDPStore struct{ Pool *pgxpool.Pool }

const tipCols = `id, uuid::text, tenant_id, kind, name, COALESCE(issuer,''), COALESCE(client_id,''),
    COALESCE(client_secret_enc,''), COALESCE(redirect_uri,''),
    COALESCE(scopes,'{}'::varchar[]), COALESCE(settings,'{}'::jsonb), status, created_at, updated_at`

func scanIDPRow(row pgx.Row) (*TenantIDPRow, error) {
	var x TenantIDPRow
	var settings []byte
	if err := row.Scan(&x.ID, &x.UUID, &x.TenantID, &x.Kind, &x.Name, &x.Issuer, &x.ClientID,
		&x.ClientSecretEnc, &x.RedirectURI, &x.Scopes, &settings, &x.Status,
		&x.CreatedAt, &x.UpdatedAt); err != nil {
		return nil, err
	}
	if len(settings) > 0 {
		_ = json.Unmarshal(settings, &x.Settings)
	}
	return &x, nil
}

func (s *PgxTenantIDPStore) ListByTenant(ctx context.Context, tenantID int64) ([]TenantIDPRow, error) {
	rows, err := s.Pool.Query(ctx,
		`SELECT `+tipCols+` FROM tenant_identity_providers
		 WHERE tenant_id=$1 AND deleted_at IS NULL ORDER BY id DESC`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TenantIDPRow
	for rows.Next() {
		x, err := scanIDPRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *x)
	}
	return out, rows.Err()
}

func (s *PgxTenantIDPStore) Insert(ctx context.Context, in TenantIDPRow) (*TenantIDPRow, error) {
	settings, _ := json.Marshal(emptyMap(in.Settings))
	row := s.Pool.QueryRow(ctx, `
		INSERT INTO tenant_identity_providers (tenant_id, kind, name, issuer, client_id, client_secret_enc,
			redirect_uri, scopes, settings, status)
		VALUES ($1,$2,$3,NULLIF($4,''),NULLIF($5,''),NULLIF($6,''),NULLIF($7,''),
		        $8, $9::jsonb, COALESCE(NULLIF($10,''),'active'))
		RETURNING `+tipCols,
		in.TenantID, in.Kind, in.Name, in.Issuer, in.ClientID, in.ClientSecretEnc,
		in.RedirectURI, in.Scopes, string(settings), in.Status)
	return scanIDPRow(row)
}

func (s *PgxTenantIDPStore) Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*TenantIDPRow, error) {
	if len(fields) == 0 {
		return s.GetByUUID(ctx, tenantID, uuid)
	}
	colMap := map[string]string{
		"name":              "name",
		"issuer":            "issuer",
		"client_id":         "client_id",
		"client_secret_enc": "client_secret_enc",
		"redirect_uri":      "redirect_uri",
		"scopes":            "scopes",
		"settings":          "settings",
		"status":            "status",
	}
	jsonbCols := map[string]bool{"settings": true}
	sets := []string{}
	args := []any{}
	idx := 1
	for k, v := range fields {
		col, ok := colMap[k]
		if !ok {
			continue
		}
		if jsonbCols[col] {
			b, _ := json.Marshal(v)
			args = append(args, string(b))
			sets = append(sets, col+" = $"+strconv.Itoa(idx)+"::jsonb")
		} else {
			args = append(args, v)
			sets = append(sets, col+" = $"+strconv.Itoa(idx))
		}
		idx++
	}
	if len(sets) == 0 {
		return s.GetByUUID(ctx, tenantID, uuid)
	}
	args = append(args, uuid, tenantID)
	q := "UPDATE tenant_identity_providers SET " + strings.Join(sets, ", ") +
		", updated_at = now() WHERE uuid = $" + strconv.Itoa(idx) +
		" AND tenant_id = $" + strconv.Itoa(idx+1) + " AND deleted_at IS NULL RETURNING " + tipCols
	row := s.Pool.QueryRow(ctx, q, args...)
	out, err := scanIDPRow(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return out, nil
}

func (s *PgxTenantIDPStore) GetByUUID(ctx context.Context, tenantID int64, uuid string) (*TenantIDPRow, error) {
	row := s.Pool.QueryRow(ctx,
		`SELECT `+tipCols+` FROM tenant_identity_providers WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`,
		uuid, tenantID)
	out, err := scanIDPRow(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return out, nil
}

func (s *PgxTenantIDPStore) SoftDelete(ctx context.Context, tenantID int64, uuid string) error {
	tag, err := s.Pool.Exec(ctx,
		`UPDATE tenant_identity_providers SET deleted_at=now(), updated_at=now()
		 WHERE uuid=$1 AND tenant_id=$2 AND deleted_at IS NULL`, uuid, tenantID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

func emptyMap(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}
