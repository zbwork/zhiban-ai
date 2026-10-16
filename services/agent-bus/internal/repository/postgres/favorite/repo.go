package favorite

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/favorite"
)

type Repo struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

func (r *Repo) Add(
	ctx context.Context,
	tenantID, accountID int64,
	kind dom.TargetKind,
	targetUUID string,
) error {
	var query string
	switch kind {
	case dom.TargetDriveFile:
		query = `
			INSERT INTO content_favorites (
				tenant_id, account_id, target_kind, drive_file_id,
				created_by, updated_by
			)
			SELECT $1, $2, 'drive_file', df.id, $2, $2
			  FROM drive_files df
			  JOIN drive_spaces ds ON ds.id = df.space_id
			 WHERE df.uuid = $3
			   AND df.is_deleted = false
			   AND ds.tenant_id = $1
			   AND ds.is_deleted = false
			ON CONFLICT (tenant_id, account_id, drive_file_id)
				WHERE target_kind = 'drive_file' AND is_deleted = false
			DO UPDATE SET updated_at = now(), updated_by = EXCLUDED.updated_by
		`
	case dom.TargetKBDocument:
		query = `
			INSERT INTO content_favorites (
				tenant_id, account_id, target_kind, kb_document_id,
				created_by, updated_by
			)
			SELECT $1, $2, 'kb_document', kd.id, $2, $2
			  FROM kb_documents kd
			  JOIN knowledge_bases kb ON kb.id = kd.kb_id
			 WHERE kd.uuid = $3
			   AND kd.deleted_at IS NULL
			   AND kb.tenant_id = $1
			   AND kb.deleted_at IS NULL
			ON CONFLICT (tenant_id, account_id, kb_document_id)
				WHERE target_kind = 'kb_document' AND is_deleted = false
			DO UPDATE SET updated_at = now(), updated_by = EXCLUDED.updated_by
		`
	default:
		return fmt.Errorf("favorite.Repo.Add: unsupported target kind %q", kind)
	}

	tag, err := r.pool.Exec(ctx, query, tenantID, accountID, targetUUID)
	if err != nil {
		return fmt.Errorf("favorite.Repo.Add: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return dom.ErrTargetNotFound
	}
	return nil
}

func (r *Repo) Remove(
	ctx context.Context,
	tenantID, accountID int64,
	kind dom.TargetKind,
	targetUUID string,
) error {
	var query string
	switch kind {
	case dom.TargetDriveFile:
		query = `
			UPDATE content_favorites cf
			   SET is_deleted = true,
			       deleted_at = now(),
			       updated_at = now(),
			       updated_by = $2
			 WHERE cf.tenant_id = $1
			   AND cf.account_id = $2
			   AND cf.target_kind = 'drive_file'
			   AND cf.is_deleted = false
			   AND cf.drive_file_id IN (
			       SELECT df.id
			         FROM drive_files df
			         JOIN drive_spaces ds ON ds.id = df.space_id
			        WHERE df.uuid = $3 AND ds.tenant_id = $1
			   )
		`
	case dom.TargetKBDocument:
		query = `
			UPDATE content_favorites cf
			   SET is_deleted = true,
			       deleted_at = now(),
			       updated_at = now(),
			       updated_by = $2
			 WHERE cf.tenant_id = $1
			   AND cf.account_id = $2
			   AND cf.target_kind = 'kb_document'
			   AND cf.is_deleted = false
			   AND cf.kb_document_id IN (
			       SELECT kd.id
			         FROM kb_documents kd
			         JOIN knowledge_bases kb ON kb.id = kd.kb_id
			        WHERE kd.uuid = $3 AND kb.tenant_id = $1
			   )
		`
	default:
		return fmt.Errorf("favorite.Repo.Remove: unsupported target kind %q", kind)
	}

	if _, err := r.pool.Exec(ctx, query, tenantID, accountID, targetUUID); err != nil {
		return fmt.Errorf("favorite.Repo.Remove: %w", err)
	}
	return nil
}

func (r *Repo) List(
	ctx context.Context,
	tenantID, accountID int64,
	limit int,
) ([]dom.Entry, error) {
	if limit <= 0 {
		limit = 100
	}
	if limit > 500 {
		limit = 500
	}

	rows, err := r.pool.Query(ctx, `
		SELECT favorite_uuid, target_kind, target_uuid, container_uuid, favorited_at
		  FROM (
		        SELECT cf.uuid::text AS favorite_uuid,
		               cf.target_kind,
		               df.uuid::text AS target_uuid,
		               ''::text AS container_uuid,
		               cf.created_at AS favorited_at
		          FROM content_favorites cf
		          JOIN drive_files df ON df.id = cf.drive_file_id
		          JOIN drive_spaces ds ON ds.id = df.space_id
		         WHERE cf.tenant_id = $1
		           AND cf.account_id = $2
		           AND cf.target_kind = 'drive_file'
		           AND cf.is_deleted = false
		           AND df.is_deleted = false
		           AND ds.tenant_id = $1
		           AND ds.is_deleted = false
		        UNION ALL
		        SELECT cf.uuid::text AS favorite_uuid,
		               cf.target_kind,
		               kd.uuid::text AS target_uuid,
		               kb.uuid::text AS container_uuid,
		               cf.created_at AS favorited_at
		          FROM content_favorites cf
		          JOIN kb_documents kd ON kd.id = cf.kb_document_id
		          JOIN knowledge_bases kb ON kb.id = kd.kb_id
		         WHERE cf.tenant_id = $1
		           AND cf.account_id = $2
		           AND cf.target_kind = 'kb_document'
		           AND cf.is_deleted = false
		           AND kd.deleted_at IS NULL
		           AND kb.tenant_id = $1
		           AND kb.deleted_at IS NULL
		       ) favorites
		 ORDER BY favorited_at DESC, favorite_uuid
		 LIMIT $3
	`, tenantID, accountID, limit)
	if err != nil {
		return nil, fmt.Errorf("favorite.Repo.List: %w", err)
	}
	defer rows.Close()

	out := make([]dom.Entry, 0)
	for rows.Next() {
		var entry dom.Entry
		if err := rows.Scan(
			&entry.UUID,
			&entry.TargetKind,
			&entry.TargetUUID,
			&entry.ContainerUUID,
			&entry.FavoritedAt,
		); err != nil {
			return nil, fmt.Errorf("favorite.Repo.List scan: %w", err)
		}
		out = append(out, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("favorite.Repo.List rows: %w", err)
	}
	return out, nil
}
