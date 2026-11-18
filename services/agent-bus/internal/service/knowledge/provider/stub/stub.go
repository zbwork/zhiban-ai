// Package stub 是 M8 Phase A KBProvider 的 PG 实现.
//
// 见 docs/tasks/m8-knowledge-bases.md §4.2:
//   - Ingest: INSERT kb_chunks(content); tsv 由 GENERATED 列自动生成.
//   - Retrieve: 主路径 ts_rank > threshold ORDER BY score DESC LIMIT top_k;
//     0 命中时补查原文子串和连续汉字片段。
//
// 关键约束:
//   - 调用方必须先用 service 层验过 KB 所属 tenant; 这里 SQL WHERE kb_id=$N 已经收口
//     在单个 KB 内; tenant 隔离由 service 保证 (provider 不重复校).
//   - 不引入 pg_trgm 或外部模型。
package stub

import (
	"context"
	"errors"
	"strings"
	"unicode"

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
	out, err := readChunks(rows, in.TopK, "tsvector")
	if err != nil || len(out) != 0 {
		return out, err
	}
	rows, err = queryRows(ctx, q,
		`SELECT uuid::text, document_id, chunk_index, content, 0.01::float8
		   FROM kb_chunks
		  WHERE kb_id = $2
		    AND strpos(lower(content), lower($1)) > 0
		  ORDER BY chunk_index ASC
		  LIMIT $3`, in.Query, in.KBID, in.TopK)
	if err != nil {
		return nil, err
	}
	out, err = readChunks(rows, in.TopK, "ilike")
	if err != nil || len(out) != 0 {
		return out, err
	}
	phrases := hanPhrases(in.Query)
	if len(phrases) == 0 {
		return out, nil
	}
	rows, err = queryRows(ctx, q,
		`SELECT chunk.uuid::text, chunk.document_id, chunk.chunk_index, chunk.content, matches.score
		   FROM kb_chunks AS chunk
		   CROSS JOIN LATERAL (
		       SELECT count(*)::float8 / cardinality($1::text[]) AS score
		         FROM unnest($1::text[]) AS phrase(text)
		        WHERE strpos(chunk.content, phrase.text) > 0
		   ) AS matches
		  WHERE chunk.kb_id = $2 AND matches.score > $3
		  ORDER BY matches.score DESC, chunk.chunk_index ASC, chunk.id ASC
		  LIMIT $4`, phrases, in.KBID, in.Threshold, in.TopK)
	if err != nil {
		return nil, err
	}
	return readChunks(rows, in.TopK, "han_phrase")
}

func readChunks(rows pgx.Rows, capacity int, source string) ([]provider.Chunk, error) {
	defer rows.Close()
	out := make([]provider.Chunk, 0, capacity)
	for rows.Next() {
		var c provider.Chunk
		if err := rows.Scan(&c.UUID, &c.DocumentID, &c.ChunkIndex, &c.Content, &c.Score); err != nil {
			return nil, err
		}
		c.Source = source
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// hanPhrases derives bounded, literal overlap candidates without assigning terms that
// do not occur in the query. Punctuation and non-Han characters break a phrase.
func hanPhrases(query string) []string {
	const width, limit = 4, 24
	trim := func(s string) string {
		return strings.TrimFunc(s, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsPunct(r) })
	}
	query = trim(query)
	for _, prefix := range []string{"请问", "请告诉我", "想知道"} {
		if rest, ok := strings.CutPrefix(query, prefix); ok {
			query = trim(rest)
			break
		}
	}
	for _, suffix := range []string{"是什么意思", "是什么", "有哪些", "是多少", "在哪里", "吗"} {
		if rest, ok := strings.CutSuffix(query, suffix); ok {
			query = trim(rest)
			break
		}
	}
	runes := []rune(query)
	seen := make(map[string]bool, limit)
	var phrases []string
	consecutive := 0
	for i, r := range runes {
		if !unicode.Is(unicode.Han, r) {
			consecutive = 0
			continue
		}
		consecutive++
		if consecutive < width {
			continue
		}
		phrase := string(runes[i-width+1 : i+1])
		if seen[phrase] {
			continue
		}
		seen[phrase] = true
		phrases = append(phrases, phrase)
		if len(phrases) == limit {
			break
		}
	}
	return phrases
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
