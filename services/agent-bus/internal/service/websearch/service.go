package websearch

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/websearch"
)

const Timeout = 20 * time.Second

type Service struct{ provider dom.Provider }

func New(provider dom.Provider) *Service { return &Service{provider: provider} }

func (s *Service) Search(ctx context.Context, in dom.Request) (dom.Response, error) {
	in.Query = strings.TrimSpace(in.Query)
	if in.Query == "" || !utf8.ValidString(in.Query) || utf8.RuneCountInString(in.Query) > 500 || strings.IndexFunc(in.Query, unicode.IsControl) >= 0 || in.Limit < 1 || in.Limit > 10 {
		return dom.Response{}, dom.ErrInvalid
	}
	if s.provider == nil {
		return dom.Response{}, dom.ErrUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, Timeout)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return dom.Response{}, err
	}
	result, err := s.provider.Search(ctx, in)
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return dom.Response{}, dom.ErrTimeout
	}
	if ctx.Err() != nil {
		return dom.Response{}, ctx.Err()
	}
	return result, err
}
