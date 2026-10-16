package install

import (
	"context"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

func TestAuthorizationPrecedesDownload(t *testing.T) {
	for _, reason := range []string{"AUTHORIZATION_CANCELLED", "AUTHORIZATION_TIMEOUT", "AUTHORIZATION_FAILED"} {
		t.Run(reason, func(t *testing.T) {
			var requests atomic.Int32
			f := newFixture(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests.Add(1); w.WriteHeader(503) }), func(assets map[string]Asset) {
				base := strings.TrimSuffix(assets[TargetCodexCLI].Sources[0].URL, "/codex.tar.gz")
				assets[TargetClaudeDesktop] = Asset{TargetID: TargetClaudeDesktop, Arch: ArchARM64, Version: testDesktopVersion, Source: SourceOfficialAnthropic, BundleName: testDesktopBundle, BundleIdentifier: testDesktopID, TeamIdentifier: testDesktopTeam, Sources: []Source{{Kind: SourceKindOfficial, URL: base + "/desktop.zip", Size: 1, SHA256: strings.Repeat("0", 64), Layout: LayoutAppBundleZip}}}
			})
			f.manager.osVersion = func() (string, error) { return minOSVersion(), nil }
			entered, release := make(chan struct{}), make(chan struct{})
			f.manager.prepareRegistration = func(ctx context.Context, report *operation.Reporter, asset Asset, path, mode string) (packageRegistration, error) {
				report.Stage(StageAuthorizing, true)
				close(entered)
				select {
				case <-release:
				case <-ctx.Done():
					return nil, ctx.Err()
				}
				return nil, operation.Fail(installCode(asset.TargetID, reason), nil)
			}
			plan, err := f.manager.Plan(context.Background(), TargetClaudeDesktop, ModeInstall)
			if err != nil {
				t.Fatal(err)
			}
			op, err := f.manager.Execute(context.Background(), plan.PlanID)
			if err != nil {
				t.Fatal(err)
			}
			select {
			case <-entered:
			case <-time.After(3 * time.Second):
				t.Fatal("did not request authorization")
			}
			current, err := f.registry.Get(op.OperationID)
			if err != nil || current.Stage != StageAuthorizing || current.State != operation.StateRunning || current.ProgressValue != nil {
				t.Fatalf("waiting state=%+v err=%v", current, err)
			}
			if requests.Load() != 0 {
				t.Fatal("network requested before consent")
			}
			close(release)
			deadline := time.Now().Add(3 * time.Second)
			for time.Now().Before(deadline) {
				current, err = f.registry.Get(op.OperationID)
				if err != nil {
					t.Fatal(err)
				}
				if current.State != operation.StateRunning {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			if current.State != operation.StateFailed || current.ErrorCode == nil || *current.ErrorCode != installCode(TargetClaudeDesktop, reason) {
				t.Fatalf("result=%+v", current)
			}
			if requests.Load() != 0 {
				t.Fatal("network requested after denied consent")
			}
		})
	}
}
