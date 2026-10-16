package skill

import (
	"strings"
	"testing"
)

func TestCommunityColumnsExcludeCommercialTables(t *testing.T) {
	got := NewCommunity(nil).columns()
	for _, name := range []string{"skill_default_prices", "skill_operations", "s.billing_type"} {
		if strings.Contains(got, name) {
			t.Fatalf("community projection contains %s", name)
		}
	}
	if !strings.Contains(got, "'free'") {
		t.Fatal("community projection must be free")
	}
	if New(nil).columns() != skillCols {
		t.Fatal("default projection changed")
	}
}
