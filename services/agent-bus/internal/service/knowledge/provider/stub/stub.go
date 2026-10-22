// Package stub 是 M8 Phase A KBProvider 的 PG 实现.
//
// 见 docs/tasks/m8-knowledge-bases.md §4.2:
//   - Ingest: INSERT kb_chunks(content); tsv 由 GENERATED 列自动生成.
//   - Retrieve: 主路径 ts_rank > threshold ORDER BY score DESC LIMIT top_k;
//     0 命中则 fallback `content ILIKE '%query%'` 兜底 (固定 score = 1.0/n 区分顺序).
//
// 关键约束:
//   - 调用方必须先用 service 层验过 KB 所属 tenant; 这里 SQL WHERE kb_id=$N 已经收口
//     在单个 KB 内; tenant 隔离由 service 保证 (provider 不重复校).
//   - 不引入 pg_trgm / 任何 extension; ILIKE 子串足够 Phase A 验收范围.
package stub

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/service/knowledge/provider"
)

// Store 是 stub provider 用到的 PG 访问点.
type Store struct {
	pool *pgxpool.Pool
}

// New 构造 stub provider; pool 必传.
func New(pool *pgxpool.Pool) *Store {
	if pool == nil {
		panic("knowledge/provider/stub: pgxpool required")
	}
	return &Store{pool: pool}
}

// Kind 返回 "stub".
func (s *Store) Kind() string { return "stub" }

// WithTx 返回一个绑定 pgx.Tx 的 provider (Ingest 同事务用; Retrieve / Delete 走 pool).
func (s *Store) WithTx(tx pgx.Tx) provider.Provider {
	return &txProvider{tx: tx, pool: s.pool}
}

// IngestChunks pool 路径; 一般 service 用 WithTx + ingest 同事务. 这里保留单独入口供单测.
func (s *Store) IngestChunks(ctx context.Context, in provider.IngestReq) (*provider.IngestResult, error) {
	return ingestChunks(ctx, s.pool, in)
}

// Retrieve 主路径 ts_rank + ILIKE fallback.
func (s *Store) Retrieve(ctx context.Context, in provider.RetrieveReq) ([]provider.Chunk, error) {
	return retrieve(ctx, s.pool, in)
}

// DeleteDocument 删除某文档下所有 chunk; pool 路径 (service 同事务删时调 WithTx).
func (s *Store) DeleteDocument(ctx context.Context, in provider.DeleteDocumentReq) error {
	return deleteDocument(ctx, s.pool, in)
}

// 编译期断言 *Store 实现 provider.Provider.
var _ provider.Provider = (*Store)(nil)

// ---- tx-bound provider ----

type txProvider struct {
	tx   pgx.Tx
	pool *pgxpool.Pool
}

func (t *txProvider) Kind() string { return "stub" }
func (t *txProvider) IngestChunks(ctx context.Context, in provider.IngestReq) (*provider.IngestResult, error) {
	return ingestChunks(ctx, t.tx, in)
}
func (t *txProvider) Retrieve(ctx context.Context, in provider.RetrieveReq) ([]provider.Chunk, error) {
	// Retrieve 一般走 pool, 但 tx-bound provider 也接受
	return retrieve(ctx, t.tx, in)
}
func (t *txProvider) DeleteDocument(ctx context.Context, in provider.DeleteDocumentReq) error {
	return deleteDocument(ctx, t.tx, in)
}

// ---- shared SQL helpers ----

// 不抽象 interface, 直接对 *pgxpool.Pool 与 pgx.Tx 做 type switch (pgconn.CommandTag 签名差异规避).

func ingestChunks(ctx context.Context, q any, in provider.IngestReq) (*provider.IngestResult, error) {
	if len(in.Chunks) == 0 {
		return &provider.IngestResult{ProviderDocID: in.ProviderDocID, ChunkCount: 0}, nil
	}
	switch e := q.(type) {
	case *pgxpool.Pool:
		for i, c := range in.Chunks {
			if _, err := e.Exec(ctx,
				`INSERT INTO kb_chunks (kb_id, document_id, chunk_index, content, metadata)
				 VALUES ($1, $2, $3, $4, '{}'::jsonb)`,
				in.KBID, in.DocumentID, i, c); err != nil {
				return nil, err
			}
		}
	case pgx.Tx:
		for i, c := range in.Chunks {
			if _, err := e.Exec(ctx,
				`INSERT INTO kb_chunks (kb_id, document_id, chunk_index, content, metadata)
				 VALUES ($1, $2, $3, $4, '{}'::jsonb)`,
				in.KBID, in.DocumentID, i, c); err != nil {
				return nil, err
			}
		}
	default:
		return nil, errors.New("stub: unsupported pg client type")
	}
	return &provider.IngestResult{ProviderDocID: in.ProviderDocID, ChunkCount: len(in.Chunks)}, nil
}

func retrieve(ctx context.Context, q any, in provider.RetrieveReq) ([]provider.Chunk, error) {
	if strings.TrimSpace(in.Query) == "" {
		return nil, nil
	}
	if in.TopK <= 0 {
		in.TopK = 5
	}
	// 主路径: tsvector + ts_rank.
	rows, err := queryRows(ctx, q,
		`SELECT uuid::text, document_id, chunk_index, content,
		        ts_rank(tsv, plainto_tsquery('simple', $1)) AS score
		   FROM kb_chunks
		  WHERE kb_id = $2
		    AND tsv @@ plainto_tsquery('simple', $1)
		    AND ts_rank(tsv, plainto_tsquery('simple', $1)) > $3
		  ORDER BY score DESC, chunk_index ASC
		  LIMIT $4`,
		in.Query, in.KBID, in.Threshold, in.TopK)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]provider.Chunk, 0, in.TopK)
	for rows.Next() {
		var c provider.Chunk
		if err := rows.Scan(&c.UUID, &c.DocumentID, &c.ChunkIndex, &c.Content, &c.Score); err != nil {
			return nil, err
		}
		c.Source = "tsvector"
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(out) > 0 {
		return out, nil
	}
	// fallback: ILIKE 子串. plainto_tsquery 解析空 / score 全 0 → 兜底.
	rows2, err := queryRows(ctx, q,
		`SELECT uuid::text, document_id, chunk_index, content
		   FROM kb_chunks
		  WHERE kb_id = $2
		    AND content ILIKE '%' || $1 || '%'
		  ORDER BY chunk_index ASC
		  LIMIT $3`,
		in.Query, in.KBID, in.TopK)
	if err != nil {
		return nil, err
	}
	defer rows2.Close()
	for rows2.Next() {
		var c provider.Chunk
		if err := rows2.Scan(&c.UUID, &c.DocumentID, &c.ChunkIndex, &c.Content); err != nil {
			return nil, err
		}
		// fallback 固定低分; 让 caller 能区分主路径与 fallback (审计 / 监控).
		c.Score = 0.01
		c.Source = "ilike"
		out = append(out, c)
	}
	if err := rows2.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

func deleteDocument(ctx context.Context, q any, in provider.DeleteDocumentReq) error {
	switch e := q.(type) {
	case *pgxpool.Pool:
		_, err := e.Exec(ctx, `DELETE FROM kb_chunks WHERE kb_id=$1 AND document_id=$2`, in.KBID, in.DocumentID)
		return err
	case pgx.Tx:
		_, err := e.Exec(ctx, `DELETE FROM kb_chunks WHERE kb_id=$1 AND document_id=$2`, in.KBID, in.DocumentID)
		return err
	}
	return errors.New("stub: unsupported pg client type")
}

// queryRows wraps both pgxpool.Pool.Query and pgx.Tx.Query.
func queryRows(ctx context.Context, q any, sql string, args ...any) (pgx.Rows, error) {
	switch e := q.(type) {
	case *pgxpool.Pool:
		return e.Query(ctx, sql, args...)
	case pgx.Tx:
		return e.Query(ctx, sql, args...)
	}
	return nil, errors.New("stub: unsupported pg client type")
}
