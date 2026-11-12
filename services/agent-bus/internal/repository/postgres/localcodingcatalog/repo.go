// Package localcodingcatalog is the PostgreSQL repository for the F31 tool
// version catalog (table local_coding_tool_versions, migration 000143).
package localcodingcatalog

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const table = "local_coding_tool_versions"

func (r *Repo) List(ctx context.Context, f dom.Filter) ([]dom.Version, int64, error) {
	where := []string{"deleted_at IS NULL"}
	args := []any{}
	add := func(cond string, val any) {
		args = append(args, val)
		where = append(where, fmt.Sprintf(cond, len(args)))
	}
	if f.TargetID != "" {
		add("target_id = $%d", f.TargetID)
	}
	if f.Platform != "" {
		add("platform = $%d", f.Platform)
	}
	if f.Arch != "" {
		add("arch = $%d", f.Arch)
	}
	if f.Status != "" {
		add("status = $%d", f.Status)
	}
	if f.Keyword != "" {
		args = append(args, "%"+f.Keyword+"%")
		n := len(args)
		where = append(where, fmt.Sprintf("(version ILIKE $%d OR release_notes ILIKE $%d)", n, n))
	}
	whereSQL := strings.Join(where, " AND ")

	var total int64
	if err := r.pool.QueryRow(ctx, `SELECT count(*) FROM `+table+` WHERE `+whereSQL, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("localcodingcatalog.List count: %w", err)
	}
	args = append(args, f.Limit, f.Offset)
	q := fmt.Sprintf(`
		SELECT %s
		  FROM %s
		 WHERE %s
		 ORDER BY target_id, platform, arch, created_at DESC
		 LIMIT $%d OFFSET $%d`, selectColumns(), table, whereSQL, len(args)-1, len(args))
	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("localcodingcatalog.List query: %w", err)
	}
	defer rows.Close()
	items := make([]dom.Version, 0)
	for rows.Next() {
		item, err := scanVersion(rows)
		if err != nil {
			return nil, 0, err
		}
		items = append(items, *item)
	}
	return items, total, rows.Err()
}

func (r *Repo) GetByUUID(ctx context.Context, uuid string) (*dom.Version, error) {
	q := fmt.Sprintf(`SELECT %s FROM %s WHERE uuid = $1 AND deleted_at IS NULL`, selectColumns(), table)
	item, err := scanVersion(r.pool.QueryRow(ctx, q, uuid))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound.Withf("local coding tool version not found")
	}
	if err != nil {
		return nil, fmt.Errorf("localcodingcatalog.GetByUUID: %w", err)
	}
	return item, nil
}

func (r *Repo) Create(ctx context.Context, in dom.UpsertInput) (*dom.Version, error) {
	q := `
		INSERT INTO ` + table + ` (
			target_id, platform, arch, version, layout, member, binary_sha256,
			bundle_identifier, team_identifier, min_bridge_version, min_app_version,
			profile_version, contract_check_ref, release_notes,
			storage_uri, file_size_bytes, sha256,
			created_by, updated_by
		) VALUES (
			$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$18
		)
		RETURNING ` + selectColumns()
	item, err := scanVersion(r.pool.QueryRow(ctx, q,
		in.TargetID, in.Platform, in.Arch, in.Version, in.Layout, in.Member, in.BinarySHA256,
		in.BundleIdentifier, in.TeamIdentifier, in.MinBridgeVersion, in.MinAppVersion,
		in.ProfileVersion, in.ContractCheckRef, in.ReleaseNotes,
		in.ExternalURL, externalSize(in), externalSHA(in),
		nullActor(in.ActorID),
	))
	if isUniqueViolation(err) {
		return nil, dom.ErrDuplicateVersion
	}
	if err != nil {
		return nil, fmt.Errorf("localcodingcatalog.Create: %w", err)
	}
	return item, nil
}

// Update only edits drafts; published rows are immutable except through
// Publish / Deprecate. An external URL (when given) replaces the package fields.
func (r *Repo) Update(ctx context.Context, uuid string, in dom.UpsertInput) (*dom.Version, error) {
	q := `
		UPDATE ` + table + `
		   SET target_id = $2, platform = $3, arch = $4, version = $5, layout = $6, member = $7,
		       binary_sha256 = $8, bundle_identifier = $9, team_identifier = $10,
		       min_bridge_version = $11, min_app_version = $12, profile_version = $13,
		       contract_check_ref = $14, release_notes = $15,
		       storage_uri = CASE WHEN $16 <> '' THEN $16 ELSE storage_uri END,
		       file_size_bytes = CASE WHEN $16 <> '' THEN $17 ELSE file_size_bytes END,
		       sha256 = CASE WHEN $16 <> '' THEN $18 ELSE sha256 END,
		       updated_by = $19, updated_at = now()
		 WHERE uuid = $1 AND deleted_at IS NULL AND status = 'draft'
		RETURNING ` + selectColumns()
	item, err := scanVersion(r.pool.QueryRow(ctx, q,
		uuid, in.TargetID, in.Platform, in.Arch, in.Version, in.Layout, in.Member,
		in.BinarySHA256, in.BundleIdentifier, in.TeamIdentifier,
		in.MinBridgeVersion, in.MinAppVersion, in.ProfileVersion,
		in.ContractCheckRef, in.ReleaseNotes,
		in.ExternalURL, externalSize(in), externalSHA(in),
		nullActor(in.ActorID),
	))
	if errors.Is(err, pgx.ErrNoRows) {
		if _, getErr := r.GetByUUID(ctx, uuid); getErr != nil {
			return nil, getErr
		}
		return nil, dom.ErrNotDraft
	}
	if isUniqueViolation(err) {
		return nil, dom.ErrDuplicateVersion
	}
	if err != nil {
		return nil, fmt.Errorf("localcodingcatalog.Update: %w", err)
	}
	return item, nil
}

func (r *Repo) SetPackage(ctx context.Context, uuid string, in dom.PackageInput) (*dom.Version, error) {
	q := `
		UPDATE ` + table + `
		   SET storage_uri = $2, file_size_bytes = $3, sha256 = $4, updated_by = $5, updated_at = now(),
		       share_code = '', share_url = '', share_expires_at = NULL
		 WHERE uuid = $1 AND deleted_at IS NULL AND status = 'draft'
		RETURNING ` + selectColumns()
	item, err := scanVersion(r.pool.QueryRow(ctx, q, uuid, in.StorageURI, in.FileSizeBytes, in.SHA256, nullActor(in.ActorID)))
	if errors.Is(err, pgx.ErrNoRows) {
		if _, getErr := r.GetByUUID(ctx, uuid); getErr != nil {
			return nil, getErr
		}
		return nil, dom.ErrNotDraft
	}
	if err != nil {
		return nil, fmt.Errorf("localcodingcatalog.SetPackage: %w", err)
	}
	return item, nil
}

func (r *Repo) SetMirrorState(ctx context.Context, uuid, state, message string) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE `+table+` SET mirror_state = $2, mirror_error = $3, updated_at = now()
		 WHERE uuid = $1 AND deleted_at IS NULL`, uuid, state, message)
	if err != nil {
		return fmt.Errorf("localcodingcatalog.SetMirrorState: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("local coding tool version not found")
	}
	return nil
}

func (r *Repo) ResetRunningMirrors(ctx context.Context, message string) (int64, error) {
	tag, err := r.pool.Exec(ctx, `
		UPDATE `+table+` SET mirror_state = $2, mirror_error = $1, updated_at = now()
		 WHERE mirror_state = $3 AND deleted_at IS NULL`, message, dom.MirrorStateFailed, dom.MirrorStateRunning)
	if err != nil {
		return 0, fmt.Errorf("localcodingcatalog.ResetRunningMirrors: %w", err)
	}
	return tag.RowsAffected(), nil
}

func (r *Repo) ReplaceStorage(ctx context.Context, uuid, storageURI string, sizeBytes int64, sha256 string, actorID int64) (*dom.Version, error) {
	item, err := scanVersion(r.pool.QueryRow(ctx, `
		UPDATE `+table+`
		   SET storage_uri = $2, mirror_state = 'done', mirror_error = '', updated_by = $5, updated_at = now(),
		       share_code = '', share_url = '', share_expires_at = NULL
		 WHERE uuid = $1 AND deleted_at IS NULL AND file_size_bytes = $3 AND sha256 = $4
		RETURNING `+selectColumns(), uuid, storageURI, sizeBytes, sha256, nullActor(actorID)))
	if errors.Is(err, pgx.ErrNoRows) {
		if _, getErr := r.GetByUUID(ctx, uuid); getErr != nil {
			return nil, getErr
		}
		return nil, dom.ErrMirrorMismatch
	}
	if err != nil {
		return nil, fmt.Errorf("localcodingcatalog.ReplaceStorage: %w", err)
	}
	return item, nil
}

func (r *Repo) Publish(ctx context.Context, uuid string, in dom.PublishInput) (*dom.Version, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("localcodingcatalog.Publish begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	cur, err := scanVersion(tx.QueryRow(ctx,
		fmt.Sprintf(`SELECT %s FROM %s WHERE uuid = $1 AND deleted_at IS NULL FOR UPDATE`, selectColumns(), table), uuid))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound.Withf("local coding tool version not found")
	}
	if err != nil {
		return nil, fmt.Errorf("localcodingcatalog.Publish lock: %w", err)
	}
	switch in.Mode {
	case dom.PublishModeCanary:
		if cur.Status != dom.StatusDraft && cur.Status != dom.StatusCanary {
			return nil, dom.ErrInvalidStatus
		}
		var overlap bool
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS (
				SELECT 1 FROM `+table+`
				 WHERE target_id = $1 AND platform = $2 AND arch = $3
				   AND status = 'canary' AND uuid <> $4 AND deleted_at IS NULL
				   AND canary_tenant_ids && $5::bigint[])`,
			cur.TargetID, cur.Platform, cur.Arch, uuid, in.TenantIDs).Scan(&overlap); err != nil {
			return nil, fmt.Errorf("localcodingcatalog.Publish overlap: %w", err)
		}
		if overlap {
			return nil, dom.ErrCanaryTenantOverlap
		}
		cur, err = scanVersion(tx.QueryRow(ctx, `
			UPDATE `+table+`
			   SET status = 'canary', canary_tenant_ids = $2::bigint[],
			       published_at = COALESCE(published_at, now()), updated_by = $3, updated_at = now()
			 WHERE uuid = $1
			RETURNING `+selectColumns(), uuid, in.TenantIDs, nullActor(in.ActorID)))
	case dom.PublishModeCurrent:
		if cur.Status == dom.StatusCurrent {
			return nil, dom.ErrInvalidStatus
		}
		// Order matters for the partial unique indexes: free "previous" first
		// (when this row is the previous, it passes through deprecated for the
		// duration of the transaction), then demote the old current, then
		// promote this row. A previous / deprecated row promoted this way is the
		// platform-level rollback: the old current becomes previous.
		if _, err := tx.Exec(ctx, `
			UPDATE `+table+` SET status = 'deprecated', updated_by = $4, updated_at = now()
			 WHERE target_id = $1 AND platform = $2 AND arch = $3 AND status = 'previous' AND deleted_at IS NULL`,
			cur.TargetID, cur.Platform, cur.Arch, nullActor(in.ActorID)); err != nil {
			return nil, fmt.Errorf("localcodingcatalog.Publish deprecate previous: %w", err)
		}
		if _, err := tx.Exec(ctx, `
			UPDATE `+table+` SET status = 'previous', updated_by = $5, updated_at = now()
			 WHERE target_id = $1 AND platform = $2 AND arch = $3 AND status = 'current' AND uuid <> $4 AND deleted_at IS NULL`,
			cur.TargetID, cur.Platform, cur.Arch, uuid, nullActor(in.ActorID)); err != nil {
			return nil, fmt.Errorf("localcodingcatalog.Publish demote current: %w", err)
		}
		cur, err = scanVersion(tx.QueryRow(ctx, `
			UPDATE `+table+`
			   SET status = 'current', canary_tenant_ids = '{}',
			       published_at = COALESCE(published_at, now()), updated_by = $2, updated_at = now()
			 WHERE uuid = $1
			RETURNING `+selectColumns(), uuid, nullActor(in.ActorID)))
	default:
		return nil, dom.ErrInvalidPublishMode
	}
	if isUniqueViolation(err) {
		return nil, dom.ErrDuplicateVersion
	}
	if err != nil {
		return nil, fmt.Errorf("localcodingcatalog.Publish update: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("localcodingcatalog.Publish commit: %w", err)
	}
	return cur, nil
}

func (r *Repo) Deprecate(ctx context.Context, uuid string, actorID int64) (*dom.Version, error) {
	item, err := scanVersion(r.pool.QueryRow(ctx, `
		UPDATE `+table+`
		   SET status = 'deprecated', canary_tenant_ids = '{}', updated_by = $2, updated_at = now()
		 WHERE uuid = $1 AND deleted_at IS NULL AND status IN ('canary','current','previous')
		RETURNING `+selectColumns(), uuid, nullActor(actorID)))
	if errors.Is(err, pgx.ErrNoRows) {
		if _, getErr := r.GetByUUID(ctx, uuid); getErr != nil {
			return nil, getErr
		}
		return nil, dom.ErrNotPublished
	}
	if err != nil {
		return nil, fmt.Errorf("localcodingcatalog.Deprecate: %w", err)
	}
	return item, nil
}

func (r *Repo) Delete(ctx context.Context, uuid string, actorID int64) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE `+table+`
		   SET deleted_at = now(), updated_by = $2, updated_at = now()
		 WHERE uuid = $1 AND deleted_at IS NULL AND status IN ('draft','deprecated')`, uuid, nullActor(actorID))
	if err != nil {
		return fmt.Errorf("localcodingcatalog.Delete: %w", err)
	}
	if tag.RowsAffected() == 0 {
		if _, getErr := r.GetByUUID(ctx, uuid); getErr != nil {
			return getErr
		}
		return dom.ErrInvalidStatus
	}
	return nil
}

func (r *Repo) ListActive(ctx context.Context, platform, arch string) ([]dom.Version, error) {
	q := fmt.Sprintf(`
		SELECT %s
		  FROM %s
		 WHERE platform = $1
		   AND (arch = $2 OR arch = 'universal')
		   AND status IN ('canary','current','previous')
		   AND deleted_at IS NULL
		 ORDER BY target_id, published_at DESC NULLS LAST, created_at DESC`, selectColumns(), table)
	rows, err := r.pool.Query(ctx, q, platform, arch)
	if err != nil {
		return nil, fmt.Errorf("localcodingcatalog.ListActive: %w", err)
	}
	defer rows.Close()
	items := make([]dom.Version, 0)
	for rows.Next() {
		item, err := scanVersion(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, *item)
	}
	return items, rows.Err()
}

// ListShareRefreshCandidates implements dom.Repository: published rows in
// the platform object store whose share link is missing or expires before
// `before`. Missing links sort first, then the soonest expiry, so one pass
// with a bounded batch still converges on the most urgent rows.
func (r *Repo) ListShareRefreshCandidates(ctx context.Context, before time.Time, limit int) ([]dom.Version, error) {
	if limit <= 0 {
		limit = 100
	}
	q := fmt.Sprintf(`
		SELECT %s
		  FROM %s
		 WHERE status IN ('canary','current','previous')
		   AND storage_uri LIKE 'oss://%%'
		   AND deleted_at IS NULL
		   AND (share_url = '' OR share_expires_at IS NULL OR share_expires_at < $1)
		 ORDER BY share_expires_at ASC NULLS FIRST, id ASC
		 LIMIT $2`, selectColumns(), table)
	rows, err := r.pool.Query(ctx, q, before, limit)
	if err != nil {
		return nil, fmt.Errorf("localcodingcatalog.ListShareRefreshCandidates: %w", err)
	}
	defer rows.Close()
	items := make([]dom.Version, 0)
	for rows.Next() {
		item, err := scanVersion(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, *item)
	}
	return items, rows.Err()
}

// SetShareLink implements dom.Repository.
func (r *Repo) SetShareLink(ctx context.Context, uuid string, in dom.ShareLinkInput) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE `+table+` SET share_code = $2, share_url = $3, share_expires_at = $4, updated_at = now()
		 WHERE uuid = $1 AND deleted_at IS NULL`, uuid, in.Code, in.URL, in.ExpiresAt)
	if err != nil {
		return fmt.Errorf("localcodingcatalog.SetShareLink: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("local coding tool version not found")
	}
	return nil
}

// autoSyncLockKey is the advisory lock of one auto sync round ("lctvsync").
const autoSyncLockKey int64 = 0x6c63747673796e63

// VersionEverRecorded implements dom.Repository; deleted rows count.
func (r *Repo) VersionEverRecorded(ctx context.Context, targetID, platform, arch, version string) (bool, error) {
	var exists bool
	err := r.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM `+table+`
		 WHERE target_id = $1 AND platform = $2 AND arch = $3 AND version = $4)`,
		targetID, platform, arch, version).Scan(&exists)
	if err != nil {
		return false, fmt.Errorf("localcodingcatalog.VersionEverRecorded: %w", err)
	}
	return exists, nil
}

// TryAutoSyncLock implements dom.Repository with a session advisory lock; the
// connection is held until release so the lock cannot outlive the round.
func (r *Repo) TryAutoSyncLock(ctx context.Context) (func(), bool, error) {
	conn, err := r.pool.Acquire(ctx)
	if err != nil {
		return nil, false, fmt.Errorf("localcodingcatalog.TryAutoSyncLock: %w", err)
	}
	var acquired bool
	if err := conn.QueryRow(ctx, `SELECT pg_try_advisory_lock($1)`, autoSyncLockKey).Scan(&acquired); err != nil {
		conn.Release()
		return nil, false, fmt.Errorf("localcodingcatalog.TryAutoSyncLock: %w", err)
	}
	if !acquired {
		conn.Release()
		return nil, false, nil
	}
	release := func() {
		// The round's context may already be cancelled; unlocking must still happen.
		_, _ = conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock($1)`, autoSyncLockKey)
		conn.Release()
	}
	return release, true, nil
}

func selectColumns() string {
	return `id, uuid::text, target_id, platform, arch, version, layout,
	        COALESCE(member,''), COALESCE(storage_uri,''), file_size_bytes, COALESCE(sha256,''),
	        COALESCE(binary_sha256,''), COALESCE(bundle_identifier,''), COALESCE(team_identifier,''),
	        COALESCE(min_bridge_version,''), COALESCE(min_app_version,''), COALESCE(profile_version,''),
	        COALESCE(contract_check_ref,''), COALESCE(release_notes,''), status, canary_tenant_ids,
	        COALESCE(mirror_state,''), COALESCE(mirror_error,''),
	        COALESCE(share_code,''), COALESCE(share_url,''), share_expires_at,
	        published_at, created_by, updated_by, created_at, updated_at`
}

func scanVersion(row pgx.Row) (*dom.Version, error) {
	var item dom.Version
	var publishedAt, shareExpiresAt pgtype.Timestamptz
	var createdBy, updatedBy pgtype.Int8
	var tenantIDs []int64
	if err := row.Scan(
		&item.ID, &item.UUID, &item.TargetID, &item.Platform, &item.Arch, &item.Version, &item.Layout,
		&item.Member, &item.StorageURI, &item.FileSizeBytes, &item.SHA256,
		&item.BinarySHA256, &item.BundleIdentifier, &item.TeamIdentifier,
		&item.MinBridgeVersion, &item.MinAppVersion, &item.ProfileVersion,
		&item.ContractCheckRef, &item.ReleaseNotes, &item.Status, &tenantIDs,
		&item.MirrorState, &item.MirrorError,
		&item.ShareCode, &item.ShareURL, &shareExpiresAt,
		&publishedAt, &createdBy, &updatedBy, &item.CreatedAt, &item.UpdatedAt,
	); err != nil {
		return nil, err
	}
	if tenantIDs == nil {
		tenantIDs = []int64{}
	}
	item.CanaryTenantIDs = tenantIDs
	item.AutoSynced = dom.IsAutoSyncRef(item.ContractCheckRef)
	if publishedAt.Valid {
		t := publishedAt.Time
		item.PublishedAt = &t
	}
	if shareExpiresAt.Valid {
		t := shareExpiresAt.Time
		item.ShareExpiresAt = &t
	}
	if createdBy.Valid {
		item.CreatedBy = ptrInt64(createdBy.Int64)
	}
	if updatedBy.Valid {
		item.UpdatedBy = ptrInt64(updatedBy.Int64)
	}
	return &item, nil
}

func externalSize(in dom.UpsertInput) int64 {
	if in.ExternalURL == "" {
		return 0
	}
	return in.FileSizeBytes
}

func externalSHA(in dom.UpsertInput) string {
	if in.ExternalURL == "" {
		return ""
	}
	return in.SHA256
}

func nullActor(id int64) any {
	if id <= 0 {
		return nil
	}
	return id
}

func ptrInt64(v int64) *int64 { return &v }

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

var _ dom.Repository = (*Repo)(nil)
