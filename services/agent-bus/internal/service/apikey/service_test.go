package apikey

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/apikey"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// fakeRepo 内存 stub; 只覆盖 Issue + Validate 用到的方法。
type fakeRepo struct {
	mu       sync.Mutex
	rows     []dom.ApiKey
	nextID   int64
	touched  int
	insertEr error
	listF    dom.ListFilter
}

func (f *fakeRepo) Insert(_ context.Context, k *dom.ApiKey) error {
	if f.insertEr != nil {
		return f.insertEr
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nextID++
	k.ID = f.nextID
	k.UUID = "uuid-" + strings.Repeat("x", 4)
	k.CreatedAt = time.Now()
	k.UpdatedAt = k.CreatedAt
	// 模拟唯一索引: 撞 prefix 返回 23505。
	for _, r := range f.rows {
		if r.KeyPrefix == k.KeyPrefix {
			return errors.New("duplicate key value (23505)")
		}
	}
	f.rows = append(f.rows, *k)
	return nil
}

func (f *fakeRepo) FindByPrefix(_ context.Context, prefix string) (*dom.ApiKey, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].KeyPrefix == prefix {
			cp := f.rows[i]
			return &cp, nil
		}
	}
	return nil, apperr.ErrNotFound
}

func (f *fakeRepo) GetByUUID(_ context.Context, _ int64, _ string) (*dom.ApiKey, error) {
	return nil, apperr.ErrNotFound
}
func (f *fakeRepo) ListByTenant(_ context.Context, _ int64, filter dom.ListFilter) ([]dom.ApiKey, int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.listF = filter
	return nil, 0, nil
}
func (f *fakeRepo) Patch(_ context.Context, _ int64, _ string, _ map[string]any) (*dom.ApiKey, error) {
	return nil, nil
}
func (f *fakeRepo) Revoke(_ context.Context, _ int64, _ string) error { return nil }
func (f *fakeRepo) TouchLastUsed(_ context.Context, _ int64, _ time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.touched++
	return nil
}

func newSvc(r *fakeRepo, now time.Time) *Service {
	return New(Deps{Repo: r, Now: func() time.Time { return now }})
}

func TestIssue_RejectsBadInput(t *testing.T) {
	r := &fakeRepo{}
	s := newSvc(r, time.Unix(1_700_000_000, 0))
	cases := []struct {
		name    string
		tenant  int64
		creator int64
		title   string
		scopes  []string
	}{
		{"empty name", 1, 1, "", []string{dom.ScopeKBRead}},
		{"no tenant", 0, 1, "x", []string{dom.ScopeKBRead}},
		{"no creator", 1, 0, "x", []string{dom.ScopeKBRead}},
		{"empty scopes", 1, 1, "x", nil},
		{"unknown scope", 1, 1, "x", []string{"chat.write"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, _, err := s.Issue(context.Background(), c.tenant, c.creator, c.title, c.scopes, nil)
			if err == nil {
				t.Fatal("expected error")
			}
		})
	}
}

func TestIssue_RejectsExpiresInPast(t *testing.T) {
	r := &fakeRepo{}
	now := time.Unix(1_700_000_000, 0)
	s := newSvc(r, now)
	past := now.Add(-time.Minute)
	_, _, err := s.Issue(context.Background(), 1, 1, "x", []string{dom.ScopeKBRead}, &past)
	if err == nil {
		t.Fatal("expected error for past expires_at")
	}
}

func TestIssue_PlaintextHasEkPrefixAndUniquePrefix(t *testing.T) {
	r := &fakeRepo{}
	s := newSvc(r, time.Unix(1_700_000_000, 0))
	_, plain1, err := s.Issue(context.Background(), 1, 1, "k1", []string{dom.ScopeKBRead}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(plain1, "ek_") {
		t.Fatalf("plaintext missing ek_ prefix: %s", plain1)
	}
	if strings.Count(plain1, "_") < 2 {
		t.Fatalf("plaintext should have 2+ underscores: %s", plain1)
	}
	_, plain2, err := s.Issue(context.Background(), 1, 1, "k2", []string{dom.ScopeKBRead}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if plain1 == plain2 {
		t.Fatal("two issues produced identical plaintext")
	}
}

func TestList_NormalizesFilter(t *testing.T) {
	r := &fakeRepo{}
	s := newSvc(r, time.Unix(1_700_000_000, 0))
	if _, _, err := s.List(context.Background(), 7, dom.ListFilter{
		Status:  " active ",
		Keyword: "  crm  ",
		Limit:   500,
		Offset:  -1,
	}); err != nil {
		t.Fatal(err)
	}
	r.mu.Lock()
	got := r.listF
	r.mu.Unlock()
	if got.Status != "active" || got.Keyword != "crm" || got.Limit != 100 || got.Offset != 0 {
		t.Fatalf("filter not normalized: %+v", got)
	}
}

func TestList_RejectsInvalidStatus(t *testing.T) {
	r := &fakeRepo{}
	s := newSvc(r, time.Unix(1_700_000_000, 0))
	if _, _, err := s.List(context.Background(), 7, dom.ListFilter{Status: "deleted"}); err == nil {
		t.Fatal("expected invalid status error")
	}
}

func TestValidate_HappyPath(t *testing.T) {
	r := &fakeRepo{}
	now := time.Unix(1_700_000_000, 0)
	s := newSvc(r, now)
	_, plain, err := s.Issue(context.Background(), 7, 11, "k", []string{dom.ScopeKBRead}, nil)
	if err != nil {
		t.Fatal(err)
	}
	id, err := s.Validate(context.Background(), plain)
	if err != nil {
		t.Fatalf("validate failed: %v", err)
	}
	if id.TenantID != 7 || id.CreatorID != 11 {
		t.Fatalf("identity mismatch: %+v", id)
	}
	if !dom.HasScope(id.Scopes, dom.ScopeKBRead) {
		t.Fatalf("scopes missing kb.read: %v", id.Scopes)
	}
	if r.touched != 1 {
		t.Fatalf("expected TouchLastUsed called once, got %d", r.touched)
	}
}

func TestValidate_RejectsTamperedSecret(t *testing.T) {
	r := &fakeRepo{}
	s := newSvc(r, time.Unix(1_700_000_000, 0))
	_, plain, _ := s.Issue(context.Background(), 1, 1, "k", []string{dom.ScopeKBRead}, nil)
	// Flip last char.
	last := plain[len(plain)-1]
	repl := "Z"
	if last == 'Z' {
		repl = "A"
	}
	tampered := plain[:len(plain)-1] + repl
	if _, err := s.Validate(context.Background(), tampered); err == nil {
		t.Fatal("expected unauthorized for tampered secret")
	}
}

func TestValidate_RejectsBadFormat(t *testing.T) {
	r := &fakeRepo{}
	s := newSvc(r, time.Unix(1_700_000_000, 0))
	cases := []string{"", "ek_", "ek_foo", "abc_def_ghi", "Bearer ek_a_b"}
	for _, c := range cases {
		if _, err := s.Validate(context.Background(), c); err == nil {
			t.Fatalf("expected error for %q", c)
		}
	}
}

func TestValidate_RejectsExpiredKey(t *testing.T) {
	r := &fakeRepo{}
	issueTime := time.Unix(1_700_000_000, 0)
	exp := issueTime.Add(time.Hour)
	s := newSvc(r, issueTime)
	_, plain, err := s.Issue(context.Background(), 1, 1, "k", []string{dom.ScopeKBRead}, &exp)
	if err != nil {
		t.Fatal(err)
	}
	// Advance time past expiry.
	s.now = func() time.Time { return exp.Add(time.Minute) }
	if _, err := s.Validate(context.Background(), plain); err == nil {
		t.Fatal("expected unauthorized for expired key")
	}
}

func TestValidate_RejectsRevokedKey(t *testing.T) {
	r := &fakeRepo{}
	s := newSvc(r, time.Unix(1_700_000_000, 0))
	_, plain, _ := s.Issue(context.Background(), 1, 1, "k", []string{dom.ScopeKBRead}, nil)
	// Flip the stored row to revoked.
	r.mu.Lock()
	r.rows[0].Status = "revoked"
	r.mu.Unlock()
	if _, err := s.Validate(context.Background(), plain); err == nil {
		t.Fatal("expected unauthorized for revoked key")
	}
}

func TestParseKey_Edges(t *testing.T) {
	cases := []struct {
		raw       string
		ok        bool
		wantPrefx string
		wantSec   string
	}{
		{"ek_a_b", true, "a", "b"},
		{"ek_abcd1234_secretSecret", true, "abcd1234", "secretSecret"},
		{"", false, "", ""},
		{"ek_", false, "", ""},
		{"ek_abc", false, "", ""},
		{"ek_abc_", false, "", ""},
		{"foo_a_b", false, "", ""},
	}
	for _, c := range cases {
		p, s, ok := parseKey(c.raw)
		if ok != c.ok {
			t.Errorf("parseKey(%q) ok=%v want %v", c.raw, ok, c.ok)
		}
		if ok && (p != c.wantPrefx || s != c.wantSec) {
			t.Errorf("parseKey(%q) = (%q,%q) want (%q,%q)", c.raw, p, s, c.wantPrefx, c.wantSec)
		}
	}
}
