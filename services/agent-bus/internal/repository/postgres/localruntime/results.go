package localruntime

import (
	"context"
	"encoding/json"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
	"reflect"
	"time"
)

// Preserve immutable identities and never regress an already confirmed archive.
func mergeResults(old, next []map[string]any) ([]map[string]any, error) {
	if len(old) == 0 {
		return next, nil
	}
	if len(old) != len(next) {
		return nil, dom.ErrConflict
	}
	byID := map[string]map[string]any{}
	for _, b := range old {
		ref, _ := b["local_artifact"].(map[string]any)
		id, _ := ref["artifact_id"].(string)
		byID[id] = b
	}
	out := make([]map[string]any, 0, len(next))
	seen := map[string]bool{}
	for _, b := range next {
		ref, _ := b["local_artifact"].(map[string]any)
		id, _ := ref["artifact_id"].(string)
		prev := byID[id]
		if prev == nil || seen[id] {
			return nil, dom.ErrConflict
		}
		seen[id] = true
		for _, key := range []string{"type", "name", "size", "mime", "local_artifact"} {
			if !reflect.DeepEqual(prev[key], b[key]) {
				return nil, dom.ErrConflict
			}
		}
		if prev["archive_status"] == "synced" {
			out = append(out, prev)
		} else {
			out = append(out, b)
		}
	}
	return out, nil
}

func (r *Repo) SaveResults(ctx context.Context, scope dom.Scope, deviceID string, generation int64, run string, fence int64, blocks []map[string]any) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	dev, err := device(ctx, tx, scope, deviceID, true)
	if err != nil {
		return err
	}
	if dev.Generation != generation || time.Since(dev.SeenAt) > 15*time.Second {
		return dom.ErrOffline
	}
	task, err := scanTask(tx.QueryRow(ctx, `SELECT `+taskCols+taskFrom+` WHERE q.uuid=$1 AND q.account_id=$2 AND q.tenant_id=$3 AND q.login_session_uuid=$4 AND q.device_uuid=$5 AND q.fence=$6 AND `+taskEmployeeValid+` FOR UPDATE OF q`, run, scope.AccountID, scope.TenantID, scope.SessionUUID, deviceID, fence))
	if err != nil {
		return err
	}
	if (task.Status != "completed" && task.Status != "failed" && task.Status != "cancelled") || task.ExpiresAt.Add(7*24*time.Hour).Before(time.Now()) {
		return dom.ErrConflict
	}
	var payload struct {
		Results []map[string]any `json:"local_results"`
	}
	if json.Unmarshal(task.Payload, &payload) != nil {
		return dom.ErrDenied
	}
	merged, err := mergeResults(payload.Results, blocks)
	if err != nil {
		return err
	}
	raw, err := json.Marshal(merged)
	if err != nil {
		return err
	}
	cards := make([]map[string]any, 0, len(merged))
	for _, block := range merged {
		card := map[string]any{}
		for k, v := range block {
			card[k] = v
		}
		card["x_source"] = "local_result"
		cards = append(cards, card)
	}
	cardRaw, err := json.Marshal(cards)
	if err != nil {
		return err
	}
	// Lock final message before patching. A streaming message is retried after finalization.
	var final bool
	if err = tx.QueryRow(ctx, `SELECT final FROM messages WHERE uuid=$1 AND tenant_id=$2 AND sender_agent_id=$3 FOR UPDATE`, task.MessageUUID, scope.TenantID, task.EmployeeID).Scan(&final); err != nil {
		return err
	}
	if !final {
		return dom.ErrConflict
	}
	_, err = tx.Exec(ctx, `UPDATE messages SET blocks=(SELECT coalesce(jsonb_agg(b),'[]'::jsonb) FROM jsonb_array_elements(coalesce(blocks,'[]'::jsonb)) b WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements($3::jsonb) n WHERE n->'local_artifact'->>'artifact_id'=b->'local_artifact'->>'artifact_id' AND n->'local_artifact'->>'device_id'=b->'local_artifact'->>'device_id')) || $3::jsonb, updated_at=now() WHERE uuid=$1 AND tenant_id=$2`, task.MessageUUID, scope.TenantID, string(cardRaw))
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE local_runtime_tasks SET payload=jsonb_set(payload,'{local_results}',$2::jsonb) WHERE uuid=$1`, run, string(raw))
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}
