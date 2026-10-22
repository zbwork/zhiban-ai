package knowledge

import "context"

type DeletedOriginal struct {
	ID, TenantID int64
	Key          string
}

// DeletedOriginals uses persistent tombstones, including documents of deleted KBs.
func (r *Repo) DeletedOriginals(ctx context.Context, limit int) ([]DeletedOriginal, error) {
	rows, err := r.pool.Query(ctx, `SELECT d.id,k.tenant_id,d.storage_key FROM kb_documents d JOIN knowledge_bases k ON k.id=d.kb_id WHERE k.tenant_id IS NOT NULL AND k.tenant_id>0 AND (d.deleted_at IS NOT NULL OR k.deleted_at IS NOT NULL) AND d.storage_key IS NOT NULL AND d.storage_key<>'' ORDER BY d.updated_at,d.id LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DeletedOriginal{}
	for rows.Next() {
		var d DeletedOriginal
		if err := rows.Scan(&d.ID, &d.TenantID, &d.Key); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}
func (r *Repo) FinishOriginalCleanup(ctx context.Context, id int64, key string, success bool) error {
	_, err := r.pool.Exec(ctx, `UPDATE kb_documents SET storage_key=CASE WHEN $3 THEN NULL ELSE storage_key END,updated_at=now() WHERE id=$1 AND storage_key=$2`, id, key, success)
	return err
}
