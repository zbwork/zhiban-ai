package account

import "context"

// ContactPositionLabels projects current position names only for the requested
// active members in one tenant. Callers apply their existing contact field mask.
func (r *Repo) ContactPositionLabels(ctx context.Context, tenantID int64, accountIDs []int64) (map[int64]string, error) {
	out := map[int64]string{}
	if tenantID <= 0 || len(accountIDs) == 0 {
		return out, nil
	}
	rows, err := r.pool.Query(ctx, `
		SELECT DISTINCT ON (m.account_id) m.account_id, p.name
		FROM tenant_memberships m
		JOIN tenant_member_positions mp ON mp.membership_id=m.id
		JOIN tenant_positions p ON p.id=mp.position_id AND p.tenant_id=m.tenant_id AND p.deleted_at IS NULL
		WHERE m.tenant_id=$1 AND m.account_id=ANY($2::bigint[])
		  AND m.deleted_at IS NULL AND m.status='active'
		ORDER BY m.account_id, mp.is_primary DESC, p.sort_order, p.id`, tenantID, accountIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var label string
		if err := rows.Scan(&id, &label); err != nil {
			return nil, err
		}
		out[id] = label
	}
	return out, rows.Err()
}
