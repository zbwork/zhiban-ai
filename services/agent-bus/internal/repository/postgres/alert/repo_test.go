package alert

import (
	"testing"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/alert"
)

// F25 评审返修回归：notify.alert.* outbox 的租户归属是租户隔离边界——
// 平台 scope 告警绝不携带租户 ID（webhook 分发按 tenant_id fan-out，携带即误投租户）。
func TestOutboxTenantID(t *testing.T) {
	tid := int64(42)
	cases := []struct {
		name  string
		alert dom.Alert
		want  int64
	}{
		{"租户告警带租户", dom.Alert{ScopeKind: dom.ScopeTenant, TenantID: &tid}, 42},
		{"租户告警缺租户(防御)", dom.Alert{ScopeKind: dom.ScopeTenant, TenantID: nil}, 0},
		{"平台告警无租户归属", dom.Alert{ScopeKind: dom.ScopePlatform, TenantID: nil}, 0},
		{"平台告警带租户归属(order_unfulfilled)也不外发", dom.Alert{ScopeKind: dom.ScopePlatform, TenantID: &tid}, 0},
	}
	for _, c := range cases {
		if got := outboxTenantID(&c.alert); got != c.want {
			t.Fatalf("%s: got %d, want %d", c.name, got, c.want)
		}
	}
}
