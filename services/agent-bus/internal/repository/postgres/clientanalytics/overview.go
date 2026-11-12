package clientanalytics

import (
	"context"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/clientanalytics"
)

func (r *Repo) Overview(ctx context.Context, days int, now time.Time, includeArchived bool) (*dom.Overview, error) {
	out := &dom.Overview{
		Trend:      []dom.DailyActivePoint{},
		Platforms:  []dom.ActiveDimension{},
		Versions:   []dom.ActiveDimension{},
		Tenants:    []dom.TenantActive{},
		ErrorTrend: []dom.DailyErrorPoint{},
		TopErrors:  []dom.ErrorGroup{},
	}
	if err := r.pool.QueryRow(ctx, `
		SELECT
			count(DISTINCT account_id) FILTER (WHERE occurred_at >= $1::timestamptz - interval '24 hours'),
			count(DISTINCT account_id) FILTER (WHERE occurred_at >= $1::timestamptz - interval '7 days'),
			count(DISTINCT account_id),
			count(DISTINCT tenant_id) FILTER (WHERE occurred_at >= $1::timestamptz - interval '24 hours')
		FROM client_analytics_events
		WHERE event_name = 'app_active'
		  AND occurred_at >= $1::timestamptz - interval '30 days'
		  AND occurred_at <= $1`, now).Scan(
		&out.DAU, &out.WAU, &out.MAU, &out.ActiveTenants24h,
	); err != nil {
		return nil, err
	}
	if err := r.pool.QueryRow(ctx, `
		SELECT count(*) FROM accounts
		WHERE deleted_at IS NULL AND created_at >= $1::timestamptz - interval '24 hours'`, now,
	).Scan(&out.NewAccounts24h); err != nil {
		return nil, err
	}

	location, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		return nil, err
	}
	localNow := now.In(location)
	start := time.Date(localNow.Year(), localNow.Month(), localNow.Day(), 0, 0, 0, 0, location).AddDate(0, 0, -(days - 1))
	end := start.AddDate(0, 0, days)

	trendRows, err := r.pool.Query(ctx, `
		WITH calendar AS (
			SELECT generate_series(
				($1::timestamptz AT TIME ZONE 'Asia/Shanghai')::date,
				(($2::timestamptz AT TIME ZONE 'Asia/Shanghai')::date - 1),
				interval '1 day'
			)::date AS day
		), daily AS (
			SELECT (occurred_at AT TIME ZONE 'Asia/Shanghai')::date AS day,
			       count(DISTINCT account_id) AS active_users
			FROM client_analytics_events
			WHERE event_name = 'app_active' AND occurred_at >= $1 AND occurred_at < $2 AND occurred_at <= $3
			GROUP BY 1
		)
		SELECT to_char(c.day, 'YYYY-MM-DD'), COALESCE(d.active_users, 0)
		FROM calendar c LEFT JOIN daily d USING (day)
		ORDER BY c.day`, start, end, now)
	if err != nil {
		return nil, err
	}
	for trendRows.Next() {
		var point dom.DailyActivePoint
		if err := trendRows.Scan(&point.Date, &point.ActiveUsers); err != nil {
			trendRows.Close()
			return nil, err
		}
		out.Trend = append(out.Trend, point)
	}
	trendRows.Close()
	if err := trendRows.Err(); err != nil {
		return nil, err
	}

	out.Platforms, err = r.activeDimensions(ctx, "platform", start, end, now, 10)
	if err != nil {
		return nil, err
	}
	out.Versions, err = r.activeDimensions(ctx, "version", start, end, now, 10)
	if err != nil {
		return nil, err
	}

	tenantRows, err := r.pool.Query(ctx, `
		SELECT e.tenant_id, COALESCE(t.name, '未知租户'), count(DISTINCT e.account_id), max(e.occurred_at)
		FROM client_analytics_events e
		LEFT JOIN tenants t ON t.id = e.tenant_id
		WHERE e.event_name = 'app_active' AND e.occurred_at >= $1 AND e.occurred_at < $2 AND e.occurred_at <= $3
		GROUP BY e.tenant_id, t.name
		ORDER BY count(DISTINCT e.account_id) DESC, max(e.occurred_at) DESC
		LIMIT 10`, start, end, now)
	if err != nil {
		return nil, err
	}
	for tenantRows.Next() {
		var item dom.TenantActive
		if err := tenantRows.Scan(&item.TenantID, &item.TenantName, &item.ActiveUsers, &item.LastActive); err != nil {
			tenantRows.Close()
			return nil, err
		}
		out.Tenants = append(out.Tenants, item)
	}
	tenantRows.Close()
	if err := tenantRows.Err(); err != nil {
		return nil, err
	}

	if err := r.loadErrorOverview(ctx, out, start, end, now, includeArchived); err != nil {
		return nil, err
	}
	return out, nil
}

func (r *Repo) loadErrorOverview(ctx context.Context, out *dom.Overview, start, end, now time.Time, includeArchived bool) error {
	if err := r.pool.QueryRow(ctx, `
		SELECT count(*), count(DISTINCT account_id), count(DISTINCT properties->>'fingerprint')
		FROM client_analytics_events
		WHERE event_name = 'app_error' AND occurred_at >= $1 AND occurred_at < $2 AND occurred_at <= $3`,
		start, end, now,
	).Scan(&out.ErrorCount, &out.ErrorUsers, &out.ErrorFingerprints); err != nil {
		return err
	}

	trendRows, err := r.pool.Query(ctx, `
		WITH calendar AS (
			SELECT generate_series(
				($1::timestamptz AT TIME ZONE 'Asia/Shanghai')::date,
				(($2::timestamptz AT TIME ZONE 'Asia/Shanghai')::date - 1),
				interval '1 day'
			)::date AS day
		), daily AS (
			SELECT (occurred_at AT TIME ZONE 'Asia/Shanghai')::date AS day,
			       count(*) AS error_count,
			       count(DISTINCT account_id) AS affected_users
			FROM client_analytics_events
			WHERE event_name = 'app_error' AND occurred_at >= $1 AND occurred_at < $2 AND occurred_at <= $3
			GROUP BY 1
		)
		SELECT to_char(c.day, 'YYYY-MM-DD'), COALESCE(d.error_count, 0), COALESCE(d.affected_users, 0)
		FROM calendar c LEFT JOIN daily d USING (day)
		ORDER BY c.day`, start, end, now)
	if err != nil {
		return err
	}
	for trendRows.Next() {
		var point dom.DailyErrorPoint
		if err := trendRows.Scan(&point.Date, &point.ErrorCount, &point.AffectedUsers); err != nil {
			trendRows.Close()
			return err
		}
		out.ErrorTrend = append(out.ErrorTrend, point)
	}
	trendRows.Close()
	if err := trendRows.Err(); err != nil {
		return err
	}

	rows, err := r.pool.Query(ctx, `
		SELECT COALESCE(properties->>'fingerprint', '') AS fingerprint,
		       COALESCE((array_agg(properties->>'error_type' ORDER BY occurred_at DESC))[1], '') AS error_type,
		       COALESCE((array_agg(properties->>'error_message' ORDER BY occurred_at DESC))[1], '') AS error_message,
		       COALESCE((array_agg((
		           SELECT string_agg(frame, E'\n' ORDER BY position)
		           FROM (
		               SELECT frame, position
		               FROM regexp_split_to_table(properties->>'stacktrace', E'\n') WITH ORDINALITY AS frames(frame, position)
		               WHERE btrim(frame) <> ''
		               ORDER BY position
		               LIMIT 2
		           ) AS first_frames
		       ) ORDER BY occurred_at DESC))[1], '') AS source_location,
		       count(*) AS occurrences,
		       count(DISTINCT account_id) AS affected_users,
		       string_agg(DISTINCT platform, ', ' ORDER BY platform) AS platforms,
		       string_agg(DISTINCT COALESCE(NULLIF(app_version, ''), '未知版本'), ', ' ORDER BY COALESCE(NULLIF(app_version, ''), '未知版本')) AS app_versions,
		       EXISTS(SELECT 1 FROM client_analytics_error_archive a WHERE a.fingerprint = (array_agg(properties->>'fingerprint'))[1]) AS archived,
		       max(occurred_at) AS last_seen_at
		FROM client_analytics_events
		WHERE event_name = 'app_error' AND occurred_at >= $1 AND occurred_at < $2 AND occurred_at <= $3
		  AND ($4 OR NOT EXISTS (SELECT 1 FROM client_analytics_error_archive a WHERE a.fingerprint = properties->>'fingerprint'))
		GROUP BY properties->>'fingerprint'
		ORDER BY occurrences DESC, last_seen_at DESC
		LIMIT 10`, start, end, now, includeArchived)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var item dom.ErrorGroup
		if err := rows.Scan(
			&item.Fingerprint, &item.ErrorType, &item.ErrorMessage, &item.SourceLocation,
			&item.Occurrences, &item.AffectedUsers, &item.Platforms,
			&item.AppVersions, &item.Archived, &item.LastSeenAt,
		); err != nil {
			return err
		}
		out.TopErrors = append(out.TopErrors, item)
	}
	return rows.Err()
}

func (r *Repo) activeDimensions(ctx context.Context, kind string, start, end, now time.Time, limit int) ([]dom.ActiveDimension, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT CASE $3
			WHEN 'platform' THEN platform
			WHEN 'version' THEN COALESCE(NULLIF(app_version, ''), '未知版本')
			ELSE '未知'
		END AS dimension, count(DISTINCT account_id)
		FROM client_analytics_events
		WHERE event_name = 'app_active' AND occurred_at >= $1 AND occurred_at < $2 AND occurred_at <= $4
		GROUP BY 1
		ORDER BY 2 DESC, 1
		LIMIT $5`, start, end, kind, now, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []dom.ActiveDimension{}
	for rows.Next() {
		var item dom.ActiveDimension
		if err := rows.Scan(&item.Key, &item.ActiveUsers); err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}
