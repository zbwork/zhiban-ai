package supportfeedback

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/supportfeedback"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

func (r *Repo) Create(ctx context.Context, in dom.CreateInput) (*dom.Feedback, error) {
	const q = `
		INSERT INTO support_feedback (
			tenant_id, account_id, agent_id, conversation_id, message_id,
			source, category, priority, status, title, description, page_url,
			client_info, attachments
		) VALUES (
			$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,COALESCE($13,'{}'::jsonb),COALESCE($14,'[]'::jsonb)
		)
		RETURNING id, uuid::text, tenant_id, account_id, agent_id, conversation_id, message_id,
		          source, category, priority, status, title, description, COALESCE(page_url,''),
		          client_info, attachments, assigned_to, assigned_at, COALESCE(handler_note,''),
		          handled_by, handled_at, created_at, updated_at`
	return scanFeedback(r.pool.QueryRow(ctx, q,
		in.TenantID, in.AccountID, in.AgentID, in.ConversationID, in.MessageID,
		in.Source, in.Category, in.Priority, in.Status, in.Title, in.Description, nullString(in.PageURL),
		jsonParam(in.ClientInfo, "{}"), jsonParam(in.Attachments, "[]"),
	))
}

func (r *Repo) LastByConversationBeforeMessage(ctx context.Context, conversationID, beforeMessageID int64) (*dom.Feedback, error) {
	const q = `
		SELECT id, uuid::text, tenant_id, account_id, agent_id, conversation_id, message_id,
		       source, category, priority, status, title, description, COALESCE(page_url,''),
		       client_info, attachments, assigned_to, assigned_at, COALESCE(handler_note,''),
		       handled_by, handled_at, created_at, updated_at
		  FROM support_feedback
		 WHERE conversation_id = $1
		   AND message_id IS NOT NULL
		   AND message_id < $2
		   AND is_deleted = false
		 ORDER BY message_id DESC
		 LIMIT 1`
	return scanFeedback(r.pool.QueryRow(ctx, q, conversationID, beforeMessageID))
}

func (r *Repo) ListPlatform(ctx context.Context, f dom.Filter) ([]dom.Feedback, int64, error) {
	where := []string{"sf.is_deleted = false"}
	args := []any{}
	add := func(cond string, val any) {
		args = append(args, val)
		where = append(where, fmt.Sprintf(cond, len(args)))
	}
	if f.TenantID > 0 {
		add("sf.tenant_id = $%d", f.TenantID)
	}
	if f.Status != "" {
		add("sf.status = $%d", f.Status)
	}
	if f.Category != "" {
		add("sf.category = $%d", f.Category)
	}
	if f.Priority != "" {
		add("sf.priority = $%d", f.Priority)
	}
	if f.Keyword != "" {
		args = append(args, "%"+f.Keyword+"%")
		n := len(args)
		where = append(where, fmt.Sprintf("(sf.title ILIKE $%d OR sf.description ILIKE $%d)", n, n))
	}
	whereSQL := strings.Join(where, " AND ")

	var total int64
	if err := r.pool.QueryRow(ctx, `SELECT count(*) FROM support_feedback sf WHERE `+whereSQL, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("supportfeedback.ListPlatform count: %w", err)
	}

	args = append(args, f.Limit, f.Offset)
	q := fmt.Sprintf(`
		SELECT sf.id, sf.uuid::text, sf.tenant_id, COALESCE(t.name, ''),
		       sf.account_id, COALESCE(a.display_name, a.email, ''),
		       sf.agent_id, COALESCE(de.name, ''), sf.conversation_id, sf.message_id,
		       sf.source, sf.category, sf.priority, sf.status, sf.title, sf.description,
		       COALESCE(sf.page_url,''), sf.client_info, sf.attachments, COALESCE(sf.handler_note,''),
		       sf.assigned_to, COALESCE(ass.display_name, ass.email, ''), sf.assigned_at,
		       sf.handled_by, COALESCE(h.display_name, h.email, ''), sf.handled_at,
		       sf.created_at, sf.updated_at
		  FROM support_feedback sf
		  JOIN tenants t ON t.id = sf.tenant_id
		  LEFT JOIN accounts a ON a.id = sf.account_id
		  LEFT JOIN digital_employees de ON de.id = sf.agent_id
		  LEFT JOIN accounts ass ON ass.id = sf.assigned_to
		  LEFT JOIN accounts h ON h.id = sf.handled_by
		 WHERE %s
		 ORDER BY sf.created_at DESC
		 LIMIT $%d OFFSET $%d`, whereSQL, len(args)-1, len(args))

	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("supportfeedback.ListPlatform query: %w", err)
	}
	defer rows.Close()
	out := make([]dom.Feedback, 0)
	for rows.Next() {
		item, err := scanFeedbackWithNames(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, *item)
	}
	return out, total, rows.Err()
}

func (r *Repo) UpdatePlatform(ctx context.Context, uuid string, actorID int64, in dom.UpdateInput) (*dom.Feedback, error) {
	var assignedTo any
	if in.AssignedToSet && in.AssignedTo != nil {
		if err := r.ensurePlatformAssignee(ctx, *in.AssignedTo); err != nil {
			return nil, err
		}
		assignedTo = *in.AssignedTo
	}
	const q = `
		WITH updated AS (
			UPDATE support_feedback
			   SET status = COALESCE(NULLIF($2, ''), status),
			       priority = COALESCE(NULLIF($3, ''), priority),
			       handler_note = $4,
			       handled_by = $5,
			       handled_at = now(),
			       assigned_to = CASE WHEN $6::boolean THEN $7::bigint ELSE assigned_to END,
			       assigned_at = CASE WHEN $6::boolean THEN now() ELSE assigned_at END,
			       updated_at = now()
			 WHERE uuid = $1
			   AND is_deleted = false
			 RETURNING *
		)
		SELECT sf.id, sf.uuid::text, sf.tenant_id, COALESCE(t.name, ''),
		       sf.account_id, COALESCE(a.display_name, a.email, ''),
		       sf.agent_id, COALESCE(de.name, ''), sf.conversation_id, sf.message_id,
		       sf.source, sf.category, sf.priority, sf.status, sf.title, sf.description,
		       COALESCE(sf.page_url,''), sf.client_info, sf.attachments, COALESCE(sf.handler_note,''),
		       sf.assigned_to, COALESCE(ass.display_name, ass.email, ''), sf.assigned_at,
		       sf.handled_by, COALESCE(h.display_name, h.email, ''), sf.handled_at,
		       sf.created_at, sf.updated_at
		  FROM updated sf
		  JOIN tenants t ON t.id = sf.tenant_id
		  LEFT JOIN accounts a ON a.id = sf.account_id
		  LEFT JOIN digital_employees de ON de.id = sf.agent_id
		  LEFT JOIN accounts ass ON ass.id = sf.assigned_to
		  LEFT JOIN accounts h ON h.id = sf.handled_by`
	item, err := scanFeedbackWithNames(r.pool.QueryRow(ctx, q, uuid, in.Status, in.Priority, in.HandlerNote, actorID, in.AssignedToSet, assignedTo))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound.Withf("support feedback not found")
	}
	if err != nil {
		return nil, fmt.Errorf("supportfeedback.UpdatePlatform: %w", err)
	}
	return item, nil
}

func scanFeedback(row pgx.Row) (*dom.Feedback, error) {
	var item dom.Feedback
	var accountID, agentID, conversationID, messageID, assignedTo, handledBy pgtype.Int8
	var assignedAt, handledAt pgtype.Timestamptz
	var clientInfoBytes, attachmentsBytes []byte
	if err := row.Scan(
		&item.ID, &item.UUID, &item.TenantID, &accountID, &agentID, &conversationID, &messageID,
		&item.Source, &item.Category, &item.Priority, &item.Status, &item.Title, &item.Description, &item.PageURL,
		&clientInfoBytes, &attachmentsBytes, &assignedTo, &assignedAt, &item.HandlerNote, &handledBy, &handledAt,
		&item.CreatedAt, &item.UpdatedAt,
	); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("support feedback not found")
		}
		return nil, err
	}
	fillNullable(&item, accountID, agentID, conversationID, messageID, assignedTo, assignedAt, handledBy, handledAt)
	fillJSON(&item, clientInfoBytes, attachmentsBytes)
	return &item, nil
}

func scanFeedbackWithNames(row pgx.Row) (*dom.Feedback, error) {
	var item dom.Feedback
	var accountID, agentID, conversationID, messageID, assignedTo, handledBy pgtype.Int8
	var assignedAt, handledAt pgtype.Timestamptz
	var clientInfoBytes, attachmentsBytes []byte
	if err := row.Scan(
		&item.ID, &item.UUID, &item.TenantID, &item.TenantName,
		&accountID, &item.AccountName, &agentID, &item.AgentName, &conversationID, &messageID,
		&item.Source, &item.Category, &item.Priority, &item.Status, &item.Title, &item.Description,
		&item.PageURL, &clientInfoBytes, &attachmentsBytes, &item.HandlerNote,
		&assignedTo, &item.AssignedToName, &assignedAt, &handledBy, &item.HandledByName, &handledAt,
		&item.CreatedAt, &item.UpdatedAt,
	); err != nil {
		return nil, err
	}
	fillNullable(&item, accountID, agentID, conversationID, messageID, assignedTo, assignedAt, handledBy, handledAt)
	fillJSON(&item, clientInfoBytes, attachmentsBytes)
	return &item, nil
}

func fillNullable(item *dom.Feedback, accountID, agentID, conversationID, messageID, assignedTo pgtype.Int8, assignedAt pgtype.Timestamptz, handledBy pgtype.Int8, handledAt pgtype.Timestamptz) {
	if accountID.Valid {
		item.AccountID = ptrInt64(accountID.Int64)
	}
	if agentID.Valid {
		item.AgentID = ptrInt64(agentID.Int64)
	}
	if conversationID.Valid {
		item.ConversationID = ptrInt64(conversationID.Int64)
	}
	if messageID.Valid {
		item.MessageID = ptrInt64(messageID.Int64)
	}
	if assignedTo.Valid {
		item.AssignedTo = ptrInt64(assignedTo.Int64)
	}
	if assignedAt.Valid {
		t := assignedAt.Time
		item.AssignedAt = &t
	}
	if handledBy.Valid {
		item.HandledBy = ptrInt64(handledBy.Int64)
	}
	if handledAt.Valid {
		t := handledAt.Time
		item.HandledAt = &t
	}
}

func fillJSON(item *dom.Feedback, clientInfoBytes, attachmentsBytes []byte) {
	if len(clientInfoBytes) > 0 {
		_ = json.Unmarshal(clientInfoBytes, &item.ClientInfo)
	}
	if item.ClientInfo == nil {
		item.ClientInfo = map[string]any{}
	}
	if len(attachmentsBytes) > 0 {
		_ = json.Unmarshal(attachmentsBytes, &item.Attachments)
	}
	if item.Attachments == nil {
		item.Attachments = []any{}
	}
}

func jsonParam(v any, fallback string) any {
	if v == nil {
		return fallback
	}
	b, err := json.Marshal(v)
	if err != nil {
		return fallback
	}
	return string(b)
}

func nullString(s string) any {
	if s == "" {
		return nil
	}
	return s
}

const platformAssigneePredicate = `(
    aa.is_platform = true
    OR EXISTS (
      SELECT 1
        FROM role_assignments pra
       WHERE pra.account_id = a.id
         AND pra.scope_kind = 'platform'
         AND pra.deleted_at IS NULL
    )
    OR (
      NOT EXISTS (
        SELECT 1
          FROM tenant_memberships tm
         WHERE tm.account_id = a.id
           AND tm.deleted_at IS NULL
      )
      AND NOT EXISTS (
        SELECT 1
          FROM role_assignments tra
         WHERE tra.account_id = a.id
           AND tra.scope_kind = 'tenant'
           AND tra.deleted_at IS NULL
      )
    )
  )`

func (r *Repo) ensurePlatformAssignee(ctx context.Context, accountID int64) error {
	var ok bool
	err := r.pool.QueryRow(ctx, `
SELECT EXISTS (
  SELECT 1
    FROM admin_accounts aa
    JOIN accounts a ON a.id = aa.account_id
   WHERE aa.account_id = $1
     AND aa.deleted_at IS NULL
     AND a.deleted_at IS NULL
     AND a.status = 'active'
     AND `+platformAssigneePredicate+`
)`, accountID).Scan(&ok)
	if err != nil {
		return fmt.Errorf("supportfeedback.ensurePlatformAssignee: %w", err)
	}
	if !ok {
		return dom.ErrInvalidAssignee
	}
	return nil
}

func ptrInt64(v int64) *int64 { return &v }

var _ dom.Repository = (*Repo)(nil)
