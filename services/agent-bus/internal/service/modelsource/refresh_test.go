package modelsource

import (
	"context"
	"errors"
	bee "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/beebridge"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	"reflect"
	"testing"
)

type catalogKeys struct {
	keys
	models []bee.Model
	err    error
	after  func()
	scope  dom.Scope
}

func (c catalogKeys) MemberModels(_ context.Context, t, a int64) ([]bee.Model, error) {
	if (dom.Scope{TenantID: t, AccountID: a}) != c.scope {
		return nil, dom.ErrDenied
	}
	if c.after != nil {
		c.after()
	}
	return c.models, c.err
}
func (r *memoryRepo) UpdateCatalog(ctx context.Context, s dom.Scope, expected *dom.Stored, value dom.Stored) (bool, error) {
	if s != r.scope {
		return false, dom.ErrDenied
	}
	index := -1
	for i, row := range r.rows {
		if row.SourceID == value.SourceID {
			index = i
		}
	}
	if expected == nil {
		if index >= 0 {
			return false, nil
		}
	} else if index < 0 || r.rows[index].Version != expected.Version || r.rows[index].Fingerprint != expected.Fingerprint {
		return false, nil
	}
	rows := append([]dom.Stored(nil), r.rows...)
	if index < 0 {
		rows = append(rows, value)
	} else {
		rows[index] = value
	}
	_, err := r.Replace(ctx, s, rows)
	return err == nil, err
}
func TestRefreshManagedPreservesSettingsAndRemovesOldSelection(t *testing.T) {
	s, r, other := fixture(t)
	ctx := context.Background()
	cfg := other
	cfg.ID = "managed"
	cfg.CatalogID = "beebridge"
	cfg.Models = []dom.Model{{ID: "keep", Label: "自定义", Enabled: true, ToolUse: true}, {ID: "disabled", Label: "保留关闭", Enabled: false}, {ID: "removed", Enabled: true}}
	initial, err := s.Sync(ctx, r.scope, []dom.Config{other, cfg})
	if err != nil {
		t.Fatal(err)
	}
	beforeOther := r.rows[0]
	selected := initial[1].ID
	removed := initial[2].ID
	bound, err := s.BindSelection(ctx, r.scope, selected)
	if err != nil {
		t.Fatal(err)
	}
	s.keys = catalogKeys{scope: r.scope, models: []bee.Model{{ID: "keep"}, {ID: "new"}, {ID: "disabled"}, {ID: "bge-m3"}}}
	out, err := s.RefreshManaged(ctx, r.scope)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(beforeOther, r.rows[0]) {
		t.Fatal("unrelated source changed")
	}
	if len(out.Models) != 4 || out.Models[0].Label != "自定义" || out.Models[1].Enabled {
		t.Fatalf("settings lost: %+v", out.Models)
	}
	if _, err = s.Resolve(ctx, r.scope, selected); err != nil {
		t.Fatal("valid selection lost", err)
	}
	if _, err = s.Resolve(ctx, r.scope, bound); err != nil {
		t.Fatal("unchanged execution binding invalidated", err)
	}
	if _, err = s.Resolve(ctx, r.scope, removed); err == nil {
		t.Fatal("removed model can still execute")
	}
	for _, o := range out.Items {
		if o.ModelID == "bge-m3" || o.ModelID == "removed" {
			t.Fatal("invalid chat item", o)
		}
	}
	version := r.rows[1].Version
	if _, err = s.RefreshManaged(ctx, r.scope); err != nil || r.rows[1].Version != version {
		t.Fatal("unchanged refresh changed revision", err)
	}
	s.keys = catalogKeys{scope: r.scope, models: []bee.Model{}}
	out, err = s.RefreshManaged(ctx, r.scope)
	if err != nil || len(out.Models) != 0 || len(out.Items) != 1 {
		t.Fatal("empty catalog not applied", out, err)
	}
}
func TestRefreshFailureAndConcurrentEditDoNotOverwrite(t *testing.T) {
	for _, tc := range []struct {
		name   string
		models []bee.Model
		err    error
		edit   bool
	}{
		{name: "remote error", err: errors.New("unavailable")},
		{name: "null catalog"}, {name: "invalid row", models: []bee.Model{{ID: ""}}},
		{name: "concurrent edit", models: []bee.Model{{ID: "new"}}, edit: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, r, c := fixture(t)
			c.CatalogID = "beebridge"
			if _, err := s.Sync(context.Background(), r.scope, []dom.Config{c}); err != nil {
				t.Fatal(err)
			}
			original := append([]dom.Stored(nil), r.rows...)
			k := catalogKeys{scope: r.scope, models: tc.models, err: tc.err}
			if tc.edit {
				k.after = func() { r.rows[0].Version++; original[0].Version++ }
			}
			s.keys = k
			if _, err := s.RefreshManaged(context.Background(), r.scope); err == nil {
				t.Fatal("refresh should fail")
			}
			if !reflect.DeepEqual(r.rows, original) {
				t.Fatal("failed refresh overwrote settings")
			}
			if _, err := s.RefreshManaged(context.Background(), dom.Scope{TenantID: 999, AccountID: 2}); err == nil {
				t.Fatal("cross-tenant refresh allowed")
			}
		})
	}
}

func TestRefreshDoesNotReactivateDisabledStoredSource(t *testing.T) {
	s, r, c := fixture(t)
	c.CatalogID = "beebridge"
	if _, err := s.Sync(context.Background(), r.scope, []dom.Config{c}); err != nil {
		t.Fatal(err)
	}
	// Legacy source retirement changes the storage flag without re-encrypting.
	r.rows[0].Enabled = false
	s.keys = catalogKeys{scope: r.scope, models: []bee.Model{{ID: "new"}}}
	out, err := s.RefreshManaged(context.Background(), r.scope)
	if err != nil || out.Enabled || len(out.Items) != 0 {
		t.Fatal("refresh re-enabled a disabled source", out, err)
	}
}
