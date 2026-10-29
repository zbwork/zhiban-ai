package websearch

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/websearch"
)

type providerFunc func(context.Context, dom.Request) (dom.Response, error)

func (p providerFunc) Search(ctx context.Context, in dom.Request) (dom.Response, error) {
	return p(ctx, in)
}

func TestValidationAndCancellationBeforeProvider(t *testing.T) {
	calls := 0
	s := New(providerFunc(func(ctx context.Context, in dom.Request) (dom.Response, error) {
		calls++
		if in.Query != "新闻" || in.Limit != 3 {
			t.Fatal("normalization mismatch")
		}
		return dom.Response{}, nil
	}))
	for _, in := range []dom.Request{{Query: " ", Limit: 5}, {Query: strings.Repeat("新", 501), Limit: 5}, {Query: "a\nb", Limit: 5}, {Query: "a", Limit: 0}, {Query: "a", Limit: 11}} {
		if _, err := s.Search(context.Background(), in); !errors.Is(err, dom.ErrInvalid) {
			t.Fatalf("expected invalid: %v", err)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := s.Search(ctx, dom.Request{Query: "新闻", Limit: 3}); !errors.Is(err, context.Canceled) {
		t.Fatal("cancelled context accepted")
	}
	if calls != 0 {
		t.Fatal("invalid/cancelled requests reached provider")
	}
	if _, err := s.Search(context.Background(), dom.Request{Query: " 新闻 ", Limit: 3}); err != nil || calls != 1 {
		t.Fatal("valid request failed")
	}
}

func TestDeadlineAndProviderFailureAreNotEmptyResults(t *testing.T) {
	s := New(providerFunc(func(ctx context.Context, in dom.Request) (dom.Response, error) {
		<-ctx.Done()
		return dom.Response{}, ctx.Err()
	}))
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	if _, err := s.Search(ctx, dom.Request{Query: "新闻", Limit: 5}); !errors.Is(err, dom.ErrTimeout) {
		t.Fatalf("got %v", err)
	}
	if _, err := New(nil).Search(context.Background(), dom.Request{Query: "新闻", Limit: 5}); !errors.Is(err, dom.ErrUnavailable) {
		t.Fatal("missing provider accepted")
	}
}
