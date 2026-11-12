// Package a2aembedding stores and queries A2A card embeddings for discover.
package a2aembedding

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	domagent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
)

const upsertEmbeddingSQL = `
	INSERT INTO a2a_card_embeddings (
		tenant_id, digital_employee_id, agent_uuid, card_version,
		embedding_model, embedding_dims, embedding, content_hash, updated_at)
	VALUES ($1, $2, $3::uuid, $4, $5, $6, $7::vector, $8, now())
	ON CONFLICT (digital_employee_id, embedding_model) DO UPDATE
	   SET tenant_id = EXCLUDED.tenant_id,
	       agent_uuid = EXCLUDED.agent_uuid,
	       card_version = EXCLUDED.card_version,
	       embedding_dims = EXCLUDED.embedding_dims,
	       embedding = EXCLUDED.embedding,
	       content_hash = EXCLUDED.content_hash,
	       updated_at = now()`

const searchSemanticSQL = `
	SELECT de.id, de.uuid, de.name, de.tags, de.workspace_id,
	       de.callable_by_agents::text, de.a2a_card::text,
	       ((2 - (ace.embedding <=> $3::vector)) / 2) AS score
	  FROM a2a_card_embeddings ace
	  JOIN digital_employees de
	    ON de.id = ace.digital_employee_id
	  JOIN runtime_environments re
	    ON re.id = de.runtime_environment_id
	   AND re.is_deleted = false
	   AND re.enabled = true
	   AND re.status = 'active'
	   AND re.egress_audit_status = 'approved'
	 WHERE ace.tenant_id = $1
	   AND ace.embedding_model = $4
	   AND ace.embedding_dims = $5
	   AND ace.card_version = COALESCE((de.a2a_card->>'card_version')::int, 0)
	   AND de.tenant_id = $1
	   AND de.is_deleted = false
	   AND de.status = 'published'
	   AND de.id != $2
	 ORDER BY ace.embedding <=> $3::vector
	 LIMIT $6
	OFFSET $7`

const listBackfillCandidatesSQL = `
	SELECT de.tenant_id, de.id, de.uuid, de.name, de.tags, de.a2a_card::text,
	       COALESCE((de.a2a_card->>'card_version')::int, 0) AS card_version
	  FROM digital_employees de
	  LEFT JOIN a2a_card_embeddings ace
	    ON ace.digital_employee_id = de.id
	   AND ace.embedding_model = $1
	 WHERE de.tenant_id IS NOT NULL
	   AND de.is_deleted = false
	   AND de.a2a_card IS NOT NULL
	   AND de.a2a_card <> '{}'::jsonb
	   AND (
	       ace.id IS NULL
	    OR ace.embedding_dims <> $2
	    OR ace.card_version <> COALESCE((de.a2a_card->>'card_version')::int, 0)
	   )
	 ORDER BY de.id ASC
	 LIMIT $3`

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

type UpsertInput struct {
	TenantID          int64
	DigitalEmployeeID int64
	AgentUUID         string
	CardVersion       int
	EmbeddingModel    string
	EmbeddingDims     int
	Embedding         []float64
	Content           string
}

type BackfillCandidate struct {
	TenantID          int64
	DigitalEmployeeID int64
	AgentUUID         string
	Name              string
	Tags              []string
	A2ACardJSON       string
	CardVersion       int
}

func (r *Repo) Upsert(ctx context.Context, in UpsertInput) error {
	if r == nil || r.pool == nil {
		return nil
	}
	if in.TenantID <= 0 || in.DigitalEmployeeID <= 0 || strings.TrimSpace(in.AgentUUID) == "" ||
		strings.TrimSpace(in.EmbeddingModel) == "" || len(in.Embedding) == 0 {
		return nil
	}
	if in.EmbeddingDims <= 0 {
		in.EmbeddingDims = len(in.Embedding)
	}
	if len(in.Embedding) != in.EmbeddingDims {
		return fmt.Errorf("a2a embedding dims mismatch: got %d want %d", len(in.Embedding), in.EmbeddingDims)
	}
	_, err := r.pool.Exec(ctx, upsertEmbeddingSQL,
		in.TenantID, in.DigitalEmployeeID, in.AgentUUID, in.CardVersion,
		in.EmbeddingModel, in.EmbeddingDims, vectorLiteral(in.Embedding), contentHash(in.Content))
	return err
}

func (r *Repo) ListSemanticCandidates(ctx context.Context, tenantID, excludeAgentID int64, queryVector []float64, embeddingModel string, embeddingDims, limit, offset int) ([]*domagent.DigitalEmployee, map[string]float64, error) {
	if r == nil || r.pool == nil || tenantID <= 0 || len(queryVector) == 0 || strings.TrimSpace(embeddingModel) == "" {
		return nil, nil, nil
	}
	if embeddingDims <= 0 {
		embeddingDims = len(queryVector)
	}
	if len(queryVector) != embeddingDims {
		return nil, nil, fmt.Errorf("a2a query embedding dims mismatch: got %d want %d", len(queryVector), embeddingDims)
	}
	if limit <= 0 {
		limit = 20
	}
	if offset < 0 {
		offset = 0
	}
	rows, err := r.pool.Query(ctx, searchSemanticSQL, tenantID, excludeAgentID, vectorLiteral(queryVector), embeddingModel, embeddingDims, limit, offset)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	var out []*domagent.DigitalEmployee
	scores := map[string]float64{}
	for rows.Next() {
		var c domagent.DigitalEmployee
		var score float64
		if err := rows.Scan(&c.ID, &c.UUID, &c.Name, &c.Tags, &c.WorkspaceID,
			&c.CallableByAgentsJSON, &c.A2ACardJSON, &score); err != nil {
			return nil, nil, err
		}
		out = append(out, &c)
		scores[c.UUID] = score
	}
	return out, scores, rows.Err()
}

func (r *Repo) ListBackfillCandidates(ctx context.Context, embeddingModel string, embeddingDims, limit int) ([]BackfillCandidate, error) {
	if r == nil || r.pool == nil || strings.TrimSpace(embeddingModel) == "" {
		return nil, nil
	}
	if embeddingDims <= 0 {
		embeddingDims = 1536
	}
	if limit <= 0 {
		limit = 100
	}
	rows, err := r.pool.Query(ctx, listBackfillCandidatesSQL, embeddingModel, embeddingDims, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []BackfillCandidate
	for rows.Next() {
		var c BackfillCandidate
		if err := rows.Scan(&c.TenantID, &c.DigitalEmployeeID, &c.AgentUUID, &c.Name, &c.Tags, &c.A2ACardJSON, &c.CardVersion); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func contentHash(content string) string {
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}

func vectorLiteral(v []float64) string {
	parts := make([]string, 0, len(v))
	for _, n := range v {
		parts = append(parts, strconv.FormatFloat(n, 'g', -1, 64))
	}
	return "[" + strings.Join(parts, ",") + "]"
}
