// Package empblock 是 emp_block_registry 的领域类型与持久化接口 (Batch 3D T3.10).
//
// 现有 schema 见 migration 000006 / 000008; 3D reconcile migration 000029 把权限切到
// 细粒度 (platform.emp.{read,create,update}), 内容侧仅做规范化, 不破坏 18 条 system seed.
package empblock

import (
	"context"
	"time"
)

// Status 枚举 (与 emp_block_registry.status CHECK 一致).
const (
	StatusDraft      = "draft"
	StatusStable     = "stable"
	StatusDeprecated = "deprecated"
)

// Block 一行 emp_block_registry.
type Block struct {
	ID                int64
	Code              string
	Version           int
	Name              string
	Category          string
	JSONSchema        map[string]any
	Status            string
	MinClientVersion  string
	FallbackBlockType string
	BreakingChanges   string
	DeprecatedAt      *time.Time
	EOLDate           *time.Time
	Description       string
	IsSystem          bool
	CreatedAt         time.Time
	UpdatedAt         time.Time
}

// UpdateInput PATCH 入参; 字段为 *T 表示 "未传 → 不动".
type UpdateInput struct {
	Name              *string
	Category          *string
	JSONSchema        *map[string]any
	Status            *string
	MinClientVersion  *string
	FallbackBlockType *string
	BreakingChanges   *string
	Description       *string
}

// CreateInput POST 入参. 所有字段必填 (Status/MinClientVersion/FallbackBlockType 可走默认).
type CreateInput struct {
	Code              string
	Version           int
	Name              string
	Category          string
	JSONSchema        map[string]any
	Status            string
	MinClientVersion  string
	FallbackBlockType string
	Description       string
}

// Repository emp_block_registry 持久化窄接口.
type Repository interface {
	// List 全表 + 按 category, code 排序; admin 列表用.
	List(ctx context.Context) ([]Block, error)

	// GetByID / GetByCode 找单行.
	GetByID(ctx context.Context, id int64) (*Block, error)
	GetByCode(ctx context.Context, code string, version int) (*Block, error)

	// Create / Update 配合 admin 写接口; 调用后 caller 负责发 pg_notify('config_change', 'emp_block_registry:<id>')
	// 让 bus 进程 emp listener 失效缓存.
	Create(ctx context.Context, in CreateInput) (*Block, error)
	Update(ctx context.Context, id int64, in UpdateInput) (*Block, error)
}
