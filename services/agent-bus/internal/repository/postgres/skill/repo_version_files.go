package skill

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// ----------------------------------------------------------------------------
// skill_version_files (F03 §4.7 R1)
//
// 上传 zip 时双写：OSS 放原始 zip 作为 archival，本表存解析后的清单 +
// 文本文件预览。读路径（文件列表 / 单文件预览）走本表，避免远端 OSS 拖 zip。
// ----------------------------------------------------------------------------

const versionFileCols = `id, version_id, path, size_bytes, sha256, content_type,
	is_binary, truncated, COALESCE(content_text,''), created_at`

func scanVersionFile(row pgx.Row) (*domskill.VersionFile, error) {
	var f domskill.VersionFile
	if err := row.Scan(
		&f.ID, &f.VersionID, &f.Path, &f.SizeBytes, &f.SHA256, &f.ContentType,
		&f.IsBinary, &f.Truncated, &f.ContentText, &f.CreatedAt,
	); err != nil {
		return nil, err
	}
	return &f, nil
}

// ReplaceVersionFiles 全量替换某 version 下的文件清单。
//
// 用一个事务先 DELETE 再批量 INSERT；版本上传是低频写入路径，简单做法即可。
// 调用方语义：service 层在 UploadSkillPackage 解析完 zip 后整批写入。
func (r *Repo) ReplaceVersionFiles(ctx context.Context, versionID int64, files []domskill.VersionFile) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx,
		`DELETE FROM skill_version_files WHERE version_id=$1`, versionID); err != nil {
		return err
	}

	if len(files) == 0 {
		return tx.Commit(ctx)
	}

	batch := &pgx.Batch{}
	for i := range files {
		f := &files[i]
		var contentArg any
		if f.IsBinary || f.Truncated || f.ContentText == "" {
			contentArg = nil
		} else {
			contentArg = f.ContentText
		}
		batch.Queue(
			`INSERT INTO skill_version_files
				(version_id, path, size_bytes, sha256, content_type, is_binary, truncated, content_text)
			 VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
			versionID, f.Path, f.SizeBytes, f.SHA256, f.ContentType,
			f.IsBinary, f.Truncated, contentArg,
		)
	}
	br := tx.SendBatch(ctx, batch)
	for range files {
		if _, err := br.Exec(); err != nil {
			_ = br.Close()
			return err
		}
	}
	if err := br.Close(); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// ListVersionFiles 列单个版本的所有文件清单（不返回 content_text 内容以减小载荷）。
func (r *Repo) ListVersionFiles(ctx context.Context, versionID int64) ([]domskill.VersionFile, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT id, version_id, path, size_bytes, sha256, content_type,
		        is_binary, truncated, '' AS content_text, created_at
		   FROM skill_version_files
		  WHERE version_id=$1
		  ORDER BY path ASC`, versionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []domskill.VersionFile{}
	for rows.Next() {
		f, err := scanVersionFile(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *f)
	}
	return out, rows.Err()
}

// GetVersionFile 按 (version_id, path) 取单文件，含 content_text。
func (r *Repo) GetVersionFile(ctx context.Context, versionID int64, path string) (*domskill.VersionFile, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+versionFileCols+` FROM skill_version_files
		  WHERE version_id=$1 AND path=$2`, versionID, path)
	f, err := scanVersionFile(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("skill.version_file.not_found")
		}
		return nil, err
	}
	return f, nil
}
