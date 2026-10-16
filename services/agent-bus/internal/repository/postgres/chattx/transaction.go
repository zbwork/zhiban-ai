package chattx

import (
	"context"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	domevent "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	event "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/event"
)

type transaction struct{ tx pgx.Tx }

func (t transaction) Commit(ctx context.Context) error   { return t.tx.Commit(ctx) }
func (t transaction) Rollback(ctx context.Context) error { return t.tx.Rollback(ctx) }
func (t transaction) Wrap() domevent.Tx                  { return event.PgTx{Tx: t.tx} }
func Beginner(pool *pgxpool.Pool) domevent.TransactionBeginner {
	return func(ctx context.Context) (domevent.Transaction, error) {
		tx, err := pool.Begin(ctx)
		if err != nil {
			return nil, err
		}
		return transaction{tx}, nil
	}
}
