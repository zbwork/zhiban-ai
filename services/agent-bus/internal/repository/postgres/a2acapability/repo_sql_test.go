package a2acapability

import (
	"strings"
	"testing"
)

// P2 修复防回归 (无 live-DB 基建, 以谓词断言看住 SQL 语义):
// a2a_invoke 是非版本化运行时开关 —— 只认哨兵行 (三条件齐, 含 source='borrow',
// v1b review 返修补齐), versioned 行 / 异常 source 行不算 enabled。
func TestHasA2AInvokeSentinelSQLPredicates(t *testing.T) {
	for _, pred := range []string{
		"capability_kind = 'a2a_invoke'",
		"agent_version_id IS NULL",
		"capability_uuid = $2::uuid",
		"source = 'borrow'",
	} {
		if !strings.Contains(hasA2AInvokeSentinelSQL, pred) {
			t.Fatalf("hasA2AInvokeSentinelSQL missing predicate %q:\n%s", pred, hasA2AInvokeSentinelSQL)
		}
	}
}
