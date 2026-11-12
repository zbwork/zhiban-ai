package imconnection

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/imconnection"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

func (r *Repo) UpsertClientMetadata(ctx context.Context, metadata dom.ClientMetadata) error {
	_, err := r.pool.Exec(ctx, `
INSERT INTO im_connection_client_metadata
 (tenant_id, account_id, device_key, client_version, platform, os_version, reported_at)
VALUES ($1,$2,$3,$4,$5,$6,$7)
ON CONFLICT (tenant_id, account_id, device_key) DO UPDATE SET
 client_version=CASE WHEN excluded.client_version<>'' THEN excluded.client_version ELSE im_connection_client_metadata.client_version END,
 platform=CASE WHEN excluded.platform<>'' THEN excluded.platform ELSE im_connection_client_metadata.platform END,
 os_version=CASE WHEN excluded.os_version<>'' THEN excluded.os_version ELSE im_connection_client_metadata.os_version END,
 reported_at=excluded.reported_at, updated_at=now()`,
		metadata.TenantID, metadata.AccountID, metadata.DeviceKey, metadata.ClientVersion,
		metadata.Platform, metadata.OSVersion, metadata.ReportedAt)
	return err
}

func (r *Repo) ApplySnapshot(ctx context.Context, observations []dom.Observation, observedAt, staleBefore time.Time) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	accountIDs, err := resolveAccountIDs(ctx, tx, observations)
	if err != nil {
		return err
	}
	for _, o := range observations {
		var stateUUID uuid.UUID
		var previousCID int64
		var previousStatus string
		err = tx.QueryRow(ctx, `
SELECT uuid, connection_id, status
  FROM im_connection_states
 WHERE uid=$1 AND device_key=$2
 FOR UPDATE`, o.UID, o.DeviceKey).Scan(&stateUUID, &previousCID, &previousStatus)
		isNew := err == pgx.ErrNoRows
		if err != nil && !isNew {
			return err
		}
		accountID := accountIDs[accountKey(o.TenantID, o.SubjectUUID)]
		if isNew {
			err = tx.QueryRow(ctx, `
INSERT INTO im_connection_states
 (tenant_id, account_id, uid, subject_kind, subject_uuid, device_key, device_id_masked,
	  device_id_available, device_flag, device_level, connection_id, protocol_version, status,
  connected_at, last_activity_at, first_seen_at, last_seen_at, last_event_type)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,'online',$13,$14,$15,$15,'connected')
RETURNING uuid`, o.TenantID, accountID, o.UID, o.SubjectKind, o.SubjectUUID, o.DeviceKey,
				o.DeviceIDMasked, o.DeviceIDAvailable, o.DeviceFlag, o.DeviceLevel, o.ConnectionID,
				o.ProtocolVersion, o.ConnectedAt, o.LastActivityAt, observedAt).Scan(&stateUUID)
			if err != nil {
				return err
			}
			if err := insertEvent(ctx, tx, stateUUID, accountID, o, "connected", nil, "observed", observedAt); err != nil {
				return err
			}
			continue
		}

		eventType := ""
		if shouldRecordReconnect(previousCID, o.ConnectionID, previousStatus) {
			eventType = "reconnected"
		}
		lastEventExpr := "last_event_type"
		if eventType != "" {
			lastEventExpr = "'reconnected'"
		}
		_, err = tx.Exec(ctx, fmt.Sprintf(`
UPDATE im_connection_states SET
 tenant_id=$1, account_id=$2, subject_kind=$3, subject_uuid=$4, device_id_masked=$5,
	 device_id_available=$6, device_flag=$7, device_level=$8, connection_id=$9, protocol_version=$10,
 status='online', connected_at=$11, last_activity_at=$12, last_seen_at=$13,
 last_event_type=%s, updated_at=now()
WHERE uuid=$14`, lastEventExpr), o.TenantID, accountID, o.SubjectKind, o.SubjectUUID,
			o.DeviceIDMasked, o.DeviceIDAvailable, o.DeviceFlag, o.DeviceLevel, o.ConnectionID,
			o.ProtocolVersion, o.ConnectedAt, o.LastActivityAt, observedAt, stateUUID)
		if err != nil {
			return err
		}
		if eventType != "" {
			previous := previousCID
			if err := insertEvent(ctx, tx, stateUUID, accountID, o, eventType, &previous, reconnectReason(previousCID, o.ConnectionID, previousStatus), observedAt); err != nil {
				return err
			}
		}
	}

	// 只有完整快照成功后才执行离线判定。连续两个 30s 周期未观察到才离线。
	_, err = tx.Exec(ctx, `
WITH missing AS (
  UPDATE im_connection_states
     SET status='offline', last_event_type='disconnected', updated_at=now()
   WHERE status='online' AND last_seen_at <= $1
 RETURNING uuid, tenant_id, account_id, uid, subject_kind, subject_uuid, device_key,
	           device_id_masked, device_flag, device_level, connection_id, protocol_version
)
INSERT INTO im_connection_events
 (state_uuid, tenant_id, account_id, uid, subject_kind, subject_uuid, device_key,
  device_id_masked, device_flag, device_level, connection_id, event_type, reason,
	  protocol_version, occurred_at)
SELECT uuid, tenant_id, account_id, uid, subject_kind, subject_uuid, device_key,
       device_id_masked, device_flag, device_level, connection_id, 'disconnected',
	       'missing_two_snapshots', protocol_version, $2
  FROM missing`, staleBefore, observedAt)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `
UPDATE im_connection_collector_status
   SET last_attempt_at=$1, last_success_at=$1, last_error='', connection_total=$2, updated_at=now()
 WHERE singleton`, observedAt, len(observations))
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// 旧采集器可能因 /connz 字段不兼容把 connection_id 写成 0。首次补齐真实 ID
// 只是数据修复，不是重连；只有两个有效 ID 发生替换或离线状态恢复才记重连。
func shouldRecordReconnect(previousCID, currentCID int64, previousStatus string) bool {
	return previousStatus == "offline" || (previousCID > 0 && currentCID > 0 && previousCID != currentCID)
}

func reconnectReason(previousCID, currentCID int64, previousStatus string) string {
	if previousStatus == "offline" {
		return "returned_after_missing_snapshots"
	}
	if previousCID > 0 && currentCID > 0 && previousCID != currentCID {
		return "connection_replaced"
	}
	return ""
}

func resolveAccountIDs(ctx context.Context, tx pgx.Tx, observations []dom.Observation) (map[string]*int64, error) {
	tenants := make([]int64, 0, len(observations))
	uuids := make([]string, 0, len(observations))
	seenTenant, seenUUID := map[int64]bool{}, map[string]bool{}
	for _, o := range observations {
		if o.SubjectKind != "human" || o.SubjectUUID == "" {
			continue
		}
		if !seenTenant[o.TenantID] {
			tenants = append(tenants, o.TenantID)
			seenTenant[o.TenantID] = true
		}
		if !seenUUID[o.SubjectUUID] {
			uuids = append(uuids, o.SubjectUUID)
			seenUUID[o.SubjectUUID] = true
		}
	}
	out := map[string]*int64{}
	if len(tenants) == 0 || len(uuids) == 0 {
		return out, nil
	}
	rows, err := tx.Query(ctx, `
SELECT tm.tenant_id, a.uuid::text, a.id
  FROM tenant_memberships tm
  JOIN accounts a ON a.id=tm.account_id
 WHERE tm.tenant_id=ANY($1) AND a.uuid::text=ANY($2) AND tm.status='active'`, tenants, uuids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var tenantID, accountID int64
		var accountUUID string
		if err := rows.Scan(&tenantID, &accountUUID, &accountID); err != nil {
			return nil, err
		}
		id := accountID
		out[accountKey(tenantID, accountUUID)] = &id
	}
	return out, rows.Err()
}

func accountKey(tenantID int64, accountUUID string) string {
	return fmt.Sprintf("%d:%s", tenantID, accountUUID)
}

func insertEvent(ctx context.Context, tx pgx.Tx, stateUUID uuid.UUID, accountID *int64, o dom.Observation, eventType string, previousCID *int64, reason string, at time.Time) error {
	_, err := tx.Exec(ctx, `
INSERT INTO im_connection_events
 (state_uuid, tenant_id, account_id, uid, subject_kind, subject_uuid, device_key,
  device_id_masked, device_flag, device_level, connection_id, previous_connection_id,
	  event_type, reason, protocol_version, occurred_at)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)`,
		stateUUID, o.TenantID, accountID, o.UID, o.SubjectKind, o.SubjectUUID, o.DeviceKey,
		o.DeviceIDMasked, o.DeviceFlag, o.DeviceLevel, o.ConnectionID, previousCID, eventType,
		reason, o.ProtocolVersion, at)
	return err
}

func (r *Repo) MarkCollectorFailure(ctx context.Context, attemptedAt time.Time, message string) error {
	message = strings.TrimSpace(message)
	if len(message) > 500 {
		message = message[:500]
	}
	_, err := r.pool.Exec(ctx, `UPDATE im_connection_collector_status
SET last_attempt_at=$1, last_error=$2, updated_at=now() WHERE singleton`, attemptedAt, message)
	return err
}

func (r *Repo) CleanupEvents(ctx context.Context, before time.Time) error {
	_, err := r.pool.Exec(ctx, `DELETE FROM im_connection_events WHERE occurred_at < $1`, before)
	return err
}

func (r *Repo) Overview(ctx context.Context) (dom.Overview, error) {
	var out dom.Overview
	err := r.pool.QueryRow(ctx, `
WITH reconnects AS (
 SELECT state_uuid,
        count(*) FILTER (WHERE occurred_at > now()-interval '5 minutes')::int r5,
        count(*) FILTER (WHERE occurred_at > now()-interval '1 hour')::int r1
   FROM im_connection_events
  WHERE event_type='reconnected' AND occurred_at > now()-interval '1 hour'
  GROUP BY state_uuid
)
SELECT count(*) FILTER (WHERE s.status='online')::int,
       count(DISTINCT s.uid) FILTER (WHERE s.status='online')::int,
       count(DISTINCT s.tenant_id) FILTER (WHERE s.status='online')::int,
		count(*) FILTER (WHERE s.device_id_available AND (COALESCE(r.r5,0)>=5 OR COALESCE(r.r1,0)>=10))::int,
	       COALESCE(sum(r.r5),0)::int, COALESCE(sum(r.r1),0)::int,
	       (SELECT count(*)::int FROM im_connection_events e
	         WHERE e.event_type='reconnected' AND e.occurred_at>now()-interval '1 hour'
	           AND (e.reason='returned_after_missing_snapshots'
	                OR (e.reason='connection_replaced' AND e.previous_connection_id=e.connection_id))),
	       (SELECT count(*)::int FROM im_connection_events e
	         WHERE e.event_type='reconnected' AND e.occurred_at>now()-interval '1 hour'
	           AND e.reason='connection_replaced' AND e.previous_connection_id>0
	           AND e.connection_id>0 AND e.previous_connection_id<>e.connection_id)
  FROM im_connection_states s LEFT JOIN reconnects r ON r.state_uuid=s.uuid`).Scan(
		&out.OnlineConnections, &out.OnlineUsers, &out.OnlineTenants, &out.AnomalousDevices,
		&out.Reconnects5m, &out.Reconnects1h, &out.Recoveries1h, &out.Replacements1h)
	if err != nil {
		return out, err
	}
	err = r.pool.QueryRow(ctx, `SELECT last_attempt_at,last_success_at,last_error,connection_total
FROM im_connection_collector_status WHERE singleton`).Scan(&out.Collector.LastAttemptAt,
		&out.Collector.LastSuccessAt, &out.Collector.LastError, &out.Collector.ConnectionTotal)
	return out, err
}

const stateSelect = `
SELECT s.uuid,s.tenant_id,COALESCE(NULLIF(t.display_name,''),t.name,''),s.account_id,
       COALESCE(a.uuid::text,''),COALESCE(NULLIF(tm.nickname,''),NULLIF(a.display_name,''),a.username,a.phone,a.email,''),
       s.uid,s.subject_kind,s.subject_uuid,s.device_id_masked,s.device_id_available,s.device_flag,
	       s.device_level,s.connection_id,s.protocol_version,
	       COALESCE(cm.client_version,''),COALESCE(cm.platform,''),COALESCE(cm.os_version,''),
	       s.status,s.connected_at,s.last_activity_at,
       s.first_seen_at,s.last_seen_at,s.last_event_type,
       COALESCE(rc.r5,0)::int,COALESCE(rc.r1,0)::int,
		(s.device_id_available AND (COALESCE(rc.r5,0)>=5 OR COALESCE(rc.r1,0)>=10))
  FROM im_connection_states s
  LEFT JOIN tenants t ON t.id=s.tenant_id
  LEFT JOIN accounts a ON a.id=s.account_id
  LEFT JOIN tenant_memberships tm ON tm.tenant_id=s.tenant_id AND tm.account_id=s.account_id
  LEFT JOIN im_connection_client_metadata cm
    ON cm.tenant_id=s.tenant_id AND cm.account_id=s.account_id AND cm.device_key=s.device_key
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE occurred_at>now()-interval '5 minutes') r5,
           count(*) FILTER (WHERE occurred_at>now()-interval '1 hour') r1
      FROM im_connection_events e
     WHERE e.state_uuid=s.uuid AND e.event_type='reconnected' AND e.occurred_at>now()-interval '1 hour'
  ) rc ON true`

func (r *Repo) ListStates(ctx context.Context, f dom.StateFilter) ([]dom.State, int, error) {
	where, args := []string{"1=1"}, []any{}
	add := func(expr string, value any) {
		args = append(args, value)
		where = append(where, fmt.Sprintf(expr, len(args)))
	}
	if f.Query != "" {
		args = append(args, "%"+f.Query+"%")
		p := fmt.Sprintf("$%d", len(args))
		where = append(where, "(s.uid ILIKE "+p+" OR COALESCE(a.display_name,'') ILIKE "+p+" OR COALESCE(tm.nickname,'') ILIKE "+p+" OR COALESCE(t.name,'') ILIKE "+p+")")
	}
	if f.TenantID > 0 {
		add("s.tenant_id=$%d", f.TenantID)
	}
	if f.Status == "online" || f.Status == "offline" {
		add("s.status=$%d", f.Status)
	}
	if f.DeviceFlag != nil {
		add("s.device_flag=$%d", *f.DeviceFlag)
	}
	if f.Anomalous {
		where = append(where, "(s.device_id_available AND (COALESCE(rc.r5,0)>=5 OR COALESCE(rc.r1,0)>=10))")
	}
	clause := strings.Join(where, " AND ")
	var total int
	args = append(args, f.Limit, f.Offset)
	query := stateSelect + ` WHERE ` + clause + fmt.Sprintf(` ORDER BY (s.device_id_available AND (COALESCE(rc.r5,0)>=5 OR COALESCE(rc.r1,0)>=10)) DESC,s.last_seen_at DESC LIMIT $%d OFFSET $%d`, len(args)-1, len(args))
	rows, err := r.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	items := []dom.State{}
	for rows.Next() {
		var item dom.State
		if err := scanState(rows, &item); err != nil {
			return nil, 0, err
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}
	// A separate count with the exact joins avoids returning a page-length total.
	countArgs := args[:len(args)-2]
	countQuery := `SELECT count(*) FROM (` + stateSelect + ` WHERE ` + clause + `) counted`
	if err := r.pool.QueryRow(ctx, countQuery, countArgs...).Scan(&total); err != nil {
		return nil, 0, err
	}
	return items, total, nil
}

type scanner interface{ Scan(...any) error }

func scanState(row scanner, s *dom.State) error {
	return row.Scan(&s.UUID, &s.TenantID, &s.TenantName, &s.AccountID, &s.AccountUUID, &s.AccountName,
		&s.UID, &s.SubjectKind, &s.SubjectUUID, &s.DeviceIDMasked, &s.DeviceIDAvailable, &s.DeviceFlag,
		&s.DeviceLevel, &s.ConnectionID, &s.ProtocolVersion, &s.ClientVersion, &s.ClientPlatform,
		&s.ClientOSVersion, &s.Status, &s.ConnectedAt, &s.LastActivityAt,
		&s.FirstSeenAt, &s.LastSeenAt, &s.LastEventType, &s.Reconnects5m, &s.Reconnects1h, &s.Anomalous)
}

func (r *Repo) GetState(ctx context.Context, id uuid.UUID) (dom.State, error) {
	var out dom.State
	err := scanState(r.pool.QueryRow(ctx, stateSelect+` WHERE s.uuid=$1`, id), &out)
	return out, err
}

func (r *Repo) ListEvents(ctx context.Context, f dom.EventFilter) ([]dom.Event, int, error) {
	where, args := []string{"1=1"}, []any{}
	if f.StateUUID != uuid.Nil {
		args = append(args, f.StateUUID)
		where = append(where, fmt.Sprintf("e.state_uuid=$%d", len(args)))
	}
	if f.TenantID > 0 {
		args = append(args, f.TenantID)
		where = append(where, fmt.Sprintf("e.tenant_id=$%d", len(args)))
	}
	if f.EventType != "" {
		args = append(args, f.EventType)
		where = append(where, fmt.Sprintf("e.event_type=$%d", len(args)))
	}
	clause := strings.Join(where, " AND ")
	var total int
	if err := r.pool.QueryRow(ctx, `SELECT count(*) FROM im_connection_events e WHERE `+clause, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	args = append(args, f.Limit, f.Offset)
	rows, err := r.pool.Query(ctx, `SELECT e.uuid,e.state_uuid,e.tenant_id,COALESCE(NULLIF(t.display_name,''),t.name,''),
COALESCE(a.uuid::text,''),COALESCE(NULLIF(tm.nickname,''),NULLIF(a.display_name,''),a.username,a.phone,a.email,''),
e.uid,e.device_id_masked,e.device_flag,e.connection_id,e.previous_connection_id,e.event_type,e.reason,
CASE WHEN e.connection_id>0 THEN 'verified' ELSE 'legacy_unreliable' END,e.protocol_version,e.occurred_at
FROM im_connection_events e LEFT JOIN tenants t ON t.id=e.tenant_id LEFT JOIN accounts a ON a.id=e.account_id
LEFT JOIN tenant_memberships tm ON tm.tenant_id=e.tenant_id AND tm.account_id=e.account_id
WHERE `+clause+fmt.Sprintf(` ORDER BY e.occurred_at DESC LIMIT $%d OFFSET $%d`, len(args)-1, len(args)), args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	items := []dom.Event{}
	for rows.Next() {
		var e dom.Event
		if err := rows.Scan(&e.UUID, &e.StateUUID, &e.TenantID, &e.TenantName, &e.AccountUUID, &e.AccountName, &e.UID, &e.DeviceIDMasked, &e.DeviceFlag, &e.ConnectionID, &e.PreviousConnectionID, &e.EventType, &e.Reason, &e.DataQuality, &e.ProtocolVersion, &e.OccurredAt); err != nil {
			return nil, 0, err
		}
		e.Reason = normalizeEventReason(e.EventType, e.Reason, e.PreviousConnectionID, e.ConnectionID)
		items = append(items, e)
	}
	return items, total, rows.Err()
}

// 早期采集器把所有 reconnected 都写成 connection_replaced。当前后连接编号相同
// 时，唯一可能的触发条件是状态从 offline 恢复，API 只修正语义，不改写历史事件。
func normalizeEventReason(eventType, reason string, previousCID *int64, currentCID int64) string {
	if eventType == "reconnected" && reason == "connection_replaced" && previousCID != nil && *previousCID == currentCID {
		return "returned_after_missing_snapshots"
	}
	return reason
}

var _ dom.Store = (*Repo)(nil)
var _ dom.ClientMetadataStore = (*Repo)(nil)
