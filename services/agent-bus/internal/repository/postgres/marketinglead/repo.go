package marketinglead

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/marketinglead"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

type Repo struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Repo {
	return &Repo{pool: pool}
}

func (r *Repo) Create(ctx context.Context, in dom.CreateInput) (*dom.Lead, error) {
	const q = `
		INSERT INTO marketing_contact_leads (
			contact_name, phone, company, message, source, page_url, ip_hash, user_agent
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
		RETURNING id, uuid::text, contact_name, phone, company, message, source, page_url,
		          status, assigned_to, assigned_at, handled_by, handled_at, remark,
		          ip_hash, user_agent, created_at, updated_at`
	return scanLead(r.pool.QueryRow(ctx, q,
		in.ContactName, in.Phone, in.Company, in.Message, in.Source, in.PageURL, in.IPHash, in.UserAgent,
	))
}

func (r *Repo) ListPlatform(ctx context.Context, f dom.Filter) ([]dom.Lead, int64, error) {
	where := []string{"mcl.is_deleted = false"}
	args := []any{}
	add := func(cond string, val any) {
		args = append(args, val)
		where = append(where, fmt.Sprintf(cond, len(args)))
	}
	if f.Status != "" {
		add("mcl.status = $%d", f.Status)
	}
	if f.CreatedGTE != nil {
		add("mcl.created_at >= $%d", *f.CreatedGTE)
	}
	if f.CreatedLTE != nil {
		add("mcl.created_at <= $%d", *f.CreatedLTE)
	}
	if f.Keyword != "" {
		args = append(args, "%"+f.Keyword+"%")
		n := len(args)
		where = append(where, fmt.Sprintf("(mcl.contact_name ILIKE $%d OR mcl.phone ILIKE $%d OR mcl.company ILIKE $%d OR mcl.message ILIKE $%d)", n, n, n, n))
	}
	whereSQL := strings.Join(where, " AND ")

	var total int64
	if err := r.pool.QueryRow(ctx, `SELECT count(*) FROM marketing_contact_leads mcl WHERE `+whereSQL, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("marketinglead.ListPlatform count: %w", err)
	}

	args = append(args, f.Limit, f.Offset)
	q := fmt.Sprintf(`
		SELECT mcl.id, mcl.uuid::text, mcl.contact_name, mcl.phone, mcl.company, mcl.message,
		       mcl.source, mcl.page_url, mcl.status,
		       mcl.assigned_to, COALESCE(ass.display_name, ass.email, ''),
		       mcl.assigned_at, mcl.handled_by, COALESCE(h.display_name, h.email, ''),
		       mcl.handled_at, mcl.remark, mcl.ip_hash, mcl.user_agent,
		       mcl.created_at, mcl.updated_at
		  FROM marketing_contact_leads mcl
		  LEFT JOIN accounts ass ON ass.id = mcl.assigned_to
		  LEFT JOIN accounts h ON h.id = mcl.handled_by
		 WHERE %s
		 ORDER BY mcl.created_at DESC
		 LIMIT $%d OFFSET $%d`, whereSQL, len(args)-1, len(args))
	rows, err := r.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("marketinglead.ListPlatform query: %w", err)
	}
	defer rows.Close()
	out := make([]dom.Lead, 0)
	for rows.Next() {
		item, err := scanLeadWithNames(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, *item)
	}
	return out, total, rows.Err()
}

func (r *Repo) UpdatePlatform(ctx context.Context, uuid string, actorID int64, in dom.UpdateInput) (*dom.Lead, error) {
	var assignedTo any
	if in.AssignedToSet && in.AssignedTo != nil {
		if err := r.ensurePlatformAssignee(ctx, *in.AssignedTo); err != nil {
			return nil, err
		}
		assignedTo = *in.AssignedTo
	}
	const q = `
		WITH updated AS (
			UPDATE marketing_contact_leads
			   SET status = COALESCE(NULLIF($2, ''), status),
			       remark = $3,
			       handled_by = $4,
			       handled_at = now(),
			       assigned_to = CASE WHEN $5::boolean THEN $6::bigint ELSE assigned_to END,
			       assigned_at = CASE WHEN $5::boolean THEN now() ELSE assigned_at END,
			       updated_at = now()
			 WHERE uuid = $1
			   AND is_deleted = false
			 RETURNING *
		)
		SELECT mcl.id, mcl.uuid::text, mcl.contact_name, mcl.phone, mcl.company, mcl.message,
		       mcl.source, mcl.page_url, mcl.status,
		       mcl.assigned_to, COALESCE(ass.display_name, ass.email, ''),
		       mcl.assigned_at, mcl.handled_by, COALESCE(h.display_name, h.email, ''),
		       mcl.handled_at, mcl.remark, mcl.ip_hash, mcl.user_agent,
		       mcl.created_at, mcl.updated_at
		  FROM updated mcl
		  LEFT JOIN accounts ass ON ass.id = mcl.assigned_to
		  LEFT JOIN accounts h ON h.id = mcl.handled_by`
	item, err := scanLeadWithNames(r.pool.QueryRow(ctx, q, uuid, in.Status, in.Remark, actorID, in.AssignedToSet, assignedTo))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound.Withf("marketing lead not found")
	}
	if err != nil {
		return nil, fmt.Errorf("marketinglead.UpdatePlatform: %w", err)
	}
	return item, nil
}

func scanLead(row pgx.Row) (*dom.Lead, error) {
	var item dom.Lead
	var assignedTo, handledBy pgtype.Int8
	var assignedAt, handledAt pgtype.Timestamptz
	if err := row.Scan(
		&item.ID, &item.UUID, &item.ContactName, &item.Phone, &item.Company, &item.Message,
		&item.Source, &item.PageURL, &item.Status, &assignedTo, &assignedAt, &handledBy, &handledAt,
		&item.Remark, &item.IPHash, &item.UserAgent, &item.CreatedAt, &item.UpdatedAt,
	); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("marketing lead not found")
		}
		return nil, err
	}
	fillNullable(&item, assignedTo, assignedAt, handledBy, handledAt)
	item.PhoneMasked = dom.MaskPhone(item.Phone)
	return &item, nil
}

func scanLeadWithNames(row pgx.Row) (*dom.Lead, error) {
	var item dom.Lead
	var assignedTo, handledBy pgtype.Int8
	var assignedAt, handledAt pgtype.Timestamptz
	if err := row.Scan(
		&item.ID, &item.UUID, &item.ContactName, &item.Phone, &item.Company, &item.Message,
		&item.Source, &item.PageURL, &item.Status,
		&assignedTo, &item.AssignedToName, &assignedAt, &handledBy, &item.HandledByName, &handledAt,
		&item.Remark, &item.IPHash, &item.UserAgent, &item.CreatedAt, &item.UpdatedAt,
	); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound.Withf("marketing lead not found")
		}
		return nil, err
	}
	fillNullable(&item, assignedTo, assignedAt, handledBy, handledAt)
	item.PhoneMasked = dom.MaskPhone(item.Phone)
	return &item, nil
}

func fillNullable(item *dom.Lead, assignedTo pgtype.Int8, assignedAt pgtype.Timestamptz, handledBy pgtype.Int8, handledAt pgtype.Timestamptz) {
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
		return fmt.Errorf("marketinglead.ensurePlatformAssignee: %w", err)
	}
	if !ok {
		return dom.ErrInvalidAssignee
	}
	return nil
}

func ptrInt64(v int64) *int64 { return &v }

var _ dom.Repository = (*Repo)(nil)
