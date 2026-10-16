package tenant

import (
	"context"
	"time"
)

// Tenant 租户。
type Tenant struct {
	ID          int64
	UUID        string
	Name        string
	Slug        string
	DisplayName string
	Description string
	IconURL     string
	Industry    string
	OwnerID     *int64
	Status      string
	Timezone    string // F08 R11 · cron 默认时区 fallback (IANA name; CreateJob 不传 timezone 时回退到此)
	// PlanID 是旧 tenants.plan_id 的只读迁移字段，不再参与现行套餐读写。
	PlanID *int64
	// InitialPlanID 只用于平台创建租户时选择 plans.id；不持久化到 tenants.plan_id。
	InitialPlanID *int64
	// EffectivePlan* 是计费侧当前生效订阅 (subscriptions.status IN trialing/active/past_due) 对应的套餐，
	// 是租户当前套餐的唯一展示口径。List 与 GetByID 查询都会填充。
	EffectivePlanID   *int64
	EffectivePlanCode string
	EffectivePlanName string
	Brand             map[string]any
	Metadata          map[string]any
	CreatedAt         time.Time
	UpdatedAt         time.Time
}

// Repository 持久化接口。
type Repository interface {
	GetByID(ctx context.Context, id int64) (*Tenant, error)
	GetByUUID(ctx context.Context, uuid string) (*Tenant, error)
	GetBySlug(ctx context.Context, slug string) (*Tenant, error)
	Create(ctx context.Context, t *Tenant) (*Tenant, error)
	Update(ctx context.Context, t *Tenant) (*Tenant, error)
	List(ctx context.Context, status, keyword string, limit, offset int) ([]Tenant, int64, error)
	Delete(ctx context.Context, id int64) error
}
