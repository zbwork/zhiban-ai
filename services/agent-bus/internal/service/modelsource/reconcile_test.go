package modelsource

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	bee "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/beebridge"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
	"reflect"
	"strings"
	"testing"
)

func seedSource(t *testing.T, s *Service, r *memoryRepo, id string, c dom.Config) dom.Stored {
	t.Helper()
	c.ID = id
	raw, err := json.Marshal(struct {
		Scope  dom.Scope
		Config dom.Config
	}{r.scope, c})
	if err != nil {
		t.Fatal(err)
	}
	encrypted, err := s.cipher.Encrypt(raw)
	if err != nil {
		t.Fatal(err)
	}
	row := dom.Stored{UUID: "uuid-" + strings.ReplaceAll(id, ":", "-"), SourceID: id, Enabled: c.Enabled, Version: 1, Fingerprint: "old-" + id, Ciphertext: encrypted}
	r.rows = append(r.rows, row)
	return row
}

func TestReconcileManagedDuplicates(t *testing.T) {
	for _, canonical := range []bool{false, true} {
		t.Run(map[bool]string{false: "two legacy", true: "canonical and legacy"}[canonical], func(t *testing.T) {
			s, r, c := fixture(t)
			ctx := context.Background()
			c.CatalogID = "beebridge"
			c.Name = "BeeBridge"
			c.Models = []dom.Model{{ID: "gpt-5.6-luna", Label: "My Luna", Enabled: true}, {ID: "gpt-5.6-sol", Enabled: false}}
			winnerID := "latest"
			if canonical {
				winnerID = managedBeeBridgeSourceID
			}
			legacy := c
			legacy.Models = append(append([]dom.Model(nil), c.Models...), dom.Model{ID: "old-only-model", Enabled: true})
			old := seedSource(t, s, r, "old", legacy)
			winner := seedSource(t, s, r, winnerID, c)
			if canonical {
				seedSource(t, s, r, "newer-legacy", c)
			}
			custom := c
			custom.CatalogID = "custom"
			byok := seedSource(t, s, r, "byok", custom)
			items, _, err := s.List(ctx, r.scope)
			if err != nil || len(items) != 2 {
				t.Fatalf("items=%+v err=%v", items, err)
			}
			if items[0].ID != reference(winner, "gpt-5.6-luna") || items[0].SourceID != managedBeeBridgeSourceID || items[0].Label != "My Luna" {
				t.Fatalf("lost identity/settings: %+v", items)
			}
			if items[1].ID != reference(byok, "gpt-5.6-luna") {
				t.Fatal("merged unrelated BYOK")
			}
			snapshot := append([]dom.Stored(nil), r.rows...)
			if _, _, err = s.List(ctx, r.scope); err != nil || !reflect.DeepEqual(snapshot, r.rows) {
				t.Fatal("repeated list changed persisted state", err)
			}
			s.keys = catalogKeys{scope: r.scope, models: []bee.Model{{ID: "gpt-5.6-luna"}, {ID: "gpt-5.6-sol"}}}
			refreshed, err := s.RefreshManaged(ctx, r.scope)
			if err != nil || len(refreshed.Items) != 2 || len(refreshed.Models) != 2 || refreshed.Models[1].Enabled {
				t.Fatal("refresh duplicates or reset preferences", refreshed, err)
			}
			bound, err := s.BindSelection(ctx, r.scope, reference(old, "gpt-5.6-luna"))
			if err != nil {
				t.Fatal("legacy selection rejected", err)
			}
			if SelectionReference(bound) != reference(winner, "gpt-5.6-luna") {
				t.Fatal("binding retained retired source", bound)
			}
			if _, err = s.Resolve(ctx, r.scope, bound); err != nil {
				t.Fatal("new bound route invalid", err)
			}
			legacyBound := "mref:" + old.UUID + ":1:Z3B0LTUuNi1sdW5h"
			if _, err = s.Resolve(ctx, r.scope, legacyBound); !errors.Is(err, dom.ErrDenied) {
				t.Fatal("old execution promoted", err)
			}
			if _, _, err = s.List(ctx, dom.Scope{TenantID: 99, AccountID: 2}); !errors.Is(err, dom.ErrDenied) {
				t.Fatal("cross scope list", err)
			}
			if _, err = s.Resolve(ctx, dom.Scope{TenantID: 1, AccountID: 99}, reference(old, "gpt-5.6-luna")); !errors.Is(err, dom.ErrDenied) {
				t.Fatal("cross scope selection", err)
			}
		})
	}
}

func TestReconcileKeepsCanonicalDisabled(t *testing.T) {
	s, r, c := fixture(t)
	c.CatalogID = "beebridge"
	c.Models = []dom.Model{{ID: "gpt-5.6-luna", Enabled: true}}
	c.Enabled = false
	stable := seedSource(t, s, r, managedBeeBridgeSourceID, c)
	c.Enabled = true
	old := seedSource(t, s, r, "legacy", c)
	items, _, err := s.List(context.Background(), r.scope)
	if err != nil || len(items) != 0 {
		t.Fatal("disabled source resurrected", items, err)
	}
	if !bytes.Equal(stable.Ciphertext, r.rows[0].Ciphertext) || stable.Version != r.rows[0].Version {
		t.Fatal("canonical changed")
	}
	if _, err = s.Resolve(context.Background(), r.scope, reference(old, "gpt-5.6-luna")); !errors.Is(err, dom.ErrDenied) {
		t.Fatal("disabled canonical accepted", err)
	}
}

func TestReconcileRollbackOnInvalidScopeEnvelope(t *testing.T) {
	s, r, c := fixture(t)
	c.CatalogID = "beebridge"
	seedSource(t, s, r, "old", c)
	row := seedSource(t, s, r, "new", c)
	r.rows[1].Ciphertext = []byte("invalid")
	before := append([]dom.Stored(nil), r.rows...)
	if _, _, err := s.List(context.Background(), r.scope); err == nil {
		t.Fatal("invalid ciphertext accepted")
	}
	if !reflect.DeepEqual(before, r.rows) {
		t.Fatal("partially retired sources", row.UUID)
	}
}
