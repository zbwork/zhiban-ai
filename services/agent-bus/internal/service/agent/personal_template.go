package agent

import (
	"context"
	"strings"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// Templates are configurations, not executable local identities.
func normalizeTemplateExecution(e, existing *dom.DigitalEmployee) error {
	if e.ExecutionLocus == "" {
		e.ExecutionLocus = "cloud"
		if existing != nil && existing.ExecutionLocus != "" {
			e.ExecutionLocus = existing.ExecutionLocus
		}
	}
	switch e.ExecutionLocus {
	case "cloud":
		if e.LocalEngine != "" {
			return apperr.ErrInvalidParams.Withf("云端模板不能指定本地引擎")
		}
	case "local":
		if isSupportBuiltinAgent(e) {
			return apperr.ErrInvalidParams.Withf("内置客服不能配置为本地模板")
		}
		if e.RuntimeEnvironmentID != nil {
			return apperr.ErrInvalidParams.Withf("本地模板不能绑定云端运行环境")
		}
		if e.LocalEngine == "" {
			e.LocalEngine = "dsh"
			if existing != nil && existing.LocalEngine != "" {
				e.LocalEngine = existing.LocalEngine
			}
		}
		if e.LocalEngine != "dsh" && e.LocalEngine != "codex_app_server" {
			return apperr.ErrInvalidParams.Withf("本地引擎仅支持 dsh/codex_app_server")
		}
		delete(e.Metadata, "agent_key")
	default:
		return apperr.ErrInvalidParams.Withf("execution_locus 仅支持 cloud/local")
	}
	return nil
}

// CreatePersonalFromTemplate uses the current published blueprint, never a caller-supplied
// tenant, creator, runtime identity, credential or capability list. Runtime authorization
// is resolved by the transport before this call and checked against the template again.
func (s *impl) CreatePersonalFromTemplate(ctx context.Context, accountID, tenantID int64, templateUUID, updatedAt string, input *dom.DigitalEmployee) (*dom.DigitalEmployee, error) {
	if accountID <= 0 || tenantID <= 0 {
		return nil, apperr.ErrForbidden
	}
	tpl, err := s.GetPublishedPlatformTemplate(ctx, templateUUID)
	if err != nil {
		return nil, err
	}
	expected, err := time.Parse(time.RFC3339Nano, updatedAt)
	if err != nil || !expected.Equal(tpl.UpdatedAt) {
		return nil, apperr.ErrConflict.Withf("模板已更新，请重新选择模板")
	}
	if isOrchestratorTemplate(*tpl) || isSupportBuiltinAgent(tpl) {
		return nil, apperr.ErrInvalidParams.Withf("该模板不支持创建个人员工")
	}
	locus := tpl.ExecutionLocus
	if locus == "" {
		locus = "cloud"
	}
	if input.ExecutionLocus != locus || input.LocalEngine != tpl.LocalEngine || !sameRuntimeID(input.RuntimeEnvironmentID, tpl.RuntimeEnvironmentID) {
		return nil, apperr.ErrInvalidParams.Withf("运行配置必须与所选模板一致，请重新选择模板")
	}
	e := *input
	e.ID, e.UUID, e.CurrentVersion = 0, "", 0
	e.Source, e.Visibility, e.Status = "personal", "private", "draft"
	e.WorkspaceID, e.IsSystem = nil, false
	e.ToolAllow, e.ToolDeny = cloneStrings(tpl.ToolAllow), cloneStrings(tpl.ToolDeny)
	e.Temperature, e.ContextWindow = tpl.Temperature, tpl.ContextWindow
	e.RecommendedQuestions = cloneStrings(tpl.RecommendedQuestions)
	// Member model configuration is initialized by the ordinary client creation path.
	e.A2ACardJSON = tpl.A2ACardJSON
	e.CallableByAgentsJSON = ""
	e.Metadata = map[string]any{"agent_kind": "single", MetadataTemplateSourceKey: tpl.UUID,
		"template_source_version": tpl.CurrentVersion, "template_source_updated_at": tpl.UpdatedAt.Format(time.RFC3339Nano)}
	if prompt, ok := input.Metadata["system_prompt"].(string); ok {
		e.Metadata["system_prompt"] = prompt
	}
	if access, ok := input.Metadata["allow_internet_access"].(bool); ok {
		e.Metadata["allow_internet_access"] = access
	}
	out, err := s.Create(ctx, accountID, tenantID, &e)
	if err != nil {
		return nil, err
	}
	// Failed inheritance never leaves a published, partially assembled employee.
	fail := func(err error) (*dom.DigitalEmployee, error) {
		if cleanupErr := s.Delete(ctx, accountID, tenantID, out.ID); cleanupErr != nil {
			return nil, apperr.ErrInternal.Withf("模板能力继承失败，草稿 %s 清理失败，请在数字员工列表删除后重试", out.UUID)
		}
		return nil, err
	}
	binds, err := s.repo.ListBindings(ctx, tpl.ID)
	if err != nil {
		return fail(err)
	}
	for _, b := range binds {
		if b.CapabilityKind != "app" && b.CapabilityKind != "composer_skill" {
			continue
		}
		b.ID, b.DigitalEmpID, b.AgentVersionID, b.Source = 0, out.ID, nil, "borrow"
		if _, err := s.repo.AddBinding(ctx, &b); err != nil {
			return fail(err)
		}
	}
	if copier, ok := s.repo.(platformAppBindingCopier); ok {
		if err := copier.CopyPlatformAppBindings(ctx, tpl.ID, out.ID); err != nil {
			return fail(err)
		}
	} else {
		for _, b := range binds {
			if b.CapabilityKind == "app" {
				return fail(apperr.ErrInternal.Withf("模板应用复制服务不可用"))
			}
		}
	}
	_, skippedSkills := s.copyTemplateSkillBindings(ctx, tpl.ID, out.ID, accountID)
	_, skippedKBs := s.copyTemplateKBBindings(ctx, tpl.ID, out.ID, accountID, true)
	skipped := append(skippedSkills, skippedKBs...)
	if len(skipped) > 0 {
		return fail(apperr.ErrInvalidParams.Withf("模板能力当前不可用：%s", strings.Join(skipped, ", ")))
	}
	latest, err := s.GetPublishedPlatformTemplate(ctx, templateUUID)
	if err != nil {
		return fail(err)
	}
	if !latest.UpdatedAt.Equal(tpl.UpdatedAt) || latest.CurrentVersion != tpl.CurrentVersion {
		return fail(apperr.ErrConflict.Withf("模板已更新，请重新选择模板"))
	}
	return out, nil
}

func sameRuntimeID(a, b *int64) bool {
	return (a == nil && b == nil) || (a != nil && b != nil && *a == *b)
}

type platformAppBindingCopier interface {
	CopyPlatformAppBindings(context.Context, int64, int64) error
}
