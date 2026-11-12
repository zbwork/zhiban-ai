// B-5-1: GET /api/agent-bus/v1/agents/positions · 租户级职位字典 (F01 §1).
//
// 改读 tenant_positions (本租户范围) 替代旧的全局 agent_positions (000057 已 DROP).
// 仍不做权限收口 (字典对所有当前 tenant 成员可见). 字段保留 label 兼容老客户端.
package clientpositions

import (
	"context"
	"net/http"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/encode"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// PositionsPool · 读 tenant_positions 字典. 直接持 *pgxpool.Pool;
// 单点路径不值得抽出 repo 包.
type PositionsPool interface {
	Query(ctx context.Context, sql string, args ...any) (PositionsRows, error)
}

// PositionsRows · pgx.Rows subset.
type PositionsRows interface {
	Next() bool
	Scan(dest ...any) error
	Close()
}

// List GET 处理.
func (h *Handlers) List(w http.ResponseWriter, r *http.Request) {
	if h.Positions == nil {
		encode.JSONError(w, apperr.ErrInternal.Withf("positions pool not wired"))
		return
	}
	tid := middleware.MustTenantID(r.Context())
	rows, err := h.Positions.Query(r.Context(),
		`SELECT uuid::text, name, COALESCE(icon,''), sort_order
		   FROM tenant_positions
		  WHERE tenant_id = $1 AND deleted_at IS NULL
		  ORDER BY sort_order, id`,
		tid,
	)
	if err != nil {
		encode.JSONError(w, apperr.ErrInternal.Wrap(err))
		return
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var uuid, name, icon string
		var sortOrder int
		if err := rows.Scan(&uuid, &name, &icon, &sortOrder); err != nil {
			encode.JSONError(w, apperr.ErrInternal.Wrap(err))
			return
		}
		out = append(out, map[string]any{
			"uuid":       uuid,
			"name":       name,
			"icon":       icon,
			"sort_order": sortOrder,
		})
	}
	encode.JSON(w, map[string]any{"items": out})
}

// PgxPositionsPool · adapter 让 *pgxpool.Pool 满足 PositionsPool 接口.
type PgxPositionsPool struct{ P *pgxpool.Pool }

func (a PgxPositionsPool) Query(ctx context.Context, sql string, args ...any) (PositionsRows, error) {
	r, err := a.P.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return pgxRowsAdapter{r}, nil
}

type pgxRowsAdapter struct {
	r interface {
		Next() bool
		Scan(...any) error
		Close()
	}
}

func (a pgxRowsAdapter) Next() bool          { return a.r.Next() }
func (a pgxRowsAdapter) Scan(d ...any) error { return a.r.Scan(d...) }
func (a pgxRowsAdapter) Close()              { a.r.Close() }
