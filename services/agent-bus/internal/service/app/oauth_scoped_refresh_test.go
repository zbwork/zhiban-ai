package app

import (
	"context"
	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/app"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
	oauth "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/oauth2"
	"testing"
)

type scopedRefreshFake struct {
	dom.RefreshTokenRepo
	hash     string
	clientID int64
	consumed bool
}

func (f *scopedRefreshFake) ConsumeAndRotateForClient(_ context.Context, hash string, id int64) (*dom.RefreshToken, error) {
	if hash != f.hash || id != f.clientID || f.consumed {
		return nil, apperr.ErrNotFound
	}
	f.consumed = true
	return &dom.RefreshToken{OAuthClientID: id}, nil
}
func TestScopedRefreshRejectsOtherClientWithoutConsuming(t *testing.T) {
	repo := &scopedRefreshFake{hash: oauth.HashSecret("rt_test"), clientID: 7}
	s := New(Deps{RefreshTokens: repo})
	if _, err := s.ConsumeRefreshTokenForClient(context.Background(), "rt_test", 8); err == nil || repo.consumed {
		t.Fatal("foreign client consumed token")
	}
	if _, err := s.ConsumeRefreshTokenForClient(context.Background(), "rt_test", 7); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ConsumeRefreshTokenForClient(context.Background(), "rt_test", 7); err == nil {
		t.Fatal("replayed token accepted")
	}
}
