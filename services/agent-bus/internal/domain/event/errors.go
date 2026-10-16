package event

import "errors"

// ErrDuplicate 表示 IdempotencyKey 冲突，事件已存在（视为已发，业务一般忽略即可）。
var ErrDuplicate = errors.New("event: duplicate idempotency_key")
