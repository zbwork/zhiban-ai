package agent

import (
	"github.com/google/uuid"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"strings"
)

func normalizeExecutionLocus(e, existing *dom.DigitalEmployee) error {
	e.ExecutionLocus = strings.TrimSpace(e.ExecutionLocus)
	if e.ExecutionLocus == "" {
		e.ExecutionLocus = "cloud"
		if existing != nil && existing.ExecutionLocus != "" {
			e.ExecutionLocus = existing.ExecutionLocus
		}
	}
	switch e.ExecutionLocus {
	case "cloud":
		if e.LocalEngine != "" && (existing == nil || existing.ExecutionLocus != "local") {
			return apperr.ErrInvalidParams.Withf("云端员工不能指定本地引擎")
		}
		e.LocalEngine = ""
		return nil
	case "local":
		if e.LocalEngine == "" {
			e.LocalEngine = "dsh"
			if existing != nil && existing.ExecutionLocus == "local" && existing.LocalEngine != "" {
				e.LocalEngine = existing.LocalEngine
			}
		}
		if e.LocalEngine != "dsh" && e.LocalEngine != "codex_app_server" {
			return apperr.ErrInvalidParams.Withf("本地引擎仅支持 dsh/codex_app_server")
		}
		if existing != nil && existing.ExecutionLocus == "local" {
			previous := existing.LocalEngine
			if previous == "" {
				previous = "dsh"
			}
			if e.LocalEngine != previous {
				return apperr.ErrInvalidParams.Withf("已有本地员工不能切换引擎，请创建新的数字员工")
			}
		}
		if (e.Source != "personal" && e.Source != "enterprise") || e.CreatorID <= 0 {
			return apperr.ErrInvalidParams.Withf("本地执行仅适用于个人或租户数字员工")
		}
		if e.RuntimeEnvironmentID != nil {
			return apperr.ErrInvalidParams.Withf("本地员工不能绑定云端运行环境")
		}
		e.Visibility = "private"
		// Never trust a caller-supplied key or collide on a nullable environment ID.
		key := ""
		if existing != nil && existing.ExecutionLocus == "local" {
			key, _ = existing.Metadata["agent_key"].(string)
		}
		if key == "" {
			key = "local-" + uuid.NewString()
		}
		if e.Metadata == nil {
			e.Metadata = map[string]any{}
		}
		e.Metadata["agent_key"] = key
		return nil
	default:
		return apperr.ErrInvalidParams.Withf("execution_locus 仅支持 cloud/local")
	}
}
