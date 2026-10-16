package skill

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	domskill "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/skill"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

const MaxBatchDeleteSkills = 100

// BatchSoftDeleteSkills 原子软删除用户明确勾选的平台技能。
// 删除语义与 SoftDeleteSkill 一致：不改 status，不改版本，不删对象存储文件。
func (s *Service) BatchSoftDeleteSkills(ctx context.Context, rawUUIDs []string, accountID int64) ([]domskill.Skill, error) {
	uuids, err := normalizeBatchDeleteUUIDs(rawUUIDs)
	if err != nil {
		return nil, err
	}
	deleted, err := s.repo.BatchSoftDeletePlatformSkills(ctx, uuids)
	if err != nil {
		return nil, err
	}
	for _, item := range deleted {
		s.notifyf(ctx, "skills:%d", item.ID)
	}
	if s.audit != nil {
		codes := make([]string, 0, len(deleted))
		deletedUUIDs := make([]string, 0, len(deleted))
		for _, item := range deleted {
			codes = append(codes, item.Code)
			deletedUUIDs = append(deletedUUIDs, item.UUID)
		}
		_ = s.audit.PublishWithTx(ctx, "audit.skill.batch_delete", 0,
			fmt.Sprintf("skill-batch-delete:%d:%d", accountID, time.Now().UnixNano()),
			map[string]any{
				"event_kind":    "skill.batch_delete",
				"resource_kind": "skill",
				"operator_id":   accountID,
				"skill_count":   len(deleted),
				"skill_uuids":   deletedUUIDs,
				"skill_codes":   codes,
			})
	}
	return deleted, nil
}

func normalizeBatchDeleteUUIDs(raw []string) ([]string, error) {
	if len(raw) == 0 || len(raw) > MaxBatchDeleteSkills {
		return nil, apperr.ErrInvalidParams.Withf("skill.batch_delete_count_must_be_1_to_%d", MaxBatchDeleteSkills)
	}
	seen := make(map[string]bool, len(raw))
	uuids := make([]string, 0, len(raw))
	for _, value := range raw {
		uuid := strings.TrimSpace(value)
		if uuid == "" || seen[uuid] {
			return nil, apperr.ErrInvalidParams.Withf("skill.batch_delete_uuid_empty_or_duplicate")
		}
		seen[uuid] = true
		uuids = append(uuids, uuid)
	}
	sort.Strings(uuids)
	return uuids, nil
}
