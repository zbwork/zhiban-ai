package drive

import (
	"context"
	"testing"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/drive"
)

type testOverrides struct{ value *dom.StorageOverride }

func (r *testOverrides) GetTenantOverride(context.Context, int64) (*dom.StorageOverride, error) {
	return r.value, nil
}

func TestUploadDoesNotChangeLocationAfterClearingOverride(t *testing.T) {
	bucket := "private-bucket"
	overrides := &testOverrides{value: &dom.StorageOverride{TenantID: 1, Bucket: &bucket, Status: dom.StorageStatusActive}}
	routing := &DriveStorage{
		base: &Storage{bucket: "default-bucket"}, overrides: overrides,
		allowed: map[int64]map[string]bool{1: {bucket: true}},
	}
	store := &tenantStore{routing: routing, tenantID: 1}
	const staging = "staging/1/pending.txt"
	const final = "tenants/1/accounts/8/202611/file.txt"
	staged, finished, err := store.UploadKeys(context.Background(), staging, final)
	if err != nil || staged == staging || finished == final {
		t.Fatalf("allocate routed keys: %v", err)
	}

	overrides.value = nil
	for physical, saved := range map[string]string{staging: staged, final: finished} {
		gotBucket, gotKey, err := store.locate(saved)
		if err != nil || gotBucket != bucket || gotKey != physical {
			t.Fatalf("routed key resolved to %q %q: %v", gotBucket, gotKey, err)
		}
	}
	gotBucket, gotKey, err := store.locate(final)
	if err != nil || gotBucket != "default-bucket" || gotKey != final {
		t.Fatalf("legacy key resolved to %q %q: %v", gotBucket, gotKey, err)
	}
	if _, _, err := (&tenantStore{routing: routing, tenantID: 2}).locate(finished); err == nil {
		t.Fatal("another tenant accepted the object location")
	}
}

func TestEndpointCustomizationsDoNotSelectDriveBucket(t *testing.T) {
	bucket := "private-bucket"
	endpoint := "http://different-storage.invalid"
	routing := &DriveStorage{base: &Storage{bucket: "default-bucket"}, allowed: map[int64]map[string]bool{1: {bucket: true}}}
	override := &dom.StorageOverride{TenantID: 1, Bucket: &bucket, Status: dom.StorageStatusActive, Endpoint: &endpoint}
	if got := routing.EffectiveBucket(override); got != "default-bucket" {
		t.Fatalf("override selected %q despite using a different storage endpoint", got)
	}
	override.TenantID, override.Endpoint = 2, nil
	if got := routing.EffectiveBucket(override); got != "default-bucket" {
		t.Fatalf("override selected a bucket approved for another tenant: %q", got)
	}
}
