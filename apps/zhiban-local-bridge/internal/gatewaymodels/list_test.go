package gatewaymodels

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
)

func TestListReadsDistinctModelIDsWithBearerKey(t *testing.T) {
	t.Parallel()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/models" || r.Header.Get("Authorization") != "Bearer member-key" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{"object":"list","data":[{"id":"gpt-5.6-luna"},{"id":" gpt-5.5 "},{"id":"gpt-5.6-luna"},{"id":""}]}`))
	}))
	defer server.Close()
	ids, err := List(context.Background(), server.Client(), server.URL+"/v1/", "member-key")
	if err != nil || !reflect.DeepEqual(ids, []string{"gpt-5.6-luna", "gpt-5.5"}) {
		t.Fatalf("List() = %v, %v", ids, err)
	}
	if _, err := List(context.Background(), server.Client(), server.URL+"/v1", "wrong"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("List() with a rejected key error = %v", err)
	}
	if _, err := List(context.Background(), server.Client(), "http://api.example/v1", "member-key"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("List() over http error = %v", err)
	}
}

func TestListRejectsAnEmptyOrMalformedList(t *testing.T) {
	t.Parallel()
	for _, body := range []string{`{"data":[]}`, `not json`} {
		server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(body))
		}))
		if _, err := List(context.Background(), server.Client(), server.URL+"/v1", "k"); !errors.Is(err, ErrInvalid) {
			t.Fatalf("List(%q) error = %v", body, err)
		}
		server.Close()
	}
}
