package sysuser

import (
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

func TestListSysUserWhereKeepsTenantAdminsOut(t *testing.T) {
	whereSQL, args := listSysUserWhere("")

	if len(args) != 0 {
		t.Fatalf("expected no keyword args, got %v", args)
	}
	for _, want := range []string{
		"aa.deleted_at IS NULL",
		"a.deleted_at IS NULL",
		"aa.is_platform = true",
		"pra.scope_kind = 'platform'",
		"tenant_memberships tm",
		"tra.scope_kind = 'tenant'",
	} {
		if !strings.Contains(whereSQL, want) {
			t.Fatalf("whereSQL missing %q:\n%s", want, whereSQL)
		}
	}
}

func TestListSysUserWhereKeyword(t *testing.T) {
	whereSQL, args := listSysUserWhere("  李  ")

	if len(args) != 1 || args[0] != "%李%" {
		t.Fatalf("unexpected keyword args: %v", args)
	}
	if !strings.Contains(whereSQL, "a.display_name ILIKE $1") {
		t.Fatalf("whereSQL missing keyword predicate:\n%s", whereSQL)
	}
}

func TestTranslateSysUserPgErrorUniqueViolations(t *testing.T) {
	tests := []struct {
		name       string
		constraint string
		want       string
	}{
		{name: "phone", constraint: "accounts_phone_key", want: "手机号已存在"},
		{name: "username", constraint: "accounts_username_key", want: "用户名已存在"},
		{name: "email", constraint: "accounts_email_key", want: "邮箱已存在"},
		{name: "admin account", constraint: "admin_accounts_account_id_key", want: "该账号已是系统用户"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := translateSysUserPgError(&pgconn.PgError{Code: "23505", ConstraintName: tt.constraint})

			app, ok := apperr.AsError(err)
			if !ok {
				t.Fatalf("expected app error, got %T %v", err, err)
			}
			if app.Code != apperr.Conflict {
				t.Fatalf("expected conflict, got %v", app.Code)
			}
			if !strings.Contains(app.Message, tt.want) {
				t.Fatalf("expected message containing %q, got %q", tt.want, app.Message)
			}
		})
	}
}

func TestTranslateSysUserPgErrorLeavesOtherErrors(t *testing.T) {
	raw := errors.New("boom")

	if got := translateSysUserPgError(raw); got != raw {
		t.Fatalf("expected original error, got %v", got)
	}
}
