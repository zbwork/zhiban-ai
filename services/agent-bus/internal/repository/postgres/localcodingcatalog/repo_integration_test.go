package localcodingcatalog

// Real-database check of the transactional publish transitions and the
// partial unique indexes from migration 000140. Gated on AGBUS_TEST_PG_DSN
// (a throwaway database with migrations applied); see
// scripts/test-local-coding-catalog.sh.

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localcodingcatalog"
)

func integrationRepo(t *testing.T) (*Repo, func()) {
	t.Helper()
	dsn := os.Getenv("AGBUS_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("set AGBUS_TEST_PG_DSN to run against a migrated throwaway database")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM agent_bus.local_coding_tool_versions`); err != nil {
		pool.Close()
		t.Fatalf("clean table: %v", err)
	}
	return New(pool), pool.Close
}

func input(version string) dom.UpsertInput {
	return dom.UpsertInput{
		TargetID: dom.TargetCodexCLI, Platform: dom.PlatformMacOS, Arch: dom.ArchArm64, Version: version,
		Layout: dom.LayoutTarballSingle, BinarySHA256: "8cf911ea676523bfb2121ec561848d2aba564890ad536db4d8a3353f2b9850b1",
		ProfileVersion: "2026.09.07.1", ContractCheckRef: "ok", ReleaseNotes: "n",
	}
}

func TestIntegrationAutoSyncLockAndDeletedVersions(t *testing.T) {
	repo, closeFn := integrationRepo(t)
	defer closeFn()
	ctx := context.Background()
	release, acquired, err := repo.TryAutoSyncLock(ctx)
	if err != nil || !acquired {
		t.Fatalf("first lock: %t %v", acquired, err)
	}
	defer release()
	_, acquired, err = repo.TryAutoSyncLock(ctx)
	if err != nil || acquired {
		t.Fatalf("overlapping lock: %t %v", acquired, err)
	}
	in := input("1.2.3")
	row, err := repo.Create(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	if err = repo.Delete(ctx, row.UUID, 0); err != nil {
		t.Fatal(err)
	}
	exists, err := repo.VersionEverRecorded(ctx, in.TargetID, in.Platform, in.Arch, in.Version)
	if err != nil || !exists {
		t.Fatalf("deleted version was forgotten: %t %v", exists, err)
	}
	rows, _, err := repo.List(ctx, dom.Filter{TargetID: in.TargetID, Platform: in.Platform, Arch: in.Arch, Status: dom.StatusDraft, Limit: 10})
	if err != nil || len(rows) != 0 {
		t.Fatalf("deleted draft is resumable: %+v %v", rows, err)
	}
}

func TestIntegrationPublishTransitionsAndIndexes(t *testing.T) {
	repo, closeFn := integrationRepo(t)
	defer closeFn()
	ctx := context.Background()

	v1, err := repo.Create(ctx, input("0.153.4"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.Create(ctx, input("0.153.4")); !errors.Is(err, dom.ErrDuplicateVersion) {
		t.Fatalf("unique (target, platform, arch, version): %v", err)
	}
	if _, err := repo.SetPackage(ctx, v1.UUID, dom.PackageInput{StorageURI: "oss://local-coding/x/a.tgz", FileSizeBytes: 10, SHA256: "ab"}); err != nil {
		t.Fatal(err)
	}
	// draft → canary (581) → current
	can, err := repo.Publish(ctx, v1.UUID, dom.PublishInput{Mode: dom.PublishModeCanary, TenantIDs: []int64{581}})
	if err != nil {
		t.Fatal(err)
	}
	if can.Status != dom.StatusCanary || fmt.Sprint(can.CanaryTenantIDs) != "[581]" || can.PublishedAt == nil {
		t.Fatalf("canary row: %+v", can)
	}
	// a second canary overlapping tenant 581 is rejected
	v2, _ := repo.Create(ctx, input("0.154.0"))
	_, _ = repo.SetPackage(ctx, v2.UUID, dom.PackageInput{StorageURI: "oss://local-coding/y/b.tgz", FileSizeBytes: 10, SHA256: "cd"})
	if _, err := repo.Publish(ctx, v2.UUID, dom.PublishInput{Mode: dom.PublishModeCanary, TenantIDs: []int64{1, 581}}); !errors.Is(err, dom.ErrCanaryTenantOverlap) {
		t.Fatalf("overlap: %v", err)
	}
	// non-overlapping canary is fine
	if _, err := repo.Publish(ctx, v2.UUID, dom.PublishInput{Mode: dom.PublishModeCanary, TenantIDs: []int64{1}}); err != nil {
		t.Fatal(err)
	}
	// v1 canary → current; v2 stays canary for tenant 1
	cur, err := repo.Publish(ctx, v1.UUID, dom.PublishInput{Mode: dom.PublishModeCurrent})
	if err != nil {
		t.Fatal(err)
	}
	if cur.Status != dom.StatusCurrent || len(cur.CanaryTenantIDs) != 0 {
		t.Fatalf("current row: %+v", cur)
	}
	// v2 → current: v1 becomes previous
	if _, err := repo.Publish(ctx, v2.UUID, dom.PublishInput{Mode: dom.PublishModeCurrent}); err != nil {
		t.Fatal(err)
	}
	// v3 → current: v1 (previous) deprecated, v2 previous
	v3, _ := repo.Create(ctx, input("0.155.0"))
	_, _ = repo.SetPackage(ctx, v3.UUID, dom.PackageInput{StorageURI: "oss://local-coding/z/c.tgz", FileSizeBytes: 10, SHA256: "ef"})
	if _, err := repo.Publish(ctx, v3.UUID, dom.PublishInput{Mode: dom.PublishModeCurrent}); err != nil {
		t.Fatal(err)
	}
	status := func(uuid string) string {
		v, err := repo.GetByUUID(ctx, uuid)
		if err != nil {
			t.Fatal(err)
		}
		return v.Status
	}
	if status(v1.UUID) != dom.StatusDeprecated || status(v2.UUID) != dom.StatusPrevious || status(v3.UUID) != dom.StatusCurrent {
		t.Fatalf("chain: v1=%s v2=%s v3=%s", status(v1.UUID), status(v2.UUID), status(v3.UUID))
	}
	// published rows are immutable through Update / SetPackage
	if _, err := repo.Update(ctx, v3.UUID, input("0.155.0")); !errors.Is(err, dom.ErrNotDraft) {
		t.Fatalf("immutable update: %v", err)
	}
	if _, err := repo.SetPackage(ctx, v3.UUID, dom.PackageInput{StorageURI: "oss://x", FileSizeBytes: 1, SHA256: "a"}); !errors.Is(err, dom.ErrNotDraft) {
		t.Fatalf("immutable package: %v", err)
	}
	// ListActive excludes deprecated and includes universal rows
	universal := input("9.9.9")
	universal.TargetID, universal.Arch, universal.Layout = dom.TargetClaudeDesktop, dom.ArchUniversal, dom.LayoutAppBundleZip
	u, _ := repo.Create(ctx, universal)
	_, _ = repo.SetPackage(ctx, u.UUID, dom.PackageInput{StorageURI: "oss://local-coding/u/d.zip", FileSizeBytes: 10, SHA256: "01"})
	if _, err := repo.Publish(ctx, u.UUID, dom.PublishInput{Mode: dom.PublishModeCurrent}); err != nil {
		t.Fatal(err)
	}
	active, err := repo.ListActive(ctx, dom.PlatformMacOS, dom.ArchArm64)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]string{}
	for _, v := range active {
		seen[v.Version] = v.Status
	}
	if seen["0.153.4"] != "" || seen["0.154.0"] != dom.StatusPrevious || seen["0.155.0"] != dom.StatusCurrent || seen["9.9.9"] != dom.StatusCurrent {
		t.Fatalf("ListActive: %v", seen)
	}
	// deprecate current → no current remains; delete only draft/deprecated
	if _, err := repo.Deprecate(ctx, v3.UUID, 0); err != nil {
		t.Fatal(err)
	}
	if err := repo.Delete(ctx, v2.UUID, 0); !errors.Is(err, dom.ErrInvalidStatus) {
		t.Fatalf("delete previous must be refused: %v", err)
	}
	if err := repo.Delete(ctx, v3.UUID, 0); err != nil {
		t.Fatalf("delete deprecated: %v", err)
	}
	if _, err := repo.GetByUUID(ctx, v3.UUID); err == nil {
		t.Fatal("deleted row must be gone")
	}

	// Platform-level rollback (2026-09-10), on its own target so the rows
	// above stay as the earlier assertions left them: a previous row goes
	// back to current (old current -> previous, old previous -> deprecated),
	// and so does a deprecated row; a current row cannot be re-published and
	// a previous row cannot become canary.
	claude := func(version string) dom.UpsertInput {
		in := input(version)
		in.TargetID = dom.TargetClaudeCLI
		return in
	}
	var c [3]*dom.Version
	for i, version := range []string{"2.1.263", "2.1.270", "2.1.280"} {
		row, err := repo.Create(ctx, claude(version))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := repo.SetPackage(ctx, row.UUID, dom.PackageInput{StorageURI: "oss://local-coding/c/" + version + ".tgz", FileSizeBytes: 10, SHA256: "aa"}); err != nil {
			t.Fatal(err)
		}
		if _, err := repo.Publish(ctx, row.UUID, dom.PublishInput{Mode: dom.PublishModeCurrent}); err != nil {
			t.Fatal(err)
		}
		c[i] = row
	}
	// now: c3 current, c2 previous, c1 deprecated
	if status(c[0].UUID) != dom.StatusDeprecated || status(c[1].UUID) != dom.StatusPrevious || status(c[2].UUID) != dom.StatusCurrent {
		t.Fatalf("claude chain: %s / %s / %s", status(c[0].UUID), status(c[1].UUID), status(c[2].UUID))
	}
	if _, err := repo.Publish(ctx, c[1].UUID, dom.PublishInput{Mode: dom.PublishModeCurrent}); err != nil {
		t.Fatalf("rollback previous → current: %v", err)
	}
	if status(c[1].UUID) != dom.StatusCurrent || status(c[2].UUID) != dom.StatusPrevious || status(c[0].UUID) != dom.StatusDeprecated {
		t.Fatalf("after rollback: %s / %s / %s", status(c[0].UUID), status(c[1].UUID), status(c[2].UUID))
	}
	if _, err := repo.Publish(ctx, c[1].UUID, dom.PublishInput{Mode: dom.PublishModeCurrent}); !errors.Is(err, dom.ErrInvalidStatus) {
		t.Fatalf("re-publishing current: %v", err)
	}
	if _, err := repo.Publish(ctx, c[2].UUID, dom.PublishInput{Mode: dom.PublishModeCanary, TenantIDs: []int64{7}}); !errors.Is(err, dom.ErrInvalidStatus) {
		t.Fatalf("previous → canary: %v", err)
	}
	// Deprecated back to current: the partial unique indexes on current /
	// previous hold throughout the transaction.
	if _, err := repo.Publish(ctx, c[0].UUID, dom.PublishInput{Mode: dom.PublishModeCurrent}); err != nil {
		t.Fatalf("rollback deprecated → current: %v", err)
	}
	if status(c[0].UUID) != dom.StatusCurrent || status(c[1].UUID) != dom.StatusPrevious || status(c[2].UUID) != dom.StatusDeprecated {
		t.Fatalf("after deprecated rollback: %s / %s / %s", status(c[0].UUID), status(c[1].UUID), status(c[2].UUID))
	}

	// Mirror bookkeeping (000144): state transitions and the storage swap that
	// only applies when size and hash still match the row.
	ext, err := repo.Create(ctx, input("7.7.7"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.SetPackage(ctx, ext.UUID, dom.PackageInput{StorageURI: "https://registry.npmmirror.com/x/y.tgz", FileSizeBytes: 42, SHA256: "ab"}); err != nil {
		t.Fatal(err)
	}
	if err := repo.SetMirrorState(ctx, ext.UUID, dom.MirrorStateRunning, ""); err != nil {
		t.Fatal(err)
	}
	if got, _ := repo.GetByUUID(ctx, ext.UUID); got.MirrorState != dom.MirrorStateRunning {
		t.Fatalf("mirror state: %+v", got)
	}
	if _, err := repo.ReplaceStorage(ctx, ext.UUID, "oss://local-coding/"+ext.UUID+"/y.tgz", 43, "ab", 0); !errors.Is(err, dom.ErrMirrorMismatch) {
		t.Fatalf("size mismatch should refuse: %v", err)
	}
	if _, err := repo.ReplaceStorage(ctx, ext.UUID, "oss://local-coding/"+ext.UUID+"/y.tgz", 42, "cd", 0); !errors.Is(err, dom.ErrMirrorMismatch) {
		t.Fatalf("hash mismatch should refuse: %v", err)
	}
	swapped, err := repo.ReplaceStorage(ctx, ext.UUID, "oss://local-coding/"+ext.UUID+"/y.tgz", 42, "ab", 0)
	if err != nil {
		t.Fatal(err)
	}
	if swapped.StorageURI != "oss://local-coding/"+ext.UUID+"/y.tgz" || swapped.MirrorState != dom.MirrorStateDone || swapped.MirrorError != "" || swapped.FileSizeBytes != 42 || swapped.SHA256 != "ab" {
		t.Fatalf("after ReplaceStorage: %+v", swapped)
	}
	if err := repo.SetMirrorState(ctx, ext.UUID, dom.MirrorStateFailed, "下载失败"); err != nil {
		t.Fatal(err)
	}
	if got, _ := repo.GetByUUID(ctx, ext.UUID); got.MirrorState != dom.MirrorStateFailed || got.MirrorError != "下载失败" {
		t.Fatalf("failed state: %+v", got)
	}
	// Startup recovery: only rows at running flip to failed with the reason.
	if err := repo.SetMirrorState(ctx, ext.UUID, dom.MirrorStateRunning, ""); err != nil {
		t.Fatal(err)
	}
	if n, err := repo.ResetRunningMirrors(ctx, "搬入被服务重启中断"); err != nil || n != 1 {
		t.Fatalf("ResetRunningMirrors: n=%d err=%v", n, err)
	}
	if got, _ := repo.GetByUUID(ctx, ext.UUID); got.MirrorState != dom.MirrorStateFailed || got.MirrorError != "搬入被服务重启中断" {
		t.Fatalf("after reset: %s / %q", got.MirrorState, got.MirrorError)
	}
	if n, err := repo.ResetRunningMirrors(ctx, "again"); err != nil || n != 0 {
		t.Fatalf("second ResetRunningMirrors: n=%d err=%v", n, err)
	}
	if err := repo.SetMirrorState(ctx, "00000000-0000-4000-8000-000000000000", dom.MirrorStateDone, ""); err == nil {
		t.Fatal("unknown uuid should fail")
	}
}

// Migration 000151: share link columns, candidate selection, clearing on
// package change.
func TestIntegrationShareLinkColumns(t *testing.T) {
	repo, closeFn := integrationRepo(t)
	defer closeFn()
	ctx := context.Background()
	far := time.Now().Add(400 * 24 * time.Hour)

	v, err := repo.Create(ctx, input("0.160.0"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.SetPackage(ctx, v.UUID, dom.PackageInput{StorageURI: "oss://local-coding/s/a.tgz", FileSizeBytes: 10, SHA256: "ab"}); err != nil {
		t.Fatal(err)
	}
	// drafts are never candidates
	if rows, err := repo.ListShareRefreshCandidates(ctx, far, 10); err != nil || len(rows) != 0 {
		t.Fatalf("draft candidates: %d %v", len(rows), err)
	}
	if _, err := repo.Publish(ctx, v.UUID, dom.PublishInput{Mode: dom.PublishModeCurrent}); err != nil {
		t.Fatal(err)
	}
	rows, err := repo.ListShareRefreshCandidates(ctx, far, 10)
	if err != nil || len(rows) != 1 || rows[0].UUID != v.UUID || rows[0].ShareURL != "" || rows[0].ShareExpiresAt != nil {
		t.Fatalf("published row without link must be a candidate: %+v %v", rows, err)
	}
	expires := time.Now().Add(365 * 24 * time.Hour).Truncate(time.Microsecond)
	if err := repo.SetShareLink(ctx, v.UUID, dom.ShareLinkInput{Code: "AbC123", URL: "https://s3.example.cn/s/AbC123/origin", ExpiresAt: expires}); err != nil {
		t.Fatal(err)
	}
	got, err := repo.GetByUUID(ctx, v.UUID)
	if err != nil || got.ShareCode != "AbC123" || got.ShareURL != "https://s3.example.cn/s/AbC123/origin" || got.ShareExpiresAt == nil || !got.ShareExpiresAt.Equal(expires) {
		t.Fatalf("stored link: %+v %v", got, err)
	}
	// candidate only once the refresh window reaches the expiry
	if rows, _ := repo.ListShareRefreshCandidates(ctx, expires.Add(-11*24*time.Hour), 10); len(rows) != 0 {
		t.Fatalf("fresh link must not be a candidate: %+v", rows)
	}
	if rows, _ := repo.ListShareRefreshCandidates(ctx, expires.Add(time.Hour), 10); len(rows) != 1 {
		t.Fatalf("expiring link must be a candidate: %+v", rows)
	}
	// external packages are never candidates; the copy into the store clears
	// the (absent) link and makes the row one, sorted before rows with a link
	extIn := input("0.161.0")
	extIn.ExternalURL, extIn.FileSizeBytes, extIn.SHA256 = "https://dl.example.cn/b.tgz", 20, "cd"
	ext, err := repo.Create(ctx, extIn)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.Publish(ctx, ext.UUID, dom.PublishInput{Mode: dom.PublishModeCanary, TenantIDs: []int64{581}}); err != nil {
		t.Fatal(err)
	}
	if rows, _ := repo.ListShareRefreshCandidates(ctx, far, 10); len(rows) != 1 || rows[0].UUID != v.UUID {
		t.Fatalf("external row must not be a candidate: %+v", rows)
	}
	if err := repo.SetShareLink(ctx, ext.UUID, dom.ShareLinkInput{Code: "x", URL: "https://s3.example.cn/s/x/origin", ExpiresAt: expires}); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.ReplaceStorage(ctx, ext.UUID, "oss://local-coding/s/b.tgz", 20, "cd", 0); err != nil {
		t.Fatal(err)
	}
	rows, _ = repo.ListShareRefreshCandidates(ctx, far, 10)
	if len(rows) != 2 || rows[0].UUID != ext.UUID || rows[0].ShareURL != "" || rows[0].ShareExpiresAt != nil || rows[1].UUID != v.UUID {
		t.Fatalf("copy must clear the link and sort the row first: %+v", rows)
	}
	if rows, _ := repo.ListShareRefreshCandidates(ctx, far, 1); len(rows) != 1 || rows[0].UUID != ext.UUID {
		t.Fatalf("limit: %+v", rows)
	}
	// replacing a draft's package clears its link too
	v2, err := repo.Create(ctx, input("0.162.0"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.SetPackage(ctx, v2.UUID, dom.PackageInput{StorageURI: "oss://local-coding/s/c.tgz", FileSizeBytes: 30, SHA256: "ef"}); err != nil {
		t.Fatal(err)
	}
	if err := repo.SetShareLink(ctx, v2.UUID, dom.ShareLinkInput{Code: "y", URL: "https://s3.example.cn/s/y/origin", ExpiresAt: expires}); err != nil {
		t.Fatal(err)
	}
	after, err := repo.SetPackage(ctx, v2.UUID, dom.PackageInput{StorageURI: "oss://local-coding/s/c2.tgz", FileSizeBytes: 31, SHA256: "ef2"})
	if err != nil || after.ShareCode != "" || after.ShareURL != "" || after.ShareExpiresAt != nil {
		t.Fatalf("SetPackage must clear the link: %+v %v", after, err)
	}
	if err := repo.SetShareLink(ctx, "00000000-0000-4000-8000-000000000000", dom.ShareLinkInput{Code: "z", URL: "https://s3.example.cn/s/z/origin", ExpiresAt: expires}); err == nil {
		t.Fatal("unknown uuid must fail")
	}
}
