package pgcli

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// New 构造一个 pgx 连接池。
//
// 启动时会 warm up 到 MinConns (max_idle_conns 配置), 避免冷启动后
// 第一波请求每个都付建连成本 — 对 dev 远程 DB (~2s/conn) 影响特别大。
func New(ctx context.Context, dsn string, maxOpen, maxIdle int) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse pg dsn: %w", err)
	}
	if maxOpen > 0 {
		cfg.MaxConns = int32(maxOpen)
	}
	if maxIdle > 0 {
		cfg.MinConns = int32(maxIdle)
	}
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.HealthCheckPeriod = 30 * time.Second

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create pg pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		return nil, fmt.Errorf("ping pg: %w", err)
	}
	// 并发预热到 MinConns 个连接, 让冷启动慢 1 次而不是 N 次。
	// Acquire N 个连接后一起 Release 回池中, 每个连接都 warm。
	warmup(ctx, pool, int(cfg.MinConns))
	return pool, nil
}

// warmup 并发抢占 n 个连接然后一起释放, 触发 pool 建到 MinConns 个 idle 连接。
// 任何单点失败不影响 pool 本身 — 它只是预热, 失败就让运行时 lazy 建。
func warmup(ctx context.Context, pool *pgxpool.Pool, n int) {
	if n <= 1 {
		return
	}
	if n > 32 {
		n = 32 // 防止有人把 max_idle_conns 调成几百, warmup 把 DB 打满
	}
	wctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	conns := make([]*pgxpool.Conn, 0, n)
	var mu sync.Mutex
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c, err := pool.Acquire(wctx)
			if err != nil {
				return // 池忙 / context 取消 — 略过, 不影响主流程
			}
			mu.Lock()
			conns = append(conns, c)
			mu.Unlock()
		}()
	}
	wg.Wait()
	// 一起 Release, 这些 warm 连接留在池中等下次 Acquire 复用
	for _, c := range conns {
		c.Release()
	}
}
