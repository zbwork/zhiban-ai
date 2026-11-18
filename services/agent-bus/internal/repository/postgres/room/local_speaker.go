package room

import (
	"context"
	"encoding/json"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/room"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// AdvanceLocalSpeaker prevents two senders from advancing the same round-robin turn.
func (r *Repo) AdvanceLocalSpeaker(ctx context.Context, tenantID, roomID int64, policy dom.SpeakerPolicy, previous, next map[string]any) error {
	oldValue, err := json.Marshal(previous)
	if err != nil {
		return err
	}
	newValue, err := json.Marshal(next)
	if err != nil {
		return err
	}
	tag, err := r.pool.Exec(ctx, `
		UPDATE rooms
		   SET speaker_policy_config=COALESCE(speaker_policy_config,'{}'::jsonb) || $5::jsonb
		 WHERE tenant_id=$1 AND id=$2 AND speaker_policy=$3 AND status='active' AND deleted_at IS NULL
		   AND COALESCE(speaker_policy_config,'{}'::jsonb)=COALESCE(NULLIF($4::jsonb,'null'::jsonb),'{}'::jsonb)
	`, tenantID, roomID, string(policy), string(oldValue), string(newValue))
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.New(apperr.Conflict, "群聊响应策略刚刚更新，请重试发送")
	}
	return nil
}

// ApplyLocalSpeaker uses a published tenant template and resets the per-room round-robin cursor.
func (r *Repo) ApplyLocalSpeaker(ctx context.Context, tenantID int64, roomUUID, policyUUID string) error {
	tag, err := r.pool.Exec(ctx, `
		UPDATE rooms r SET speaker_policy=p.base_policy, manager_agent_id=p.manager_agent_id,
		       speaker_policy_config=COALESCE(p.selector_config,'{}'::jsonb) - 'last_idx'
		         || jsonb_build_object('template_uuid',p.uuid::text),
		       updated_at=now()
		  FROM speaker_policies p
		 WHERE r.tenant_id=$1 AND r.uuid=$2 AND r.room_kind='group' AND r.deleted_at IS NULL
		   AND p.tenant_id=r.tenant_id AND p.uuid=$3 AND NOT p.is_deleted
		   AND p.base_policy IN ('manual','manager','round_robin')
		   AND (p.base_policy<>'manager' OR EXISTS (
		       SELECT 1 FROM room_participants part
		       WHERE part.room_id=r.id AND part.agent_id=p.manager_agent_id AND part.left_at IS NULL))
	`, tenantID, roomUUID, policyUUID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.New(apperr.PreconditionFailed, "请使用本租户可用的响应策略，且主持人须在群内")
	}
	return nil
}
