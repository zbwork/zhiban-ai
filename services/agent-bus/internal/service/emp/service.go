// Package emp 是 EMP block registry 的 admin 服务 (Batch 3D T3.10).
//
// 4 个端点对应 (4 个全部走 EMP service, 不再分裂到 Platform):
//
//	GET    /api/admin/v1/platform/emp-blocks       perm=platform.emp.read   → List
//	GET    /api/admin/v1/platform/emp-blocks/{id}  perm=platform.emp.read   → Get
//	POST   /api/admin/v1/platform/emp-blocks       perm=platform.emp.create → Create
//	PATCH  /api/admin/v1/platform/emp-blocks/{id}  perm=platform.emp.update → Update
//
// 写接口 (Create/Update) 的 pg_notify 由 repo 在 INSERT/UPDATE 同 tx 内执行 (3D 返修 #1):
// PG transactional NOTIFY 保证 commit 后才广播, commit 失败 NOTIFY 不发, ROLLBACK 时
// row 与 notify 都不生效. service 层不再持 Notifier.
package emp

import (
	"context"
	"errors"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/empblock"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// 3D Codex review 返修 #1 错误码: fallback_block_type 指向 unknown/draft/deprecated
// (或非空但找不到) → 拒绝 Create/Update.
const ErrCodeFallbackInvalid = "emp.fallback_block_type_invalid"

// Service admin EMP block 服务.
type Service interface {
	List(ctx context.Context) ([]dom.Block, error)
	Get(ctx context.Context, id int64) (*dom.Block, error)
	Create(ctx context.Context, in dom.CreateInput) (*dom.Block, error)
	Update(ctx context.Context, id int64, in dom.UpdateInput) (*dom.Block, error)
}

type impl struct {
	logger *log.Logger
	repo   dom.Repository
}

// New 构造 emp service. NOTIFY 由 repo 在 INSERT/UPDATE 同 tx 内完成 (3D 返修 #1),
// 不再需要 Notifier 依赖.
func New(logger *log.Logger, repo dom.Repository) Service {
	return &impl{logger: logger, repo: repo}
}

func (s *impl) List(ctx context.Context) ([]dom.Block, error) {
	return s.repo.List(ctx)
}

func (s *impl) Get(ctx context.Context, id int64) (*dom.Block, error) {
	return s.repo.GetByID(ctx, id)
}

func (s *impl) Create(ctx context.Context, in dom.CreateInput) (*dom.Block, error) {
	if in.Code == "" {
		return nil, apperr.ErrInvalidParams.Withf("code required")
	}
	if in.Name == "" {
		return nil, apperr.ErrInvalidParams.Withf("name required")
	}
	if in.Category == "" {
		return nil, apperr.ErrInvalidParams.Withf("category required")
	}
	switch in.Category {
	case "content", "interactive", "process", "artifact":
	default:
		return nil, apperr.ErrInvalidParams.Withf("category must be content/interactive/process/artifact, got %q", in.Category)
	}
	if in.Version <= 0 {
		in.Version = 1
	}
	if in.Status == "" {
		in.Status = dom.StatusDraft
	}
	switch in.Status {
	case dom.StatusDraft, dom.StatusStable, dom.StatusDeprecated:
	default:
		return nil, apperr.ErrInvalidParams.Withf("status must be draft/stable/deprecated, got %q", in.Status)
	}
	if in.FallbackBlockType == "" {
		in.FallbackBlockType = "markdown"
	}
	// 3D Codex review 返修 #1: fallback_block_type 必须指向 emp_block_registry 里
	// status='stable' 的 row. 注意允许自指 (in.Code == in.FallbackBlockType) 仅当新 row
	// 自己也是 stable 时; Create 时新 row 还没落库, 所以自指必须额外允许 (validator 不会
	// 死循环, 因为它一旦命中自己就直接用自身 stable 渲染).
	if err := s.assertFallbackOK(ctx, in.FallbackBlockType, in.Code, in.Status); err != nil {
		return nil, err
	}
	// 3D 返修 #1: NOTIFY 由 repo.Create 在同 tx 内执行 + commit; commit 失败时 row 与
	// NOTIFY 都不生效, service 这一层不再需要单独触发.
	return s.repo.Create(ctx, in)
}

func (s *impl) Update(ctx context.Context, id int64, in dom.UpdateInput) (*dom.Block, error) {
	if in.Status != nil {
		switch *in.Status {
		case dom.StatusDraft, dom.StatusStable, dom.StatusDeprecated:
		default:
			return nil, apperr.ErrInvalidParams.Withf("status must be draft/stable/deprecated, got %q", *in.Status)
		}
	}
	if in.Category != nil {
		switch *in.Category {
		case "content", "interactive", "process", "artifact":
		default:
			return nil, apperr.ErrInvalidParams.Withf("category invalid, got %q", *in.Category)
		}
	}
	// 3D Codex review 返修 #2: in.Status 或 in.FallbackBlockType 任一变化都重新评估
	// (effFallback, effStatus) 跑 assertFallbackOK; 防止 self-ref stable 的行 PATCH
	// 自己 status 到 draft/deprecated 后, fallback_block_type 还指向自身 (现在已经不是
	// stable) 留下不可消解的 fallback 链.
	if in.Status != nil || in.FallbackBlockType != nil {
		cur, err := s.repo.GetByID(ctx, id)
		if err != nil {
			return nil, err
		}
		effFallback := cur.FallbackBlockType
		if in.FallbackBlockType != nil {
			effFallback = *in.FallbackBlockType
		}
		effStatus := cur.Status
		if in.Status != nil {
			effStatus = *in.Status
		}
		if err := s.assertFallbackOK(ctx, effFallback, cur.Code, effStatus); err != nil {
			return nil, err
		}
	}
	// 3D 返修 #1: NOTIFY 由 repo.Update 在同 tx 内执行.
	return s.repo.Update(ctx, id, in)
}

// assertFallbackOK 3D Codex review 返修 #1:
//
//   - 空 fallback → 调用方应当先默认 "markdown"; 进入这里时已经被填好.
//   - 自指 (fallback == selfCode): 仅当 selfStatus=='stable' 时允许 (新行也是 stable 即可).
//     注意 Create 时 selfStatus 是入参里的目标 status, 不查 DB; Update 时是 PATCH 后值.
//   - 其它情况: 查 DB; 必须 (code, version=1) 存在 + status='stable'.
//     unknown / draft / deprecated → 拒, 返 emp.fallback_block_type_invalid.
//
// 不允许跨 version 引 (3D 全部 18 row 都是 v1; 后续多版本需扩接口).
func (s *impl) assertFallbackOK(ctx context.Context, fallback, selfCode, selfStatus string) error {
	if fallback == "" {
		// caller 在调用前已经 default 成 "markdown"; 进到这里空串视为编程错误.
		return apperr.New(apperr.InvalidParams, ErrCodeFallbackInvalid).Withf("fallback_block_type must not be empty")
	}
	if fallback == selfCode {
		if selfStatus == dom.StatusStable {
			return nil
		}
		return apperr.New(apperr.InvalidParams, ErrCodeFallbackInvalid).Withf(
			"self-referential fallback only allowed when own status='stable', got %q", selfStatus)
	}
	target, err := s.repo.GetByCode(ctx, fallback, 1)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			return apperr.New(apperr.InvalidParams, ErrCodeFallbackInvalid).Withf(
				"fallback_block_type %q does not exist in emp_block_registry", fallback)
		}
		return apperr.ErrInternal.Wrap(err)
	}
	if target.Status != dom.StatusStable {
		return apperr.New(apperr.InvalidParams, ErrCodeFallbackInvalid).Withf(
			"fallback_block_type %q has status=%q, must be stable", fallback, target.Status)
	}
	return nil
}

// (notify helper 已移除: NOTIFY 由 repo.Create / repo.Update 在同 tx 内执行)
