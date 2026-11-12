package agentsdk

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/agentsdk"
	domaudit "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/audit"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

// fake repos —— 内存 stub, 覆盖测试用的方法。

type fakeCredRepo struct {
	mu        sync.Mutex
	rows      []dom.Credential
	nextID    int64
	touchHits int
}

func (f *fakeCredRepo) Insert(_ context.Context, c *dom.Credential) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, r := range f.rows {
		if r.ClientID == c.ClientID {
			return apperr.ErrConflict.Withf("duplicate (23505)")
		}
	}
	f.nextID++
	c.ID = f.nextID
	c.UUID = "uuid-cred"
	c.CreatedAt = time.Now()
	c.UpdatedAt = c.CreatedAt
	f.rows = append(f.rows, *c)
	return nil
}
func (f *fakeCredRepo) SetTenantGrants(_ context.Context, credentialID int64, mode string, tenantIDs []int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].ID == credentialID {
			f.rows[i].TenantGrantMode = mode
			f.rows[i].AllowedTenantIDs = append([]int64(nil), tenantIDs...)
			if mode == dom.PlatformTenantGrantAllEnabled {
				f.rows[i].AllowedTenantIDs = nil
			}
			return nil
		}
	}
	return apperr.ErrNotFound
}
func (f *fakeCredRepo) FindByClientID(_ context.Context, clientID string) (*dom.Credential, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].ClientID == clientID {
			cp := f.rows[i]
			return &cp, nil
		}
	}
	return nil, apperr.ErrNotFound
}
func (f *fakeCredRepo) GetByUUID(_ context.Context, tenantID int64, uuid string) (*dom.Credential, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].UUID == uuid && f.rows[i].TenantID == tenantID {
			cp := f.rows[i]
			return &cp, nil
		}
	}
	return nil, apperr.ErrNotFound
}
func (f *fakeCredRepo) GetPlatformByUUID(_ context.Context, uuid string) (*dom.Credential, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].UUID == uuid && f.rows[i].TenantID == 0 && f.rows[i].Scope == dom.CredentialScopePlatform {
			cp := f.rows[i]
			return &cp, nil
		}
	}
	return nil, apperr.ErrNotFound
}
func (f *fakeCredRepo) GetByID(_ context.Context, id int64) (*dom.Credential, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].ID == id {
			cp := f.rows[i]
			return &cp, nil
		}
	}
	return nil, apperr.ErrNotFound
}
func (f *fakeCredRepo) ListByTenant(_ context.Context, _ int64) ([]dom.Credential, error) {
	return nil, nil
}
func (f *fakeCredRepo) ListPlatform(_ context.Context) ([]dom.Credential, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []dom.Credential
	for _, row := range f.rows {
		if row.TenantID == 0 && row.Scope == dom.CredentialScopePlatform {
			out = append(out, row)
		}
	}
	return out, nil
}
func (f *fakeCredRepo) IsTenantAllowedForPlatformCredential(_ context.Context, credentialID, tenantID int64) (bool, string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, row := range f.rows {
		if row.ID != credentialID {
			continue
		}
		if row.TenantGrantMode == dom.PlatformTenantGrantAllEnabled {
			return true, row.TenantGrantMode, nil
		}
		for _, allowed := range row.AllowedTenantIDs {
			if allowed == tenantID {
				return true, dom.PlatformTenantGrantAllowlist, nil
			}
		}
		return false, dom.PlatformTenantGrantAllowlist, nil
	}
	return false, "", apperr.ErrNotFound
}
func (f *fakeCredRepo) Patch(_ context.Context, _ int64, _ string, _ map[string]any) (*dom.Credential, error) {
	return nil, nil
}
func (f *fakeCredRepo) Revoke(_ context.Context, tenantID int64, uuid string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].UUID == uuid && f.rows[i].TenantID == tenantID {
			f.rows[i].Status = "revoked"
			return nil
		}
	}
	return apperr.ErrNotFound
}
func (f *fakeCredRepo) RevokePlatform(_ context.Context, uuid string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].UUID == uuid && f.rows[i].TenantID == 0 && f.rows[i].Scope == dom.CredentialScopePlatform {
			f.rows[i].Status = "revoked"
			return nil
		}
	}
	return apperr.ErrNotFound
}
func (f *fakeCredRepo) TouchLastUsed(_ context.Context, _ int64, _ time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.touchHits++
	return nil
}

type fakeSTRepo struct {
	mu        sync.Mutex
	rows      []dom.SessionToken
	nextID    int64
	touchHits int
}

func (f *fakeSTRepo) Insert(_ context.Context, t *dom.SessionToken) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, r := range f.rows {
		if r.TokenPrefix == t.TokenPrefix {
			return apperr.ErrConflict.Withf("duplicate (23505)")
		}
	}
	f.nextID++
	t.ID = f.nextID
	t.UUID = "uuid-st"
	t.IssuedAt = time.Now()
	f.rows = append(f.rows, *t)
	return nil
}
func (f *fakeSTRepo) FindByPrefix(_ context.Context, prefix string) (*dom.SessionToken, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].TokenPrefix == prefix {
			cp := f.rows[i]
			return &cp, nil
		}
	}
	return nil, apperr.ErrNotFound
}
func (f *fakeSTRepo) GetByID(_ context.Context, id int64) (*dom.SessionToken, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].ID == id {
			cp := f.rows[i]
			return &cp, nil
		}
	}
	return nil, apperr.ErrNotFound
}
func (f *fakeSTRepo) Revoke(_ context.Context, _ string) error { return nil }
func (f *fakeSTRepo) RevokeByCredential(_ context.Context, credID int64) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var n int64
	for i := range f.rows {
		if f.rows[i].CredentialID == credID && f.rows[i].Status == "active" {
			f.rows[i].Status = "revoked"
			n++
		}
	}
	return n, nil
}

func (f *fakeSTRepo) RevokeByRuntimeEnvironment(_ context.Context, runtimeEnvironmentID int64) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var n int64
	for i := range f.rows {
		if f.rows[i].RuntimeEnvironmentID != nil &&
			*f.rows[i].RuntimeEnvironmentID == runtimeEnvironmentID &&
			f.rows[i].Status == "active" {
			f.rows[i].Status = "revoked"
			n++
		}
	}
	return n, nil
}

// RevokeChain F01 §3.6.3: 从 rootID 沿 parent_session_id 正向 cascade 撤销.
// 简化版实现 (没用 recursive CTE): 先收集 root + descendants 的 ID 集合, 再 mark.
func (f *fakeSTRepo) RevokeChain(_ context.Context, rootID int64) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	// 收集链路
	toRevoke := map[int64]bool{rootID: true}
	added := true
	for added {
		added = false
		for i := range f.rows {
			if f.rows[i].ParentSessionID != nil && toRevoke[*f.rows[i].ParentSessionID] && !toRevoke[f.rows[i].ID] {
				toRevoke[f.rows[i].ID] = true
				added = true
			}
		}
	}
	var n int64
	for i := range f.rows {
		if toRevoke[f.rows[i].ID] && f.rows[i].Status == "active" {
			f.rows[i].Status = "revoked"
			n++
		}
	}
	return n, nil
}

func (f *fakeSTRepo) RevokeChainByUUID(ctx context.Context, uuid string) (int64, error) {
	f.mu.Lock()
	var rootID int64
	for i := range f.rows {
		if f.rows[i].UUID == uuid {
			rootID = f.rows[i].ID
			break
		}
	}
	f.mu.Unlock()
	if rootID == 0 {
		return 0, nil
	}
	return f.RevokeChain(ctx, rootID)
}

func (f *fakeSTRepo) CleanupExpired(_ context.Context) (int64, error) { return 0, nil }
func (f *fakeSTRepo) TouchLastUsed(_ context.Context, _ int64, _ time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.touchHits++
	return nil
}

// setSTRowStatus helper: 强制改一行 status (测试用 - 例如模拟"对应 row 仍 active 但 parent 已 revoke").
func (f *fakeSTRepo) setStatus(id int64, status string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].ID == id {
			f.rows[i].Status = status
			return
		}
	}
}

// expireAt helper: 直接改 expires_at, 模拟"已过期".
func (f *fakeSTRepo) expireAt(id int64, t time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].ID == id {
			f.rows[i].ExpiresAt = t
			return
		}
	}
}

func newSvc(t *testing.T, now time.Time) (*Service, *fakeCredRepo, *fakeSTRepo) {
	t.Helper()
	c, s := &fakeCredRepo{}, &fakeSTRepo{}
	return New(Deps{
		CredRepo:      c,
		SessionRepo:   s,
		Now:           func() time.Time { return now },
		TouchDebounce: 1 * time.Microsecond, // 让测试不被节流压抑
	}), c, s
}

type fakeRuntimeAccess struct {
	res *dom.RuntimeAccessResolution
	err error
}

func (f fakeRuntimeAccess) ResolveRuntimeAccess(_ context.Context, _ *dom.Credential, _ dom.RuntimeAccessRequest) (*dom.RuntimeAccessResolution, error) {
	return f.res, f.err
}

func (f fakeRuntimeAccess) ResolveRuntimeAccessAgent(_ context.Context, _ string, _, _ int64) (int64, error) {
	if f.err != nil {
		return 0, f.err
	}
	if f.res == nil || f.res.AgentID == nil {
		return 0, apperr.ErrForbidden.Withf("agent not allowed")
	}
	return *f.res.AgentID, nil
}

type fakeAuditStore struct {
	mu     sync.Mutex
	events []domaudit.Event
}

func (f *fakeAuditStore) Insert(_ context.Context, e domaudit.Event) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, e)
	return nil
}

func (f *fakeAuditStore) InsertMany(_ context.Context, events []domaudit.Event) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, events...)
	return nil
}

func TestIssueSessionToken_ClampsExcessiveTTL(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	svc, cred, _ := newSvc(t, now)
	cred.Insert(context.Background(), &dom.Credential{TenantID: 1, CreatorID: 1, Name: "k", ClientID: "agentsdk_a", CapabilityBindings: []string{"kb.read"}, Status: "active"})
	// 试图申请 100 年 (codex challenge #2)
	tok, _, err := svc.IssueSessionToken(context.Background(), 1, nil, nil, nil, 100*365*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	// 必须 cap 到 DefaultSessionTokenTTL (60min)
	want := now.Add(dom.DefaultSessionTokenTTL)
	if !tok.ExpiresAt.Equal(want) {
		t.Fatalf("TTL not clamped: got expires_at=%v want %v", tok.ExpiresAt, want)
	}
}

func TestValidateSessionToken_RejectsAfterCredentialRevoked(t *testing.T) {
	// codex challenge #1: 撤销 credential 后 token 必须立即作废。
	now := time.Unix(1_700_000_000, 0)
	svc, cred, _ := newSvc(t, now)
	c := &dom.Credential{TenantID: 1, CreatorID: 1, Name: "k", ClientID: "agentsdk_a", CapabilityBindings: []string{"kb.read"}, Status: "active"}
	cred.Insert(context.Background(), c)
	_, plain, err := svc.IssueSessionToken(context.Background(), c.ID, nil, nil, nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	// 1. 撤销前: Validate 通过
	if _, err := svc.ValidateSessionToken(context.Background(), plain); err != nil {
		t.Fatalf("validate before revoke: %v", err)
	}
	// 2. 撤销 credential
	if err := svc.RevokeCredential(context.Background(), 1, c.UUID); err != nil {
		t.Fatal(err)
	}
	// 3. 即使 session_token 仍 active (cascade revoke 失败的极端情况), 父 credential 已 revoked → 拒
	if _, err := svc.ValidateSessionToken(context.Background(), plain); err == nil {
		t.Fatal("expected unauthorized after credential revoke")
	}
}

func TestRevokeCredential_CascadeRevokesSessionTokens(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	svc, cred, st := newSvc(t, now)
	c := &dom.Credential{TenantID: 1, CreatorID: 1, Name: "k", ClientID: "agentsdk_a", CapabilityBindings: []string{"kb.read"}, Status: "active"}
	cred.Insert(context.Background(), c)
	svc.IssueSessionToken(context.Background(), c.ID, nil, nil, nil, 0)
	svc.IssueSessionToken(context.Background(), c.ID, nil, nil, nil, 0)

	st.mu.Lock()
	activeBefore := 0
	for _, r := range st.rows {
		if r.Status == "active" {
			activeBefore++
		}
	}
	st.mu.Unlock()
	if activeBefore != 2 {
		t.Fatalf("expected 2 active tokens before revoke, got %d", activeBefore)
	}
	if err := svc.RevokeCredential(context.Background(), 1, c.UUID); err != nil {
		t.Fatal(err)
	}
	st.mu.Lock()
	activeAfter := 0
	for _, r := range st.rows {
		if r.Status == "active" {
			activeAfter++
		}
	}
	st.mu.Unlock()
	if activeAfter != 0 {
		t.Fatalf("expected 0 active tokens after cascade revoke, got %d", activeAfter)
	}
}

func TestIssueSessionToken_RejectsCapabilityExceedingParent(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	svc, cred, _ := newSvc(t, now)
	cred.Insert(context.Background(), &dom.Credential{TenantID: 1, CreatorID: 1, Name: "k", ClientID: "agentsdk_a", CapabilityBindings: []string{"kb.read"}, Status: "active"})
	// 父 cred 只有 kb.read; session 想要 drive.read 应被拒
	_, _, err := svc.IssueSessionToken(context.Background(), 1, nil, nil, []string{"drive.read"}, 0)
	if err == nil || !strings.Contains(err.Error(), "exceed") {
		t.Fatalf("expected capability exceed error, got %v", err)
	}
}

func TestIssueSessionToken_RejectsPlatformCredential(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	svc, cred, _ := newSvc(t, now)
	rid := int64(9)
	if err := cred.Insert(context.Background(), &dom.Credential{
		TenantID: 0, CreatorID: 1, Name: "platform", ClientID: "agentsdk_p",
		CapabilityBindings: []string{"notification.write"}, RuntimeEnvironmentID: &rid,
		Scope: dom.CredentialScopePlatform, Status: "active",
	}); err != nil {
		t.Fatal(err)
	}
	_, _, err := svc.IssueSessionToken(context.Background(), 1, nil, nil, nil, 0)
	if err == nil || !strings.Contains(err.Error(), "runtime_access") {
		t.Fatalf("expected platform credential to require runtime_access, got %v", err)
	}
}

func TestIssuePlatformCredential_BindsRuntimeAndListsPlatformOnly(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	svc, credRepo, _ := newSvc(t, now)
	runtimeID := int64(9)
	row, secret, err := svc.IssuePlatformCredential(context.Background(), 7, "HR Runtime", []string{"notification.write"}, runtimeID, dom.PlatformTenantGrantAllowlist, []int64{100})
	if err != nil {
		t.Fatalf("IssuePlatformCredential: %v", err)
	}
	if secret == "" {
		t.Fatal("expected one-time client secret")
	}
	if row.TenantID != 0 || row.Scope != dom.CredentialScopePlatform || row.RuntimeEnvironmentID == nil || *row.RuntimeEnvironmentID != runtimeID {
		t.Fatalf("platform credential binding wrong: %+v", row)
	}
	if row.TenantGrantMode != dom.PlatformTenantGrantAllowlist || len(row.AllowedTenantIDs) != 1 || row.AllowedTenantIDs[0] != 100 {
		t.Fatalf("tenant grant binding wrong: %+v", row)
	}
	if _, _, err := svc.IssuePlatformCredential(context.Background(), 7, "no runtime", []string{"notification.write"}, 0, dom.PlatformTenantGrantAllowlist, []int64{100}); err == nil {
		t.Fatal("expected runtime_environment_id required")
	}
	if _, _, err := svc.IssuePlatformCredential(context.Background(), 7, "no tenants", []string{"notification.write"}, runtimeID, dom.PlatformTenantGrantAllowlist, nil); err == nil {
		t.Fatal("expected allowed tenant ids required for allowlist mode")
	}
	tenantCred := &dom.Credential{
		TenantID: 1, CreatorID: 7, Name: "tenant", ClientID: "agentsdk_t",
		CapabilityBindings: []string{"kb.read"}, Scope: dom.CredentialScopeTenant, Status: "active",
	}
	if err := credRepo.Insert(context.Background(), tenantCred); err != nil {
		t.Fatal(err)
	}
	rows, err := svc.ListPlatformCredentials(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Scope != dom.CredentialScopePlatform {
		t.Fatalf("platform list should only include platform credentials: %+v", rows)
	}
}

func TestIssuePlatformCredential_AllEnabledTenantGrant(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	svc, _, _ := newSvc(t, now)
	runtimeID := int64(9)
	row, _, err := svc.IssuePlatformCredential(context.Background(), 7, "HR Runtime", []string{"notification.write"}, runtimeID, dom.PlatformTenantGrantAllEnabled, nil)
	if err != nil {
		t.Fatalf("IssuePlatformCredential all_enabled: %v", err)
	}
	if row.TenantGrantMode != dom.PlatformTenantGrantAllEnabled || len(row.AllowedTenantIDs) != 0 {
		t.Fatalf("all_enabled grant binding wrong: %+v", row)
	}
}

func TestRevokePlatformCredential_CascadeRevokesSessionTokens(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	credRepo, stRepo := &fakeCredRepo{}, &fakeSTRepo{}
	runtimeID := int64(9)
	svc := New(Deps{
		CredRepo:    credRepo,
		SessionRepo: stRepo,
		RuntimeAccess: fakeRuntimeAccess{res: &dom.RuntimeAccessResolution{
			TenantID: 100, RuntimeEnvironmentID: runtimeID,
		}},
		Now: func() time.Time { return now },
	})
	row, _, err := svc.IssuePlatformCredential(context.Background(), 7, "HR Runtime", []string{"notification.write"}, runtimeID, dom.PlatformTenantGrantAllowlist, []int64{100})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := svc.IssueRuntimeAccessToken(context.Background(), row.ID, dom.RuntimeAccessRequest{
		TenantID: "tenant-a",
	}); err != nil {
		t.Fatal(err)
	}
	if err := svc.RevokePlatformCredential(context.Background(), row.UUID); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.ValidateSessionToken(context.Background(), "st_bad_bad"); err == nil {
		t.Fatal("sanity: fake token should not validate")
	}
	stRepo.mu.Lock()
	defer stRepo.mu.Unlock()
	if len(stRepo.rows) != 1 || stRepo.rows[0].Status != "revoked" {
		t.Fatalf("expected issued st_ to be revoked, got %+v", stRepo.rows)
	}
}

func TestIssueRuntimeAccessToken_BindsTenantAndRuntimeContext(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	credRepo, stRepo := &fakeCredRepo{}, &fakeSTRepo{}
	runtimeID := int64(9)
	svc := New(Deps{
		CredRepo:    credRepo,
		SessionRepo: stRepo,
		RuntimeAccess: fakeRuntimeAccess{res: &dom.RuntimeAccessResolution{
			TenantID: 100, RuntimeEnvironmentID: runtimeID,
		}},
		Now: func() time.Time { return now },
	})
	if err := credRepo.Insert(context.Background(), &dom.Credential{
		TenantID: 0, CreatorID: 1, Name: "platform", ClientID: "agentsdk_p",
		CapabilityBindings: []string{"notification.write", "chat.message.write", "kb.read"}, RuntimeEnvironmentID: &runtimeID,
		Scope: dom.CredentialScopePlatform, Status: "active",
	}); err != nil {
		t.Fatal(err)
	}
	tok, plain, err := svc.IssueRuntimeAccessToken(context.Background(), 1, dom.RuntimeAccessRequest{
		TenantID: "tenant-a",
		TTL:      10 * time.Minute,
	})
	if err != nil {
		t.Fatalf("IssueRuntimeAccessToken: %v", err)
	}
	if tok.TenantID != 100 || tok.AccountID != nil || tok.AgentID != nil ||
		tok.RuntimeEnvironmentID == nil || *tok.RuntimeEnvironmentID != runtimeID {
		t.Fatalf("token binding wrong: %+v", tok)
	}
	if got, want := tok.ExpiresAt, now.Add(10*time.Minute); !got.Equal(want) {
		t.Fatalf("expires_at=%v want %v", got, want)
	}
	id, err := svc.ValidateSessionToken(context.Background(), plain)
	if err != nil {
		t.Fatalf("ValidateSessionToken: %v", err)
	}
	if id.TenantID != 100 || id.AccountID != 0 || id.AgentID != 0 || id.RuntimeEnvironmentID != runtimeID {
		t.Fatalf("identity binding wrong: %+v", id)
	}
	if !dom.HasCapability(id.CapabilityBindings, "tenant.notification.write") {
		t.Fatalf("notification alias should match caps: %v", id.CapabilityBindings)
	}
	if !dom.HasCapability(id.CapabilityBindings, "tenant.chat.message.write") {
		t.Fatalf("chat message alias should match caps: %v", id.CapabilityBindings)
	}
}

func TestIssueRuntimeAccessToken_BindsResolvedAccountContext(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	credRepo, stRepo := &fakeCredRepo{}, &fakeSTRepo{}
	runtimeID := int64(9)
	accountID := int64(321)
	svc := New(Deps{
		CredRepo:    credRepo,
		SessionRepo: stRepo,
		RuntimeAccess: fakeRuntimeAccess{res: &dom.RuntimeAccessResolution{
			TenantID: 100, RuntimeEnvironmentID: runtimeID, AccountID: &accountID,
		}},
		Now: func() time.Time { return now },
	})
	if err := credRepo.Insert(context.Background(), &dom.Credential{
		TenantID: 0, CreatorID: 1, Name: "platform", ClientID: "agentsdk_p",
		CapabilityBindings: []string{"a2a.invoke"}, RuntimeEnvironmentID: &runtimeID,
		Scope: dom.CredentialScopePlatform, Status: "active",
	}); err != nil {
		t.Fatal(err)
	}
	tok, plain, err := svc.IssueRuntimeAccessToken(context.Background(), 1, dom.RuntimeAccessRequest{
		TenantID:    "tenant-a",
		AccountUUID: "account-uuid",
	})
	if err != nil {
		t.Fatalf("IssueRuntimeAccessToken: %v", err)
	}
	if tok.AccountID == nil || *tok.AccountID != accountID {
		t.Fatalf("token account binding wrong: %+v", tok.AccountID)
	}
	id, err := svc.ValidateSessionToken(context.Background(), plain)
	if err != nil {
		t.Fatalf("ValidateSessionToken: %v", err)
	}
	if id.AccountID != accountID {
		t.Fatalf("identity account_id=%d want %d", id.AccountID, accountID)
	}
}

func TestIssueRuntimeAccessToken_AuditsRuntimeIssue(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	credRepo, stRepo, auditStore := &fakeCredRepo{}, &fakeSTRepo{}, &fakeAuditStore{}
	runtimeID := int64(9)
	svc := New(Deps{
		CredRepo:    credRepo,
		SessionRepo: stRepo,
		RuntimeAccess: fakeRuntimeAccess{res: &dom.RuntimeAccessResolution{
			TenantID: 100, RuntimeEnvironmentID: runtimeID,
		}},
		Audit: auditStore,
		Now:   func() time.Time { return now },
	})
	if err := credRepo.Insert(context.Background(), &dom.Credential{
		TenantID: 0, CreatorID: 1, Name: "platform", ClientID: "agentsdk_p",
		CapabilityBindings: []string{"notification.write"}, RuntimeEnvironmentID: &runtimeID,
		Scope: dom.CredentialScopePlatform, Status: "active",
	}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := svc.IssueRuntimeAccessToken(context.Background(), 1, dom.RuntimeAccessRequest{
		TenantID: "tenant-a",
	}); err != nil {
		t.Fatal(err)
	}
	auditStore.mu.Lock()
	defer auditStore.mu.Unlock()
	if len(auditStore.events) != 1 {
		t.Fatalf("expected one audit event, got %d", len(auditStore.events))
	}
	got := auditStore.events[0]
	if got.Domain != "runtime" || got.EventKind != "runtime.token.issue" || got.TenantID != 100 || got.ResourceUUID == "" {
		t.Fatalf("unexpected audit event: %+v", got)
	}
}

// A2A v1a: resolver 解析出 AgentID 时, 换出的 st_ 必须绑定 agent_id (Identity 同步透出);
// 审计 payload 带 agent_uuid_param。不传 agent_uuid 的旧行为由
// TestIssueRuntimeAccessToken_BindsTenantAndRuntimeContext 的 `tok.AgentID != nil → fail` 断言看住。
func TestIssueRuntimeAccessToken_BindsAgentWhenResolved(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	credRepo, stRepo, auditStore := &fakeCredRepo{}, &fakeSTRepo{}, &fakeAuditStore{}
	runtimeID, agentID := int64(9), int64(42)
	svc := New(Deps{
		CredRepo:    credRepo,
		SessionRepo: stRepo,
		RuntimeAccess: fakeRuntimeAccess{res: &dom.RuntimeAccessResolution{
			TenantID: 100, RuntimeEnvironmentID: runtimeID, AgentID: &agentID,
		}},
		Audit: auditStore,
		Now:   func() time.Time { return now },
	})
	if err := credRepo.Insert(context.Background(), &dom.Credential{
		TenantID: 0, CreatorID: 1, Name: "platform", ClientID: "agentsdk_p",
		CapabilityBindings: []string{"kb.read"}, RuntimeEnvironmentID: &runtimeID,
		Scope: dom.CredentialScopePlatform, Status: "active",
	}); err != nil {
		t.Fatal(err)
	}
	tok, plain, err := svc.IssueRuntimeAccessToken(context.Background(), 1, dom.RuntimeAccessRequest{
		TenantID:  "100",
		AgentUUID: "agent-a-uuid",
	})
	if err != nil {
		t.Fatalf("IssueRuntimeAccessToken: %v", err)
	}
	if tok.AgentID == nil || *tok.AgentID != agentID {
		t.Fatalf("session token must bind agent_id=42, got %+v", tok.AgentID)
	}
	id, err := svc.ValidateSessionToken(context.Background(), plain)
	if err != nil {
		t.Fatalf("ValidateSessionToken: %v", err)
	}
	if id.AgentID != agentID || id.TenantID != 100 || id.RuntimeEnvironmentID != runtimeID {
		t.Fatalf("identity binding wrong: %+v", id)
	}
	auditStore.mu.Lock()
	defer auditStore.mu.Unlock()
	if len(auditStore.events) != 1 {
		t.Fatalf("expected one audit event, got %d", len(auditStore.events))
	}
	payload := string(auditStore.events[0].Payload)
	if !strings.Contains(payload, `"agent_uuid_param":"agent-a-uuid"`) || !strings.Contains(payload, `"agent_id":42`) {
		t.Fatalf("audit payload missing agent binding info: %s", payload)
	}
}

// A2A v1a: resolver 拒绝 (agent 校验不过) 时换发必须 fail-closed, 不发 token。
func TestIssueRuntimeAccessToken_AgentRejectedFailClosed(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	credRepo, stRepo := &fakeCredRepo{}, &fakeSTRepo{}
	runtimeID := int64(9)
	svc := New(Deps{
		CredRepo:      credRepo,
		SessionRepo:   stRepo,
		RuntimeAccess: fakeRuntimeAccess{err: apperr.ErrForbidden.Withf("agent not allowed")},
		Now:           func() time.Time { return now },
	})
	if err := credRepo.Insert(context.Background(), &dom.Credential{
		TenantID: 0, CreatorID: 1, Name: "platform", ClientID: "agentsdk_p",
		CapabilityBindings: []string{"kb.read"}, RuntimeEnvironmentID: &runtimeID,
		Scope: dom.CredentialScopePlatform, Status: "active",
	}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := svc.IssueRuntimeAccessToken(context.Background(), 1, dom.RuntimeAccessRequest{
		TenantID: "100", AgentUUID: "agent-x",
	}); err == nil {
		t.Fatal("expected fail-closed error")
	}
	stRepo.mu.Lock()
	defer stRepo.mu.Unlock()
	if len(stRepo.rows) != 0 {
		t.Fatalf("no token must be issued on reject; got %d", len(stRepo.rows))
	}
}

// =============================================================================
// F01 §3.6.3 / F09 PR4.5 derive 测试 (7 scenarios)
// =============================================================================

// setupParent helper: 建一个 active credential + 一条 master session.
// 返 (svc, parentSessionToken, plain).
func setupParent(t *testing.T, now time.Time, caps []string) (*Service, *fakeCredRepo, *fakeSTRepo, *dom.SessionToken, string) {
	t.Helper()
	svc, credRepo, stRepo := newSvc(t, now)
	c := &dom.Credential{
		TenantID: 1, CreatorID: 1, Name: "k", ClientID: "agentsdk_a",
		CapabilityBindings: append([]string(nil), caps...), Status: "active",
	}
	if err := credRepo.Insert(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	parent, plain, err := svc.IssueSessionToken(context.Background(), c.ID, nil, ptrInt64(100), caps, 30*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	return svc, credRepo, stRepo, parent, plain
}

func ptrInt64(v int64) *int64 { return &v }

func TestDerive_HappyPath(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	svc, _, stRepo, parent, _ := setupParent(t, now, []string{"kb.read", "drive.read"})
	child, plain, err := svc.IssueDerivedSessionToken(context.Background(), parent.ID, 200, []string{"kb.read"}, 10*time.Minute)
	if err != nil {
		t.Fatalf("derive: %v", err)
	}
	// 不变量: child 继承 tenant_id / conversation_id (parent 是 nil) / parent_session_id 指 parent / agent_id=target
	if child.TenantID != parent.TenantID {
		t.Fatalf("child tenant mismatch")
	}
	if child.ParentSessionID == nil || *child.ParentSessionID != parent.ID {
		t.Fatalf("child parent_session_id not set; got %v", child.ParentSessionID)
	}
	if child.AgentID == nil || *child.AgentID != 200 {
		t.Fatalf("child agent_id should be target (200); got %v", child.AgentID)
	}
	if len(child.CapabilityBindings) != 1 || child.CapabilityBindings[0] != "kb.read" {
		t.Fatalf("child caps wrong: %v", child.CapabilityBindings)
	}
	// child ttl 应被 clamp 到 10min (caller 请求, < parent 剩余 30min, < Max 60min)
	wantExp := now.Add(10 * time.Minute)
	if !child.ExpiresAt.Equal(wantExp) {
		t.Fatalf("child expires_at = %v want %v", child.ExpiresAt, wantExp)
	}
	// child Validate 可通过 (parent active + cred active)
	if _, err := svc.ValidateSessionToken(context.Background(), plain); err != nil {
		t.Fatalf("validate child: %v", err)
	}
	// stRepo 里应该有 2 行 (parent + child)
	stRepo.mu.Lock()
	defer stRepo.mu.Unlock()
	if n := len(stRepo.rows); n != 2 {
		t.Fatalf("st rows = %d want 2", n)
	}
}

func TestDerive_CapsExceedRejected(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	svc, _, _, parent, _ := setupParent(t, now, []string{"kb.read"})
	// 父 caps 只有 kb.read; child 想 drive.read → 应拒
	_, _, err := svc.IssueDerivedSessionToken(context.Background(), parent.ID, 200, []string{"drive.read"}, 5*time.Minute)
	if err == nil || !strings.Contains(err.Error(), "exceed") {
		t.Fatalf("expected caps exceed error, got %v", err)
	}
}

func TestDerive_TTLClampedToParentRemaining(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	// parent ttl 30min
	svc, _, _, parent, _ := setupParent(t, now, []string{"kb.read"})
	// caller 请求 50min (大于 parent 剩余 30min, 也大于全局 Max 60min → 先 clamp 到 Max 60min, 再 clamp 到 parent 剩余 30min)
	child, _, err := svc.IssueDerivedSessionToken(context.Background(), parent.ID, 200, nil, 50*time.Minute)
	if err != nil {
		t.Fatalf("derive: %v", err)
	}
	want := parent.ExpiresAt // child expires_at = parent expires_at (clamp)
	if !child.ExpiresAt.Equal(want) {
		t.Fatalf("ttl not clamped to parent remaining: got %v want %v", child.ExpiresAt, want)
	}
}

func TestDerive_RejectsAfterParentRevoked(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	svc, _, stRepo, parent, _ := setupParent(t, now, []string{"kb.read"})
	// 撤销 parent
	stRepo.setStatus(parent.ID, "revoked")
	// derive 应拒
	_, _, err := svc.IssueDerivedSessionToken(context.Background(), parent.ID, 200, nil, 5*time.Minute)
	if err == nil {
		t.Fatal("expected error after parent revoked")
	}
}

func TestDerive_RejectsAfterParentExpired(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	svc, _, stRepo, parent, _ := setupParent(t, now, []string{"kb.read"})
	// 直接把 parent expires_at 改为 1 小时前
	stRepo.expireAt(parent.ID, now.Add(-1*time.Hour))
	_, _, err := svc.IssueDerivedSessionToken(context.Background(), parent.ID, 200, nil, 5*time.Minute)
	if err == nil {
		t.Fatal("expected error after parent expired")
	}
}

func TestRevokeChain_CascadesDescendants(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	svc, _, stRepo, parent, _ := setupParent(t, now, []string{"kb.read"})
	// 派生 2 个孩子 + 1 个孙子
	child1, _, err := svc.IssueDerivedSessionToken(context.Background(), parent.ID, 201, nil, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = svc.IssueDerivedSessionToken(context.Background(), parent.ID, 202, nil, 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	_, grandchildPlain, err := svc.IssueDerivedSessionToken(context.Background(), child1.ID, 301, nil, 3*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	// grandchild 撤销前 validate 通过 (chain 全 active)
	if _, err := svc.ValidateSessionToken(context.Background(), grandchildPlain); err != nil {
		t.Fatalf("validate grandchild before revoke: %v", err)
	}
	// 撤销 parent (uuid 入口) → 应级联 4 行 (parent + 2 children + 1 grandchild)
	if err := svc.RevokeSessionToken(context.Background(), parent.UUID); err != nil {
		t.Fatal(err)
	}
	stRepo.mu.Lock()
	active := 0
	for _, r := range stRepo.rows {
		if r.Status == "active" {
			active++
		}
	}
	stRepo.mu.Unlock()
	if active != 0 {
		t.Fatalf("expected all 4 sessions revoked, got %d still active", active)
	}
	// grandchild 单独 validate 也应失败 (row 自己 status 已 revoked)
	if _, err := svc.ValidateSessionToken(context.Background(), grandchildPlain); err == nil {
		t.Fatal("expected grandchild to fail validate after chain revoke")
	}
}

func TestValidate_MultiLevelChain(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	svc, _, stRepo, parent, _ := setupParent(t, now, []string{"kb.read", "drive.read"})

	// 3 层: parent → child → grandchild
	child, _, err := svc.IssueDerivedSessionToken(context.Background(), parent.ID, 201, []string{"kb.read", "drive.read"}, 20*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	_, grandchildPlain, err := svc.IssueDerivedSessionToken(context.Background(), child.ID, 301, []string{"kb.read"}, 10*time.Minute)
	if err != nil {
		t.Fatal(err)
	}

	// 1. grandchild 全活时 validate 通过
	if _, err := svc.ValidateSessionToken(context.Background(), grandchildPlain); err != nil {
		t.Fatalf("validate fresh grandchild: %v", err)
	}

	// 2. 单点失效中间 child → grandchild 必须立即拒 (chain walk 到 middle 节点检测到 revoked)
	stRepo.setStatus(child.ID, "revoked")
	if _, err := svc.ValidateSessionToken(context.Background(), grandchildPlain); err == nil {
		t.Fatal("grandchild should fail validate after middle node revoked")
	}

	// 3. 恢复 child + revoke parent (顶层) → grandchild 仍应拒 (chain walk 到 master 检测到 revoked)
	stRepo.setStatus(child.ID, "active")
	stRepo.setStatus(parent.ID, "revoked")
	if _, err := svc.ValidateSessionToken(context.Background(), grandchildPlain); err == nil {
		t.Fatal("grandchild should fail validate after root master revoked")
	}
}

func TestValidate_TouchDebounce(t *testing.T) {
	// codex challenge #4: 同 token 60s 内只写库 1 次。
	// 这里把 debounce 设成 100ms, 连发 3 次, 只期望 1 次 touch。
	now := time.Unix(1_700_000_000, 0)
	c, s := &fakeCredRepo{}, &fakeSTRepo{}
	svc := New(Deps{CredRepo: c, SessionRepo: s, Now: func() time.Time { return now }, TouchDebounce: 100 * time.Millisecond})
	cred := &dom.Credential{TenantID: 1, CreatorID: 1, Name: "k", ClientID: "agentsdk_a", CapabilityBindings: []string{"kb.read"}, Status: "active"}
	c.Insert(context.Background(), cred)
	_, plain, _ := svc.IssueSessionToken(context.Background(), cred.ID, nil, nil, nil, 0)
	for i := 0; i < 3; i++ {
		svc.ValidateSessionToken(context.Background(), plain)
	}
	s.mu.Lock()
	hits := s.touchHits
	s.mu.Unlock()
	if hits != 1 {
		t.Fatalf("expected 1 debounced touch hit, got %d", hits)
	}
}

func TestEnsurePlatformCredentialWithSecret_CreateThenIdempotentThenConflict(t *testing.T) {
	repo := &fakeCredRepo{}
	svc := New(Deps{CredRepo: repo})
	caps := []string{"kb.read", "a2a.invoke"}
	c, err := svc.EnsurePlatformCredentialWithSecret(context.Background(), 9, "dsh 反向通道", "agentsdk_dsh", "top-secret", caps, 42)
	if err != nil {
		t.Fatalf("ensure: %v", err)
	}
	if c.Scope != dom.CredentialScopePlatform || c.ClientID != "agentsdk_dsh" || c.RuntimeEnvironmentID == nil || *c.RuntimeEnvironmentID != 42 ||
		c.ClientSecretHash != hashSecret("top-secret") || c.TenantID != 0 || c.CreatorID != 9 {
		t.Fatalf("created credential mismatch: %+v", c)
	}
	stored, _ := repo.FindByClientID(context.Background(), "agentsdk_dsh")
	if stored.TenantGrantMode != dom.PlatformTenantGrantAllEnabled {
		t.Fatalf("platform credential must grant all enabled tenants, got %q", stored.TenantGrantMode)
	}
	// 同 secret 再来一次 = 幂等 (不新建)
	again, err := svc.EnsurePlatformCredentialWithSecret(context.Background(), 9, "dsh 反向通道", "agentsdk_dsh", "top-secret", caps, 42)
	if err != nil || again.ID != c.ID || len(repo.rows) != 1 {
		t.Fatalf("second ensure must be idempotent: err=%v rows=%d", err, len(repo.rows))
	}
	// secret 不一致 → 冲突, 不覆盖
	if _, err := svc.EnsurePlatformCredentialWithSecret(context.Background(), 9, "dsh 反向通道", "agentsdk_dsh", "other", caps, 42); err == nil {
		t.Fatal("different secret must be refused")
	}
	if _, err := svc.EnsurePlatformCredentialWithSecret(context.Background(), 9, "x", "agentsdk_dsh", "top-secret", []string{"bogus.cap"}, 42); err == nil {
		t.Fatal("unknown capability must be refused")
	}
}
