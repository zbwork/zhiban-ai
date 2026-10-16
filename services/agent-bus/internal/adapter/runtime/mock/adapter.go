// Package mock 是一个回声型 Runtime adapter，用于本地开发与测试。
//
// 行为：把用户最后一句话拆成若干 chunk，逐 chunk 推 delta，最后推 final + markdown block。
package mock

import (
	"context"
	"errors"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/runtime"
)

type Adapter struct{}

func New() *Adapter { return &Adapter{} }

func (a *Adapter) Name() string { return "mock" }

func (a *Adapter) HealthCheck(ctx context.Context) error { return ctx.Err() }

func (a *Adapter) Stream(ctx context.Context, req runtime.StreamRequest) (runtime.Stream, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if req.UserMessage == "" && len(req.UserBlocks) == 0 {
		return nil, errors.New("empty user message")
	}
	s := &stream{
		ctx:   ctx,
		text:  req.UserMessage,
		agent: req.AgentUUID,
		ch:    make(chan runtime.StreamEvent, 8),
		done:  make(chan struct{}),
	}
	go s.run(ctx)
	return s, nil
}

type stream struct {
	ctx       context.Context
	closeOnce sync.Once
	text      string
	agent     string
	ch        chan runtime.StreamEvent
	done      chan struct{}
}

func (s *stream) run(ctx context.Context) {
	defer close(s.ch)
	intro := "Mock Agent " + s.agent + " 收到你的消息: "
	full := intro + s.text
	// chunk by 12 chars to fake stream
	cur := ""
	runes := []rune(full)
	for i := 0; i < len(runes); i += 12 {
		end := i + 12
		if end > len(runes) {
			end = len(runes)
		}
		cur += string(runes[i:end])
		select {
		case <-ctx.Done():
			return
		case <-s.done:
			return
		case s.ch <- runtime.StreamEvent{Kind: "delta", Text: cur}:
		}
		timer := time.NewTimer(80 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-s.done:
			timer.Stop()
			return
		case <-timer.C:
		}
	}
	// final: markdown block + suggestions
	finalBlocks := []map[string]any{
		{"type": "markdown", "text": full},
		{"type": "suggestion", "items": suggestions(s.text)},
	}
	select {
	case <-ctx.Done():
	case <-s.done:
	case s.ch <- runtime.StreamEvent{Kind: "final", Blocks: finalBlocks, Final: true}:
	}
}

func suggestions(text string) []string {
	out := []string{"详细解释一下", "举个例子", "下一步该做什么?"}
	if strings.Contains(text, "?") || strings.Contains(text, "？") {
		out = append([]string{"换个角度再问一次"}, out...)
	}
	if len(out) > 3 {
		out = out[:3]
	}
	return out
}

func (s *stream) Recv() (runtime.StreamEvent, error) {
	if err := s.ctx.Err(); err != nil {
		return runtime.StreamEvent{}, err
	}
	select {
	case <-s.ctx.Done():
		return runtime.StreamEvent{}, s.ctx.Err()
	case <-s.done:
		return runtime.StreamEvent{}, io.EOF
	case ev, ok := <-s.ch:
		if !ok {
			return runtime.StreamEvent{}, io.EOF
		}
		return ev, nil
	}
}
func (s *stream) Close() error {
	s.closeOnce.Do(func() { close(s.done) })
	return nil
}
