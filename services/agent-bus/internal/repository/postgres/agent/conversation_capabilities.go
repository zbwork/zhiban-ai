package agent

import (
	"context"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
)

// ConversationCapabilities is called only after contacts visibility filtering.
// Tenant and explicit UUID restrictions also apply at the repository boundary.
func (r *Repo) ConversationCapabilities(ctx context.Context, tenantID int64, uuids []string) (map[string]dom.ConversationCapabilities, error) {
	out := make(map[string]dom.ConversationCapabilities)
	if len(uuids) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx, `SELECT de.uuid, de.execution_locus,
   COALESCE(de.metadata->>'runtime_kind','') <> 'support_builtin'
   AND COALESCE(de.metadata->>'agent_key','') <> 'zhiban-support'
   AND (de.execution_locus = 'local' OR re.framework IN ('openclaw','hermes','dsh')),
   de.model_source, COALESCE(de.model_service_config->>'model_id',''), COALESCE(de.local_engine,'')
 FROM digital_employees de
 LEFT JOIN runtime_environments re ON re.id=de.runtime_environment_id AND re.is_deleted=false
 WHERE de.uuid=ANY($2::uuid[]) AND (de.tenant_id=$1 OR de.source='platform')
 AND de.deleted_at IS NULL AND de.is_deleted=false`, tenantID, uuids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var value dom.ConversationCapabilities
		var supported *bool
		if err := rows.Scan(&id, &value.ExecutionLocus, &supported, &value.ModelSource, &value.ModelServiceModelID, &value.LocalEngine); err != nil {
			return nil, err
		}
		value.SupportsModelSelection = supported != nil && *supported
		out[id] = value
	}
	return out, rows.Err()
}
