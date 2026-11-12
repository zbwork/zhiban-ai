// Package agentsdk 是 domain/agentsdk 的 pgx 仓储。
package agentsdk

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentsdk"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// CredentialRepo pgxpool 实现。
type CredentialRepo struct{ pool *pgxpool.Pool }

func NewCredentialRepo(pool *pgxpool.Pool) *CredentialRepo { return &CredentialRepo{pool: pool} }

const credCols = `id, uuid, COALESCE(tenant_id, 0), creator_id, name, client_id, client_secret_hash,
    COALESCE(capability_bindings,'{}'::varchar[]), runtime_environment_id,
    COALESCE(scope,'tenant'), last_used_at, status, created_at, updated_at, revoked_at`

func scanCred(row pgx.Row) (*dom.Credential, error) {
	var x dom.Credential
	if err := row.Scan(&x.ID, &x.UUID, &x.TenantID, &x.CreatorID, &x.Name, &x.ClientID,
		&x.ClientSecretHash, &x.CapabilityBindings, &x.RuntimeEnvironmentID,
		&x.Scope, &x.LastUsedAt, &x.Status, &x.CreatedAt, &x.UpdatedAt, &x.RevokedAt); err != nil {
		return nil, err
	}
	return &x, nil
}

// FindActivePlatformByRuntimeEnvironment returns the runtime_access credential used by
// platform-managed runtimes. It is intentionally not part of the public domain
// CredentialRepo interface; only trusted Bus-internal tool proxies should call it.
func (r *CredentialRepo) FindActivePlatformByRuntimeEnvironment(ctx context.Context, runtimeEnvironmentID int64) (*dom.Credential, error) {
	if runtimeEnvironmentID <= 0 {
		return nil, apperr.ErrInvalidParams.Withf("runtime_environment_id required")
	}
	row := r.pool.QueryRow(ctx, `
		SELECT `+credCols+`
		  FROM agent_sdk_credentials
		 WHERE scope='platform'
		   AND tenant_id IS NULL
		   AND runtime_environment_id=$1
		   AND status='active'
		 ORDER BY created_at DESC, id DESC
		 LIMIT 1`, runtimeEnvironmentID)
	x, err := scanCred(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *CredentialRepo) Insert(ctx context.Context, c *dom.Credential) error {
	row := r.pool.QueryRow(ctx, `
		INSERT INTO agent_sdk_credentials (tenant_id, creator_id, name, client_id, client_secret_hash,
			capability_bindings, runtime_environment_id, scope, status)
		VALUES (NULLIF($1,0),$2,$3,$4,$5,$6,$7, COALESCE(NULLIF($8,''),'tenant'), COALESCE(NULLIF($9,''),'active'))
		RETURNING `+credCols,
		c.TenantID, c.CreatorID, c.Name, c.ClientID, c.ClientSecretHash,
		c.CapabilityBindings, c.RuntimeEnvironmentID, c.Scope, c.Status)
	got, err := scanCred(row)
	if err != nil {
		return err
	}
	*c = *got
	return nil
}

func (r *CredentialRepo) SetTenantGrants(ctx context.Context, credentialID int64, mode string, tenantIDs []int64) error {
	if credentialID <= 0 {
		return apperr.ErrInvalidParams.Withf("credential_id required")
	}
	if mode == "" {
		mode = dom.PlatformTenantGrantAllowlist
	}
	if mode != dom.PlatformTenantGrantAllEnabled && mode != dom.PlatformTenantGrantAllowlist {
		return apperr.ErrInvalidParams.Withf("tenant grant mode invalid")
	}
	if mode == dom.PlatformTenantGrantAllowlist && len(tenantIDs) == 0 {
		return apperr.ErrInvalidParams.Withf("allowed tenant ids required")
	}
	return pgx.BeginFunc(ctx, r.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM agent_sdk_credential_tenant_grants WHERE credential_id=$1`, credentialID); err != nil {
			return err
		}
		if mode == dom.PlatformTenantGrantAllEnabled {
			_, err := tx.Exec(ctx, `
				INSERT INTO agent_sdk_credential_tenant_grants (credential_id, tenant_id, grant_mode)
				VALUES ($1, NULL, $2)`, credentialID, mode)
			return err
		}
		for _, tenantID := range tenantIDs {
			if tenantID <= 0 {
				return apperr.ErrInvalidParams.Withf("allowed tenant id invalid")
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO agent_sdk_credential_tenant_grants (credential_id, tenant_id, grant_mode)
				VALUES ($1, $2, $3)`,
				credentialID, tenantID, mode); err != nil {
				return err
			}
		}
		return nil
	})
}

func (r *CredentialRepo) FindByClientID(ctx context.Context, clientID string) (*dom.Credential, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+credCols+` FROM agent_sdk_credentials WHERE client_id=$1`, clientID)
	x, err := scanCred(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *CredentialRepo) GetByUUID(ctx context.Context, tenantID int64, uuid string) (*dom.Credential, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+credCols+` FROM agent_sdk_credentials WHERE uuid=$1 AND tenant_id=$2`, uuid, tenantID)
	x, err := scanCred(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *CredentialRepo) GetPlatformByUUID(ctx context.Context, uuid string) (*dom.Credential, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+credCols+` FROM agent_sdk_credentials WHERE uuid=$1 AND tenant_id IS NULL AND scope=$2`,
		uuid, dom.CredentialScopePlatform)
	x, err := scanCred(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *CredentialRepo) GetByID(ctx context.Context, id int64) (*dom.Credential, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+credCols+` FROM agent_sdk_credentials WHERE id=$1`, id)
	x, err := scanCred(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *CredentialRepo) ListByTenant(ctx context.Context, tenantID int64) ([]dom.Credential, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+credCols+` FROM agent_sdk_credentials WHERE tenant_id=$1 AND scope=$2 ORDER BY id DESC`,
		tenantID, dom.CredentialScopeTenant)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Credential
	for rows.Next() {
		x, err := scanCred(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *x)
	}
	return out, rows.Err()
}

func (r *CredentialRepo) ListPlatform(ctx context.Context) ([]dom.Credential, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+credCols+` FROM agent_sdk_credentials WHERE tenant_id IS NULL AND scope=$1 ORDER BY id DESC`,
		dom.CredentialScopePlatform)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dom.Credential
	for rows.Next() {
		x, err := scanCred(rows)
		if err != nil {
			return nil, err
		}
		if err := r.attachTenantGrants(ctx, x); err != nil {
			return nil, err
		}
		out = append(out, *x)
	}
	return out, rows.Err()
}

func (r *CredentialRepo) attachTenantGrants(ctx context.Context, c *dom.Credential) error {
	if c == nil || c.Scope != dom.CredentialScopePlatform || c.ID <= 0 {
		return nil
	}
	rows, err := r.pool.Query(ctx, `
		SELECT grant_mode, COALESCE(tenant_id, 0)
		  FROM agent_sdk_credential_tenant_grants
		 WHERE credential_id=$1
		 ORDER BY tenant_id NULLS FIRST`, c.ID)
	if err != nil {
		return err
	}
	defer rows.Close()
	mode := ""
	var tenants []int64
	for rows.Next() {
		var grantMode string
		var tenantID int64
		if err := rows.Scan(&grantMode, &tenantID); err != nil {
			return err
		}
		if mode == "" {
			mode = grantMode
		}
		if grantMode == dom.PlatformTenantGrantAllEnabled {
			mode = grantMode
			tenants = nil
			break
		}
		if tenantID > 0 {
			tenants = append(tenants, tenantID)
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	c.TenantGrantMode = mode
	c.AllowedTenantIDs = tenants
	return nil
}

func (r *CredentialRepo) IsTenantAllowedForPlatformCredential(ctx context.Context, credentialID, tenantID int64) (bool, string, error) {
	if credentialID <= 0 || tenantID <= 0 {
		return false, "", apperr.ErrInvalidParams
	}
	var allEnabled bool
	if err := r.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM agent_sdk_credential_tenant_grants
			 WHERE credential_id=$1 AND tenant_id IS NULL AND grant_mode=$2
		)`, credentialID, dom.PlatformTenantGrantAllEnabled).Scan(&allEnabled); err != nil {
		return false, "", err
	}
	if allEnabled {
		return true, dom.PlatformTenantGrantAllEnabled, nil
	}
	var allowed bool
	if err := r.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM agent_sdk_credential_tenant_grants
			 WHERE credential_id=$1 AND tenant_id=$2 AND grant_mode=$3
		)`, credentialID, tenantID, dom.PlatformTenantGrantAllowlist).Scan(&allowed); err != nil {
		return false, "", err
	}
	return allowed, dom.PlatformTenantGrantAllowlist, nil
}

func (r *CredentialRepo) Patch(ctx context.Context, tenantID int64, uuid string, fields map[string]any) (*dom.Credential, error) {
	get := func() (*dom.Credential, error) {
		if tenantID > 0 {
			return r.GetByUUID(ctx, tenantID, uuid)
		}
		return r.GetPlatformByUUID(ctx, uuid)
	}
	if len(fields) == 0 {
		return get()
	}
	colMap := map[string]string{
		"name":                   "name",
		"capability_bindings":    "capability_bindings",
		"runtime_environment_id": "runtime_environment_id",
		"scope":                  "scope",
	}
	sets := []string{}
	args := []any{}
	idx := 1
	for k, v := range fields {
		col, ok := colMap[k]
		if !ok {
			continue
		}
		args = append(args, v)
		sets = append(sets, col+" = $"+strconv.Itoa(idx))
		idx++
	}
	if len(sets) == 0 {
		return get()
	}
	// 平台凭据 tenant_id 为 NULL (对齐 RevokePlatform): tenantID<=0 走 IS NULL 谓词。
	// 此前恒拼 tenant_id=$n, 传 0 时匹配零行 → 平台凭据换绑 runtime_environment_id
	// 永远 ErrNotFound (2026-09-02 生产实锤: 误删环境后 bootstrap 卡在凭据步无法自愈)。
	args = append(args, uuid)
	q := "UPDATE agent_sdk_credentials SET " + strings.Join(sets, ", ") +
		", updated_at = now() WHERE uuid = $" + strconv.Itoa(idx)
	if tenantID > 0 {
		args = append(args, tenantID)
		q += " AND tenant_id = $" + strconv.Itoa(idx+1)
	} else {
		q += " AND tenant_id IS NULL"
	}
	q += " RETURNING " + credCols
	row := r.pool.QueryRow(ctx, q, args...)
	x, err := scanCred(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *CredentialRepo) Revoke(ctx context.Context, tenantID int64, uuid string) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE agent_sdk_credentials SET status='revoked', revoked_at=now(), updated_at=now()
		WHERE uuid=$1 AND tenant_id=$2 AND scope=$3 AND status<>'revoked'`, uuid, tenantID, dom.CredentialScopeTenant)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		if _, gerr := r.GetByUUID(ctx, tenantID, uuid); gerr != nil {
			return gerr
		}
	}
	return nil
}

func (r *CredentialRepo) RevokePlatform(ctx context.Context, uuid string) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE agent_sdk_credentials SET status='revoked', revoked_at=now(), updated_at=now()
		WHERE uuid=$1 AND tenant_id IS NULL AND scope=$2 AND status<>'revoked'`, uuid, dom.CredentialScopePlatform)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		if _, gerr := r.GetPlatformByUUID(ctx, uuid); gerr != nil {
			return gerr
		}
	}
	return nil
}

func (r *CredentialRepo) TouchLastUsed(ctx context.Context, id int64, ts time.Time) error {
	_, err := r.pool.Exec(ctx, `UPDATE agent_sdk_credentials SET last_used_at=$2 WHERE id=$1`, id, ts)
	return err
}

// =====================================================
// SessionTokenRepo
// =====================================================

type SessionTokenRepo struct{ pool *pgxpool.Pool }

func NewSessionTokenRepo(pool *pgxpool.Pool) *SessionTokenRepo { return &SessionTokenRepo{pool: pool} }

// F01 §3.6.3 PR4.5: stCols 加 parent_session_id (NULL = master session).
const stCols = `id, uuid, credential_id, tenant_id, account_id, conversation_id, agent_id, runtime_environment_id, parent_session_id,
    token_prefix, token_hash,
    COALESCE(capability_bindings,'{}'::varchar[]), issued_at, expires_at, last_used_at, status, revoked_at`

func scanST(row pgx.Row) (*dom.SessionToken, error) {
	var x dom.SessionToken
	if err := row.Scan(&x.ID, &x.UUID, &x.CredentialID, &x.TenantID, &x.AccountID, &x.ConversationID, &x.AgentID,
		&x.RuntimeEnvironmentID, &x.ParentSessionID,
		&x.TokenPrefix, &x.TokenHash, &x.CapabilityBindings,
		&x.IssuedAt, &x.ExpiresAt, &x.LastUsedAt, &x.Status, &x.RevokedAt); err != nil {
		return nil, err
	}
	return &x, nil
}

func (r *SessionTokenRepo) Insert(ctx context.Context, t *dom.SessionToken) error {
	row := r.pool.QueryRow(ctx, `
		INSERT INTO session_tokens (credential_id, tenant_id, account_id, conversation_id, agent_id, runtime_environment_id, parent_session_id,
			token_prefix, token_hash, capability_bindings, expires_at, status)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11, COALESCE(NULLIF($12,''),'active'))
		RETURNING `+stCols,
		t.CredentialID, t.TenantID, t.AccountID, t.ConversationID, t.AgentID, t.RuntimeEnvironmentID, t.ParentSessionID,
		t.TokenPrefix, t.TokenHash, t.CapabilityBindings, t.ExpiresAt, t.Status)
	got, err := scanST(row)
	if err != nil {
		return err
	}
	*t = *got
	return nil
}

func (r *SessionTokenRepo) FindByPrefix(ctx context.Context, prefix string) (*dom.SessionToken, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+stCols+` FROM session_tokens WHERE token_prefix=$1`, prefix)
	x, err := scanST(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

// GetByID 按主键查 (F01 §3.6.3 链路 validate 沿 parent_session_id 回溯时用).
func (r *SessionTokenRepo) GetByID(ctx context.Context, id int64) (*dom.SessionToken, error) {
	row := r.pool.QueryRow(ctx, `SELECT `+stCols+` FROM session_tokens WHERE id=$1`, id)
	x, err := scanST(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	return x, nil
}

func (r *SessionTokenRepo) Revoke(ctx context.Context, uuid string) error {
	_, err := r.pool.Exec(ctx, `
		UPDATE session_tokens SET status='revoked', revoked_at=now()
		WHERE uuid=$1 AND status='active'`, uuid)
	return err
}

// RevokeByCredential 级联撤销该 credential 颁发的所有 active session_tokens。
func (r *SessionTokenRepo) RevokeByCredential(ctx context.Context, credentialID int64) (int64, error) {
	tag, err := r.pool.Exec(ctx, `
		UPDATE session_tokens SET status='revoked', revoked_at=now()
		WHERE credential_id=$1 AND status='active'`, credentialID)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

func (r *SessionTokenRepo) RevokeByRuntimeEnvironment(ctx context.Context, runtimeEnvironmentID int64) (int64, error) {
	tag, err := r.pool.Exec(ctx, `
		UPDATE session_tokens SET status='revoked', revoked_at=now()
		WHERE runtime_environment_id=$1 AND status='active'`, runtimeEnvironmentID)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// RuntimeAccessRepo 负责把 runtime_access 换发请求收窄到真实 DB 资源。
type RuntimeAccessRepo struct{ pool *pgxpool.Pool }

func NewRuntimeAccessRepo(pool *pgxpool.Pool) *RuntimeAccessRepo {
	return &RuntimeAccessRepo{pool: pool}
}

func (r *RuntimeAccessRepo) ResolveRuntimeAccess(ctx context.Context, cred *dom.Credential, req dom.RuntimeAccessRequest) (*dom.RuntimeAccessResolution, error) {
	if cred == nil {
		return nil, apperr.ErrUnauthorized
	}
	tenantID := cred.TenantID
	tenantParam := strings.TrimSpace(req.TenantID)
	if tenantID <= 0 {
		if tenantParam == "" {
			return nil, apperr.ErrInvalidParams.Withf("tenant_id required")
		}
		resolvedTenantID, err := r.resolveTenantID(ctx, tenantParam)
		if err != nil {
			return nil, err
		}
		tenantID = resolvedTenantID
	} else if tenantParam != "" {
		resolvedTenantID, err := r.resolveTenantID(ctx, tenantParam)
		if err != nil {
			return nil, err
		}
		if resolvedTenantID != tenantID {
			return nil, apperr.ErrForbidden.Withf("tenant not allowed")
		}
	}
	if cred.Scope != dom.CredentialScopePlatform && cred.TenantID != tenantID {
		return nil, apperr.ErrForbidden.Withf("tenant not allowed")
	}
	if cred.Scope == dom.CredentialScopePlatform {
		if err := r.checkPlatformCredentialTenantGrant(ctx, cred, tenantID); err != nil {
			return nil, err
		}
	}

	if cred.RuntimeEnvironmentID == nil || *cred.RuntimeEnvironmentID <= 0 {
		return nil, apperr.ErrForbidden.Withf("platform credential requires runtime_environment_id")
	}
	runtimeID := *cred.RuntimeEnvironmentID

	if cred.Scope == dom.CredentialScopePlatform {
		if err := r.checkPlatformRuntimeAllowed(ctx, runtimeID, tenantID); err != nil {
			return nil, err
		}
	}

	res := &dom.RuntimeAccessResolution{
		TenantID:             tenantID,
		RuntimeEnvironmentID: runtimeID,
	}
	if accountUUID := strings.TrimSpace(req.AccountUUID); accountUUID != "" {
		accountID, err := r.resolveRuntimeAccessAccount(ctx, accountUUID, tenantID)
		if err != nil {
			return nil, err
		}
		res.AccountID = &accountID
	}
	// A2A v1a (ADR-0030 修订记录): 可选 agent 绑定。缺省不传 = 旧行为, 不查表。
	if agentUUID := strings.TrimSpace(req.AgentUUID); agentUUID != "" {
		agentID, err := r.resolveRuntimeAccessAgent(ctx, agentUUID, tenantID, runtimeID)
		if err != nil {
			return nil, err
		}
		res.AgentID = &agentID
	}
	return res, nil
}

func (r *RuntimeAccessRepo) resolveRuntimeAccessAccount(ctx context.Context, accountUUID string, tenantID int64) (int64, error) {
	var accountID int64
	err := r.pool.QueryRow(ctx, `
		SELECT a.id
		  FROM accounts a
		  JOIN tenant_memberships tm ON tm.account_id=a.id
		 WHERE a.uuid::text=$1
		   AND tm.tenant_id=$2
		   AND a.status='active'
		   AND tm.status='active'
		   AND a.deleted_at IS NULL
		 LIMIT 1`, accountUUID, tenantID).Scan(&accountID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, apperr.ErrForbidden.Withf("account not allowed")
		}
		return 0, err
	}
	return accountID, nil
}

// resolveRuntimeAccessAgent 取 digital_employees 事实行并做换发期绑定校验 (纯校验逻辑在
// dom.ValidateRuntimeAccessAgentBinding)。所有失败统一 Forbidden "agent not allowed" (防探测)。
func (r *RuntimeAccessRepo) resolveRuntimeAccessAgent(ctx context.Context, agentUUID string, tenantID, runtimeID int64) (int64, error) {
	var f dom.RuntimeAccessAgentFacts
	err := r.pool.QueryRow(ctx, `
		SELECT id, tenant_id, runtime_environment_id, status, is_deleted
		  FROM digital_employees
		 WHERE uuid=$1`, agentUUID).
		Scan(&f.ID, &f.TenantID, &f.RuntimeEnvironmentID, &f.Status, &f.IsDeleted)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, apperr.ErrForbidden.Withf("agent not allowed")
		}
		return 0, err
	}
	if verr := dom.ValidateRuntimeAccessAgentBinding(f, tenantID, runtimeID); verr != nil {
		return 0, apperr.ErrForbidden.Withf("agent not allowed")
	}
	return f.ID, nil
}

// ResolveRuntimeAccessAgent 复用换发期校验，供业务接口在请求期授权动态 agent_id。
func (r *RuntimeAccessRepo) ResolveRuntimeAccessAgent(ctx context.Context, agentUUID string, tenantID, runtimeID int64) (int64, error) {
	if strings.TrimSpace(agentUUID) == "" || tenantID <= 0 || runtimeID <= 0 {
		return 0, apperr.ErrForbidden.Withf("agent not allowed")
	}
	return r.resolveRuntimeAccessAgent(ctx, strings.TrimSpace(agentUUID), tenantID, runtimeID)
}

func (r *RuntimeAccessRepo) resolveTenantID(ctx context.Context, tenantParam string) (int64, error) {
	if id, err := strconv.ParseInt(tenantParam, 10, 64); err == nil && id > 0 {
		var tenantID int64
		if err := r.pool.QueryRow(ctx, `
			SELECT id FROM tenants
			 WHERE id=$1 AND deleted_at IS NULL AND status IN ('trial','active')`, id).Scan(&tenantID); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return 0, apperr.ErrForbidden.Withf("tenant not allowed")
			}
			return 0, err
		}
		return tenantID, nil
	}
	var tenantID int64
	if err := r.pool.QueryRow(ctx, `
		SELECT id FROM tenants
		 WHERE uuid::text=$1 AND deleted_at IS NULL AND status IN ('trial','active')`, tenantParam).Scan(&tenantID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, apperr.ErrForbidden.Withf("tenant not allowed")
		}
		return 0, err
	}
	return tenantID, nil
}

func (r *RuntimeAccessRepo) checkPlatformRuntimeAllowed(ctx context.Context, runtimeID, tenantID int64) error {
	var scope, status string
	var enabled, openToTenants bool
	if err := r.pool.QueryRow(ctx, `
		SELECT scope, status, enabled, open_to_tenants
		  FROM runtime_environments
		 WHERE id=$1 AND is_deleted=false`, runtimeID).Scan(&scope, &status, &enabled, &openToTenants); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrForbidden.Withf("runtime not allowed")
		}
		return err
	}
	if scope != "platform" || status != "active" || !enabled {
		return apperr.ErrForbidden.Withf("runtime not allowed")
	}
	if openToTenants {
		return nil
	}
	var exists bool
	if err := r.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM tenant_runtime_enablements
			 WHERE tenant_id=$1 AND runtime_environment_id=$2 AND is_deleted=false
		)`, tenantID, runtimeID).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return apperr.ErrForbidden.Withf("runtime not enabled for tenant")
	}
	return nil
}

func (r *RuntimeAccessRepo) checkPlatformCredentialTenantGrant(ctx context.Context, cred *dom.Credential, tenantID int64) error {
	if cred == nil || cred.Scope != dom.CredentialScopePlatform {
		return nil
	}
	allowed, _, err := NewCredentialRepo(r.pool).IsTenantAllowedForPlatformCredential(ctx, cred.ID, tenantID)
	if err != nil {
		return err
	}
	if !allowed {
		return apperr.ErrForbidden.Withf("tenant not allowed by platform credential")
	}
	return nil
}

// RevokeChain (F01 §3.6.3 / F09 PR4.5) 沿 parent_session_id 正向 cascade 撤销
// 给定 root session 自己 + 所有 descendants. 使用 PG recursive CTE 一次性完成,
// O(N) 走 idx_session_tokens_parent.
//
// 语义:
//   - 只动 status='active' 的行 (已 revoked / expired 不重复操作)
//   - 同时刷新 revoked_at = now()
//   - 返回总共改了多少行 (含 root 自己)
//   - root 不存在 / 不 active 时返 (0, nil) 不报错 (调用方可重试幂等)
func (r *SessionTokenRepo) RevokeChain(ctx context.Context, rootID int64) (int64, error) {
	tag, err := r.pool.Exec(ctx, `
		WITH RECURSIVE chain AS (
			SELECT id FROM session_tokens WHERE id=$1
			UNION ALL
			SELECT st.id
			FROM session_tokens st
			JOIN chain c ON st.parent_session_id = c.id
		)
		UPDATE session_tokens
		SET status='revoked', revoked_at=now()
		WHERE id IN (SELECT id FROM chain) AND status='active'`,
		rootID,
	)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// RevokeChainByUUID 同 RevokeChain 语义, anchor 用 UUID 而不是 ID.
func (r *SessionTokenRepo) RevokeChainByUUID(ctx context.Context, uuid string) (int64, error) {
	tag, err := r.pool.Exec(ctx, `
		WITH RECURSIVE chain AS (
			SELECT id FROM session_tokens WHERE uuid=$1
			UNION ALL
			SELECT st.id
			FROM session_tokens st
			JOIN chain c ON st.parent_session_id = c.id
		)
		UPDATE session_tokens
		SET status='revoked', revoked_at=now()
		WHERE id IN (SELECT id FROM chain) AND status='active'`,
		uuid,
	)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// CleanupExpired:
//   - 把 expires_at <= now() 的 active 行标记成 expired (软删, 保留审计可查 7 天);
//   - 真删 revoked_at < now()-7d OR status='expired' 且 expires_at < now()-7d。
//
// 兼顾审计 + 防表无限增长 (codex challenge #9)。
func (r *SessionTokenRepo) CleanupExpired(ctx context.Context) (int64, error) {
	// 软过期: 把过期但 status='active' 的标为 expired (不删, 让审计看得见)
	_, err := r.pool.Exec(ctx, `
		UPDATE session_tokens SET status='expired'
		WHERE status='active' AND expires_at <= now()`)
	if err != nil {
		return 0, err
	}
	// 硬删: 7 天前的 revoked / expired 行
	tag, err := r.pool.Exec(ctx, `
		DELETE FROM session_tokens
		WHERE (status='revoked' AND revoked_at < now() - interval '7 days')
		   OR (status='expired' AND expires_at < now() - interval '7 days')`)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

func (r *SessionTokenRepo) TouchLastUsed(ctx context.Context, id int64, ts time.Time) error {
	_, err := r.pool.Exec(ctx, `UPDATE session_tokens SET last_used_at=$2 WHERE id=$1`, id, ts)
	return err
}
