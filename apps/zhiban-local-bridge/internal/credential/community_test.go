package credential

import (
	"context"
	"errors"
	"testing"
)

func TestCommunityKeyStaysBoundToAddress(t *testing.T) {
	m := &CommunityManager{backend: &memoryItemBackend{}}
	ctx := context.Background()
	settings := BYOKSettings{TargetID: TargetCodexCLI, BaseURL: "https://one.example/v1/", Model: "test-model", APIKey: "test-only-key", Save: true}
	if _, err := m.Settings(ctx, settings); err != nil {
		t.Fatal(err)
	}
	settings.APIKey = ""
	settings.Model = "other-model"
	if _, err := m.Settings(ctx, settings); err != nil {
		t.Fatal("same address must retain key", err)
	}
	settings.BaseURL = "https://two.example/v1"
	if _, err := m.Settings(ctx, settings); !errors.Is(err, ErrInvalidData) {
		t.Fatalf("changed address retained key: %v", err)
	}
	old, err := m.load(ctx, TargetCodexCLI)
	if err != nil || old.BaseURL != "https://one.example/v1" || old.APIKey != "test-only-key" {
		t.Fatal("rejected save changed stored credentials")
	}
	settings.APIKey = "new-test-key"
	if _, err := m.Settings(ctx, settings); err != nil {
		t.Fatal("explicit new key rejected", err)
	}
}
