// Package externalorg defines the original external organization contract.
package externalorg

import (
	"context"
	"time"
)

// ExternalDepartment 对外 DTO — 不含内部 int64 id。
type ExternalDepartment struct {
	ID                string         `json:"id"`
	ParentID          string         `json:"parent_id,omitempty"`
	UUID              string         `json:"-"`
	ParentUUID        string         `json:"-"`
	Name              string         `json:"name"`
	Path              string         `json:"path"`
	Depth             int            `json:"depth"`
	SortOrder         int            `json:"sort_order"`
	ThirdDepartmentID string         `json:"third_department_id,omitempty"`
	ExternalCode      string         `json:"-"`
	MemberCount       int            `json:"member_count"`
	Metadata          map[string]any `json:"metadata,omitempty"`
	Status            string         `json:"status"` // active / deleted (tombstone)
	UpdatedAt         time.Time      `json:"updated_at"`
}

// ExternalMember 对外 DTO — 用 account_id 标识。
type ExternalMember struct {
	AccountID      string    `json:"account_id"`
	DepartmentID   string    `json:"department_id,omitempty"`
	AccountUUID    string    `json:"-"`
	DisplayName    string    `json:"display_name"`
	Email          string    `json:"email,omitempty"`
	Phone          string    `json:"phone,omitempty"`
	ThirdUserID    string    `json:"third_user_id,omitempty"`
	EmployeeID     string    `json:"-"`
	Title          string    `json:"title,omitempty"`
	DepartmentUUID string    `json:"-"`
	Status         string    `json:"status"` // active / invited / suspended / left
	Roles          []string  `json:"roles,omitempty"`
	UpdatedAt      time.Time `json:"updated_at"`
}

// ExternalPosition 对外 DTO。
type ExternalPosition struct {
	ID              string         `json:"id"`
	UUID            string         `json:"-"`
	Name            string         `json:"name"`
	Description     string         `json:"description,omitempty"`
	SortOrder       int            `json:"sort_order"`
	ThirdPositionID string         `json:"third_position_id,omitempty"`
	ExternalCode    string         `json:"-"`
	IsSystem        bool           `json:"is_system"`
	MemberCount     int            `json:"member_count"`
	AgentCount      int            `json:"agent_count"`
	Metadata        map[string]any `json:"metadata,omitempty"`
	Status          string         `json:"status"` // active / deleted
	UpdatedAt       time.Time      `json:"updated_at"`
}

// CursorPage 游标分页响应。
type CursorPage[T any] struct {
	Items      []T    `json:"items"`
	NextCursor string `json:"next_cursor,omitempty"`
	HasMore    bool   `json:"has_more"`
}

// CreateDepartmentInput 创建部门入参。
type CreateDepartmentInput struct {
	Name              string         `json:"name"`
	ParentID          string         `json:"parent_id,omitempty"`
	ParentUUID        string         `json:"-"`
	SortOrder         int            `json:"sort_order"`
	ThirdDepartmentID string         `json:"third_department_id,omitempty"`
	ExternalCode      string         `json:"-"`
	Metadata          map[string]any `json:"metadata,omitempty"`
}

// UpdateDepartmentInput 更新部门入参。
type UpdateDepartmentInput struct {
	Name              *string         `json:"name,omitempty"`
	ParentID          *string         `json:"parent_id,omitempty"`
	ParentUUID        *string         `json:"-"`
	SortOrder         *int            `json:"sort_order,omitempty"`
	ThirdDepartmentID *string         `json:"third_department_id,omitempty"`
	ExternalCode      *string         `json:"-"`
	Metadata          *map[string]any `json:"metadata,omitempty"`
}

// CreateMemberInput 创建/邀请成员入参。
type CreateMemberInput struct {
	Phone          string `json:"phone"`
	Email          string `json:"email"`
	DisplayName    string `json:"display_name"`
	Title          string `json:"title,omitempty"`
	ThirdUserID    string `json:"third_user_id,omitempty"`
	EmployeeID     string `json:"-"`
	DepartmentID   string `json:"department_id,omitempty"`
	DepartmentUUID string `json:"-"`
	RoleCode       string `json:"role_code,omitempty"`
}

// UpdateMemberInput 更新成员入参。
type UpdateMemberInput struct {
	DisplayName    *string `json:"display_name,omitempty"`
	Title          *string `json:"title,omitempty"`
	ThirdUserID    *string `json:"third_user_id,omitempty"`
	EmployeeID     *string `json:"-"`
	DepartmentID   *string `json:"department_id,omitempty"`
	DepartmentUUID *string `json:"-"`
	Status         *string `json:"status,omitempty"`
}

// CreatePositionInput 创建职位入参。
type CreatePositionInput struct {
	Name            string         `json:"name"`
	Description     string         `json:"description,omitempty"`
	SortOrder       int            `json:"sort_order"`
	ThirdPositionID string         `json:"third_position_id,omitempty"`
	ExternalCode    string         `json:"-"`
	Metadata        map[string]any `json:"metadata,omitempty"`
}

// UpdatePositionInput 更新职位入参。
type UpdatePositionInput struct {
	Name            *string         `json:"name,omitempty"`
	Description     *string         `json:"description,omitempty"`
	SortOrder       *int            `json:"sort_order,omitempty"`
	ThirdPositionID *string         `json:"third_position_id,omitempty"`
	ExternalCode    *string         `json:"-"`
	Metadata        *map[string]any `json:"metadata,omitempty"`
}

// Service 外部组织架构 API 业务层。
type Service interface {
	// --- 部门 ---
	ListDepartments(ctx context.Context, tenantID int64, cursor string, limit int, updatedSince *time.Time) (*CursorPage[ExternalDepartment], error)
	GetDepartment(ctx context.Context, tenantID int64, uuid string) (*ExternalDepartment, error)
	CreateDepartment(ctx context.Context, tenantID int64, in CreateDepartmentInput) (*ExternalDepartment, error)
	UpdateDepartment(ctx context.Context, tenantID int64, uuid string, in UpdateDepartmentInput) (*ExternalDepartment, error)
	DeleteDepartment(ctx context.Context, tenantID int64, uuid string) error

	// --- 成员 ---
	ListMembers(ctx context.Context, tenantID int64, cursor string, limit int, updatedSince *time.Time) (*CursorPage[ExternalMember], error)
	GetMember(ctx context.Context, tenantID int64, accountUUID string) (*ExternalMember, error)
	CreateMember(ctx context.Context, tenantID int64, in CreateMemberInput) (*ExternalMember, error)
	UpdateMember(ctx context.Context, tenantID int64, accountUUID string, in UpdateMemberInput) (*ExternalMember, error)
	DeleteMember(ctx context.Context, tenantID int64, accountUUID string) error

	// --- 职位 ---
	ListPositions(ctx context.Context, tenantID int64, cursor string, limit int, updatedSince *time.Time) (*CursorPage[ExternalPosition], error)
	GetPosition(ctx context.Context, tenantID int64, uuid string) (*ExternalPosition, error)
	CreatePosition(ctx context.Context, tenantID int64, in CreatePositionInput) (*ExternalPosition, error)
	UpdatePosition(ctx context.Context, tenantID int64, uuid string, in UpdatePositionInput) (*ExternalPosition, error)
	DeletePosition(ctx context.Context, tenantID int64, uuid string) error
}
