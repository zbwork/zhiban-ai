package a2a

import (
	"context"
	"strings"
	"sync"
	"time"

	doma2a "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2acalledge"
	domstream "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/a2astream"
	apperr "github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/errors"
)

const a2aStreamBufferLimit = 256

var a2aStreamStorePollInterval = time.Second

type A2AStreamEvent = domstream.Event

type A2AStreamSubscription struct {
	Events <-chan A2AStreamEvent
	Cancel func()
}

type A2AStreamStore = domstream.Repository

type A2AStreamHub interface {
	Publish(edgeUUID string, edgeCreatedAt time.Time, ev A2AStreamEvent)
	Close(edgeUUID string, edgeCreatedAt time.Time, ev A2AStreamEvent)
	Wake(edgeUUID string)
	Subscribe(edgeUUID string, edgeCreatedAt time.Time, afterSeq int64) A2AStreamSubscription
}

type localA2AStreamHub struct {
	mu      sync.Mutex
	streams map[string]*localA2AStreamState
}

type localA2AStreamState struct {
	nextSeq int64
	events  []A2AStreamEvent
	subs    map[chan A2AStreamEvent]struct{}
	closed  bool
}

func NewLocalA2AStreamHub() A2AStreamHub {
	return &localA2AStreamHub{streams: map[string]*localA2AStreamState{}}
}

func (h *localA2AStreamHub) Publish(edgeUUID string, edgeCreatedAt time.Time, ev A2AStreamEvent) {
	h.publish(edgeUUID, edgeCreatedAt, ev, false)
}

func (h *localA2AStreamHub) Close(edgeUUID string, edgeCreatedAt time.Time, ev A2AStreamEvent) {
	h.publish(edgeUUID, edgeCreatedAt, ev, true)
}

func (h *localA2AStreamHub) Wake(edgeUUID string) {
	if h == nil || strings.TrimSpace(edgeUUID) == "" {
		return
	}
	prefix := strings.TrimSpace(edgeUUID) + "|"
	h.mu.Lock()
	subs := []chan A2AStreamEvent{}
	for key, st := range h.streams {
		if st == nil || st.closed || !strings.HasPrefix(key, prefix) {
			continue
		}
		for ch := range st.subs {
			subs = append(subs, ch)
		}
	}
	h.mu.Unlock()

	ev := A2AStreamEvent{Event: "a2a.wake", EdgeUUID: strings.TrimSpace(edgeUUID), CreatedAt: time.Now().UTC()}
	for _, ch := range subs {
		select {
		case ch <- ev:
		default:
		}
	}
}

func (h *localA2AStreamHub) publish(edgeUUID string, edgeCreatedAt time.Time, ev A2AStreamEvent, closeAfter bool) {
	if h == nil || strings.TrimSpace(edgeUUID) == "" {
		return
	}
	key := a2aStreamKey(edgeUUID, edgeCreatedAt)
	h.mu.Lock()
	if h.streams == nil {
		h.streams = map[string]*localA2AStreamState{}
	}
	st := h.streams[key]
	if st == nil {
		st = &localA2AStreamState{subs: map[chan A2AStreamEvent]struct{}{}}
		h.streams[key] = st
	}
	if st.closed {
		h.mu.Unlock()
		return
	}
	if ev.Seq > 0 {
		if st.nextSeq < ev.Seq {
			st.nextSeq = ev.Seq
		}
	} else {
		st.nextSeq++
		ev.Seq = st.nextSeq
	}
	ev.EdgeUUID = edgeUUID
	ev.EdgeCreatedAt = edgeCreatedAt
	if ev.CreatedAt.IsZero() {
		ev.CreatedAt = time.Now().UTC()
	}
	st.events = append(st.events, ev)
	if len(st.events) > a2aStreamBufferLimit {
		st.events = append([]A2AStreamEvent(nil), st.events[len(st.events)-a2aStreamBufferLimit:]...)
	}
	subs := make([]chan A2AStreamEvent, 0, len(st.subs))
	for ch := range st.subs {
		subs = append(subs, ch)
	}
	if closeAfter {
		st.closed = true
		delete(h.streams, key)
	}
	h.mu.Unlock()

	for _, ch := range subs {
		select {
		case ch <- ev:
		default:
		}
	}
	if closeAfter {
		for _, ch := range subs {
			close(ch)
		}
	}
}

func (h *localA2AStreamHub) Subscribe(edgeUUID string, edgeCreatedAt time.Time, afterSeq int64) A2AStreamSubscription {
	ch := make(chan A2AStreamEvent, a2aStreamBufferLimit+32)
	if h == nil || strings.TrimSpace(edgeUUID) == "" {
		close(ch)
		return A2AStreamSubscription{Events: ch, Cancel: func() {}}
	}
	key := a2aStreamKey(edgeUUID, edgeCreatedAt)
	h.mu.Lock()
	if h.streams == nil {
		h.streams = map[string]*localA2AStreamState{}
	}
	st := h.streams[key]
	if st == nil {
		st = &localA2AStreamState{subs: map[chan A2AStreamEvent]struct{}{}}
		h.streams[key] = st
	}
	history := make([]A2AStreamEvent, 0, len(st.events))
	for _, ev := range st.events {
		if ev.Seq > afterSeq {
			history = append(history, ev)
		}
	}
	closed := st.closed
	if !closed {
		st.subs[ch] = struct{}{}
	}
	h.mu.Unlock()

	for _, ev := range history {
		ch <- ev
	}
	if closed {
		close(ch)
	}

	cancel := func() {
		h.mu.Lock()
		if st := h.streams[key]; st != nil {
			if _, ok := st.subs[ch]; ok {
				delete(st.subs, ch)
				close(ch)
			}
		}
		h.mu.Unlock()
	}
	return A2AStreamSubscription{Events: ch, Cancel: cancel}
}

func a2aStreamKey(edgeUUID string, edgeCreatedAt time.Time) string {
	return edgeUUID + "|" + edgeCreatedAt.UTC().Format(time.RFC3339Nano)
}

func (s *Service) SubscribeEdgeStream(ctx context.Context, tenantID int64, edgeUUID string, edgeCreatedAt time.Time, callerAgentID int64, afterSeq int64) (*doma2a.Edge, A2AStreamSubscription, error) {
	edge, err := s.GetEdge(ctx, tenantID, edgeUUID, edgeCreatedAt, callerAgentID)
	if err != nil {
		return nil, A2AStreamSubscription{}, err
	}
	if edge.InvokeKind != doma2a.InvokeStream {
		return nil, A2AStreamSubscription{}, apperr.ErrInvalidParams.Withf("edge is not stream invoke")
	}
	if s.deps.StreamStore != nil {
		if isA2ATerminal(edge.Status) {
			history, _ := s.deps.StreamStore.ListAfter(ctx, tenantID, edge.UUID, edge.CreatedAt, afterSeq, a2aStreamBufferLimit)
			if len(history) == 0 {
				if afterSeq > 0 {
					return edge, closedA2AStreamSubscription(nil), nil
				}
				return edge, closedA2AStreamSubscription([]A2AStreamEvent{terminalStreamEvent(edge)}), nil
			}
			return edge, closedA2AStreamSubscription(history), nil
		}
		live := s.deps.StreamHub.Subscribe(edge.UUID, edge.CreatedAt, afterSeq)
		history, err := s.deps.StreamStore.ListAfter(ctx, tenantID, edge.UUID, edge.CreatedAt, afterSeq, a2aStreamBufferLimit)
		if err != nil {
			live.Cancel()
			return nil, A2AStreamSubscription{}, err
		}
		return edge, s.combineA2AStreamSources(ctx, tenantID, edge.UUID, edge.CreatedAt, history, live), nil
	}
	if isA2ATerminal(edge.Status) {
		return edge, closedA2AStreamSubscription([]A2AStreamEvent{terminalStreamEvent(edge)}), nil
	}
	return edge, s.deps.StreamHub.Subscribe(edge.UUID, edge.CreatedAt, afterSeq), nil
}

func closedA2AStreamSubscription(events []A2AStreamEvent) A2AStreamSubscription {
	ch := make(chan A2AStreamEvent, len(events))
	for _, ev := range events {
		ch <- ev
	}
	close(ch)
	return A2AStreamSubscription{Events: ch, Cancel: func() {}}
}

func (s *Service) combineA2AStreamSources(ctx context.Context, tenantID int64, edgeUUID string, edgeCreatedAt time.Time, history []A2AStreamEvent, live A2AStreamSubscription) A2AStreamSubscription {
	out := make(chan A2AStreamEvent, a2aStreamBufferLimit+32)
	done := make(chan struct{})
	var once sync.Once
	go func() {
		defer close(out)
		maxSeq := int64(0)
		for _, ev := range history {
			if ev.Seq > maxSeq {
				maxSeq = ev.Seq
			}
			if emitA2AStreamEvent(done, out, ev) {
				return
			}
		}
		ticker := time.NewTicker(a2aStreamStorePollInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-done:
				return
			case ev, ok := <-live.Events:
				if !ok {
					return
				}
				if ev.Event == "a2a.wake" {
					if s.drainA2AStreamStore(ctx, done, out, tenantID, edgeUUID, edgeCreatedAt, &maxSeq) {
						return
					}
					continue
				}
				if emitA2AStreamIfNew(done, out, ev, &maxSeq) {
					return
				}
			case <-ticker.C:
				if s.drainA2AStreamStore(ctx, done, out, tenantID, edgeUUID, edgeCreatedAt, &maxSeq) {
					return
				}
			}
		}
	}()
	return A2AStreamSubscription{
		Events: out,
		Cancel: func() {
			once.Do(func() {
				close(done)
				live.Cancel()
			})
		},
	}
}

func (s *Service) drainA2AStreamStore(ctx context.Context, done <-chan struct{}, out chan<- A2AStreamEvent, tenantID int64, edgeUUID string, edgeCreatedAt time.Time, maxSeq *int64) bool {
	if s == nil || s.deps.StreamStore == nil || maxSeq == nil {
		return false
	}
	events, err := s.deps.StreamStore.ListAfter(ctx, tenantID, edgeUUID, edgeCreatedAt, *maxSeq, a2aStreamBufferLimit)
	if err != nil {
		return false
	}
	for _, ev := range events {
		if emitA2AStreamIfNew(done, out, ev, maxSeq) {
			return true
		}
	}
	return false
}

func emitA2AStreamIfNew(done <-chan struct{}, out chan<- A2AStreamEvent, ev A2AStreamEvent, maxSeq *int64) bool {
	if ev.Seq > 0 && maxSeq != nil {
		if ev.Seq <= *maxSeq {
			return false
		}
		*maxSeq = ev.Seq
	}
	return emitA2AStreamEvent(done, out, ev)
}

func emitA2AStreamEvent(done <-chan struct{}, out chan<- A2AStreamEvent, ev A2AStreamEvent) bool {
	select {
	case <-done:
		return true
	case out <- ev:
		return isA2AStreamTerminalEvent(ev)
	}
}

func isA2AStreamTerminalEvent(ev A2AStreamEvent) bool {
	switch ev.Event {
	case "a2a.done", "a2a.failed", "a2a.cancelled", "a2a.rejected", "a2a.expired", "a2a.awaiting_approval":
		return true
	default:
		return false
	}
}

func isA2ATerminal(st doma2a.Status) bool {
	switch st {
	case doma2a.StatusDone, doma2a.StatusFailed, doma2a.StatusCancelled, doma2a.StatusRejected, doma2a.StatusExpired, doma2a.StatusAwaitingApproval:
		return true
	default:
		return false
	}
}

func terminalStreamEvent(edge *doma2a.Edge) A2AStreamEvent {
	ev := A2AStreamEvent{
		EdgeUUID:        edge.UUID,
		EdgeCreatedAt:   edge.CreatedAt,
		Status:          edge.Status,
		ErrorMessage:    edge.ErrorMessage,
		ResponsePayload: edge.ResponsePayload,
	}
	switch edge.Status {
	case doma2a.StatusDone:
		ev.Event = "a2a.done"
	case doma2a.StatusAwaitingApproval:
		ev.Event = "a2a.awaiting_approval"
	case doma2a.StatusCancelled:
		ev.Event = "a2a.cancelled"
	case doma2a.StatusRejected:
		ev.Event = "a2a.rejected"
	case doma2a.StatusExpired:
		ev.Event = "a2a.expired"
	default:
		ev.Event = "a2a.failed"
	}
	return ev
}
