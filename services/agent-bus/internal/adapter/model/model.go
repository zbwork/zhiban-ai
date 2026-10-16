package model

import "context"

// ChatMessage OpenAI 兼容格式。
type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// ChatRequest 简化的聊天请求。
type ChatRequest struct {
	Model    string         `json:"model"`
	Messages []ChatMessage  `json:"messages"`
	Stream   bool           `json:"stream"`
	Metadata map[string]any `json:"-"`
}

// EmbeddingRequest OpenAI 兼容 embedding 请求。
type EmbeddingRequest struct {
	Model    string         `json:"model"`
	Input    []string       `json:"input"`
	Metadata map[string]any `json:"-"`
}

// EmbeddingResponse 是 embedding 供应商返回的向量集合。
type EmbeddingResponse struct {
	Embeddings [][]float64
}

// ChatChunk 流式响应的一个 chunk。
type ChatChunk struct {
	Delta string
	Done  bool
	Err   error
}

// Stream 是模型响应流。
type Stream interface {
	Recv() (ChatChunk, error)
	Close() error
}

// Provider 是 LLM 供应商抽象。
type Provider interface {
	Name() string
	StreamChat(ctx context.Context, req ChatRequest) (Stream, error)
}

// Embedder 是可选的 embedding 能力。不是所有 LLM provider 都必须实现。
type Embedder interface {
	Name() string
	Embed(ctx context.Context, req EmbeddingRequest) (*EmbeddingResponse, error)
}
