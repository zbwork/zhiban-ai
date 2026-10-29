package localmedia

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"image"
	_ "image/jpeg"
	"image/png"
	"io"
	"regexp"
	"strings"
	"time"

	dom "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localmedia"
	local "github.com/zbwork/zhiban-ai/services/agent-bus/internal/domain/localruntime"
)

type Service struct {
	repo     dom.Repository
	provider dom.Provider
}

func New(repo dom.Repository, provider dom.Provider) *Service { return &Service{repo, provider} }

var identifier = regexp.MustCompile(`^[a-f0-9]{64}$`)
var modelName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$`)

func (s *Service) Generate(ctx context.Context, task *local.Task, input dom.Request, beforeSubmit ...func(context.Context) error) ([]byte, error) {
	if ctx.Err() != nil {
		return nil, dom.ErrUnknown
	}
	if task == nil || !identifier.MatchString(input.OperationID) || !modelName.MatchString(input.Model) || strings.TrimSpace(input.Prompt) == "" || len(input.Prompt) > 16000 {
		return nil, dom.ErrInvalid
	}
	switch input.Size {
	case "1024x1024", "1536x1024", "1024x1536":
	default:
		return nil, dom.ErrInvalid
	}
	// Never include local file paths in request identity. Retry with a new output path is still the same paid operation.
	canonical, _ := json.Marshal([]string{input.Model, input.Prompt, input.Size})
	digest := sha256.Sum256(canonical)
	submit, err := s.provider.PrepareLocalImage(ctx, task, input)
	if err != nil {
		return nil, err
	}
	rec, claimed, err := s.repo.Claim(ctx, task, input.OperationID, hex.EncodeToString(digest[:]))
	if err != nil {
		return nil, err
	}
	if !claimed {
		if rec.State == "failed" {
			return nil, dom.ErrRejected
		}
		if rec.State == "completed" && len(rec.Image) > 0 {
			return rec.Image, nil
		}
		return nil, dom.ErrUnknown
	}
	if len(beforeSubmit) > 0 && beforeSubmit[0] != nil {
		if err := beforeSubmit[0](ctx); err != nil {
			_ = s.repo.Uncertain(ctx, task, rec.ID)
			return nil, dom.ErrCredits
		}
	}
	// Claim is durable before touching the provider. Even a crash leaves a non-retryable tombstone.
	response, err := submit(ctx)
	var result []byte
	if err == nil && response != nil {
		defer response.Body.Close()
		switch response.StatusCode {
		case 400, 401, 403, 404, 422, 429:
			// Definitive rejection is not an in-flight generation. Retain the tombstone:
			// neither retries nor a changed operation ID may issue another paid request.
			if err := s.repo.Reject(ctx, task, rec.ID); err != nil {
				return nil, dom.ErrUnknown
			}
			return nil, dom.ErrRejected
		}
		if response.StatusCode >= 200 && response.StatusCode < 300 {
			result, err = decodeImage(response.Body)
		} else {
			err = dom.ErrUnavailable
		}
	}
	if err != nil || len(result) == 0 || ctx.Err() != nil {
		// A cancelled context may prevent this update; submitting is equally non-retryable.
		_ = s.repo.Uncertain(ctx, task, rec.ID)
		if ctx.Err() != nil {
			return nil, dom.ErrUnknown
		}
		if err == dom.ErrInvalid {
			return nil, dom.ErrInvalid
		}
		return nil, dom.ErrUnknown
	}
	if err = s.repo.Complete(ctx, task, rec.ID, result); err != nil {
		return nil, dom.ErrUnknown
	}
	return result, nil
}
func (s *Service) Expire(ctx context.Context) error { return s.repo.ExpireResults(ctx) }

// Decode the full image (not just its magic header) after bounding compressed bytes and dimensions.
func decodeImage(body io.Reader) ([]byte, error) {
	raw, err := io.ReadAll(io.LimitReader(body, 17<<20))
	if err != nil || len(raw) >= 17<<20 {
		return nil, dom.ErrInvalid
	}
	var response struct {
		Data []struct {
			B64 []byte `json:"b64_json"`
		} `json:"data"`
	}
	if json.Unmarshal(raw, &response) != nil || len(response.Data) != 1 {
		return nil, dom.ErrInvalid
	}
	data := response.Data[0].B64
	if len(data) == 0 || len(data) > dom.MaxImageBytes {
		return nil, dom.ErrInvalid
	}
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || (format != "png" && format != "jpeg") || cfg.Width <= 0 || cfg.Height <= 0 || int64(cfg.Width)*int64(cfg.Height) > 16_000_000 {
		return nil, dom.ErrInvalid
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, dom.ErrInvalid
	}
	var out bytes.Buffer
	if err = png.Encode(&out, img); err != nil || out.Len() > dom.MaxImageBytes {
		return nil, dom.ErrInvalid
	}
	return out.Bytes(), nil
}

// Kept in this package so HTTP callers use the same bounded provider duration.
const Timeout = 5 * time.Minute
