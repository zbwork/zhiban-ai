// Package agentrun persists F24 agent-run observability rows.
//
// Write-side invariants (F24 D7/D8/D9):
//   - Runs upsert on (message_uuid, created_at): finalize retries, HITL
//     pause/resume and late writes converge on one row.
//   - Steps upsert on (run_uuid, seq, created_at); step.created_at always
//     equals the owning run's created_at so the whole run shares a partition.
//   - Backfill inserts use ON CONFLICT DO NOTHING and never clobber live rows.
//   - error_message is redacted by callers before it reaches this package;
//     this package only enforces the 500-char cap as a last resort.
package agentrun

import (
	"context"
	"encoding/json"
	"errors"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentrun"
)

type Repo struct{ pool *pgxpool.Pool }

func New(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

func (r *Repo) Pool() *pgxpool.Pool { return r.pool }

const upsertRunSQL = `
INSERT INTO agent_runs
  (uuid, tenant_id, account_id, digital_employee_id,
   conversation_uuid, message_uuid, stream_id, room_id,
   runtime_kind, runtime_environment_id, runtime_instance_id,
   trigger_source, status,
   started_at, completed_at, duration_ms, first_output_ms, thinking_ms, hitl_wait_ms,
   tool_call_count, tool_error_count, a2a_edge_count,
   input_tokens, output_tokens, total_tokens, usage_source,
   model, agent_version_id, root_a2a_edge_uuid,
   error_code, error_message, trace_id, tags, created_at, updated_at,
   execution_locus, requested_model, executed_model, response_model,
   retry_index, retry_reason, fallback_chain)
VALUES (COALESCE($1, gen_random_uuid()), $2, $3, $4,
        $5, $6, $7, $8,
        $9, $10, $11,
        $12, $13,
        $14, $15, $16, $17, $18, $19,
        $20, $21, $22,
        $23, $24, $25, $26,
        $27, $28, $29,
        $30, $31, $32, $33::jsonb, $34, now(),
        $35, $36, $37, $38,
        $39, $40, $41::jsonb)
ON CONFLICT (message_uuid, created_at) DO UPDATE SET
  status            = EXCLUDED.status,
  stream_id         = COALESCE(EXCLUDED.stream_id, agent_runs.stream_id),
  completed_at      = EXCLUDED.completed_at,
  duration_ms       = EXCLUDED.duration_ms,
  first_output_ms   = COALESCE(EXCLUDED.first_output_ms, agent_runs.first_output_ms),
  thinking_ms       = COALESCE(EXCLUDED.thinking_ms, agent_runs.thinking_ms),
  hitl_wait_ms      = GREATEST(COALESCE(EXCLUDED.hitl_wait_ms, 0), COALESCE(agent_runs.hitl_wait_ms, 0)),
  tool_call_count   = GREATEST(EXCLUDED.tool_call_count, agent_runs.tool_call_count),
  tool_error_count  = GREATEST(EXCLUDED.tool_error_count, agent_runs.tool_error_count),
  a2a_edge_count    = GREATEST(EXCLUDED.a2a_edge_count, agent_runs.a2a_edge_count),
  input_tokens      = COALESCE(EXCLUDED.input_tokens, agent_runs.input_tokens),
  output_tokens     = COALESCE(EXCLUDED.output_tokens, agent_runs.output_tokens),
  total_tokens      = COALESCE(EXCLUDED.total_tokens, agent_runs.total_tokens),
  usage_source      = CASE WHEN EXCLUDED.usage_source = 'runtime' THEN 'runtime' ELSE agent_runs.usage_source END,
  model             = COALESCE(NULLIF(EXCLUDED.model, ''), agent_runs.model),
  agent_version_id  = COALESCE(EXCLUDED.agent_version_id, agent_runs.agent_version_id),
  root_a2a_edge_uuid = COALESCE(EXCLUDED.root_a2a_edge_uuid, agent_runs.root_a2a_edge_uuid),
  error_code        = EXCLUDED.error_code,
  error_message     = EXCLUDED.error_message,
  trace_id          = COALESCE(NULLIF(EXCLUDED.trace_id, ''), agent_runs.trace_id),
  tags              = agent_runs.tags || EXCLUDED.tags,
  -- 执行位置在派发时确定，重试/对账回写不得改写它。
  execution_locus   = agent_runs.execution_locus,
  requested_model   = COALESCE(NULLIF(EXCLUDED.requested_model, ''), agent_runs.requested_model),
  executed_model    = COALESCE(NULLIF(EXCLUDED.executed_model, ''), agent_runs.executed_model),
  response_model    = COALESCE(NULLIF(EXCLUDED.response_model, ''), agent_runs.response_model),
  -- 重试次数与回退链只增不减：晚到的对账写入不能把已观察到的重试抹掉。
  retry_index       = GREATEST(EXCLUDED.retry_index, agent_runs.retry_index),
  retry_reason      = COALESCE(NULLIF(EXCLUDED.retry_reason, ''), agent_runs.retry_reason),
  fallback_chain    = COALESCE(EXCLUDED.fallback_chain, agent_runs.fallback_chain),
  updated_at        = now()
RETURNING uuid`

// UpsertRun writes (or converges) one run row and returns the persisted run
// uuid. Callers must keep run.CreatedAt stable across retries (D7).
func (r *Repo) UpsertRun(ctx context.Context, run *dom.Run) (string, error) {
	tags := marshalMap(dom.FilterTags(run.Tags))
	var uuid string
	err := r.pool.QueryRow(ctx, upsertRunSQL,
		nilIfEmpty(run.UUID), run.TenantID, run.AccountID, run.DigitalEmployeeID,
		nilIfEmpty(run.ConversationUUID), run.MessageUUID, nilIfEmpty(run.StreamID), run.RoomID,
		run.RuntimeKind, run.RuntimeEnvironmentID, nilIfEmpty(run.RuntimeInstanceID),
		run.TriggerSource, run.Status,
		run.StartedAt, run.CompletedAt, run.DurationMS, run.FirstOutputMS, run.ThinkingMS, run.HITLWaitMS,
		run.ToolCallCount, run.ToolErrorCount, run.A2AEdgeCount,
		run.InputTokens, run.OutputTokens, run.TotalTokens, run.UsageSource,
		nilIfEmpty(truncStr(run.Model, 128)), run.AgentVersionID, nilIfEmpty(run.RootA2AEdgeUUID),
		nilIfEmpty(truncStr(run.ErrorCode, 64)), nilIfEmpty(truncStr(run.ErrorMessage, 500)), nilIfEmpty(run.TraceID),
		tags, run.CreatedAt,
		run.ExecutionLocus,
		nilIfEmpty(truncStr(run.RequestedModel, 128)), nilIfEmpty(truncStr(run.ExecutedModel, 128)), nilIfEmpty(truncStr(run.ResponseModel, 128)),
		run.RetryIndex, nilIfEmpty(truncStr(run.RetryReason, 64)), marshalFallbackChain(run.FallbackChain),
	).Scan(&uuid)
	return uuid, err
}

const insertRunSkeletonSQL = `
INSERT INTO agent_runs
  (tenant_id, account_id, digital_employee_id,
   conversation_uuid, message_uuid, stream_id, room_id,
   runtime_kind, trigger_source, status,
   started_at, completed_at, duration_ms,
   input_tokens, output_tokens, total_tokens, usage_source,
   model, error_code, error_message, trace_id, tags, created_at, updated_at)
VALUES ($1, $2, $3,
        $4, $5, $6, $7,
        $8, $9, $10,
        $11, $12, $13,
        $14, $15, $16, $17,
        $18, $19, $20, $21, $22::jsonb, $23, now())
ON CONFLICT (message_uuid, created_at) DO NOTHING`

// skeletonExistsGuardSQL: 唯一键含分区键 created_at, live 行与骨架行的 created_at
// 可能不同 —— 必须显式按 message_uuid 查重, 不能依赖 ON CONFLICT (codex/review C9)。
const skeletonExistsGuardSQL = `SELECT EXISTS (SELECT 1 FROM agent_runs WHERE message_uuid = $1)`

// InsertRunSkeleton is used only by the reconcile worker (D8). It never
// overwrites a live row: the live writer wins on conflict.
func (r *Repo) InsertRunSkeleton(ctx context.Context, run *dom.Run) error {
	var exists bool
	if err := r.pool.QueryRow(ctx, skeletonExistsGuardSQL, run.MessageUUID).Scan(&exists); err != nil {
		return err
	}
	if exists {
		return nil // live 行已在 (任意 created_at) —— 骨架永远让位
	}
	tags := marshalMap(dom.FilterTags(run.Tags))
	_, err := r.pool.Exec(ctx, insertRunSkeletonSQL,
		run.TenantID, run.AccountID, run.DigitalEmployeeID,
		nilIfEmpty(run.ConversationUUID), run.MessageUUID, nilIfEmpty(run.StreamID), run.RoomID,
		run.RuntimeKind, run.TriggerSource, run.Status,
		run.StartedAt, run.CompletedAt, run.DurationMS,
		run.InputTokens, run.OutputTokens, run.TotalTokens, run.UsageSource,
		nilIfEmpty(truncStr(run.Model, 128)), nilIfEmpty(truncStr(run.ErrorCode, 64)), nilIfEmpty(truncStr(run.ErrorMessage, 500)), nilIfEmpty(run.TraceID),
		tags, run.CreatedAt,
	)
	return err
}

const upsertStepSQL = `
INSERT INTO agent_run_steps
  (tenant_id, run_uuid, seq, step_kind, name, status,
   started_at, ended_at, duration_ms,
   ref_kind, ref_uuid, ref_created_at,
   error_message, attrs, created_at)
VALUES ($1, $2, $3, $4, $5, $6,
        $7, $8, $9,
        $10, $11, $12,
        $13, $14::jsonb, $15)
ON CONFLICT (run_uuid, seq, created_at) DO UPDATE SET
  status        = EXCLUDED.status,
  ended_at      = EXCLUDED.ended_at,
  duration_ms   = EXCLUDED.duration_ms,
  error_message = EXCLUDED.error_message,
  attrs         = EXCLUDED.attrs`

// UpsertSteps batch-writes the steps of one run inside a single implicit
// transaction (pgx batch). Steps must carry the run's CreatedAt.
func (r *Repo) UpsertSteps(ctx context.Context, steps []*dom.Step) error {
	if len(steps) == 0 {
		return nil
	}
	batch := &pgx.Batch{}
	for _, s := range steps {
		batch.Queue(upsertStepSQL,
			s.TenantID, s.RunUUID, s.Seq, s.Kind, truncStr(s.Name, 256), s.Status,
			s.StartedAt, s.EndedAt, s.DurationMS,
			nilIfEmpty(s.RefKind), nilIfEmpty(truncStr(s.RefUUID, 128)), s.RefCreatedAt,
			nilIfEmpty(truncStr(s.ErrorMessage, 500)), marshalMap(dom.FilterAttrs(s.Attrs)), s.CreatedAt,
		)
	}
	br := r.pool.SendBatch(ctx, batch)
	defer br.Close()
	for range steps {
		if _, err := br.Exec(); err != nil {
			return err
		}
	}
	return nil
}

const completeA2AStepSQL = `
UPDATE agent_run_steps
SET status = $1,
    ended_at = $2,
    duration_ms = GREATEST(0, (EXTRACT(EPOCH FROM ($2::timestamptz - started_at)) * 1000)::int),
    error_message = COALESCE($3, error_message)
WHERE tenant_id = $4 AND ref_kind = 'a2a_edge' AND ref_uuid = $5 AND status = 'running'
RETURNING run_uuid, created_at`

const bumpRunErrorSQL = `
UPDATE agent_runs
SET tool_error_count = tool_error_count + 1, updated_at = now()
WHERE uuid = $1 AND created_at = $2`

// CompleteA2AStep closes the a2a_invoke step referencing edgeUUID after the
// edge reaches a terminal state later than the caller run's finalize (F24
// §3.1-5). Idempotent: only rows still in 'running' match; repeat callbacks
// are no-ops. On error status the owning run's tool_error_count is bumped.
// 返回 updated=false 表示没有可收敛的 running 行 (可能 step 尚未落库 —— 调用方
// 可有界重试, 最终由 reconcile sweeper 兜底收敛)。
func (r *Repo) CompleteA2AStep(ctx context.Context, tenantID int64, edgeUUID, status string, endedAt time.Time, errMsg string) (bool, error) {
	var runUUID string
	var runCreatedAt time.Time
	err := r.pool.QueryRow(ctx, completeA2AStepSQL,
		status, endedAt, nilIfEmpty(truncStr(errMsg, 500)), tenantID, edgeUUID,
	).Scan(&runUUID, &runCreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil // already closed or step not yet persisted
	}
	if err != nil {
		return false, err
	}
	if status == dom.StepError {
		if _, err := r.pool.Exec(ctx, bumpRunErrorSQL, runUUID, runCreatedAt); err != nil {
			return true, err
		}
	}
	return true, nil
}

const closeAwaitingRunSQL = `
UPDATE agent_runs
SET status = 'completed',
    hitl_wait_ms = COALESCE(hitl_wait_ms, 0)
        + GREATEST(0, (EXTRACT(EPOCH FROM ($2::timestamptz - COALESCE(completed_at, updated_at))) * 1000)::int),
    updated_at = now()
WHERE message_uuid = $3 AND tenant_id = $1 AND status = 'awaiting_user'`

// CloseAwaitingRun settles a HITL run when the user responds: the awaiting
// message is claimed → final, so its run becomes completed and hitl_wait_ms
// captures pause→respond (excluded from duration_ms — F24 §3.4). Idempotent:
// only awaiting rows match.
// 返回 updated=false 表示 awaiting 行尚未落库 (Flush 异步写还没到) —— 调用方可
// 有界重试, 最终由 reconcile sweeper 按 messages 终态兜底收敛。
func (r *Repo) CloseAwaitingRun(ctx context.Context, tenantID int64, messageUUID string, respondedAt time.Time) (bool, error) {
	tag, err := r.pool.Exec(ctx, closeAwaitingRunSQL, tenantID, respondedAt, messageUUID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

// MissingRunMessage is one finalized agent message lacking an agent_runs row.
type MissingRunMessage struct {
	MessageUUID      string
	TenantID         int64
	ConversationUUID string
	AccountID        *int64
	SenderAgentID    *int64
	RoomID           *int64
	StreamID         string
	Status           string
	ErrorCode        string
	ErrorMessage     string
	TraceID          string
	UsageJSON        []byte
	BlocksJSON       []byte
	CreatedAt        time.Time
	UpdatedAt        time.Time
}

const missingRunsSQL = `
SELECT m.uuid, m.tenant_id, c.uuid, c.account_id, m.sender_agent_id, m.room_id,
       COALESCE(m.stream_id, ''), m.status,
       COALESCE(m.error_code, ''), COALESCE(m.error_message, ''), COALESCE(m.trace_id, ''),
       m.metadata->'usage',
       m.blocks,
       m.created_at, m.updated_at
FROM messages m
JOIN conversations c ON c.id = m.conversation_id
LEFT JOIN agent_runs ar ON ar.message_uuid = m.uuid
WHERE m.role = 'agent'
  AND m.status IN ('final', 'failed', 'cancelled')
  AND m.created_at >= $1 AND m.created_at < $2
  AND ar.message_uuid IS NULL
ORDER BY m.created_at
LIMIT $3`

// FindMessagesMissingRuns returns finalized agent messages in [since, until)
// that have no agent_runs row — input for the reconcile backfill (D8).
func (r *Repo) FindMessagesMissingRuns(ctx context.Context, since, until time.Time, limit int) ([]*MissingRunMessage, error) {
	rows, err := r.pool.Query(ctx, missingRunsSQL, since, until, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*MissingRunMessage
	for rows.Next() {
		m := &MissingRunMessage{}
		if err := rows.Scan(
			&m.MessageUUID, &m.TenantID, &m.ConversationUUID, &m.AccountID, &m.SenderAgentID, &m.RoomID,
			&m.StreamID, &m.Status,
			&m.ErrorCode, &m.ErrorMessage, &m.TraceID,
			&m.UsageJSON, &m.BlocksJSON,
			&m.CreatedAt, &m.UpdatedAt,
		); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func marshalMap(m map[string]any) string {
	if len(m) == 0 {
		return "{}"
	}
	b, err := json.Marshal(m)
	if err != nil {
		return "{}"
	}
	return string(b)
}

func nilIfEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// truncStr caps s at n BYTES without splitting a UTF-8 rune mid-sequence —
// a mid-rune cut produces invalid UTF-8 and Postgres rejects the whole INSERT
// (which would silently drop the run in the fire-and-forget path).
func truncStr(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

const convergeA2AStepsSQL = `
UPDATE agent_run_steps s
SET status = CASE WHEN e.status = 'done' THEN 'ok' ELSE 'error' END,
    ended_at = COALESCE(e.completed_at, now()),
    duration_ms = GREATEST(0, (EXTRACT(EPOCH FROM (COALESCE(e.completed_at, now()) - s.started_at)) * 1000)::int)
FROM a2a_call_edges e
WHERE s.step_kind = 'a2a_invoke' AND s.status = 'running'
  AND s.created_at >= $1
  AND e.tenant_id = s.tenant_id AND e.uuid::text = s.ref_uuid
  AND e.status IN ('done','failed','cancelled','rejected','expired','dropped_loop','dropped_budget','dropped_whitelist')
  AND COALESCE(e.completed_at, e.created_at) < now() - interval '2 minutes'`

// ConvergeA2ASteps closes a2a_invoke steps whose edge reached a terminal state
// but whose callback lost the ordering race with the async step insert (F24
// review C2/B1). 2-minute settle window lets the fast callback path win first.
func (r *Repo) ConvergeA2ASteps(ctx context.Context, since time.Time) (int64, error) {
	tag, err := r.pool.Exec(ctx, convergeA2AStepsSQL, since)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

const closeStaleAwaitingRunsSQL = `
UPDATE agent_runs ar
SET status = 'completed',
    hitl_wait_ms = COALESCE(ar.hitl_wait_ms, 0)
        + GREATEST(0, (EXTRACT(EPOCH FROM (m.updated_at - COALESCE(ar.completed_at, ar.started_at))) * 1000)::int),
    updated_at = now()
FROM messages m
WHERE ar.status = 'awaiting_user'
  AND ar.created_at >= $1
  AND m.uuid = ar.message_uuid
  AND m.status IN ('final', 'cancelled', 'failed')
  AND m.updated_at < now() - interval '2 minutes'`

// CloseStaleAwaitingRuns settles awaiting runs whose message already left the
// awaiting state but whose CloseAwaitingRun callback raced the async insert
// (F24 review C3). hitl_wait anchors on the message's terminal timestamp.
func (r *Repo) CloseStaleAwaitingRuns(ctx context.Context, since time.Time) (int64, error) {
	tag, err := r.pool.Exec(ctx, closeStaleAwaitingRunsSQL, since)
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// marshalFallbackChain returns nil (SQL NULL) for an empty chain so a plain run
// is distinguishable from one that retried and happened to end on slot 0.
func marshalFallbackChain(steps []dom.FallbackStep) any {
	if len(steps) == 0 {
		return nil
	}
	raw, err := json.Marshal(steps)
	if err != nil {
		return nil
	}
	return string(raw)
}
