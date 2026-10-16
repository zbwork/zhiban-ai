package agent

import (
	"context"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Translate blueprint capability rows into the canonical application bindings.
// Validate the complete set before writing; inactive/tenant-disabled apps are not silently omitted.
func (r *Repo) CopyPlatformAppBindings(ctx context.Context, templateID, copyID int64) error {
	rows, err := r.pool.Query(ctx, `
 SELECT b.capability_uuid::text, COALESCE(a.id,0), b.sort_order,
        COALESCE(a.deleted_at IS NULL AND a.tenant_id IS NULL AND a.status='active'
          AND a.usage_scope IN ('all','agent') AND COALESCE(tas.is_enabled,true),false)
 FROM agent_capability_bindings b
 JOIN digital_employees de ON de.id=$2 AND de.deleted_at IS NULL
 LEFT JOIN apps a ON a.uuid=b.capability_uuid
 LEFT JOIN tenant_app_settings tas ON tas.app_id=a.id AND tas.tenant_id=de.tenant_id
 WHERE b.digital_employee_id=$1 AND b.capability_kind='app' AND b.agent_version_id IS NULL
 ORDER BY b.sort_order,b.id`, templateID, copyID)
	if err != nil {
		return err
	}
	type binding struct {
		id    int64
		order int
	}
	items := []binding{}
	for rows.Next() {
		var id string
		var b binding
		var allowed bool
		if err := rows.Scan(&id, &b.id, &b.order, &allowed); err != nil {
			rows.Close()
			return err
		}
		if !allowed {
			rows.Close()
			return apperr.ErrInvalidParams.Withf("模板应用 %s 当前不可用", id)
		}
		items = append(items, b)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	for _, b := range items {
		if _, err := tx.Exec(ctx, `INSERT INTO agent_app_bindings(agent_id,app_id,sort_order) VALUES($1,$2,$3)
   ON CONFLICT(agent_id,app_id) DO NOTHING`, copyID, b.id, b.order); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
