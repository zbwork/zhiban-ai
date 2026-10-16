package event

import "context"

// Transaction is the minimal commit/rollback boundary for audited operations.
type Transaction interface {
	Commit(context.Context) error
	Rollback(context.Context) error
	Wrap() Tx
}
type TransactionBeginner func(context.Context) (Transaction, error)
