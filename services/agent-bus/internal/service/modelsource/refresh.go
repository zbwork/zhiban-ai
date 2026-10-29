package modelsource

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"

	bee "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/beebridge"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
)

var ErrRefreshConflict = errors.New("model_source.refresh_conflict")

type MemberCatalog interface {
	MemberModels(context.Context, int64, int64) ([]bee.Model, error)
}
type RefreshedCatalog struct {
	Models  []dom.Model `json:"models"`
	Enabled bool        `json:"enabled"`
	Items   []Option    `json:"items"`
}

// RefreshManaged updates only this member's managed source. A stale fetch must
// never replace a concurrent settings edit or another provider's configuration.
func (s *Service) RefreshManaged(ctx context.Context, scope dom.Scope) (RefreshedCatalog, error) {
	out := RefreshedCatalog{}
	catalog, ok := s.keys.(MemberCatalog)
	writer, writable := s.repo.(interface {
		UpdateCatalog(context.Context, dom.Scope, *dom.Stored, dom.Stored) (bool, error)
	})
	if !ok || !writable || s.cipher == nil || len(s.secret) < 32 {
		return out, dom.ErrConfiguration
	}
	rows, err := s.reconcileManaged(ctx, scope)
	if err != nil {
		return out, err
	}
	cfg := dom.Config{ID: managedBeeBridgeSourceID, CatalogID: "beebridge", Name: "BeeBridge", Enabled: true, Protocol: "openai-compatible", BaseURL: s.memberBase}
	var expected *dom.Stored
	for _, row := range rows {
		c, e := s.decode(scope, row)
		if e != nil {
			return out, e
		}
		if c.CatalogID == "beebridge" && (expected == nil || row.SourceID == managedBeeBridgeSourceID) {
			copy := row
			expected = &copy
			cfg = c
			cfg.ID = row.SourceID
			cfg.Enabled = row.Enabled
		}
	}
	remote, err := catalog.MemberModels(ctx, scope.TenantID, scope.AccountID)
	if err != nil {
		return out, err
	}
	if remote == nil {
		return out, dom.ErrConfiguration
	}
	available := map[string]bee.Model{}
	for _, m := range remote {
		if m.ID == "" || len(m.ID) > 256 {
			return out, dom.ErrConfiguration
		}
		available[m.ID] = m
	}
	next := make([]dom.Model, 0, len(remote))
	for _, m := range cfg.Models {
		if _, ok := available[m.ID]; ok {
			next = append(next, m)
			delete(available, m.ID)
		}
	}
	for _, m := range remote {
		if _, ok := available[m.ID]; !ok {
			continue
		}
		next = append(next, dom.Model{ID: m.ID, Label: m.ID, Enabled: true, ToolUse: m.SupportsChat()})
		delete(available, m.ID)
	}
	cfg.Models = next
	raw, err := json.Marshal(struct {
		Scope  dom.Scope
		Config dom.Config
	}{scope, cfg})
	if err != nil {
		return out, err
	}
	encrypted, err := s.cipher.Encrypt(raw)
	if err != nil {
		return out, err
	}
	value := dom.Stored{SourceID: cfg.ID, Fingerprint: hex.EncodeToString(s.mac(raw)), Enabled: cfg.Enabled, Ciphertext: encrypted}
	applied, err := writer.UpdateCatalog(ctx, scope, expected, value)
	if err != nil {
		return out, err
	}
	if !applied {
		return out, ErrRefreshConflict
	}
	items, _, err := s.List(ctx, scope)
	if err != nil {
		return out, err
	}
	return RefreshedCatalog{Models: next, Enabled: cfg.Enabled, Items: items}, nil
}
