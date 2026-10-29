package modelsource

import (
	"context"
	"encoding/hex"
	"encoding/json"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/modelsource"
)

func (s *Service) reconcileManaged(ctx context.Context, scope dom.Scope) ([]dom.Stored, error) {
	if s.unmanagedBeeBridge {
		return s.repo.List(ctx, scope)
	}
	return s.repo.Reconcile(ctx, scope, func(rows []dom.Stored) ([]dom.Stored, error) {
		selected := -1
		canonical := -1
		configs := make(map[int]dom.Config)
		for i, row := range rows {
			c, err := s.decode(scope, row)
			if err != nil {
				return nil, err
			}
			if row.SourceID == managedBeeBridgeSourceID && c.CatalogID != "beebridge" {
				return nil, dom.ErrConfiguration
			}
			if c.CatalogID != "beebridge" {
				continue
			}
			configs[i] = c
			selected = i // Repository order: oldest to newest.
			if row.SourceID == managedBeeBridgeSourceID {
				canonical = i
			}
		}
		if canonical >= 0 {
			selected = canonical
		}
		if selected < 0 {
			return nil, nil
		}
		changes := []dom.Stored{}
		winner := rows[selected]
		if winner.SourceID != managedBeeBridgeSourceID {
			cfg := configs[selected]
			cfg.ID = managedBeeBridgeSourceID
			cfg.Enabled = winner.Enabled
			raw, err := json.Marshal(struct {
				Scope  dom.Scope
				Config dom.Config
			}{scope, cfg})
			if err != nil {
				return nil, err
			}
			encrypted, err := s.cipher.Encrypt(raw)
			if err != nil {
				return nil, err
			}
			winner.SourceID = managedBeeBridgeSourceID
			winner.Ciphertext = encrypted
			winner.Fingerprint = hex.EncodeToString(s.mac(raw))
			changes = append(changes, winner)
		}
		for i, row := range rows {
			if _, managed := configs[i]; managed && i != selected && row.Enabled {
				row.Enabled = false
				changes = append(changes, row)
			}
		}
		return changes, nil
	})
}
