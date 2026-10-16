package claudecode

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSupportsThirdPartyInferenceReadsTheAppArchive(t *testing.T) {
	write := func(content string) string {
		bundle := filepath.Join(t.TempDir(), "Claude.app")
		asar := filepath.Join(bundle, asarRelativePath)
		if err := os.MkdirAll(filepath.Dir(asar), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(asar, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		return bundle
	}
	if supported, known := SupportsThirdPartyInference(write(`{"inferenceGatewayBaseUrl":1,"inferenceCredentialHelper":2}`)); !supported || !known {
		t.Fatalf("current app = %v, %v", supported, known)
	}
	if supported, known := SupportsThirdPartyInference(write(`{"inferenceGatewayBaseUrl":1}`)); supported || !known {
		t.Fatalf("app without the credential helper key = %v, %v", supported, known)
	}
	if supported, known := SupportsThirdPartyInference(filepath.Join(t.TempDir(), "Missing.app")); supported || known {
		t.Fatalf("unreadable app must be unknown, got %v, %v", supported, known)
	}
}
