package localruntime

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

var _ dom.Repository = (*Repo)(nil)

// Principal validity is DB-authoritative on every control-plane and proxy lookup.
const principalJoin = ` JOIN login_sessions s ON s.uuid=d.login_session_uuid
 JOIN accounts a ON a.id=d.account_id JOIN tenants t ON t.id=d.tenant_id
 JOIN tenant_memberships m ON m.account_id=d.account_id AND m.tenant_id=d.tenant_id `
const principalValid = ` d.revoked_at IS NULL AND s.account_id=d.account_id AND s.revoked_at IS NULL AND s.expires_at>now()
 AND s.act_tenant_id=d.tenant_id AND a.status='active' AND a.deleted_at IS NULL
 AND t.status='active' AND m.status='active' AND m.deleted_at IS NULL
 AND lower(trim(s.device_type)) IN ('desktop','macos','macosx','darwin','windows','linux') `
const scopeWhere = ` d.account_id=$1 AND d.tenant_id=$2 AND d.login_session_uuid=$3 `

type rowQuerier interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func device(ctx context.Context, db rowQuerier, scope dom.Scope, id string, lock bool) (*dom.Device, error) {
	query := `SELECT d.uuid,t.uuid,a.uuid,coalesce(d.installation_id::text,''),d.platform,d.generation,coalesce(d.seen_at,'epoch'::timestamptz),d.protocol_version,d.engines
 FROM local_runtime_devices d ` + principalJoin + ` WHERE ` + scopeWhere + ` AND d.uuid=$4 AND ` + principalValid
	if lock {
		query += ` FOR UPDATE OF d`
	}
	out := &dom.Device{Scope: scope}
	var engines []byte
	err := db.QueryRow(ctx, query, scope.AccountID, scope.TenantID, scope.SessionUUID, id).Scan(&out.UUID, &out.TenantUUID, &out.AccountUUID, &out.InstallationID, &out.Platform, &out.Generation, &out.SeenAt, &out.ProtocolVersion, &engines)
	if err == nil {
		err = json.Unmarshal(engines, &out.Engines)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, dom.ErrDenied
	}
	return out, err
}

func (r *Repo) Register(ctx context.Context, scope dom.Scope, installationID, platform string) (*dom.Device, error) {
	var id string
	err := r.pool.QueryRow(ctx, `INSERT INTO local_runtime_devices(tenant_id,account_id,login_session_uuid,installation_id,platform)
 SELECT $2,$1,$3,$4,$5 FROM login_sessions s
 JOIN accounts a ON a.id=s.account_id JOIN tenants t ON t.id=$2
 JOIN tenant_memberships m ON m.account_id=a.id AND m.tenant_id=t.id
 WHERE s.uuid=$3 AND s.account_id=$1 AND s.revoked_at IS NULL AND s.expires_at>now() AND s.act_tenant_id=$2
 AND a.status='active' AND a.deleted_at IS NULL AND t.status='active' AND m.status='active' AND m.deleted_at IS NULL
 AND lower(trim(s.device_type)) IN ('desktop','macos','macosx','darwin','windows','linux') AND coalesce(s.device_fingerprint,'')<>''
 ON CONFLICT(tenant_id,account_id,login_session_uuid) DO UPDATE SET platform=excluded.platform,installation_id=excluded.installation_id,public_key=NULL
 WHERE (local_runtime_devices.installation_id IS NULL OR local_runtime_devices.installation_id=excluded.installation_id) AND local_runtime_devices.revoked_at IS NULL
 RETURNING uuid`, scope.AccountID, scope.TenantID, scope.SessionUUID, installationID, platform).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, dom.ErrDenied
	}
	if err != nil {
		return nil, err
	}
	return r.GetDevice(ctx, scope, id)
}

func (r *Repo) GetDevice(ctx context.Context, scope dom.Scope, id string) (*dom.Device, error) {
	return device(ctx, r.pool, scope, id, false)
}

func (r *Repo) Connect(ctx context.Context, scope dom.Scope, id string, expectedGeneration int64) (*dom.Device, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	out, err := device(ctx, tx, scope, id, true)
	if err != nil {
		return nil, err
	}
	if out.Generation != expectedGeneration {
		return nil, dom.ErrConflict
	}
	err = tx.QueryRow(ctx, `UPDATE local_runtime_devices SET generation=generation+1,seen_at=now() WHERE uuid=$1 RETURNING generation,seen_at`, id).Scan(&out.Generation, &out.SeenAt)
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return out, nil
}

func (r *Repo) Heartbeat(ctx context.Context, scope dom.Scope, id string, generation int64) error {
	result, err := r.pool.Exec(ctx, `UPDATE local_runtime_devices dest SET seen_at=now() FROM local_runtime_devices d `+principalJoin+` WHERE dest.uuid=d.uuid AND `+scopeWhere+` AND d.uuid=$4 AND d.generation=$5 AND `+principalValid, scope.AccountID, scope.TenantID, scope.SessionUUID, id, generation)
	if err != nil {
		return err
	}
	if result.RowsAffected() != 1 {
		return dom.ErrDenied
	}
	return nil
}

func (r *Repo) Revoke(ctx context.Context, scope dom.Scope, id string) error {
	result, err := r.pool.Exec(ctx, `UPDATE local_runtime_devices SET revoked_at=coalesce(revoked_at,now()),generation=generation+1 WHERE uuid=$1 AND account_id=$2 AND tenant_id=$3`, id, scope.AccountID, scope.TenantID)
	if err != nil {
		return err
	}
	if result.RowsAffected() != 1 {
		return dom.ErrDenied
	}
	return nil
}

func (r *Repo) Disconnect(ctx context.Context, scope dom.Scope, id string, generation int64) error {
	_, err := r.pool.Exec(ctx, `UPDATE local_runtime_devices SET seen_at=NULL WHERE uuid=$1 AND account_id=$2 AND tenant_id=$3 AND login_session_uuid=$4 AND generation=$5`, id, scope.AccountID, scope.TenantID, scope.SessionUUID, generation)
	return err
}

const taskCols = `q.uuid,q.device_uuid,q.account_id,q.tenant_id,q.login_session_uuid,t.uuid,a.uuid,q.digital_employee_id,e.uuid,
 q.conversation_uuid,q.message_uuid,q.stream_id,q.fence,q.model,q.status,q.payload,q.token_hash,q.expires_at,q.last_seq,coalesce(q.requester_session_uuid::text,''),q.local_engine,COALESCE(e.local_engine,'')`
const taskFrom = ` FROM local_runtime_tasks q JOIN local_runtime_devices d ON d.uuid=q.device_uuid
 JOIN accounts a ON a.id=q.account_id JOIN tenants t ON t.id=q.tenant_id JOIN digital_employees e ON e.id=q.digital_employee_id `

// A local employee runs on the requesting member's active desktop. Personal employees remain
// creator-only; enterprise employees are tenant-owned; platform employees are shared read-only
// rows whose effective tenant is the task tenant.
const taskEmployeeValid = `e.execution_locus='local' AND e.local_engine=q.local_engine AND e.status='published' AND e.deleted_at IS NULL AND NOT e.is_deleted AND (
 (e.source='personal' AND e.visibility='private' AND e.tenant_id=q.tenant_id AND e.creator_id=q.account_id) OR
 (e.source='enterprise' AND e.tenant_id=q.tenant_id) OR
 (e.source='platform' AND e.visibility='platform' AND e.tenant_id IS NULL)
)`

func scanTask(row pgx.Row) (*dom.Task, error) {
	var out dom.Task
	err := row.Scan(&out.UUID, &out.DeviceUUID, &out.Scope.AccountID, &out.Scope.TenantID, &out.Scope.SessionUUID, &out.TenantUUID, &out.AccountUUID, &out.EmployeeID, &out.EmployeeUUID,
		&out.ConversationUUID, &out.MessageUUID, &out.StreamID, &out.Fence, &out.Model, &out.Status, &out.Payload, &out.TokenHash, &out.ExpiresAt, &out.LastSeq, &out.RequesterSessionUUID, &out.LocalEngine, &out.CurrentEngine)
	out.LoginSessionUUID = out.Scope.SessionUUID
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, dom.ErrDenied
	}
	return &out, err
}

func (r *Repo) GetTask(ctx context.Context, scope dom.Scope, id string) (*dom.Task, error) {
	return scanTask(r.pool.QueryRow(ctx, `SELECT `+taskCols+taskFrom+` WHERE q.uuid=$1 AND q.account_id=$2 AND q.tenant_id=$3 AND q.login_session_uuid=$4`, id, scope.AccountID, scope.TenantID, scope.SessionUUID))
}

func (r *Repo) CreateTask(ctx context.Context, task *dom.Task) (*dom.Task, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	dev, err := device(ctx, tx, task.Scope, task.DeviceUUID, true)
	if err != nil {
		return nil, err
	}
	if (task.RequesterSessionUUID != "" && dev.ProtocolVersion < 2) || dev.Generation <= 0 || time.Since(dev.SeenAt) > 15*time.Second {
		return nil, dom.ErrOffline
	}
	if task.LocalEngine == "" {
		task.LocalEngine = dom.EngineDSH
	}
	if !dom.SupportsEngine(dev, task.LocalEngine) {
		return nil, dom.ErrUpgradeRequired
	}
	var id string
	err = tx.QueryRow(ctx, `INSERT INTO local_runtime_tasks(uuid,device_uuid,tenant_id,account_id,login_session_uuid,digital_employee_id,conversation_uuid,message_uuid,stream_id,model,payload,token_hash,expires_at,requester_session_uuid,local_engine)
 SELECT $1,$2,$3,$4,$5,e.id,c.uuid,$8,$9,$10,$11,$12,least($13::timestamptz,now()+interval '15 minutes',s.expires_at),NULLIF($14,'')::uuid,e.local_engine
 FROM digital_employees e JOIN conversations c ON c.digital_employee_id=e.id JOIN login_sessions s ON s.uuid=$5
	 WHERE e.id=$6 AND e.execution_locus='local' AND e.local_engine=$15 AND e.status='published' AND e.deleted_at IS NULL AND NOT e.is_deleted
	 AND ((e.source='personal' AND e.visibility='private' AND e.tenant_id=$3 AND e.creator_id=$4)
	   OR (e.source='enterprise' AND e.tenant_id=$3)
	   OR (e.source='platform' AND e.visibility='platform' AND e.tenant_id IS NULL))
 AND c.uuid=$7 AND c.tenant_id=$3 AND c.account_id=$4 AND c.deleted_at IS NULL
 AND ($14='' OR EXISTS(SELECT 1 FROM login_sessions u WHERE u.uuid=NULLIF($14,'')::uuid AND u.account_id=$4 AND u.act_tenant_id=$3 AND u.revoked_at IS NULL AND u.expires_at>now()))
 ON CONFLICT(message_uuid) DO NOTHING RETURNING uuid`, task.UUID, task.DeviceUUID, task.Scope.TenantID, task.Scope.AccountID, task.Scope.SessionUUID, task.EmployeeID, task.ConversationUUID, task.MessageUUID, task.StreamID, task.Model, task.Payload, task.TokenHash, task.ExpiresAt, task.RequesterSessionUUID, task.LocalEngine).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, dom.ErrConflict
	}
	var conflict *pgconn.PgError
	if errors.As(err, &conflict) && conflict.Code == "23505" {
		return nil, dom.ErrConflict
	}
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return r.GetTask(ctx, task.Scope, id)
}

func (r *Repo) PendingTasks(ctx context.Context, scope dom.Scope, id string, generation int64) ([]dom.Task, error) {
	dev, err := r.GetDevice(ctx, scope, id)
	if err != nil {
		return nil, err
	}
	if dev.Generation != generation {
		return nil, dom.ErrDenied
	}
	rows, err := r.pool.Query(ctx, `SELECT `+taskCols+taskFrom+` WHERE q.device_uuid=$1 AND q.status IN ('dispatched','accepted') AND q.expires_at>now() AND (q.requester_session_uuid IS NULL OR $2>=2) ORDER BY q.created_at LIMIT 8`, id, dev.ProtocolVersion)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []dom.Task{}
	for rows.Next() {
		task, err := scanTask(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *task)
	}
	return out, rows.Err()
}

func (r *Repo) AcceptTask(ctx context.Context, scope dom.Scope, deviceID string, generation int64, id string, fence int64) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	dev, err := device(ctx, tx, scope, deviceID, true)
	if err != nil {
		return err
	}
	if dev.Generation != generation {
		return dom.ErrDenied
	}
	result, err := tx.Exec(ctx, `UPDATE local_runtime_tasks SET status='accepted' WHERE uuid=$1 AND device_uuid=$2 AND fence=$3 AND status IN ('dispatched','accepted') AND expires_at>now()`, id, deviceID, fence)
	if err != nil {
		return err
	}
	if result.RowsAffected() != 1 {
		return dom.ErrConflict
	}
	return tx.Commit(ctx)
}

func terminal(name string) string {
	switch name {
	case "message.completed":
		return "completed"
	case "message.failed":
		return "failed"
	case "message.cancelled":
		return "cancelled"
	}
	return ""
}

func (r *Repo) AppendEvent(ctx context.Context, scope dom.Scope, deviceID string, generation int64, ev dom.Event) (int64, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	dev, err := device(ctx, tx, scope, deviceID, true)
	if err != nil {
		return 0, err
	}
	if dev.Generation != generation {
		return 0, dom.ErrDenied
	}
	var seq int64
	var status string
	var expires time.Time
	err = tx.QueryRow(ctx, `SELECT last_seq,status,expires_at FROM local_runtime_tasks WHERE uuid=$1 AND device_uuid=$2 AND fence=$3 FOR UPDATE`, ev.RunUUID, deviceID, ev.Fence).Scan(&seq, &status, &expires)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, dom.ErrDenied
	}
	if err != nil {
		return 0, err
	}
	if ev.Seq <= seq {
		var same bool
		err = tx.QueryRow(ctx, `SELECT event=$3 AND data=$4::jsonb FROM local_runtime_events WHERE run_uuid=$1 AND seq=$2`, ev.RunUUID, ev.Seq, ev.Name, ev.Data).Scan(&same)
		if err != nil || !same {
			return seq, dom.ErrConflict
		}
		return seq, tx.Commit(ctx)
	}
	if status != "accepted" || !expires.After(time.Now()) {
		return seq, dom.ErrConflict
	}
	if ev.Seq != seq+1 || (seq == 0 && ev.Name != "message.created") || (seq > 0 && ev.Name == "message.created") {
		return seq, dom.ErrSequence
	}
	if _, err = tx.Exec(ctx, `INSERT INTO local_runtime_events(run_uuid,seq,event,data) VALUES($1,$2,$3,$4)`, ev.RunUUID, ev.Seq, ev.Name, ev.Data); err != nil {
		return seq, err
	}
	end := terminal(ev.Name)
	_, err = tx.Exec(ctx, `UPDATE local_runtime_tasks SET last_seq=$2,status=CASE WHEN $3<>'' THEN $3 ELSE status END,settled_at=CASE WHEN $3<>'' THEN now() ELSE NULL END WHERE uuid=$1`, ev.RunUUID, ev.Seq, end)
	if err != nil {
		return seq, err
	}
	return ev.Seq, tx.Commit(ctx)
}

func (r *Repo) Events(ctx context.Context, scope dom.Scope, id string, after int64) ([]dom.Event, error) {
	if _, err := r.GetTask(ctx, scope, id); err != nil {
		return nil, err
	}
	rows, err := r.pool.Query(ctx, `SELECT ev.seq,ev.event,ev.data,q.fence FROM local_runtime_events ev JOIN local_runtime_tasks q ON q.uuid=ev.run_uuid WHERE ev.run_uuid=$1 AND ev.seq>$2 ORDER BY ev.seq LIMIT 256`, id, after)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []dom.Event{}
	for rows.Next() {
		ev := dom.Event{RunUUID: id}
		if err := rows.Scan(&ev.Seq, &ev.Name, &ev.Data, &ev.Fence); err != nil {
			return nil, err
		}
		out = append(out, ev)
	}
	return out, rows.Err()
}

func (r *Repo) CancelTask(ctx context.Context, scope dom.Scope, id string) error {
	result, err := r.pool.Exec(ctx, `UPDATE local_runtime_tasks SET status=CASE WHEN status IN ('dispatched','accepted') THEN 'cancelled' ELSE status END,settled_at=coalesce(settled_at,now()) WHERE uuid=$1 AND account_id=$2 AND tenant_id=$3 AND login_session_uuid=$4`, id, scope.AccountID, scope.TenantID, scope.SessionUUID)
	if err != nil {
		return err
	}
	if result.RowsAffected() != 1 {
		return dom.ErrDenied
	}
	return nil
}

func (r *Repo) ExpireTasks(ctx context.Context) (int64, error) {
	result, err := r.pool.Exec(ctx, `UPDATE local_runtime_tasks q SET status='failed',settled_at=now() WHERE q.status IN ('dispatched','accepted') AND
	 (q.expires_at<=now() OR (q.requester_session_uuid IS NOT NULL AND NOT EXISTS(SELECT 1 FROM login_sessions u WHERE u.uuid=q.requester_session_uuid AND u.account_id=q.account_id AND u.act_tenant_id=q.tenant_id AND u.revoked_at IS NULL AND u.expires_at>now())) OR NOT EXISTS(SELECT 1 FROM digital_employees e WHERE e.id=q.digital_employee_id AND `+taskEmployeeValid+`) OR NOT EXISTS(SELECT 1 FROM local_runtime_devices d `+principalJoin+` WHERE d.uuid=q.device_uuid AND d.seen_at>now()-interval '15 seconds' AND `+principalValid+`))`)
	return result.RowsAffected(), err
}
