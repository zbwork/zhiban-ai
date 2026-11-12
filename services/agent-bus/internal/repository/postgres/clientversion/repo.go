package clientversion

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientversion"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

func (r *Repo) List(ctx context.Context, f dom.Filter) ([]dom.Version, int64, error) {
	where := []string{"deleted_at IS NULL"}
	args := []any{}
	add := func(cond string, val any) {
		args = append(args, val)
		where = append(where, fmt.Sprintf(cond, len(args)))
	}
	if f.Platform != "" {
		add("platform = $%d", f.Platform)
	}
	if f.Arch != "" {
		add("arch = $%d", f.Arch)
	}
	if f.Channel != "" {
		add("channel = $%d", f.Channel)
	}
	if f.Status != "" {
		add("status = $%d", f.Status)
	}
	if f.Keyword != "" {
		args = append(args, "%"+f.Keyword+"%")
		n := len(args)
		where = append(where, fmt.Sprintf("(version ILIKE $%d OR build_number ILIKE $%d OR title ILIKE $%d)", n, n, n))
	}
	whereSQL := strings.Join(where, " AND ")

	var total int64
	if err := r.pool.QueryRow(ctx, `SELECT count(*) FROM client_app_versions WHERE `+whereSQL, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("clientversion.List count: %w", err)
	}

	orderBy := "created_at DESC"
	switch f.SortBy {
	case "build_number":
		orderBy = "build_number::bigint ASC"
	case "-build_number":
		orderBy = "build_number::bigint DESC"
	}
	args = append(args, f.Limit, f.Offset)
	q := fmt.Sprintf(`
		SELECT %s
		  FROM client_app_versions
		 WHERE %s
		 ORDER BY %s
		 LIMIT $%d OFFSET $%d`, selectColumns(), whereSQL, orderBy, len(args)-1, len(args))
	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("clientversion.List query: %w", err)
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
	q := fmt.Sprintf(`SELECT %s FROM client_app_versions WHERE uuid = $1 AND deleted_at IS NULL`, selectColumns())
	item, err := scanVersion(r.pool.QueryRow(ctx, q, uuid))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound.Withf("client version not found")
	}
	if err != nil {
		return nil, fmt.Errorf("clientversion.GetByUUID: %w", err)
	}
	return item, nil
}

func (r *Repo) Create(ctx context.Context, in dom.UpsertInput) (*dom.Version, error) {
	const q = `
		INSERT INTO client_app_versions (
			platform, arch, channel, version, build_number, title, release_notes,
			download_url, appcast_url, sparkle_ed_signature, file_size_bytes, sha256,
			min_os_version, min_supported_version, is_forced, status, published_at,
			created_by, updated_by
		) VALUES (
			$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16::varchar,
			CASE WHEN $16::text = 'published' THEN now() ELSE NULL END,
			$17,$17
		)
		RETURNING `
	item, err := scanVersion(r.pool.QueryRow(ctx, q+selectColumns(),
		in.Platform, in.Arch, in.Channel, in.Version, in.BuildNumber, in.Title, in.ReleaseNotes,
		in.DownloadURL, in.AppcastURL, in.SparkleEDSignature, in.FileSizeBytes, in.SHA256,
		in.MinOSVersion, in.MinSupportedVersion, in.IsForced, in.Status, nullActor(in.ActorID),
	))
	if isUniqueViolation(err) {
		return nil, dom.ErrDuplicateBuild
	}
	if err != nil {
		return nil, fmt.Errorf("clientversion.Create: %w", err)
	}
	return item, nil
}

func (r *Repo) Update(ctx context.Context, uuid string, in dom.UpsertInput) (*dom.Version, error) {
	const q = `
		UPDATE client_app_versions
		   SET platform = $2,
		       arch = $3,
		       channel = $4,
		       version = $5,
		       build_number = $6,
		       title = $7,
		       release_notes = $8,
		       download_url = $9,
		       appcast_url = $10,
		       sparkle_ed_signature = $11,
		       file_size_bytes = $12,
		       sha256 = $13,
		       min_os_version = $14,
		       min_supported_version = $15,
		       is_forced = $16,
		       status = $17::varchar,
		       published_at = CASE
		           WHEN $17::text = 'published' THEN COALESCE(published_at, now())
		           ELSE published_at
		       END,
		       updated_by = $18,
		       updated_at = now()
		 WHERE uuid = $1
		   AND deleted_at IS NULL
		RETURNING `
	item, err := scanVersion(r.pool.QueryRow(ctx, q+selectColumns(),
		uuid, in.Platform, in.Arch, in.Channel, in.Version, in.BuildNumber, in.Title, in.ReleaseNotes,
		in.DownloadURL, in.AppcastURL, in.SparkleEDSignature, in.FileSizeBytes, in.SHA256,
		in.MinOSVersion, in.MinSupportedVersion, in.IsForced, in.Status, nullActor(in.ActorID),
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound.Withf("client version not found")
	}
	if isUniqueViolation(err) {
		return nil, dom.ErrDuplicateBuild
	}
	if err != nil {
		return nil, fmt.Errorf("clientversion.Update: %w", err)
	}
	return item, nil
}

func (r *Repo) Delete(ctx context.Context, uuid string, actorID int64) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE client_app_versions
		   SET deleted_at = now(), updated_by = $2, updated_at = now()
		 WHERE uuid = $1
		   AND deleted_at IS NULL`, uuid, nullActor(actorID))
	if err != nil {
		return fmt.Errorf("clientversion.Delete: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("client version not found")
	}
	return nil
}

func (r *Repo) ListPublishedCandidates(ctx context.Context, platform, arch, channel string) ([]dom.Version, error) {
	q := fmt.Sprintf(`
		SELECT %s
		  FROM client_app_versions
		 WHERE platform = $1
		   AND channel = $2
		   AND status = 'published'
		   AND deleted_at IS NULL
		   AND ($3 = '' OR arch = $3 OR arch = 'universal')
		 ORDER BY published_at DESC NULLS LAST, created_at DESC
		 LIMIT 50`, selectColumns())
	rows, err := r.pool.Query(ctx, q, platform, channel, arch)
	if err != nil {
		return nil, fmt.Errorf("clientversion.ListPublishedCandidates: %w", err)
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

func selectColumns() string {
	return `id, uuid::text, platform, arch, channel, version, build_number,
	        COALESCE(title,''), COALESCE(release_notes,''), COALESCE(download_url,''),
	        COALESCE(appcast_url,''), COALESCE(sparkle_ed_signature,''), file_size_bytes,
	        COALESCE(sha256,''), COALESCE(min_os_version,''), COALESCE(min_supported_version,''),
	        is_forced, status, published_at, created_by, updated_by, created_at, updated_at,
	        COALESCE(deltas::text, '[]')`
}

func scanVersion(row pgx.Row) (*dom.Version, error) {
	var item dom.Version
	var publishedAt pgtype.Timestamptz
	var createdBy, updatedBy pgtype.Int8
	var deltasJSON string
	if err := row.Scan(
		&item.ID, &item.UUID, &item.Platform, &item.Arch, &item.Channel, &item.Version, &item.BuildNumber,
		&item.Title, &item.ReleaseNotes, &item.DownloadURL, &item.AppcastURL, &item.SparkleEDSignature,
		&item.FileSizeBytes, &item.SHA256, &item.MinOSVersion, &item.MinSupportedVersion,
		&item.IsForced, &item.Status, &publishedAt, &createdBy, &updatedBy, &item.CreatedAt, &item.UpdatedAt,
		&deltasJSON,
	); err != nil {
		return nil, err
	}
	if publishedAt.Valid {
		t := publishedAt.Time
		item.PublishedAt = &t
	}
	if createdBy.Valid {
		item.CreatedBy = ptrInt64(createdBy.Int64)
	}
	if updatedBy.Valid {
		item.UpdatedBy = ptrInt64(updatedBy.Int64)
	}
	if deltasJSON != "" && deltasJSON != "[]" {
		if err := json.Unmarshal([]byte(deltasJSON), &item.Deltas); err != nil {
			return nil, fmt.Errorf("clientversion scan deltas: %w", err)
		}
	}
	return &item, nil
}

// AppendDelta 追加一条 delta 元数据到版本记录的 deltas JSONB 列。
func (r *Repo) AppendDelta(ctx context.Context, uuid string, d dom.DeltaInfo) error {
	payload, err := json.Marshal([]dom.DeltaInfo{d})
	if err != nil {
		return fmt.Errorf("clientversion.AppendDelta marshal: %w", err)
	}
	tag, err := r.pool.Exec(ctx, `
		UPDATE client_app_versions
		   SET deltas = COALESCE((
		         SELECT jsonb_agg(elem)
		           FROM jsonb_array_elements(deltas) elem
		          WHERE elem->>'delta_from' <> $3
		       ), '[]'::jsonb) || $2::jsonb,
		       updated_at = now()
		 WHERE uuid = $1
		   AND deleted_at IS NULL`, uuid, string(payload), d.DeltaFrom)
	if err != nil {
		return fmt.Errorf("clientversion.AppendDelta: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("client version not found")
	}
	return nil
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
