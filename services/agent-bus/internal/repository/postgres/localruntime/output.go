package localruntime

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

var _ dom.OutputAgentResolver = (*Repo)(nil)

// ResolveOutputAgent uses the same employee policy as task execution, including
// platform employees whose tenant is deliberately NULL. It never changes ownership.
func (r *Repo) ResolveOutputAgent(ctx context.Context, task *dom.Task) (string, error) {
	if task == nil {
		return "", dom.ErrDenied
	}
	var name string
	err := r.pool.QueryRow(ctx, `SELECT e.name FROM local_runtime_tasks q
 JOIN local_runtime_devices d ON d.uuid=q.device_uuid
 JOIN digital_employees e ON e.id=q.digital_employee_id `+principalJoin+`
 WHERE `+scopeWhere+` AND q.account_id=d.account_id AND q.tenant_id=d.tenant_id
 AND q.login_session_uuid=d.login_session_uuid AND q.uuid=$4 AND q.fence=$5
 AND q.device_uuid=$6 AND e.uuid=$7 AND q.local_engine=$8
 AND q.status IN ('accepted','running','completed','failed')
 AND q.expires_at + interval '7 days' > now()
 AND `+principalValid+` AND `+taskEmployeeValid,
		task.Scope.AccountID, task.Scope.TenantID, task.Scope.SessionUUID,
		task.UUID, task.Fence, task.DeviceUUID, task.EmployeeUUID, task.LocalEngine).Scan(&name)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", dom.ErrDenied
	}
	return name, err
}
