package a2aembedding

import (
	"strings"
	"testing"
)

func TestSearchSemanticSQLPredicates(t *testing.T) {
	for _, pred := range []string{
		"ace.tenant_id = $1",
		"ace.embedding_model = $4",
		"ace.embedding_dims = $5",
		"ace.card_version = COALESCE((de.a2a_card->>'card_version')::int, 0)",
		"de.tenant_id = $1",
		"de.is_deleted = false",
		"de.status = 'published'",
		"de.id != $2",
		"re.enabled = true",
		"re.status = 'active'",
		"re.egress_audit_status = 'approved'",
		"ORDER BY ace.embedding <=> $3::vector",
		"OFFSET $7",
	} {
		if !strings.Contains(searchSemanticSQL, pred) {
			t.Fatalf("searchSemanticSQL missing predicate %q:\n%s", pred, searchSemanticSQL)
		}
	}
	if strings.Contains(searchSemanticSQL, "de.visibility") {
		t.Fatalf("searchSemanticSQL must not filter contact visibility for A2A discover:\n%s", searchSemanticSQL)
	}
	for _, banned := range []string{"primary_endpoint", "api_key_secret_ref"} {
		if strings.Contains(searchSemanticSQL, banned) {
			t.Fatalf("searchSemanticSQL must not select %q", banned)
		}
	}
}

func TestListBackfillCandidatesSQLPredicates(t *testing.T) {
	for _, pred := range []string{
		"LEFT JOIN a2a_card_embeddings ace",
		"ace.embedding_model = $1",
		"de.tenant_id IS NOT NULL",
		"de.is_deleted = false",
		"de.a2a_card <> '{}'::jsonb",
		"ace.id IS NULL",
		"ace.embedding_dims <> $2",
		"ace.card_version <> COALESCE((de.a2a_card->>'card_version')::int, 0)",
		"LIMIT $3",
	} {
		if !strings.Contains(listBackfillCandidatesSQL, pred) {
			t.Fatalf("listBackfillCandidatesSQL missing predicate %q:\n%s", pred, listBackfillCandidatesSQL)
		}
	}
	for _, banned := range []string{"primary_endpoint", "api_key_secret_ref", "request_payload", "response_payload"} {
		if strings.Contains(listBackfillCandidatesSQL, banned) {
			t.Fatalf("listBackfillCandidatesSQL must not select %q", banned)
		}
	}
}

func TestVectorLiteral(t *testing.T) {
	got := vectorLiteral([]float64{1, 0.5, -2})
	if got != "[1,0.5,-2]" {
		t.Fatalf("vector literal=%q", got)
	}
}
