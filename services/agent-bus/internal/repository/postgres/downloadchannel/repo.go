package downloadchannel

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/downloadchannel"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

// kindCond F29: Filter.Kind → WHERE 条件。""/marketing 缺省只查 marketing, all 不过滤。
func kindCond(f dom.Filter, args *[]any, where *[]string) {
	switch f.Kind {
	case dom.KindAll:
	case dom.KindUserShare:
		*args = append(*args, dom.KindUserShare)
		*where = append(*where, fmt.Sprintf("c.kind = $%d", len(*args)))
	default:
		*args = append(*args, dom.KindMarketing)
		*where = append(*where, fmt.Sprintf("c.kind = $%d", len(*args)))
	}
}

func (r *Repo) List(ctx context.Context, f dom.Filter) ([]dom.ChannelWithStats, int64, error) {
	where := []string{"c.deleted_at IS NULL"}
	args := []any{}
	add := func(cond string, val any) {
		args = append(args, val)
		where = append(where, fmt.Sprintf(cond, len(args)))
	}
	kindCond(f, &args, &where)
	if f.Status != "" {
		add("c.status = $%d", f.Status)
	}
	if f.Keyword != "" {
		args = append(args, "%"+f.Keyword+"%")
		n := len(args)
		where = append(where, fmt.Sprintf("(c.name ILIKE $%d OR c.code ILIKE $%d)", n, n))
	}
	whereSQL := strings.Join(where, " AND ")

	var total int64
	countQ := `SELECT count(*) FROM download_channels c WHERE ` + whereSQL
	if err := r.pool.QueryRow(ctx, countQ, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("downloadchannel.List count: %w", err)
	}

	rangeArgs := append([]any{}, args...)
	rangeArgs = append(rangeArgs, f.RangeStart, f.RangeEnd)
	startIdx := len(rangeArgs) - 1
	endIdx := len(rangeArgs)
	rangeArgs = append(rangeArgs, f.Limit, f.Offset)

	q := fmt.Sprintf(`
		SELECT c.id, c.uuid::text, c.code, c.name, c.description, c.status,
		       c.kind, c.owner_account_id,
		       c.created_by, c.updated_by, c.created_at, c.updated_at,
		       COALESCE(v.cnt, 0), COALESCE(d.cnt, 0)
		  FROM download_channels c
		  LEFT JOIN (
		        SELECT channel_id, count(*) cnt
		          FROM download_channel_events
		         WHERE event_kind = 'visit'
		           AND ($%d::timestamptz IS NULL OR occurred_at >= $%d)
		           AND ($%d::timestamptz IS NULL OR occurred_at <= $%d)
		         GROUP BY channel_id
		       ) v ON v.channel_id = c.id
		  LEFT JOIN (
		        SELECT channel_id, count(*) cnt
		          FROM download_channel_events
		         WHERE event_kind = 'download_click'
		           AND ($%d::timestamptz IS NULL OR occurred_at >= $%d)
		           AND ($%d::timestamptz IS NULL OR occurred_at <= $%d)
		         GROUP BY channel_id
		       ) d ON d.channel_id = c.id
		 WHERE %s
		 ORDER BY c.created_at DESC
		 LIMIT $%d OFFSET $%d`,
		startIdx, startIdx, endIdx, endIdx,
		startIdx, startIdx, endIdx, endIdx,
		whereSQL, len(rangeArgs)-1, len(rangeArgs))

	rows, err := r.pool.Query(ctx, q, rangeArgs...)
	if err != nil {
		return nil, 0, fmt.Errorf("downloadchannel.List query: %w", err)
	}
	defer rows.Close()
	items := make([]dom.ChannelWithStats, 0)
	for rows.Next() {
		item, err := scanChannelWithStats(rows)
		if err != nil {
			return nil, 0, err
		}
		items = append(items, *item)
	}
	return items, total, rows.Err()
}

func shareGrowthWhere(f dom.Filter, args *[]any) string {
	where := []string{"c.deleted_at IS NULL", "c.kind = 'user_share'"}
	add := func(cond string, val any) {
		*args = append(*args, val)
		where = append(where, fmt.Sprintf(cond, len(*args)))
	}
	if f.Status != "" {
		add("c.status = $%d", f.Status)
	}
	if f.Keyword != "" {
		*args = append(*args, "%"+f.Keyword+"%")
		n := len(*args)
		where = append(where, fmt.Sprintf(
			"(c.code ILIKE $%d OR COALESCE(a.display_name, '') ILIKE $%d OR COALESCE(a.phone, '') ILIKE $%d)",
			n, n, n,
		))
	}
	return strings.Join(where, " AND ")
}

func (r *Repo) ListShareGrowth(ctx context.Context, f dom.Filter) ([]dom.ShareGrowthItem, int64, error) {
	args := []any{}
	whereSQL := shareGrowthWhere(f, &args)

	var total int64
	countQ := `SELECT count(*)
		FROM download_channels c
		LEFT JOIN accounts a ON a.id = c.owner_account_id
		WHERE ` + whereSQL
	if err := r.pool.QueryRow(ctx, countQ, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("downloadchannel.ListShareGrowth count: %w", err)
	}

	queryArgs := append([]any{}, args...)
	queryArgs = append(queryArgs, f.RangeStart, f.RangeEnd, f.Limit, f.Offset)
	startIdx := len(queryArgs) - 3
	endIdx := len(queryArgs) - 2
	limitIdx := len(queryArgs) - 1
	offsetIdx := len(queryArgs)
	q := fmt.Sprintf(`
		SELECT COALESCE(a.uuid::text, ''), COALESCE(a.display_name, ''), COALESCE(a.phone, ''),
		       c.code, c.status,
		       COALESCE(ev.visit_count, 0), COALESCE(ev.download_count, 0),
		       ev.first_event_at, ev.last_event_at, c.created_at
		  FROM download_channels c
		  LEFT JOIN accounts a ON a.id = c.owner_account_id
		  LEFT JOIN LATERAL (
		        SELECT count(*) FILTER (WHERE e.event_kind = 'visit') AS visit_count,
		               count(*) FILTER (WHERE e.event_kind = 'download_click') AS download_count,
		               min(e.occurred_at) AS first_event_at,
		               max(e.occurred_at) AS last_event_at
		          FROM download_channel_events e
		         WHERE e.channel_id = c.id
		           AND ($%d::timestamptz IS NULL OR e.occurred_at >= $%d)
		           AND ($%d::timestamptz IS NULL OR e.occurred_at <= $%d)
		       ) ev ON true
		 WHERE %s
		 ORDER BY COALESCE(ev.visit_count, 0) DESC, ev.last_event_at DESC NULLS LAST, c.created_at DESC
		 LIMIT $%d OFFSET $%d`,
		startIdx, startIdx, endIdx, endIdx, whereSQL, limitIdx, offsetIdx)

	rows, err := r.pool.Query(ctx, q, queryArgs...)
	if err != nil {
		return nil, 0, fmt.Errorf("downloadchannel.ListShareGrowth query: %w", err)
	}
	defer rows.Close()
	items := make([]dom.ShareGrowthItem, 0)
	for rows.Next() {
		var item dom.ShareGrowthItem
		var phone string
		if err := rows.Scan(
			&item.OwnerAccountUUID, &item.OwnerDisplayName, &phone,
			&item.InviteCode, &item.Status, &item.VisitCount, &item.DownloadCount,
			&item.FirstEventAt, &item.LastEventAt, &item.CreatedAt,
		); err != nil {
			return nil, 0, fmt.Errorf("downloadchannel.ListShareGrowth scan: %w", err)
		}
		item.InviteCode = strings.ToUpper(item.InviteCode)
		item.OwnerPhoneMasked = maskPhone(phone)
		items = append(items, item)
	}
	return items, total, rows.Err()
}

func (r *Repo) ShareGrowthStats(ctx context.Context, f dom.Filter) (*dom.ShareGrowthStats, error) {
	args := []any{}
	whereSQL := shareGrowthWhere(f, &args)
	args = append(args, f.RangeStart, f.RangeEnd)
	startIdx := len(args) - 1
	endIdx := len(args)

	stats := &dom.ShareGrowthStats{
		Trend:     make([]dom.DailyPoint, 0),
		Platforms: make([]dom.PlatformPoint, 0),
	}
	overviewQ := fmt.Sprintf(`
		SELECT count(*),
		       count(*) FILTER (WHERE COALESCE(ev.visit_count, 0) > 0),
		       COALESCE(sum(ev.visit_count), 0),
		       COALESCE(sum(ev.download_count), 0)
		  FROM download_channels c
		  LEFT JOIN accounts a ON a.id = c.owner_account_id
		  LEFT JOIN LATERAL (
		        SELECT count(*) FILTER (WHERE e.event_kind = 'visit') AS visit_count,
		               count(*) FILTER (WHERE e.event_kind = 'download_click') AS download_count
		          FROM download_channel_events e
		         WHERE e.channel_id = c.id
		           AND ($%d::timestamptz IS NULL OR e.occurred_at >= $%d)
		           AND ($%d::timestamptz IS NULL OR e.occurred_at <= $%d)
		       ) ev ON true
		 WHERE %s`, startIdx, startIdx, endIdx, endIdx, whereSQL)
	if err := r.pool.QueryRow(ctx, overviewQ, args...).Scan(
		&stats.TotalCodes, &stats.ActiveSharers, &stats.TotalVisits, &stats.TotalDownloads,
	); err != nil {
		return nil, fmt.Errorf("downloadchannel.ShareGrowthStats overview: %w", err)
	}

	trendQ := fmt.Sprintf(`
		SELECT date_trunc('day', e.occurred_at)::date::text,
		       count(*) FILTER (WHERE e.event_kind = 'visit'),
		       count(*) FILTER (WHERE e.event_kind = 'download_click')
		  FROM download_channel_events e
		  JOIN download_channels c ON c.id = e.channel_id
		  LEFT JOIN accounts a ON a.id = c.owner_account_id
		 WHERE %s
		   AND ($%d::timestamptz IS NULL OR e.occurred_at >= $%d)
		   AND ($%d::timestamptz IS NULL OR e.occurred_at <= $%d)
		 GROUP BY 1
		 ORDER BY 1`, whereSQL, startIdx, startIdx, endIdx, endIdx)
	rows, err := r.pool.Query(ctx, trendQ, args...)
	if err != nil {
		return nil, fmt.Errorf("downloadchannel.ShareGrowthStats trend: %w", err)
	}
	for rows.Next() {
		var point dom.DailyPoint
		if err := rows.Scan(&point.Date, &point.VisitCount, &point.DownloadCount); err != nil {
			rows.Close()
			return nil, fmt.Errorf("downloadchannel.ShareGrowthStats trend scan: %w", err)
		}
		stats.Trend = append(stats.Trend, point)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, fmt.Errorf("downloadchannel.ShareGrowthStats trend rows: %w", err)
	}
	rows.Close()

	platformQ := fmt.Sprintf(`
		SELECT COALESCE(NULLIF(e.platform, ''), 'unknown'), count(*)
		  FROM download_channel_events e
		  JOIN download_channels c ON c.id = e.channel_id
		  LEFT JOIN accounts a ON a.id = c.owner_account_id
		 WHERE %s
		   AND e.event_kind = 'download_click'
		   AND ($%d::timestamptz IS NULL OR e.occurred_at >= $%d)
		   AND ($%d::timestamptz IS NULL OR e.occurred_at <= $%d)
		 GROUP BY 1
		 ORDER BY 2 DESC, 1`, whereSQL, startIdx, startIdx, endIdx, endIdx)
	rows, err = r.pool.Query(ctx, platformQ, args...)
	if err != nil {
		return nil, fmt.Errorf("downloadchannel.ShareGrowthStats platforms: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var point dom.PlatformPoint
		if err := rows.Scan(&point.Platform, &point.DownloadCount); err != nil {
			return nil, fmt.Errorf("downloadchannel.ShareGrowthStats platforms scan: %w", err)
		}
		stats.Platforms = append(stats.Platforms, point)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("downloadchannel.ShareGrowthStats platforms rows: %w", err)
	}
	return stats, nil
}

func (r *Repo) Stats(ctx context.Context, f dom.Filter) (*dom.Stats, error) {
	where := []string{"c.deleted_at IS NULL"}
	args := []any{}
	add := func(cond string, val any) {
		args = append(args, val)
		where = append(where, fmt.Sprintf(cond, len(args)))
	}
	kindCond(f, &args, &where)
	if f.Status != "" {
		add("c.status = $%d", f.Status)
	}
	if f.Keyword != "" {
		args = append(args, "%"+f.Keyword+"%")
		n := len(args)
		where = append(where, fmt.Sprintf("(c.name ILIKE $%d OR c.code ILIKE $%d)", n, n))
	}
	args = append(args, f.RangeStart, f.RangeEnd)
	startIdx := len(args) - 1
	endIdx := len(args)
	whereSQL := strings.Join(where, " AND ")

	q := fmt.Sprintf(`
		SELECT e.day::date::text, e.visit_count, e.download_count
		  FROM (
		        SELECT date_trunc('day', ev.occurred_at) AS day,
		               count(*) FILTER (WHERE ev.event_kind = 'visit') AS visit_count,
		               count(*) FILTER (WHERE ev.event_kind = 'download_click') AS download_count
		          FROM download_channel_events ev
		          JOIN download_channels c ON c.id = ev.channel_id
		         WHERE %s
		           AND ($%d::timestamptz IS NULL OR ev.occurred_at >= $%d)
		           AND ($%d::timestamptz IS NULL OR ev.occurred_at <= $%d)
		         GROUP BY 1
		       ) e
		 ORDER BY e.day`,
		whereSQL, startIdx, startIdx, endIdx, endIdx)

	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("downloadchannel.Stats query: %w", err)
	}
	defer rows.Close()
	stats := &dom.Stats{Trend: make([]dom.DailyPoint, 0)}
	for rows.Next() {
		var point dom.DailyPoint
		if err := rows.Scan(&point.Date, &point.VisitCount, &point.DownloadCount); err != nil {
			return nil, fmt.Errorf("downloadchannel.Stats scan: %w", err)
		}
		stats.TotalVisits += point.VisitCount
		stats.TotalDownloads += point.DownloadCount
		stats.Trend = append(stats.Trend, point)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("downloadchannel.Stats rows: %w", err)
	}

	platformQ := fmt.Sprintf(`
		SELECT COALESCE(NULLIF(e.platform, ''), 'unknown'), count(*)
		  FROM download_channel_events e
		  JOIN download_channels c ON c.id = e.channel_id
		 WHERE %s
		   AND e.event_kind = 'download_click'
		   AND ($%d::timestamptz IS NULL OR e.occurred_at >= $%d)
		   AND ($%d::timestamptz IS NULL OR e.occurred_at <= $%d)
		 GROUP BY 1
		 ORDER BY 2 DESC, 1`, whereSQL, startIdx, startIdx, endIdx, endIdx)
	stats.Platforms = make([]dom.PlatformPoint, 0)
	platformRows, err := r.pool.Query(ctx, platformQ, args...)
	if err != nil {
		return nil, fmt.Errorf("downloadchannel.Stats platforms: %w", err)
	}
	defer platformRows.Close()
	for platformRows.Next() {
		var point dom.PlatformPoint
		if err := platformRows.Scan(&point.Platform, &point.DownloadCount); err != nil {
			return nil, fmt.Errorf("downloadchannel.Stats platforms scan: %w", err)
		}
		stats.Platforms = append(stats.Platforms, point)
	}
	if err := platformRows.Err(); err != nil {
		return nil, fmt.Errorf("downloadchannel.Stats platforms rows: %w", err)
	}
	return stats, nil
}

func (r *Repo) GetByUUID(ctx context.Context, uuid string) (*dom.Channel, error) {
	q := `SELECT ` + selectColumns() + ` FROM download_channels WHERE uuid = $1 AND deleted_at IS NULL`
	item, err := scanChannel(r.pool.QueryRow(ctx, q, uuid))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound.Withf("download channel not found")
	}
	if err != nil {
		return nil, fmt.Errorf("downloadchannel.GetByUUID: %w", err)
	}
	return item, nil
}

func (r *Repo) Create(ctx context.Context, in dom.UpsertInput) (*dom.Channel, error) {
	const q = `
		INSERT INTO download_channels (code, name, description, status, created_by, updated_by)
		VALUES ($1,$2,$3,$4,$5,$5)
		RETURNING `
	item, err := scanChannel(r.pool.QueryRow(ctx, q+selectColumns(),
		in.Code, in.Name, in.Description, in.Status, nullActor(in.ActorID),
	))
	if isUniqueViolation(err) {
		return nil, dom.ErrDuplicateCode
	}
	if err != nil {
		return nil, fmt.Errorf("downloadchannel.Create: %w", err)
	}
	return item, nil
}

// GetUserShareByAccount F29: 取账号个人分享码渠道; 无则 ErrChannelNotFound。
func (r *Repo) GetUserShareByAccount(ctx context.Context, accountID int64) (*dom.Channel, error) {
	q := `SELECT ` + selectColumns() + ` FROM download_channels
	       WHERE kind = 'user_share' AND owner_account_id = $1 AND deleted_at IS NULL`
	item, err := scanChannel(r.pool.QueryRow(ctx, q, accountID))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, dom.ErrChannelNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("downloadchannel.GetUserShareByAccount: %w", err)
	}
	return item, nil
}

// CreateUserShare F29: 建账号个人分享码渠道。
// code 撞唯一索引 → ErrDuplicateCode（调用方换码重试）;
// 账号已有码（并发 find-or-create）→ ErrOwnerShareExists（调用方重读）。
func (r *Repo) CreateUserShare(ctx context.Context, accountID int64, code, name, description string) (*dom.Channel, error) {
	const q = `
		INSERT INTO download_channels (code, name, description, status, kind, owner_account_id, created_by, updated_by)
		VALUES ($1,$2,$3,'active','user_share',$4,$4,$4)
		RETURNING `
	item, err := scanChannel(r.pool.QueryRow(ctx, q+selectColumns(), code, name, description, accountID))
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		if pgErr.ConstraintName == "uq_download_channels_owner_share" {
			return nil, dom.ErrOwnerShareExists
		}
		return nil, dom.ErrDuplicateCode
	}
	if err != nil {
		return nil, fmt.Errorf("downloadchannel.CreateUserShare: %w", err)
	}
	return item, nil
}

func (r *Repo) Update(ctx context.Context, uuid string, in dom.UpsertInput) (*dom.Channel, error) {
	const q = `
		UPDATE download_channels
		   SET name = $2,
		       description = $3,
		       status = $4,
		       updated_by = $5,
		       updated_at = now()
		 WHERE uuid = $1
		   AND deleted_at IS NULL
		RETURNING `
	item, err := scanChannel(r.pool.QueryRow(ctx, q+selectColumns(),
		uuid, in.Name, in.Description, in.Status, nullActor(in.ActorID),
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound.Withf("download channel not found")
	}
	if err != nil {
		return nil, fmt.Errorf("downloadchannel.Update: %w", err)
	}
	return item, nil
}

func (r *Repo) Delete(ctx context.Context, uuid string, actorID int64) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE download_channels
		   SET deleted_at = now(), updated_by = $2, updated_at = now()
		 WHERE uuid = $1
		   AND deleted_at IS NULL`, uuid, nullActor(actorID))
	if err != nil {
		return fmt.Errorf("downloadchannel.Delete: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return apperr.ErrNotFound.Withf("download channel not found")
	}
	return nil
}

func (r *Repo) RecordEvent(ctx context.Context, in dom.EventInput) error {
	_, err := r.pool.Exec(ctx, `
		INSERT INTO download_channel_events (channel_id, event_kind, platform, page_url, ip_hash, user_agent)
		SELECT id, $2, $3, $4, $5, $6
		  FROM download_channels
		 WHERE code = $1
		   AND status = 'active'
		   AND deleted_at IS NULL`,
		in.ChannelCode, in.EventKind, in.Platform, in.PageURL, in.IPHash, in.UserAgent,
	)
	if err != nil {
		return fmt.Errorf("downloadchannel.RecordEvent: %w", err)
	}
	return nil
}

func selectColumns() string {
	return `id, uuid::text, code, name, COALESCE(description,''), status, kind, owner_account_id, created_by, updated_by, created_at, updated_at`
}

func scanChannel(row pgx.Row) (*dom.Channel, error) {
	var item dom.Channel
	var owner, createdBy, updatedBy pgtype.Int8
	if err := row.Scan(
		&item.ID, &item.UUID, &item.Code, &item.Name, &item.Description, &item.Status,
		&item.Kind, &owner,
		&createdBy, &updatedBy, &item.CreatedAt, &item.UpdatedAt,
	); err != nil {
		return nil, err
	}
	if owner.Valid {
		item.OwnerAccountID = ptrInt64(owner.Int64)
	}
	if createdBy.Valid {
		item.CreatedBy = ptrInt64(createdBy.Int64)
	}
	if updatedBy.Valid {
		item.UpdatedBy = ptrInt64(updatedBy.Int64)
	}
	return &item, nil
}

func scanChannelWithStats(row pgx.Row) (*dom.ChannelWithStats, error) {
	var item dom.ChannelWithStats
	var owner, createdBy, updatedBy pgtype.Int8
	if err := row.Scan(
		&item.ID, &item.UUID, &item.Code, &item.Name, &item.Description, &item.Status,
		&item.Kind, &owner,
		&createdBy, &updatedBy, &item.CreatedAt, &item.UpdatedAt,
		&item.VisitCount, &item.DownloadCount,
	); err != nil {
		return nil, err
	}
	if owner.Valid {
		item.OwnerAccountID = ptrInt64(owner.Int64)
	}
	if createdBy.Valid {
		item.CreatedBy = ptrInt64(createdBy.Int64)
	}
	if updatedBy.Valid {
		item.UpdatedBy = ptrInt64(updatedBy.Int64)
	}
	return &item, nil
}

func nullActor(id int64) any {
	if id <= 0 {
		return nil
	}
	return id
}

func ptrInt64(v int64) *int64 { return &v }

func maskPhone(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	runes := []rune(v)
	if len(runes) < 7 {
		return strings.Repeat("*", len(runes))
	}
	return string(runes[:3]) + "****" + string(runes[len(runes)-4:])
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

var _ dom.Repository = (*Repo)(nil)
