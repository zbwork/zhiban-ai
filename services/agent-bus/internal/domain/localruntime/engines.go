package localruntime

import "context"

const EngineDSH = "dsh"
const EngineCodex = "codex_app_server"

// EngineRepository stores only host-reported availability; it does not grant execution authority.
type EngineRepository interface {
	SetEngines(context.Context, Scope, string, map[string]string) error
}

func SupportsEngine(device *Device, engine string) bool {
	if engine == "" {
		engine = EngineDSH
	}
	if device == nil {
		return false
	}
	if device.Engines == nil {
		return engine == EngineDSH
	}
	return device.Engines[engine] != ""
}
