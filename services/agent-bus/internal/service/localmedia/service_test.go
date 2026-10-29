package localmedia

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localmedia"
	local "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

type memoryRepo struct {
	mu  sync.Mutex
	rec *dom.Record
}

func (r *memoryRepo) Claim(_ context.Context, _ *local.Task, id, digest string) (*dom.Record, bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.rec != nil {
		if r.rec.ID == id && r.rec.Digest != digest {
			return nil, false, dom.ErrConflict
		}
		out := *r.rec
		return &out, false, nil
	}
	r.rec = &dom.Record{ID: id, Digest: digest, State: "submitting"}
	out := *r.rec
	return &out, true, nil
}
func (r *memoryRepo) Complete(_ context.Context, _ *local.Task, _ string, b []byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.rec.State = "completed"
	r.rec.Image = b
	return nil
}
func (r *memoryRepo) Uncertain(_ context.Context, _ *local.Task, _ string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.rec.State = "unknown"
	return nil
}
func (r *memoryRepo) ExpireResults(context.Context) error { return nil }
func (r *memoryRepo) Reject(_ context.Context, _ *local.Task, _ string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.rec.State = "failed"
	return nil
}

type fakeProvider struct {
	calls  atomic.Int32
	submit func(context.Context) (*http.Response, error)
}

func (p *fakeProvider) PrepareLocalImage(_ context.Context, _ *local.Task, _ dom.Request) (func(context.Context) (*http.Response, error), error) {
	return func(ctx context.Context) (*http.Response, error) { p.calls.Add(1); return p.submit(ctx) }, nil
}
func fixturePNG() []byte {
	m := image.NewRGBA(image.Rect(0, 0, 2, 2))
	m.Set(0, 0, color.RGBA{20, 100, 200, 255})
	var b bytes.Buffer
	_ = png.Encode(&b, m)
	return b.Bytes()
}
func imageResponse(data []byte) *http.Response {
	b, _ := json.Marshal(map[string]any{"data": []any{map[string]any{"b64_json": data}}})
	return &http.Response{StatusCode: 200, Body: io.NopCloser(bytes.NewReader(b))}
}
func request() dom.Request {
	return dom.Request{OperationID: strings.Repeat("a", 64), Model: "gpt-image-2.5", Prompt: "blue office", Size: "1024x1024"}
}
func TestImageConcurrentReplayAndConflict(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	p := &fakeProvider{submit: func(context.Context) (*http.Response, error) {
		close(entered)
		<-release
		return imageResponse(fixturePNG()), nil
	}}
	s := New(&memoryRepo{}, p)
	ctx := context.Background()
	task := &local.Task{}
	result := make(chan error, 1)
	go func() { _, err := s.Generate(ctx, task, request()); result <- err }()
	<-entered
	if _, err := s.Generate(ctx, task, request()); !errors.Is(err, dom.ErrUnknown) {
		t.Fatal(err)
	}
	close(release)
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	b, err := s.Generate(ctx, task, request())
	if err != nil || len(b) == 0 {
		t.Fatal(err)
	}
	in := request()
	in.Prompt = "different"
	if _, err = s.Generate(ctx, task, in); !errors.Is(err, dom.ErrConflict) {
		t.Fatal(err)
	}
	if p.calls.Load() != 1 {
		t.Fatal("duplicate provider charge")
	}
}
func TestImageUncertainNeverRetries(t *testing.T) {
	for _, kind := range []string{"timeout", "status", "invalid", "cancel"} {
		t.Run(kind, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			p := &fakeProvider{submit: func(context.Context) (*http.Response, error) {
				switch kind {
				case "timeout":
					return nil, io.ErrUnexpectedEOF
				case "status":
					return &http.Response{StatusCode: 500, Body: io.NopCloser(strings.NewReader("secret-provider-error"))}, nil
				case "cancel":
					cancel()
					return imageResponse(fixturePNG()), nil
				default:
					return imageResponse([]byte("not an image")), nil
				}
			}}
			s := New(&memoryRepo{}, p)
			if _, err := s.Generate(ctx, &local.Task{}, request()); err == nil || strings.Contains(err.Error(), "secret") {
				t.Fatal(err)
			}
			if _, err := s.Generate(context.Background(), &local.Task{}, request()); err == nil {
				t.Fatal("retried uncertain")
			}
			if p.calls.Load() != 1 {
				t.Fatal("duplicate submission")
			}
		})
	}
}

func TestImageRejectionReplaysWithoutResubmitting(t *testing.T) {
	for _, status := range []int{400, 401, 403, 404, 422, 429} {
		p := &fakeProvider{submit: func(context.Context) (*http.Response, error) {
			return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader("private upstream body"))}, nil
		}}
		r := &memoryRepo{}
		for i := 0; i < 2; i++ {
			// New service instance uses the durable result, without calling upstream.
			if _, err := New(r, p).Generate(context.Background(), &local.Task{}, request()); !errors.Is(err, dom.ErrRejected) {
				t.Fatalf("status %d: %v", status, err)
			}
		}
		if p.calls.Load() != 1 || r.rec.State != "failed" {
			t.Fatal("rejection retried or not recorded")
		}
	}
}
func TestImageRejectsInvalidRequestsBeforeProvider(t *testing.T) {
	p := &fakeProvider{}
	s := New(&memoryRepo{}, p)
	for _, change := range []func(*dom.Request){func(r *dom.Request) { r.Model = "https://host?key=secret" }, func(r *dom.Request) { r.Size = "999999x999999" }, func(r *dom.Request) { r.Prompt = "" }, func(r *dom.Request) { r.OperationID = "bad" }} {
		in := request()
		change(&in)
		if _, err := s.Generate(context.Background(), &local.Task{}, in); !errors.Is(err, dom.ErrInvalid) {
			t.Fatal(err)
		}
	}
	if p.calls.Load() != 0 {
		t.Fatal("called provider")
	}
}
func TestImageRejectsTruncatedImageAndURL(t *testing.T) {
	b := fixturePNG()
	r := imageResponse(b[:len(b)-14])
	if _, err := decodeImage(r.Body); !errors.Is(err, dom.ErrInvalid) {
		t.Fatal(err)
	}
	if _, err := decodeImage(strings.NewReader(`{"data":[{"url":"http://127.0.0.1/private"}]}`)); !errors.Is(err, dom.ErrInvalid) {
		t.Fatal(err)
	}
}

func TestImageReplayDoesNotRequireAnotherCreditCharge(t *testing.T) {
	p := &fakeProvider{submit: func(context.Context) (*http.Response, error) { return imageResponse(fixturePNG()), nil }}
	s := New(&memoryRepo{}, p)
	ctx := context.Background()
	checks := 0
	check := func(context.Context) error {
		checks++
		if checks > 1 {
			return dom.ErrCredits
		}
		return nil
	}
	if _, err := s.Generate(ctx, &local.Task{}, request(), check); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Generate(ctx, &local.Task{}, request(), check); err != nil {
		t.Fatal("completed image blocked after credits depleted", err)
	}
	if checks != 1 || p.calls.Load() != 1 {
		t.Fatal("replayed result recharged")
	}
}
