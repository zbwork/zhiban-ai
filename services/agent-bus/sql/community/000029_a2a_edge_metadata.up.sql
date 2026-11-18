-- Restore the columns read by the shared call-edge repository (upstream 000086/000087).
SET LOCAL search_path=agent_bus,public;
ALTER TABLE a2a_call_edges
  ADD COLUMN IF NOT EXISTS origin_conversation_id bigint,
  ADD COLUMN IF NOT EXISTS root_edge_id bigint,
  ADD COLUMN IF NOT EXISTS root_edge_created_at timestamptz,
  ADD COLUMN IF NOT EXISTS request_fingerprint varchar(64);
CREATE INDEX IF NOT EXISTS idx_a2a_origin_conversation
  ON a2a_call_edges(tenant_id, origin_conversation_id)
  WHERE origin_conversation_id IS NOT NULL AND NOT is_deleted;
CREATE INDEX IF NOT EXISTS idx_a2a_edges_root_chain
  ON a2a_call_edges(tenant_id, root_edge_id, root_edge_created_at);
COMMENT ON COLUMN a2a_call_edges.origin_conversation_id IS 'Originating conversation shared by the delegated call chain, if any.';
COMMENT ON COLUMN a2a_call_edges.root_edge_id IS 'Root call ID; NULL for the root itself.';
COMMENT ON COLUMN a2a_call_edges.root_edge_created_at IS 'Root call partition timestamp; NULL for the root itself.';
COMMENT ON COLUMN a2a_call_edges.request_fingerprint IS 'Canonical redacted request digest for repeated-call governance.';
