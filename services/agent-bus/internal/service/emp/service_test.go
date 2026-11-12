// Batch 3D T3.10 单测: admin emp service 行为.
//
// 3D Codex 二次返修后, NOTIFY 同 INSERT/UPDATE 一个 tx 由 repo 负责; service 层不再持
// notifier, 改用 "fake repo 返错" 模拟 tx 失败 (e.g. pg_notify error / commit error).
//
// 覆盖:
//   - List / Get / 字段必填 / category & status 枚举
//   - Create 默认 status=draft、version=1、fallback=markdown
//   - fallback_block_type 必须存在且 stable; self-ref 仅 stable 允许; unknown/draft/deprecated 拒
//   - Update status-only 触发 fallback re-eval (self-ref stable → PATCH status=draft 拒)
//   - repo.Create / Update 返错时 service 透传 (模拟 NOTIFY/commit 失败)
package emp

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/empblock"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/log"
)

// fakeRepo 内存实现; 支持 createErr / updateErr 钩子, 模拟 NOTIFY/commit 失败时 repo
// 返错 + row 不落库的语义.
type fakeRepo struct {
	mu        sync.Mutex
	rows      []dom.Block
	nextID    int64
	createErr error
	updateErr error
	creates   int
	updates   int
}

func (r *fakeRepo) List(ctx context.Context) ([]dom.Block, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]dom.Block, len(r.rows))
	copy(out, r.rows)
	return out, nil
}

func (r *fakeRepo) GetByID(ctx context.Context, id int64) (*dom.Block, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := range r.rows {
		if r.rows[i].ID == id {
			cp := r.rows[i]
			return &cp, nil
		}
	}
	return nil, apperr.ErrNotFound
}

func (r *fakeRepo) GetByCode(ctx context.Context, code string, v int) (*dom.Block, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := range r.rows {
		if r.rows[i].Code == code && r.rows[i].Version == v {
			cp := r.rows[i]
			return &cp, nil
		}
	}
	return nil, apperr.ErrNotFound
}

func (r *fakeRepo) Create(ctx context.Context, in dom.CreateInput) (*dom.Block, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.creates++
	if r.createErr != nil {
		// 模拟 tx ROLLBACK: row 不入 rows.
		return nil, r.createErr
	}
	r.nextID++
	b := dom.Block{
		ID: r.nextID, Code: in.Code, Version: in.Version, Name: in.Name,
		Category: in.Category, JSONSchema: in.JSONSchema, Status: in.Status,
		MinClientVersion: in.MinClientVersion, FallbackBlockType: in.FallbackBlockType,
		Description: in.Description, CreatedAt: time.Now(), UpdatedAt: time.Now(),
	}
	r.rows = append(r.rows, b)
	return &b, nil
}

func (r *fakeRepo) Update(ctx context.Context, id int64, in dom.UpdateInput) (*dom.Block, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.updates++
	if r.updateErr != nil {
		// 模拟 tx ROLLBACK: 不应用任何字段.
		return nil, r.updateErr
	}
	for i := range r.rows {
		if r.rows[i].ID == id {
			if in.Name != nil {
				r.rows[i].Name = *in.Name
			}
			if in.Status != nil {
				r.rows[i].Status = *in.Status
			}
			if in.MinClientVersion != nil {
				r.rows[i].MinClientVersion = *in.MinClientVersion
			}
			if in.FallbackBlockType != nil {
				r.rows[i].FallbackBlockType = *in.FallbackBlockType
			}
			r.rows[i].UpdatedAt = time.Now()
			cp := r.rows[i]
			return &cp, nil
		}
	}
	return nil, apperr.ErrNotFound
}

func (r *fakeRepo) rowCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.rows)
}

// ----- tests -----

func TestCreate_RequiredFields(t *testing.T) {
	svc := New(log.Default(), &fakeRepo{})
	cases := []struct {
		name string
		in   dom.CreateInput
	}{
		{"missing code", dom.CreateInput{Name: "n", Category: "content"}},
		{"missing name", dom.CreateInput{Code: "x", Category: "content"}},
		{"missing category", dom.CreateInput{Code: "x", Name: "n"}},
		{"bad category", dom.CreateInput{Code: "x", Name: "n", Category: "ghost"}},
		{"bad status", dom.CreateInput{Code: "x", Name: "n", Category: "content", Status: "running"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := svc.Create(context.Background(), c.in)
			if err == nil {
				t.Fatalf("expected error")
			}
			ae, ok := apperr.AsError(err)
			if !ok || ae.Code != apperr.InvalidParams {
				t.Fatalf("expected InvalidParams, got %v", err)
			}
		})
	}
}

func TestCreate_DefaultsAndRowCount(t *testing.T) {
	repo := &fakeRepo{rows: []dom.Block{
		{ID: 1, Code: "markdown", Version: 1, Status: dom.StatusStable},
	}, nextID: 1}
	svc := New(log.Default(), repo)
	b, err := svc.Create(context.Background(), dom.CreateInput{
		Code: "ganntt", Name: "Gantt", Category: "content",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if b.Version != 1 || b.Status != dom.StatusDraft || b.FallbackBlockType != "markdown" {
		t.Fatalf("defaults wrong: %+v", b)
	}
	if repo.rowCount() != 2 {
		t.Fatalf("expected 2 rows, got %d", repo.rowCount())
	}
}

// ----- 返修 #1: NOTIFY 同 tx 失败时 service 透传错误, row 不落库 -----

func TestCreate_RepoTxFailure_ServiceReturnsError(t *testing.T) {
	repo := &fakeRepo{
		rows:      []dom.Block{{ID: 1, Code: "markdown", Version: 1, Status: dom.StatusStable}},
		nextID:    1,
		createErr: errors.New("pg_notify failed; tx rolled back"),
	}
	svc := New(log.Default(), repo)
	preCount := repo.rowCount()
	_, err := svc.Create(context.Background(), dom.CreateInput{
		Code: "gantt", Name: "G", Category: "content",
	})
	if err == nil {
		t.Fatalf("expected tx failure error")
	}
	// fake repo 在 createErr 路径下不写 rows, 模拟 ROLLBACK 后 DB 状态不变.
	if repo.rowCount() != preCount {
		t.Fatalf("row count must stay %d after tx failure, got %d", preCount, repo.rowCount())
	}
}

func TestUpdate_RepoTxFailure_ServiceReturnsError(t *testing.T) {
	repo := &fakeRepo{
		rows:      []dom.Block{{ID: 7, Code: "chart", Version: 1, Status: dom.StatusStable, FallbackBlockType: "markdown"}},
		updateErr: errors.New("pg_notify failed; tx rolled back"),
	}
	svc := New(log.Default(), repo)
	newName := "renamed"
	_, err := svc.Update(context.Background(), 7, dom.UpdateInput{Name: &newName})
	if err == nil {
		t.Fatalf("expected tx failure error")
	}
}

// ----- 返修 #1: fallback 校验 (Create) -----

func TestCreate_FallbackRejected(t *testing.T) {
	base := []dom.Block{
		{ID: 1, Code: "markdown", Version: 1, Status: dom.StatusStable},
		{ID: 2, Code: "thought", Version: 1, Status: dom.StatusStable},
		{ID: 3, Code: "draftish", Version: 1, Status: dom.StatusDraft},
		{ID: 4, Code: "oldcard", Version: 1, Status: dom.StatusDeprecated},
	}
	t.Run("unknown", func(t *testing.T) {
		repo := &fakeRepo{rows: append([]dom.Block(nil), base...), nextID: 10}
		svc := New(log.Default(), repo)
		_, err := svc.Create(context.Background(), dom.CreateInput{
			Code: "gantt", Name: "G", Category: "content",
			FallbackBlockType: "ghost",
		})
		expectInvalidFallback(t, err)
	})
	t.Run("draft target", func(t *testing.T) {
		repo := &fakeRepo{rows: append([]dom.Block(nil), base...), nextID: 10}
		svc := New(log.Default(), repo)
		_, err := svc.Create(context.Background(), dom.CreateInput{
			Code: "gantt", Name: "G", Category: "content",
			FallbackBlockType: "draftish",
		})
		expectInvalidFallback(t, err)
	})
	t.Run("deprecated target", func(t *testing.T) {
		repo := &fakeRepo{rows: append([]dom.Block(nil), base...), nextID: 10}
		svc := New(log.Default(), repo)
		_, err := svc.Create(context.Background(), dom.CreateInput{
			Code: "gantt", Name: "G", Category: "content",
			FallbackBlockType: "oldcard",
		})
		expectInvalidFallback(t, err)
	})
	t.Run("stable target ok", func(t *testing.T) {
		repo := &fakeRepo{rows: append([]dom.Block(nil), base...), nextID: 10}
		svc := New(log.Default(), repo)
		if _, err := svc.Create(context.Background(), dom.CreateInput{
			Code: "gantt", Name: "G", Category: "content",
			FallbackBlockType: "thought",
		}); err != nil {
			t.Fatalf("stable target should pass: %v", err)
		}
	})
	t.Run("self-ref draft rejected", func(t *testing.T) {
		repo := &fakeRepo{rows: append([]dom.Block(nil), base...), nextID: 10}
		svc := New(log.Default(), repo)
		_, err := svc.Create(context.Background(), dom.CreateInput{
			Code: "selfdraft", Name: "S", Category: "content",
			Status: dom.StatusDraft, FallbackBlockType: "selfdraft",
		})
		expectInvalidFallback(t, err)
	})
	t.Run("self-ref stable ok", func(t *testing.T) {
		repo := &fakeRepo{rows: append([]dom.Block(nil), base...), nextID: 10}
		svc := New(log.Default(), repo)
		if _, err := svc.Create(context.Background(), dom.CreateInput{
			Code: "selfstable", Name: "S", Category: "content",
			Status: dom.StatusStable, FallbackBlockType: "selfstable",
		}); err != nil {
			t.Fatalf("self-ref stable should pass: %v", err)
		}
	})
}

// ----- 返修 #2: Update status-only 也要重跑 fallback 校验 -----

func TestUpdate_FallbackRejected(t *testing.T) {
	repo := &fakeRepo{rows: []dom.Block{
		{ID: 1, Code: "markdown", Version: 1, Status: dom.StatusStable},
		{ID: 2, Code: "draftish", Version: 1, Status: dom.StatusDraft},
		{ID: 7, Code: "chart", Version: 1, Status: dom.StatusStable, FallbackBlockType: "markdown"},
	}}
	svc := New(log.Default(), repo)
	// PATCH chart.fallback_block_type='draftish' (draft) → 拒.
	target := "draftish"
	_, err := svc.Update(context.Background(), 7, dom.UpdateInput{FallbackBlockType: &target})
	expectInvalidFallback(t, err)
	// PATCH chart.fallback_block_type='ghost' (unknown) → 拒.
	ghost := "ghost"
	_, err = svc.Update(context.Background(), 7, dom.UpdateInput{FallbackBlockType: &ghost})
	expectInvalidFallback(t, err)
	// PATCH chart.fallback_block_type='markdown' (stable) → 通过.
	ok := "markdown"
	if _, err := svc.Update(context.Background(), 7, dom.UpdateInput{FallbackBlockType: &ok}); err != nil {
		t.Fatalf("stable target should pass: %v", err)
	}
}

// TestUpdate_StatusOnlyTriggersFallbackCheck (3D Codex review 返修 #2):
// self-ref stable 的 row PATCH status=draft 必须被拒, 否则会留下"fallback 指向自身但
// 自身不再 stable"的不可消解链.
//
// 同样 PATCH status=deprecated 必须被拒.
func TestUpdate_StatusOnlyTriggersFallbackCheck(t *testing.T) {
	// "selfstable" 自指 fallback.
	repo := &fakeRepo{rows: []dom.Block{
		{ID: 1, Code: "markdown", Version: 1, Status: dom.StatusStable},
		{ID: 7, Code: "selfstable", Version: 1, Status: dom.StatusStable, FallbackBlockType: "selfstable"},
	}}
	svc := New(log.Default(), repo)

	draft := dom.StatusDraft
	_, err := svc.Update(context.Background(), 7, dom.UpdateInput{Status: &draft})
	expectInvalidFallback(t, err)
	if repo.rows[1].Status != dom.StatusStable {
		t.Fatalf("status must not change on reject: %+v", repo.rows[1])
	}

	deprecated := dom.StatusDeprecated
	_, err = svc.Update(context.Background(), 7, dom.UpdateInput{Status: &deprecated})
	expectInvalidFallback(t, err)

	// PATCH 同时把 fallback 改成其它 stable code → 应放行.
	other := "markdown"
	_, err = svc.Update(context.Background(), 7, dom.UpdateInput{Status: &draft, FallbackBlockType: &other})
	if err != nil {
		t.Fatalf("status=draft + fallback=markdown(stable) should pass: %v", err)
	}
}

// TestUpdate_StatusEnum 校验 in.Status 必须是枚举值 (status 校验早于 fallback re-eval).
func TestUpdate_StatusEnum(t *testing.T) {
	repo := &fakeRepo{rows: []dom.Block{{ID: 7, Code: "chart", Version: 1, Status: dom.StatusStable}}}
	svc := New(log.Default(), repo)
	bad := "rolling"
	_, err := svc.Update(context.Background(), 7, dom.UpdateInput{Status: &bad})
	if err == nil {
		t.Fatalf("expected enum reject")
	}
	ae, ok := apperr.AsError(err)
	if !ok || ae.Code != apperr.InvalidParams {
		t.Fatalf("expected InvalidParams, got %v", err)
	}
}

// TestUpdate_OK 简单 happy-path 验证 PATCH 名字成功且 fallback re-eval 在 status 未变时
// 仍然按现有 (status, fallback) 跑.
func TestUpdate_OK(t *testing.T) {
	repo := &fakeRepo{rows: []dom.Block{
		{ID: 1, Code: "markdown", Version: 1, Status: dom.StatusStable},
		{ID: 7, Code: "chart", Version: 1, Status: dom.StatusStable, FallbackBlockType: "markdown"},
	}}
	svc := New(log.Default(), repo)
	deprecated := dom.StatusDeprecated
	// chart 不是自指 fallback → status PATCH 到 deprecated 应放行.
	b, err := svc.Update(context.Background(), 7, dom.UpdateInput{Status: &deprecated})
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if b.Status != dom.StatusDeprecated {
		t.Fatalf("status not updated: %+v", b)
	}
}

// ----- list / get passthrough -----

func TestGetList_Passthrough(t *testing.T) {
	repo := &fakeRepo{rows: []dom.Block{{ID: 5, Code: "tool_call"}}}
	svc := New(log.Default(), repo)
	xs, err := svc.List(context.Background())
	if err != nil || len(xs) != 1 || xs[0].Code != "tool_call" {
		t.Fatalf("list = %v %v", xs, err)
	}
	g, err := svc.Get(context.Background(), 5)
	if err != nil || g.Code != "tool_call" {
		t.Fatalf("get = %v %v", g, err)
	}
}

// ----- helpers -----

func expectInvalidFallback(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected fallback-invalid error, got nil")
	}
	ae, ok := apperr.AsError(err)
	if !ok || ae.Code != apperr.InvalidParams {
		t.Fatalf("expected InvalidParams, got code=%v err=%v", ae, err)
	}
	if !contains(ae.Message, ErrCodeFallbackInvalid) {
		t.Fatalf("expected message contains %q, got %q", ErrCodeFallbackInvalid, ae.Message)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
