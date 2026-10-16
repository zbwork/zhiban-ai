package agent

import (
	"errors"

	"github.com/jackc/pgx/v5/pgconn"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// translatePgErr 把 Postgres SQLSTATE 翻成 apperr 类型, 给上层返回友好的 4xx。
//
// 目前只翻 23505 unique violation; 其它原样返回。
func translatePgErr(err error) error {
	if err == nil {
		return nil
	}
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		switch pg.Code {
		case "23505":
			return apperr.ErrConflict.Withf("已存在: %s", pg.ConstraintName)
		}
	}
	return err
}
