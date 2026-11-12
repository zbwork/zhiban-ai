package admincore

import (
	"strings"
	"testing"
)

// P2 修复防回归 (无 live-DB 基建, 谓词断言看住 SQL 语义):
// Admin a2a_invoke 开关只读写哨兵行 —— 三条件齐 (version NULL + uuid_nil + source='borrow',
// v1b review 返修补齐 source)。关闭时**不**删 versioned 行 / 异常 source 行 / 其它 capability_kind。
func TestA2AInvokeAdminSQLSentinelOnly(t *testing.T) {
	sentinelPreds := []string{
		"capability_kind='a2a_invoke'",
		"agent_version_id IS NULL",
		"capability_uuid=$2::uuid",
		"source='borrow'",
	}
	for name, sql := range map[string]string{
		"get":     a2aInvokeGetSentinelSQL,
		"disable": a2aInvokeDisableSentinelSQL,
	} {
		for _, pred := range sentinelPreds {
			if !strings.Contains(sql, pred) {
				t.Fatalf("%s SQL missing sentinel predicate %q:\n%s", name, pred, sql)
			}
		}
	}
	// enable: 插入形态必须是哨兵行 (version NULL + 哨兵 uuid + borrow), 幂等 WHERE NOT EXISTS
	// 且 NOT EXISTS 同样按三条件 (存在异常 source 行时仍插入合法哨兵行)。
	for _, pred := range []string{
		"SELECT $1, NULL, 'a2a_invoke', $2::uuid, 'borrow'",
		"WHERE NOT EXISTS",
		"agent_version_id IS NULL",
		"source='borrow'",
	} {
		if !strings.Contains(a2aInvokeEnableSentinelSQL, pred) {
			t.Fatalf("enable SQL missing %q:\n%s", pred, a2aInvokeEnableSentinelSQL)
		}
	}
}

// a2a-card PUT: 本租户闸门 + updated_by/updated_at + card_version 服务端原子自增。
func TestA2ACardUpdateSQLPredicates(t *testing.T) {
	for _, pred := range []string{
		"tenant_id=$2",
		"is_deleted=false",
		"updated_by = $4",
		"updated_at = now()",
		"'card_version', COALESCE((a2a_card->>'card_version')::int, 0) + 1",
	} {
		if !strings.Contains(a2aCardUpdateSQL, pred) {
			t.Fatalf("a2aCardUpdateSQL missing %q:\n%s", pred, a2aCardUpdateSQL)
		}
	}
}

// platform preset a2a-card PUT: 只允许平台模板原行,不触碰租户实例。
func TestPlatformPresetA2ACardUpdateSQLPredicates(t *testing.T) {
	for _, pred := range []string{
		"tenant_id IS NULL",
		"source='platform'",
		"visibility='platform'",
		"is_deleted=false",
		"updated_by = $3",
		"updated_at = now()",
		"'card_version', COALESCE((a2a_card->>'card_version')::int, 0) + 1",
	} {
		if !strings.Contains(platformPresetA2ACardUpdateSQL, pred) {
			t.Fatalf("platformPresetA2ACardUpdateSQL missing %q:\n%s", pred, platformPresetA2ACardUpdateSQL)
		}
	}
}
