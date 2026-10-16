package drive

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

// EnsureSystemChild binds ownership to the employee identity, never its display
// name. The transaction lock also prevents concurrent first use of one employee
// from creating multiple directories with different names.
func (r *FolderRepo) EnsureSystemChild(ctx context.Context, in dom.CreateFolderInput) (*dom.Folder, error) {
	if in.ParentID == nil || in.AgentID == nil || *in.AgentID == "" || !in.IsSystem ||
		(in.Kind != dom.FolderKindDeAgent && in.Kind != dom.FolderKindDeOutputs) {
		return nil, fmt.Errorf("drive.invalid_system_folder_identity")
	}
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	key := fmt.Sprintf("drive-system:%d:%d:%s:%s", in.SpaceID, *in.ParentID, in.Kind, *in.AgentID)
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, key); err != nil {
		return nil, err
	}
	const columns = `id, uuid, space_id, parent_id, name, kind, agent_id, is_system, path, sort,
created_at, created_by, updated_at, updated_by, is_deleted, deleted_at`
	scan := func(row pgx.Row) (*dom.Folder, error) {
		var f dom.Folder
		err := row.Scan(&f.ID, &f.UUID, &f.SpaceID, &f.ParentID, &f.Name, &f.Kind, &f.AgentID, &f.IsSystem, &f.Path, &f.Sort,
			&f.CreatedAt, &f.CreatedBy, &f.UpdatedAt, &f.UpdatedBy, &f.IsDeleted, &f.DeletedAt)
		return &f, err
	}
	f, err := scan(tx.QueryRow(ctx, `SELECT `+columns+` FROM drive_folders
WHERE space_id=$1 AND parent_id=$2 AND kind=$3 AND agent_id=$4 AND is_system=true AND is_deleted=false LIMIT 1`,
		in.SpaceID, *in.ParentID, string(in.Kind), *in.AgentID))
	if err == nil {
		return f, tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	parentPath := strings.TrimSuffix(in.Path, in.Name+"/")
	hash := sha256.Sum256([]byte(*in.AgentID))
	for attempt := 0; attempt < 16; attempt++ {
		name := in.Name
		if attempt > 0 {
			suffix := fmt.Sprintf("-%x", hash[:4])
			if attempt > 1 {
				suffix += fmt.Sprintf("-%d", attempt)
			}
			for len(name)+len(suffix) > 128 {
				_, size := utf8.DecodeLastRuneInString(name)
				name = name[:len(name)-size]
			}
			name += suffix
		}
		f, err = scan(tx.QueryRow(ctx, `INSERT INTO drive_folders
(space_id,parent_id,name,kind,agent_id,is_system,path,created_by,updated_by)
VALUES ($1,$2,$3,$4,$5,true,$6,$7,$7) ON CONFLICT DO NOTHING RETURNING `+columns,
			in.SpaceID, *in.ParentID, name, string(in.Kind), *in.AgentID, parentPath+name+"/", in.CreatedBy))
		if err == nil {
			return f, tx.Commit(ctx)
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}
	return nil, ErrDuplicateName
}
