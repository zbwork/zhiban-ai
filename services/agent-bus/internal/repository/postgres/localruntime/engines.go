package localruntime

import (
	"context"
	"encoding/json"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

func (r *Repo) SetEngines(ctx context.Context, scope dom.Scope, id string, engines map[string]string) error {
	body, err := json.Marshal(engines)
	if err != nil {
		return err
	}
	result, err := r.pool.Exec(ctx, `UPDATE local_runtime_devices dest SET engines=$5::jsonb FROM local_runtime_devices d `+principalJoin+` WHERE dest.uuid=d.uuid AND `+scopeWhere+` AND d.uuid=$4 AND `+principalValid, scope.AccountID, scope.TenantID, scope.SessionUUID, id, body)
	if err != nil {
		return err
	}
	if result.RowsAffected() != 1 {
		return dom.ErrDenied
	}
	return nil
}
