// Package auditpg 是 ADR-0011 audit fields standard 的 pgx-layer 实现。
//
// 项目用 pgx 不是 gorm, 所以无法直接套 GORM Callback hook。本包提供轻量 helper,
// repo 层在写 INSERT/UPDATE 前调一次 Actor(ctx) 拿当前 actor 账号 ID, 自己塞进
// created_by / updated_by 列。
//
// 这是"半自动"方案: 比 gorm hook 多一句调用, 但比每个 repo 自己解析 ctx 安全
// (只读单一 ctx key, 不易出错)。
//
// 用法 (repo):
//
//	actor := auditpg.Actor(ctx)
//	row := r.pool.QueryRow(ctx, `INSERT INTO foo (..., created_by, updated_by) VALUES (..., $N, $N) RETURNING ...`,
//	    ..., actor, actor)
//
// 服务层 (ADR + ai-office/CLAUDE.md 规则) 不直接调用本包; 由 repo 调用。
package auditpg

import (
	"context"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/middleware"
)

// Actor 返回当前请求账号 ID 指针 (供 NULL-able BIGINT 列直接使用);
// 0 (系统调用 / migration / cron) 返回 nil, 让 DB 写 NULL。
func Actor(ctx context.Context) *int64 {
	id := middleware.MustAccountID(ctx)
	if id == 0 {
		return nil
	}
	return &id
}
