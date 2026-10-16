package communityresources

import (
	"context"
	"github.com/jackc/pgx/v5"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Initialize provisions actual storage quota, with no subscription or billing tables.
func Initialize(quotaBytes int64) func(context.Context, pgx.Tx, int64, int64, int64) error {
	return func(ctx context.Context, tx pgx.Tx, tenantID, planID, actorID int64) error {
		if quotaBytes <= 0 || planID != 0 {
			return apperr.ErrInvalidParams.Withf("community storage quota required; commercial plan unsupported")
		}
		var hasPassword bool
		if err := tx.QueryRow(ctx, "SELECT COALESCE(password_hash,'') <> '' FROM accounts WHERE id=$1 AND status='active' AND deleted_at IS NULL", actorID).Scan(&hasPassword); err != nil {
			return err
		}
		if !hasPassword {
			return apperr.ErrInvalidParams.Withf("community tenant administrator must be an existing password-enabled account")
		}
		_, err := tx.Exec(ctx, "INSERT INTO drive_quotas(tenant_id,subject_kind,subject_id,quota_bytes,used_bytes,created_by,updated_by) VALUES($1,'tenant',NULL,$2,0,$3,$3)", tenantID, quotaBytes, actorID)
		if err != nil {
			return err
		}
		var environmentID int64
		if err = tx.QueryRow(ctx, "INSERT INTO runtime_environments(scope,tenant_id,name,framework,hosting_kind,created_by,updated_by) VALUES('tenant',$1,'Community','generic','embedded',$2,$2) RETURNING id", tenantID, actorID).Scan(&environmentID); err != nil {
			return err
		}
		var employeeID int64
		err = tx.QueryRow(ctx, "INSERT INTO digital_employees(tenant_id,creator_id,name,visibility,status,current_version,runtime_environment_id,created_by,updated_by) VALUES($1,$2,'社区助手','tenant','published',1,$3,$2,$2) RETURNING id", tenantID, actorID, environmentID).Scan(&employeeID)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, "INSERT INTO agent_versions(digital_employee_id,version,snapshot,status,published_by,published_at,notes) SELECT id,1,to_jsonb(digital_employees),'published',$2,now(),'Community bootstrap' FROM digital_employees WHERE id=$1", employeeID, actorID)
		return err
	}
}
