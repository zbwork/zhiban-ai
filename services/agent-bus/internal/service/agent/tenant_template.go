package agent

import (
	"context"
	"strings"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agent"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// CreateTenantFromTemplate creates an independent organization-owned copy after
// revalidating the selected published platform employee and its version.
func (s *impl) CreateTenantFromTemplate(ctx context.Context, accountID, tenantID int64, uuid, updatedAt string, input *dom.DigitalEmployee) (*dom.DigitalEmployee, error) {
	if accountID <= 0 || tenantID <= 0 || input == nil {
		return nil, apperr.ErrForbidden
	}
	tpl, err := s.GetPublishedPlatformTemplate(ctx, uuid)
	if err != nil {
		return nil, err
	}
	if isOrchestratorTemplate(*tpl) {
		return nil, apperr.ErrInvalidParams.Withf("该模板不支持创建租户共享数字员工")
	}
	at, err := time.Parse(time.RFC3339Nano, updatedAt)
	if err != nil || !at.Equal(tpl.UpdatedAt) {
		return nil, apperr.ErrConflict.Withf("模板已更新，请重新选择模板")
	}
	e := *input
	e.Metadata = make(map[string]any, len(input.Metadata)+2)
	for k, v := range input.Metadata {
		e.Metadata[k] = v
	}
	e.Metadata[MetadataTemplateSourceKey] = tpl.UUID
	e.Metadata["template_source_version"] = tpl.CurrentVersion
	e.Metadata["template_source_updated_at"] = tpl.UpdatedAt.Format(time.RFC3339Nano)
	delete(e.Metadata, "agent_key")
	e.ID, e.UUID, e.CurrentVersion = 0, "", 0
	e.Source, e.Status = "enterprise", "draft"
	out, err := s.create(ctx, accountID, tenantID, &e, false)
	if err != nil {
		return nil, err
	}
	fail := func(cause error) (*dom.DigitalEmployee, error) {
		if err := s.Delete(ctx, accountID, tenantID, out.ID); err != nil {
			return nil, apperr.ErrInternal.Withf("模板继承失败，草稿 %s 清理失败，请删除后重试", out.UUID)
		}
		return nil, cause
	}
	binds, err := s.repo.ListBindings(ctx, tpl.ID)
	if err != nil {
		return fail(err)
	}
	for _, binding := range binds {
		if binding.CapabilityKind != "app" && binding.CapabilityKind != "composer_skill" {
			continue
		}
		binding.ID, binding.DigitalEmpID, binding.AgentVersionID, binding.Source = 0, out.ID, nil, "borrow"
		if _, err := s.repo.AddBinding(ctx, &binding); err != nil {
			return fail(err)
		}
	}
	if copier, ok := s.repo.(platformAppBindingCopier); ok {
		if err := copier.CopyPlatformAppBindings(ctx, tpl.ID, out.ID); err != nil {
			return fail(err)
		}
	} else {
		for _, binding := range binds {
			if binding.CapabilityKind == "app" {
				return fail(apperr.ErrInternal.Withf("模板应用复制服务不可用"))
			}
		}
	}
	_, skippedSkills := s.copyTemplateSkillBindings(ctx, tpl.ID, out.ID, accountID)
	_, skippedKBs := s.copyTemplateKBBindings(ctx, tpl.ID, out.ID, accountID, true)
	if skipped := append(skippedSkills, skippedKBs...); len(skipped) > 0 {
		return fail(apperr.ErrInvalidParams.Withf("模板能力当前不可用：%s", strings.Join(skipped, ", ")))
	}
	latest, err := s.GetPublishedPlatformTemplate(ctx, uuid)
	if err != nil {
		return fail(err)
	}
	if !latest.UpdatedAt.Equal(tpl.UpdatedAt) || latest.CurrentVersion != tpl.CurrentVersion {
		return fail(apperr.ErrConflict.Withf("模板已更新，请重新选择模板"))
	}
	return out, nil
}
