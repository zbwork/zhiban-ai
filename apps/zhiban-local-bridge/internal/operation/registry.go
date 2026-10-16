// Package operation is the session-local operation model shared by long
// running Bridge methods (install.execute, verify.execute). Every operation
// returns a contract §2.5 envelope immediately and is polled through
// operation.get until it reaches a terminal state. Operations only live inside
// the current stdio session: Shutdown cancels everything still running.
package operation

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"io"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	StateRunning   = "running"
	StateSucceeded = "succeeded"
	StateFailed    = "failed"
	StateCancelled = "cancelled"

	ProgressDeterminate   = "determinate"
	ProgressIndeterminate = "indeterminate"

	KindInstall = "install"
	KindVerify  = "verify"

	operationIDBytes = 22
	maxRetained      = 64
)

var (
	ErrInvalidInput = errors.New("operation: invalid input")
	ErrBusy         = errors.New("operation: target busy")
	ErrNotFound     = errors.New("operation: not found")
	ErrClosed       = errors.New("operation: registry closed")

	safeValuePattern = regexp.MustCompile(`^[0-9A-Za-z._+-]{1,128}$`)
)

// Envelope is the contract §2.5 write-operation result.
type Envelope struct {
	OperationID   string  `json:"operation_id"`
	TargetID      string  `json:"target_id"`
	Kind          string  `json:"kind"`
	State         string  `json:"state"`
	Stage         string  `json:"stage"`
	ProgressKind  string  `json:"progress_kind"`
	ProgressValue *int    `json:"progress_value"`
	Cancellable   bool    `json:"cancellable"`
	ErrorCode     *string `json:"error_code"`
	// ErrorDetail is the gateway's own answer to a failed verification
	// ("HTTP 503 · <relay message>", secrets redacted; contract §2.7
	// verify.execute). Only failed envelopes may carry it.
	ErrorDetail *string  `json:"error_detail,omitempty"`
	TraceID     *string  `json:"trace_id"`
	NextActions []string `json:"next_actions"`
	Result      any      `json:"result,omitempty"`
}

// Failure carries a contract §6 error code out of a RunFunc.
type Failure struct {
	Code string
	// Detail becomes Envelope.ErrorDetail; the RunFunc must have redacted it.
	Detail string
	Err    error
}

func (f *Failure) Error() string {
	if f.Err != nil {
		return f.Code + ": " + f.Err.Error()
	}
	return f.Code
}

func (f *Failure) Unwrap() error { return f.Err }

// Fail wraps err with a contract error code.
func Fail(code string, err error) error {
	return &Failure{Code: code, Err: err}
}

// FailDetail is Fail with a user-visible detail (see Envelope.ErrorDetail).
func FailDetail(code, detail string, err error) error {
	return &Failure{Code: code, Detail: detail, Err: err}
}

// Reporter lets a RunFunc publish stage and progress transitions.
type Reporter struct {
	registry *Registry
	id       string
}

// Stage moves the operation to an indeterminate stage.
func (r *Reporter) Stage(stage string, cancellable bool) {
	r.registry.update(r.id, func(record *record) {
		record.envelope.Stage = stage
		record.envelope.ProgressKind = ProgressIndeterminate
		record.envelope.ProgressValue = nil
		record.envelope.Cancellable = cancellable
	})
}

// Progress moves the operation to a determinate stage at percent (0..100).
func (r *Reporter) Progress(stage string, percent int, cancellable bool) {
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	r.registry.update(r.id, func(record *record) {
		value := percent
		record.envelope.Stage = stage
		record.envelope.ProgressKind = ProgressDeterminate
		record.envelope.ProgressValue = &value
		record.envelope.Cancellable = cancellable
	})
}

// Cancelled reports whether operation.cancel has been requested.
func (r *Reporter) Cancelled() bool {
	return r.registry.cancelRequested(r.id)
}

// RunFunc executes an operation. Returning a *Failure sets the failed state
// with its code; returning ctx.Err() after a cancel request sets cancelled;
// any other error fails with Spec.FailureCode.
type RunFunc func(ctx context.Context, report *Reporter) (any, error)

// Spec describes an operation to start.
type Spec struct {
	TargetID     string
	Kind         string
	InitialStage string
	Cancellable  bool
	CancelCode   string
	FailureCode  string
	Run          RunFunc
	Cleanup      func()
}

// Event is delivered to the observer when an operation reaches a terminal state.
type Event struct {
	Envelope Envelope
	At       time.Time
}

type record struct {
	envelope        Envelope
	cancel          context.CancelFunc
	cancelRequested bool
	createdAt       time.Time
	finishedAt      time.Time
	done            chan struct{}
}

// Registry owns every operation of one Bridge session.
type Registry struct {
	baseCtx    context.Context
	baseCancel context.CancelFunc
	random     io.Reader
	now        func() time.Time
	observer   func(Event)

	mu      sync.Mutex
	closed  bool
	items   map[string]*record
	order   []string
	running map[string]string
	wg      sync.WaitGroup
}

// Option customises a Registry.
type Option func(*Registry)

// WithObserver receives terminal transitions (used by diagnostics). The
// observer is invoked while the registry lock is held and must not call back
// into the registry.
func WithObserver(observer func(Event)) Option {
	return func(r *Registry) { r.observer = observer }
}

// WithClock overrides time.Now (tests).
func WithClock(now func() time.Time) Option {
	return func(r *Registry) { r.now = now }
}

// WithRandom overrides the operation id source (tests).
func WithRandom(random io.Reader) Option {
	return func(r *Registry) { r.random = random }
}

// NewRegistry creates an empty registry.
func NewRegistry(options ...Option) *Registry {
	ctx, cancel := context.WithCancel(context.Background())
	registry := &Registry{
		baseCtx: ctx, baseCancel: cancel, random: rand.Reader, now: time.Now,
		items: make(map[string]*record), running: make(map[string]string),
	}
	for _, option := range options {
		option(registry)
	}
	return registry
}

// Start launches spec in the background and returns its initial envelope.
func (r *Registry) Start(spec Spec) (Envelope, error) {
	if !safeValuePattern.MatchString(spec.TargetID) || spec.Kind == "" || spec.InitialStage == "" ||
		spec.Run == nil || spec.CancelCode == "" || spec.FailureCode == "" {
		return Envelope{}, ErrInvalidInput
	}
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return Envelope{}, ErrClosed
	}
	if _, busy := r.running[spec.TargetID]; busy {
		r.mu.Unlock()
		return Envelope{}, ErrBusy
	}
	id, err := r.newIDLocked()
	if err != nil {
		r.mu.Unlock()
		return Envelope{}, err
	}
	ctx, cancel := context.WithCancel(r.baseCtx)
	item := &record{
		envelope: Envelope{
			OperationID: id, TargetID: spec.TargetID, Kind: spec.Kind, State: StateRunning,
			Stage: spec.InitialStage, ProgressKind: ProgressIndeterminate, Cancellable: spec.Cancellable,
			NextActions: nextActions(StateRunning, spec.Cancellable),
		},
		cancel: cancel, createdAt: r.now().UTC(), done: make(chan struct{}),
	}
	r.items[id] = item
	r.order = append(r.order, id)
	r.running[spec.TargetID] = id
	r.pruneLocked()
	r.wg.Add(1)
	envelope := cloneEnvelope(item.envelope)
	r.mu.Unlock()

	go r.run(ctx, id, spec)
	return envelope, nil
}

func (r *Registry) run(ctx context.Context, id string, spec Spec) {
	defer r.wg.Done()
	result, err := r.safeRun(ctx, spec.Run, &Reporter{registry: r, id: id})
	if spec.Cleanup != nil {
		spec.Cleanup()
	}

	r.mu.Lock()
	item := r.items[id]
	item.cancel()
	item.envelope.Cancellable = false
	item.envelope.ProgressKind = ProgressIndeterminate
	item.envelope.ProgressValue = nil
	switch {
	case err == nil:
		item.envelope.State = StateSucceeded
		item.envelope.Result = result
	case item.cancelRequested && (errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)):
		item.envelope.State = StateCancelled
		item.envelope.ErrorCode = stringPointer(spec.CancelCode)
	default:
		var failure *Failure
		code := spec.FailureCode
		if errors.As(err, &failure) && safeErrorCode(failure.Code) {
			code = failure.Code
			if detail := boundedDetail(failure.Detail); detail != "" {
				item.envelope.ErrorDetail = stringPointer(detail)
			}
		}
		item.envelope.State = StateFailed
		item.envelope.ErrorCode = stringPointer(code)
	}
	item.envelope.NextActions = nextActions(item.envelope.State, false)
	item.finishedAt = r.now().UTC()
	if r.running[spec.TargetID] == id {
		delete(r.running, spec.TargetID)
	}
	// The observer runs under the registry lock so a diagnostics record is
	// visible before operation.get can return the terminal envelope. Observers
	// must not call back into the registry.
	if r.observer != nil {
		r.observer(Event{Envelope: cloneEnvelope(item.envelope), At: item.finishedAt})
	}
	close(item.done)
	r.mu.Unlock()
}

func (r *Registry) safeRun(ctx context.Context, run RunFunc, report *Reporter) (result any, err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			result = nil
			err = errors.New("operation: run panicked")
		}
	}()
	return run(ctx, report)
}

// Get returns the current envelope for id.
func (r *Registry) Get(id string) (Envelope, error) {
	if !safeValuePattern.MatchString(id) {
		return Envelope{}, ErrInvalidInput
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	item, ok := r.items[id]
	if !ok {
		return Envelope{}, ErrNotFound
	}
	return cloneEnvelope(item.envelope), nil
}

// Cancel requests cancellation when the operation is still cancellable and
// returns the current envelope either way.
func (r *Registry) Cancel(id string) (Envelope, error) {
	if !safeValuePattern.MatchString(id) {
		return Envelope{}, ErrInvalidInput
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	item, ok := r.items[id]
	if !ok {
		return Envelope{}, ErrNotFound
	}
	if item.envelope.State == StateRunning && item.envelope.Cancellable && !item.cancelRequested {
		item.cancelRequested = true
		item.cancel()
	}
	return cloneEnvelope(item.envelope), nil
}

// Latest returns the most recently started operation for targetID.
func (r *Registry) Latest(targetID string) (Envelope, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for index := len(r.order) - 1; index >= 0; index-- {
		item, ok := r.items[r.order[index]]
		if ok && item.envelope.TargetID == targetID {
			return cloneEnvelope(item.envelope), true
		}
	}
	return Envelope{}, false
}

// Running reports whether targetID has an operation in progress.
func (r *Registry) Running(targetID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, busy := r.running[targetID]
	return busy
}

// Shutdown cancels every running operation and waits up to timeout for their
// cleanup hooks. Further Start calls fail with ErrClosed.
func (r *Registry) Shutdown(timeout time.Duration) bool {
	r.mu.Lock()
	r.closed = true
	for _, id := range r.running {
		if item, ok := r.items[id]; ok {
			item.cancelRequested = true
		}
	}
	r.mu.Unlock()
	r.baseCancel()

	finished := make(chan struct{})
	go func() {
		r.wg.Wait()
		close(finished)
	}()
	select {
	case <-finished:
		return true
	case <-time.After(timeout):
		return false
	}
}

// Wait blocks until the operation reaches a terminal state (tests and
// session shutdown helpers).
func (r *Registry) Wait(ctx context.Context, id string) (Envelope, error) {
	r.mu.Lock()
	item, ok := r.items[id]
	r.mu.Unlock()
	if !ok {
		return Envelope{}, ErrNotFound
	}
	select {
	case <-item.done:
		return r.Get(id)
	case <-ctx.Done():
		return Envelope{}, ctx.Err()
	}
}

func (r *Registry) update(id string, apply func(*record)) {
	r.mu.Lock()
	defer r.mu.Unlock()
	item, ok := r.items[id]
	if !ok || item.envelope.State != StateRunning {
		return
	}
	apply(item)
	item.envelope.NextActions = nextActions(StateRunning, item.envelope.Cancellable)
}

func (r *Registry) cancelRequested(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	item, ok := r.items[id]
	return ok && item.cancelRequested
}

func (r *Registry) newIDLocked() (string, error) {
	for attempt := 0; attempt < 4; attempt++ {
		value := make([]byte, operationIDBytes)
		if _, err := io.ReadFull(r.random, value); err != nil {
			return "", errors.Join(ErrInvalidInput, err)
		}
		id := base64.RawURLEncoding.EncodeToString(value)
		if _, exists := r.items[id]; !exists {
			return id, nil
		}
	}
	return "", ErrInvalidInput
}

// pruneLocked drops the oldest finished operations beyond maxRetained so a
// long session cannot grow without bound.
func (r *Registry) pruneLocked() {
	if len(r.order) <= maxRetained {
		return
	}
	kept := r.order[:0]
	excess := len(r.order) - maxRetained
	for _, id := range r.order {
		item := r.items[id]
		if excess > 0 && item.envelope.State != StateRunning {
			delete(r.items, id)
			excess--
			continue
		}
		kept = append(kept, id)
	}
	r.order = kept
}

func nextActions(state string, cancellable bool) []string {
	switch state {
	case StateRunning:
		if cancellable {
			return []string{"cancel"}
		}
		return []string{}
	case StateSucceeded:
		return []string{"detect"}
	case StateFailed:
		return []string{"retry", "diagnostics"}
	case StateCancelled:
		return []string{"retry"}
	default:
		return []string{}
	}
}

func cloneEnvelope(value Envelope) Envelope {
	clone := value
	if value.ProgressValue != nil {
		progress := *value.ProgressValue
		clone.ProgressValue = &progress
	}
	if value.ErrorCode != nil {
		code := *value.ErrorCode
		clone.ErrorCode = &code
	}
	if value.ErrorDetail != nil {
		detail := *value.ErrorDetail
		clone.ErrorDetail = &detail
	}
	if value.TraceID != nil {
		trace := *value.TraceID
		clone.TraceID = &trace
	}
	clone.NextActions = append([]string{}, value.NextActions...)
	return clone
}

func stringPointer(value string) *string {
	return &value
}

// maxErrorDetailBytes bounds Envelope.ErrorDetail whatever the producer did.
const maxErrorDetailBytes = 1024

func boundedDetail(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > maxErrorDetailBytes || !utf8.ValidString(value) {
		return ""
	}
	return value
}

func safeErrorCode(value string) bool {
	return len(value) > 0 && len(value) <= 96 && safeValuePattern.MatchString(value)
}
