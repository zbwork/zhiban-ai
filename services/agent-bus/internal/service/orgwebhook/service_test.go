package orgwebhook

import (
	"strings"
	"testing"
)

func TestCleanEventTypes(t *testing.T) {
	got, err := cleanEventTypes([]string{
		"org.member.created",
		"org.member.created",
		"org.department.updated",
	})
	if err != nil {
		t.Fatalf("cleanEventTypes returned error: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("len=%d, want 2 (%v)", len(got), got)
	}

	if _, err := cleanEventTypes([]string{"org.unknown.created"}); err == nil {
		t.Fatalf("unknown event type should be rejected")
	}
}

func TestCleanCallbackURL(t *testing.T) {
	svc := New(Deps{})
	if _, err := svc.cleanCallbackURL("http://example.com/hook"); err == nil {
		t.Fatalf("http callback should be rejected")
	}
	if _, err := svc.cleanCallbackURL("https://127.0.0.1/hook"); err == nil {
		t.Fatalf("loopback callback should be rejected")
	}
	if _, err := svc.cleanCallbackURL("https://169.254.169.254/latest/meta-data"); err == nil {
		t.Fatalf("metadata callback should be rejected")
	}
}

func TestCleanCallbackURL_AllowLocalCallbacks(t *testing.T) {
	svc := New(Deps{AllowLocalCallbacks: true})
	if _, err := svc.cleanCallbackURL("http://127.0.0.1:7801/api/org-sync/webhook"); err != nil {
		t.Fatalf("local callback should be allowed in dev mode: %v", err)
	}
}

func TestGenSigningSecret(t *testing.T) {
	secret, err := genSigningSecret()
	if err != nil {
		t.Fatalf("genSigningSecret: %v", err)
	}
	if !strings.HasPrefix(secret, "whsec_") {
		t.Fatalf("secret prefix=%q, want whsec_", secret)
	}
	if len(secret) < 40 {
		t.Fatalf("secret too short: %d", len(secret))
	}
}
