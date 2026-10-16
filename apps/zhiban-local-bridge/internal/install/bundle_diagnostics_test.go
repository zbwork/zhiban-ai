package install

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/diagnostics"
	"github.com/zbwork/zhiban-ai/apps/zhiban-local-bridge/internal/operation"
)

func TestBundleFailureDetailSurvivesOperationAndPersistentDiagnostics(t *testing.T) {
	for _, tc := range []struct {
		stage string
		kind  error
		cause string
	}{
		{"解压安装包", errArchiveInvalid, "ditto: exit status 1; invalid zip"},
		{"检查应用目录", errArchiveInvalid, "未找到预期的应用目录"},
		{"验证应用签名（codesign）", errPublisherMismatch, "codesign: exit status 1; a sealed resource is missing or invalid"},
		{"系统安全检查（Gatekeeper）", errPublisherMismatch, "spctl: exit status 3; source=Unnotarized Developer ID"},
	} {
		t.Run(tc.stage, func(t *testing.T) {
			err := newBundleFailure(tc.kind, tc.stage, errors.New(tc.cause))
			mapped := (&Manager{}).mapPlaceError(TargetCodexDesktop, err)
			var failure *operation.Failure
			if !errors.As(mapped, &failure) || !errors.Is(mapped, tc.kind) || failure.Code != "LCT-CODEX_DESKTOP-INSTALL-PUBLISHER_MISMATCH" {
				t.Fatalf("mapped failure = %v", mapped)
			}
			if !strings.Contains(failure.Detail, tc.stage) || !strings.Contains(failure.Detail, tc.cause) {
				t.Fatal(failure.Detail)
			}
			path := filepath.Join(t.TempDir(), "diagnostics.json")
			r := diagnostics.NewPersistentRecorder("test", nil, path)
			r.Observe(operation.Event{Envelope: operation.Envelope{State: operation.StateFailed, TargetID: TargetCodexDesktop,
				Kind: "install", Stage: StageInstalling, ErrorCode: &failure.Code, ErrorDetail: &failure.Detail}})
			latest := diagnostics.NewPersistentRecorder("test", nil, path).Latest(TargetCodexDesktop)
			if latest.ErrorDetail == nil || *latest.ErrorDetail != failure.Detail {
				t.Fatalf("lost detail: %+v", latest)
			}
		})
	}
}

func TestNativeBundleDetailRedactsAndBounds(t *testing.T) {
	path := "/Users/private user/Applications/Codex.app"
	message := path + ": invalid signature\nIn subcomponent: " + path + "/Contents/Helper.app\n" +
		"https://example.test/download?token=private bearer secret-value password=private-key sk-secretValue123 " + strings.Repeat("a", 60)
	err := nativeToolFailure("codesign", errors.New("exit status 1"), message, []string{"--verify", path})
	detail := newBundleFailure(errPublisherMismatch, "验证应用签名", err).Error()
	for _, secret := range []string{"private user", "Helper.app", "example.test", "private-key", "secret-value", "secretValue123", strings.Repeat("a", 60)} {
		if strings.Contains(detail, secret) {
			t.Fatalf("leaked %q: %s", secret, detail)
		}
	}
	if !strings.Contains(detail, "codesign: exit status 1") || !strings.Contains(detail, "invalid signature") {
		t.Fatal(detail)
	}
	for _, value := range []string{strings.Repeat("错误 ", 2000), "invalid\x00\x1b\n\xffutf8"} {
		got := safeBundleDetail(value)
		if len(got) > 900 || !utf8.ValidString(got) || strings.ContainsAny(got, "\x00\x1b\n") {
			t.Fatalf("unsafe detail: %q", got)
		}
	}
}

func TestNativeToolFailurePreservesTimeout(t *testing.T) {
	err := nativeToolFailure("spctl", context.DeadlineExceeded, "", nil)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
	detail := bundleFailureDetail(newBundleFailure(errPublisherMismatch, "系统安全检查", err))
	if !strings.Contains(detail, "spctl") || !strings.Contains(detail, "context deadline exceeded") {
		t.Fatal(detail)
	}
}
