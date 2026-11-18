package oss

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHeadBucketRejectsMissingBucketAndRedirects(t *testing.T) {
	for _, status := range []int{http.StatusOK, http.StatusNotFound, http.StatusTemporaryRedirect} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodHead || r.URL.Path != "/test-bucket/" ||
					!strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 ") {
					t.Errorf("expected signed HEAD for the bucket, got %s %s", r.Method, r.URL.Path)
				}
				w.Header().Set("Location", "/unexpected")
				w.WriteHeader(status)
			}))
			defer server.Close()

			store, err := New(Config{
				Endpoint: server.URL, Bucket: "test-bucket",
				AccessKeyID: "test", SecretAccessKey: "test", ForcePathStyle: true,
			})
			if err != nil {
				t.Fatal(err)
			}
			if err := store.HeadBucket(context.Background()); (err == nil) != (status == http.StatusOK) {
				t.Fatalf("HTTP %d: HeadBucket returned %v", status, err)
			}
		})
	}
}
