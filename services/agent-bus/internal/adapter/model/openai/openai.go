// Package openai implements the OpenAI-compatible model data plane used by BeeBridge.
// Management PATs must never be passed as model credentials.
package openai

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/adapter/model"
	"github.com/zbwork/zhiban-ai/services/agent-bus/internal/pkg/httpcli"
)

type Provider struct {
	baseURL        string
	token          string
	model          string
	embeddingModel string
	client         *http.Client
}

// New 构造 OpenAI-compatible provider。
func New(baseURL, token, defaultModel string, timeoutSec int) *Provider {
	client := httpcli.New(time.Duration(timeoutSec) * time.Second)
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &Provider{
		baseURL: normalizeBaseURL(baseURL),
		token:   token,
		model:   defaultModel,
		client:  client,
	}
}

func (p *Provider) Name() string { return "openai_compatible" }

// SetEmbeddingModel 配置 OpenAI-compatible /v1/embeddings 使用的默认模型。
func (p *Provider) SetEmbeddingModel(model string) {
	p.embeddingModel = strings.TrimSpace(model)
}

func normalizeBaseURL(baseURL string) string {
	base := strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if strings.HasSuffix(base, "/v1") {
		return strings.TrimRight(strings.TrimSuffix(base, "/v1"), "/")
	}
	return base
}

func (p *Provider) StreamChat(ctx context.Context, req model.ChatRequest) (model.Stream, error) {
	if p.baseURL == "" || p.token == "" {
		return nil, errors.New("model base_url or API key not configured")
	}
	if req.Model == "" {
		req.Model = p.model
	}
	req.Stream = true
	req.Metadata = nil // Local attribution is not a BeeBridge billing contract.
	body, _ := json.Marshal(req)
	httpReq, err := http.NewRequestWithContext(ctx, "POST", p.baseURL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+p.token)
	httpReq.Header.Set("Accept", "text/event-stream")
	httpReq.Header.Set("User-Agent", "agent-bus/0.1 (+go-http-client)")
	resp, err := p.client.Do(httpReq)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		resp.Body.Close()
		return nil, fmt.Errorf("model gateway HTTP %d", resp.StatusCode)
	}
	return &stream{body: resp.Body, sc: bufio.NewScanner(resp.Body)}, nil
}

func (p *Provider) Embed(ctx context.Context, req model.EmbeddingRequest) (*model.EmbeddingResponse, error) {
	if p.baseURL == "" || p.token == "" {
		return nil, errors.New("model base_url or API key not configured")
	}
	if len(req.Input) == 0 {
		return &model.EmbeddingResponse{Embeddings: [][]float64{}}, nil
	}
	if req.Model == "" {
		req.Model = p.embeddingModel
	}
	if req.Model == "" {
		return nil, errors.New("model gateway embedding model not configured")
	}
	req.Metadata = nil // Local attribution is not a BeeBridge billing contract.
	body, _ := json.Marshal(req)
	httpReq, err := http.NewRequestWithContext(ctx, "POST", p.baseURL+"/v1/embeddings", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+p.token)
	httpReq.Header.Set("User-Agent", "agent-bus/0.1 (+go-http-client)")
	resp, err := p.client.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("model gateway embeddings HTTP %d", resp.StatusCode)
	}
	var parsed struct {
		Data []struct {
			Index     int       `json:"index"`
			Embedding []float64 `json:"embedding"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return nil, err
	}
	out := make([][]float64, len(req.Input))
	for _, item := range parsed.Data {
		if item.Index < 0 || item.Index >= len(out) {
			continue
		}
		out[item.Index] = append([]float64(nil), item.Embedding...)
	}
	for i := range out {
		if len(out[i]) == 0 {
			return nil, fmt.Errorf("model gateway embeddings response missing vector at index %d", i)
		}
	}
	return &model.EmbeddingResponse{Embeddings: out}, nil
}

type stream struct {
	done bool
	body io.ReadCloser
	sc   *bufio.Scanner
}

type chunkResp struct {
	Choices []struct {
		Delta struct {
			Content string `json:"content"`
		} `json:"delta"`
		FinishReason *string `json:"finish_reason"`
	} `json:"choices"`
}

func (s *stream) Recv() (model.ChatChunk, error) {
	if s.done {
		return model.ChatChunk{}, io.EOF
	}
	for s.sc.Scan() {
		line := s.sc.Text()
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		raw := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if raw == "" {
			continue
		}
		if raw == "[DONE]" {
			s.done = true
			return model.ChatChunk{Done: true}, nil
		}
		var c chunkResp
		if err := json.Unmarshal([]byte(raw), &c); err != nil {
			return model.ChatChunk{Err: err}, nil
		}
		if len(c.Choices) > 0 {
			ch := c.Choices[0]
			done := ch.FinishReason != nil && *ch.FinishReason != ""
			s.done = done
			return model.ChatChunk{Delta: ch.Delta.Content, Done: done}, nil
		}
	}
	if err := s.sc.Err(); err != nil {
		return model.ChatChunk{}, err
	}
	return model.ChatChunk{}, io.ErrUnexpectedEOF
}

func (s *stream) Close() error { return s.body.Close() }
