package localruntime

import (
	"context"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	"strings"
)

func (s *Service) RegisterWithEngines(ctx context.Context, scope dom.Scope, platform, installationID string, version int, engines map[string]string) (*Registration, error) {
	if engines == nil {
		engines = map[string]string{dom.EngineDSH: "legacy"}
	}
	if len(engines) > 2 {
		return nil, dom.ErrDenied
	}
	for name, v := range engines {
		if (name != dom.EngineDSH && name != dom.EngineCodex) || len(v) == 0 || len(v) > 64 || strings.ContainsAny(v, "\r\n\x00") {
			return nil, dom.ErrDenied
		}
	}
	registration, err := s.Register(ctx, scope, platform, installationID, version)
	if err != nil {
		return nil, err
	}
	repository, ok := s.repo.(dom.EngineRepository)
	if !ok {
		if len(engines) != 1 || engines[dom.EngineDSH] == "" {
			return nil, dom.ErrUpgradeRequired
		}
		return registration, nil
	}
	if err = repository.SetEngines(ctx, scope, registration.Device.UUID, engines); err != nil {
		return nil, err
	}
	registration.Device.Engines = engines
	return registration, nil
}
