package sysuser

import (
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// fakeRow 实现 pgx.Row，用于在无 DB 情况下驱动 scanUser 的错误分支。
type fakeRow struct{ err error }

func (r fakeRow) Scan(dest ...any) error { return r.err }

// TestScanUserMapsNoRowsToNotFound 回归 QA-2026-07-02 BUG-2:
// 查不到系统用户时 scanUser 必须返回 NotFound(4040)，而不是把 pgx.ErrNoRows
// 透到 transport 被兜底包装成 500 internal error。Get 走 scanUser，故此路径被覆盖。
func TestScanUserMapsNoRowsToNotFound(t *testing.T) {
	_, err := scanUser(fakeRow{err: pgx.ErrNoRows})
	var ae *apperr.Error
	if !errors.As(err, &ae) || ae.Code != apperr.NotFound {
		t.Fatalf("expected NotFound(4040) for no-rows, got %v", err)
	}
}

// TestScanUserPassesThroughOtherErrors 保证只映射 no-rows；其它错误原样透出，
// 不被误判成 NotFound（否则会掩盖真实内部错误）。
func TestScanUserPassesThroughOtherErrors(t *testing.T) {
	sentinel := errors.New("boom")
	_, err := scanUser(fakeRow{err: sentinel})
	if !errors.Is(err, sentinel) {
		t.Fatalf("non-norows error should pass through unchanged, got %v", err)
	}
	var ae *apperr.Error
	if errors.As(err, &ae) && ae.Code == apperr.NotFound {
		t.Fatalf("non-norows error must not be mapped to NotFound")
	}
}
