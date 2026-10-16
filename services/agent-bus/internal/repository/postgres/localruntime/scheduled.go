package localruntime

import (
	"context"
	"encoding/json"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

// OnlineDesktopPrincipalsSQL is shared by Cron's bounded polling and execution-time
// resolution, so an offline backlog cannot starve online owners or weaken identity checks.
const OnlineDesktopPrincipalsSQL = `SELECT d.uuid,d.account_id,d.tenant_id,d.login_session_uuid,
 t.uuid AS tenant_uuid,a.uuid AS account_uuid,d.platform,d.generation,d.seen_at,d.protocol_version,d.engines
 FROM local_runtime_devices d ` + principalJoin + ` WHERE ` + principalValid + `
 AND d.generation>0 AND d.seen_at>now()-interval '15 seconds'`

// ResolveScheduledDesktop is internal-only: the persisted job owner supplies identity.
// No old requester session or client-provided device is used as authority.
func (r *Repo) ResolveScheduledDesktop(ctx context.Context, accountID, tenantID int64) (*dom.Device, error) {
	rows, err := r.pool.Query(ctx, `SELECT uuid,login_session_uuid,tenant_uuid,account_uuid,
 platform,generation,seen_at,protocol_version,engines FROM (`+OnlineDesktopPrincipalsSQL+`) online
 WHERE account_id=$1 AND tenant_id=$2 LIMIT 2`, accountID, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out *dom.Device
	for rows.Next() {
		if out != nil {
			return nil, dom.ErrConflict
		}
		out = &dom.Device{Scope: dom.Scope{AccountID: accountID, TenantID: tenantID}}
		var engines []byte
		if err = rows.Scan(&out.UUID, &out.Scope.SessionUUID, &out.TenantUUID, &out.AccountUUID, &out.Platform, &out.Generation, &out.SeenAt, &out.ProtocolVersion, &engines); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(engines, &out.Engines); err != nil {
			return nil, err
		}
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	if out == nil {
		return nil, dom.ErrOffline
	}
	if out.ProtocolVersion < 2 {
		return out, dom.ErrUpgradeRequired
	}
	return out, nil
}
