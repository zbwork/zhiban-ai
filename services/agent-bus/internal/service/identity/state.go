// state.go — OIDC state/nonce store (Redis-backed, 5min TTL)。
//
// 防 CSRF: caller 拿 AuthCodeURL 前 Save(state, payload); IdP 回跳后 Pop(state) 拿到 payload
// (包含 expected nonce + 关联的 IdP uuid)。Pop 一次性 (取出即删, 防 replay)。
package identity

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"

	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// StatePayload OIDC 流程跨网络往返时挂在 state 上的数据。
type StatePayload struct {
	ProviderUUID string `json:"provider_uuid"`
	Nonce        string `json:"nonce"`
	// AfterRedirect 用户原本想去的页面 (登陆成功跳回去)。默认 "/dashboard"。
	AfterRedirect string `json:"after_redirect,omitempty"`
}

// StateStore Redis 实现。
type StateStore struct {
	rdb *redis.Client
	ttl time.Duration
}

// NewStateStore 构造; TTL 默认 5min (足够用户完成 IdP 登录跳回)。
func NewStateStore(rdb *redis.Client) *StateStore {
	return &StateStore{rdb: rdb, ttl: 5 * time.Minute}
}

const stateKeyPrefix = "zhiban:oidc:state:"

// Save 写 state → payload, TTL=5min。
func (s *StateStore) Save(ctx context.Context, state string, payload StatePayload) error {
	if state == "" {
		return apperr.ErrInvalidParams.Withf("state required")
	}
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	return s.rdb.Set(ctx, stateKeyPrefix+state, string(b), s.ttl).Err()
}

// Pop 原子取出 + 删; 取不到返 ErrUnauthorized (state 过期 / replay)。
func (s *StateStore) Pop(ctx context.Context, state string) (*StatePayload, error) {
	if state == "" {
		return nil, apperr.ErrUnauthorized.Withf("missing state")
	}
	key := stateKeyPrefix + state
	// 用 GETDEL (Redis 6.2+); 一次性原子取删, 防 replay。
	val, err := s.rdb.GetDel(ctx, key).Result()
	if err != nil {
		if err == redis.Nil {
			return nil, apperr.ErrUnauthorized.Withf("state expired or replayed")
		}
		return nil, fmt.Errorf("oidc state pop: %w", err)
	}
	var p StatePayload
	if err := json.Unmarshal([]byte(val), &p); err != nil {
		return nil, fmt.Errorf("oidc state decode: %w", err)
	}
	return &p, nil
}
