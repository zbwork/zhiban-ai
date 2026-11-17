// Package externalorg composes the original organization implementation through its repository.
package externalorg

import (
	"github.com/jackc/pgx/v5/pgxpool"
	domevt "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/event"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/externalorg"
	repo "github.com/zbwork/zhiban-ai/services/agent-bus/internal/repository/postgres/externalorg"
)

type ExternalDepartment = dom.ExternalDepartment
type ExternalMember = dom.ExternalMember
type ExternalPosition = dom.ExternalPosition
type CreateDepartmentInput = dom.CreateDepartmentInput
type UpdateDepartmentInput = dom.UpdateDepartmentInput
type CreateMemberInput = dom.CreateMemberInput
type UpdateMemberInput = dom.UpdateMemberInput
type CreatePositionInput = dom.CreatePositionInput
type UpdatePositionInput = dom.UpdatePositionInput
type Service = dom.Service
type CursorPage[T any] = dom.CursorPage[T]

func New(pool *pgxpool.Pool, pub domevt.Publisher) Service { return repo.New(pool, pub) }
